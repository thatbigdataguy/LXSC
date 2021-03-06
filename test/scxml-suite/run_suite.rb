#!/usr/bin/env ruby
#encoding: utf-8
BASE   = 'http://www.w3.org/Voice/2013/SCXML-irp/'
CACHE  = 'spec-cache'
REPORT = 'scxml10-ir-results-lxsc.xml'

require 'uri'
require 'fileutils'
require 'nokogiri' # gem install nokogiri

def run!
	Dir.chdir(File.dirname(__FILE__)) do
		FileUtils.mkdir_p CACHE
		@manifest = Nokogiri.XML( get_file('manifest.xml'), &:noblanks )
		@mod      = Nokogiri.XML(IO.read('manifest-mod.xml'))
		@report   = Nokogiri.XML(IO.read(REPORT),&:noblanks)
		run_tests
		File.open(REPORT,'w'){ |f| f<<@report }
	end
end

def run_tests
	Dir['*.scxml'].each{ |f| File.delete(f) }
	Dir['*.txml' ].each{ |f| File.delete(f) }
	FileUtils.rm_f('luacov.stats.out')
	@report.xpath('//assert').remove

	tests = @manifest.xpath('//test')
	required = tests.reject{ |t| t['conformance']=='optional' }
	required.sort_by{ |test| [test['manual']=='false' ? 0 : 1,test['id']] }.each.with_index do |test,i|
		id    = test['id']
		auto  = test['manual']=='false'
		start = test.at('start')
		uri   = start['uri']

		print "Test ##{i+1}/#{required.length} #{uri} (#{auto ? :auto : :manual}): " 

		scxml = prepare_scxml(uri)
		# Fetch dependent files, copy to working directory
		test.xpath('dep').each{ |d| File.open(File.basename(d['uri']),'w'){ |f| f<<get_file(d['uri']) } }

		if mod=@mod.at("//assert[@id='#{id}']")
			@report.root << mod
			# Destroy local copies of dependent files
			test.xpath('dep').each{ |d| FileUtils.rm_f(File.basename d['uri']) }
			if auto
				FileUtils.rm_f(scxml)
				puts "skip #{mod['res']}"
			else
				puts "trace"
				system("lua autotest.lua #{scxml} --trace")
			end
		elsif auto
			if system("lua autotest.lua #{scxml}")
				@report.root << "<assert id='#{id}' res='pass'/>"
				# Destroy local copies of dependent files
				test.xpath('dep').each{ |d| FileUtils.rm_f(File.basename d['uri']) }
				FileUtils.rm_f(scxml)
				puts "pass"
			else
				@report.root << "<assert id='#{id}' res='fail'/>"
				`subl #{scxml}`
				puts "fail"
			end
		else
			puts "trace"
			system("lua autotest.lua #{scxml} --trace")
		end
	end
end

def prepare_scxml(uri)
	doc = Nokogiri.XML( get_file(uri), &:noblanks )
	convert_to_scxml!(doc)
	File.basename(uri).sub('txml','scxml').tap do |file|
		File.open(file,'w:utf-8'){ |f| f.puts doc }
	end
end

def convert_to_scxml!(doc)
	doc.at_xpath('//conf:pass').replace '<final id="pass" />' if doc.at_xpath('//conf:pass')
	doc.at_xpath('//conf:fail').replace '<final id="fail" />' if doc.at_xpath('//conf:fail')
	{
		arrayVar:             ->(a){ ['array',  "testvar#{a}"                         ]},
		arrayTextVar:         ->(a){ ['array',  "testvar#{a}"                         ]},
		eventdataVal:         ->(a){ ['cond',   "_event.data == #{a}"                 ]},
		eventNameVal:         ->(a){ ['cond',   "_event.name == '#{a}'"               ]},
		originTypeEq:         ->(a){ ['cond',   "_event.origintype == '#{a}'"         ]},
		emptyEventData:       ->(a){ ['cond',   "_event.data == nil"                  ]},
		eventFieldHasNoValue: ->(a){ ['cond',   "_event.#{a} == ''"                   ]},
		isBound:              ->(a){ ['cond',   "testvar#{a} ~= nil"                  ]},
		inState:              ->(a){ ['cond',   "In('#{a}')"                          ]},
		true:                 ->(a){ ['cond',   'true'                                ]},
		false:                ->(a){ ['cond',   'false'                               ]},
		unboundVar:           ->(a){ ['cond',   "testvar#{a}==nil"                    ]},
		noValue:              ->(a){ ['cond',   "testvar#{a}==nil or testvar#{a}==''" ]},
		nameVarVal:           ->(a){ ['cond',   "_name == '#{a}'"                     ]},
		nonBoolean:           ->(a){ ['cond',   "@@@@@@@@@@@@@@@@"                    ]},
		systemVarIsBound:     ->(a){ ['cond',   "#{a} ~= nil"                         ]},
		varPrefix:     ->(a){
      x,y = a.split /\s+/
			['cond',"string.sub(testvar#{y},1,string.len(testvar#{x}))==testvar#{x}"]
		},
		VarEqVar:      ->(a){
      x,y = a.split /\s+/
			['cond',"testvar#{x}==testvar#{y}"]
		},
		idQuoteVal:    ->(a){
			x,op,y = a.split(/([=<>]=?)/)
			['cond',"testvar#{x} #{op=='=' ? '==' : op} '#{y}'"]
		},
		idVal:         ->(a){
      x,op,y = a.split /([=<>]+)/
			['cond',"testvar#{x} #{op == '=' ? '==' : op} #{y}"]
		},
		namelistIdVal: ->(a){
			x,op,y = a.split /([=<>]+)/
			['cond',"testvar#{x} #{op == '=' ? '==' : op} #{y}"]
		},
		idSystemVarVal: ->(a){
			x,op,y = a.split /([=<>]+)/
			['cond',"testvar#{x} #{op == '=' ? '==' : op} #{y}"]
		},
		compareIDVal:  ->(a){
			x,op,y = a.split /([=<>]+)/
			['cond',"testvar#{x} #{op == '=' ? '==' : op} testvar#{y}"]
		},
		eventvarVal: ->(a){
			x,op,y = a.split /([=<>]+)/
			['cond',"_event.data['testvar#{x}'] #{op == '=' ? '==' : op} #{y}"]
		},
		VarEqVarStruct: ->(a){
			x,y = a.split /\D+/
			['cond',"testvar#{x} == testvar#{y}"]
		},
		eventFieldsAreBound: ->(a){
			['cond', "_event.name~=nil and _event.type~=nil and _event.sendid~=nil and _event.origin~=nil and _event.invokeid~=nil"]
		},
		datamodel:                ->(a){ ['datamodel', 'lua'                 ]},
		delay:                    ->(a){ ['delay',      "#{100*a.to_i}ms"    ]},
		delayExpr:                ->(a){ ['delayexpr',  "testvar#{a}"        ]},
		delayFromVar:             ->(a){ ['delayexpr',  "testvar#{a}"        ]},
		# delayFromVar:             ->(a){ ['delayexpr',  "100*tonumber(testvar#{a})..'ms'" ]},
		eventExpr:                ->(a){ ['eventexpr',  "testvar#{a}"        ]},
		eventDataFieldValue:      ->(a){ ['expr',       "_event.data.#{a}"   ]},
		eventDataNamelistValue:   ->(a){ ['expr',       "_event.data.testvar#{a}" ]},
		eventDataParamValue:      ->(a){ ['expr',       "_event.data.#{a}"   ]},
		eventField:               ->(a){ ['expr',       "_event.#{a}"        ]},
		eventName:                ->(a){ ['expr',       "_event.name"        ]},
		eventSendid:              ->(a){ ['expr',       "_event.sendid"      ]},
		eventType:                ->(a){ ['expr',       "_event.type"        ]},
		eventRaw:                 ->(a){ ['expr',       "_event:inspect(true)"]},
		expr:                     ->(a){ ['expr',       a                    ]},
		illegalArray:             ->(a){ ['expr',       "7"                  ]},
		illegalExpr:              ->(a){ ['expr',       "!"                  ]},
		invalidSendTypeExpr:      ->(a){ ['expr',       '27'                 ]},
		invalidSessionID:         ->(a){ ['expr',       "-1"                 ]},
		invalidName:              ->(a){ ['name',       ""                   ]},
		varExpr:                  ->(a){ ['expr',       "testvar#{a}"        ]},
		varChildExpr:             ->(a){ ['expr',       "testvar#{a}"        ]},
		quoteExpr:                ->(a){ ['expr',       "'#{a}'"             ]},
		systemVarExpr:            ->(a){ ['expr',       a                    ]},
		scxmlEventIOLocation:     ->(a){ ['expr',       "FIXME"              ]},
		varNonexistentStruct:     ->(a){ ['expr',       "testvar#{a}.nonono" ]},
		id:                       ->(a){ ['id',         "testvar#{a}"        ]},
		idlocation:               ->(a){ ['idlocation', "'testvar#{a}'"      ]},
		index:                    ->(a){ ['index',      "testvar#{a}"        ]},
		item:                     ->(a){ ['item',       "testvar#{a}"        ]},
		illegalItem:              ->(a){ ['item',       "_no"                ]},
		location:                 ->(a){ ['location',   "testvar#{a}"        ]},
		invalidLocation:          ->(a){ ['location',   ""                   ]},
		invalidParamLocation:     ->(a){ ['location',   ""                   ]},
		systemVarLocation:        ->(a){ ['location',   a                    ]},
		name:                     ->(a){ ['name',       "testvar#{a}"        ]},
		namelist:                 ->(a){ ['namelist',   "testvar#{a}"        ]},
		invalidNamelist:          ->(a){ ['namelist',   ""                   ]},
		sendIDExpr:               ->(a){ ['sendidexpr', "testvar#{a}"        ]},
		srcExpr:                  ->(a){ ['srcexpr',    "testvar#{a}"        ]},
		scriptBadSrc:             ->(a){ ['src',        "-badfile-"          ]},
		targetpass:               ->(a){ ['target',     'pass'               ]},
		targetfail:               ->(a){ ['target',     'fail'               ]},
		illegalTarget:            ->(a){ ['target',     'xxxxxxxxx'          ]},
		unreachableTarget:        ->(a){ ['target',     'FIXME'              ]},
		targetVar:                ->(a){ ['targetexpr', "testvar#{a}"        ]},
		targetExpr:               ->(a){ ['targetexpr', "testvar#{a}"        ]},
		basicHTTPAccessURITarget: ->(a){ ['targetexpr', "FIXME"              ]},
		invalidSendType:          ->(a){ ['type',       '27'                 ]},
		typeExpr:                 ->(a){ ['typeexpr',   "testvar#{a}"        ]},
	}.each do |a1,proc|
		doc.xpath("//@conf:#{a1}").each{ |a| a2,v=proc[a.value]; a.parent[a2]=v; a.remove }
	end

	doc.xpath('//conf:incrementID').each{ |e|
		e.replace "<assign location='testvar#{e['id']}' expr='testvar#{e['id']}+1' />"
	}
	doc.xpath('//conf:array123').each{ |e| e.replace "{1,2,3}" }
	doc.xpath('//conf:extendArray').each{ |e| e.replace "<assign location='testvar#{e['id']}' expr='(function() local t2={}; for i=1,#testvar#{e['id']} do t2[i]=testvar#{e['id']}[i] end t2[#t2+1]=4 return t2 end)()' />" }
	doc.xpath('//conf:sumVars').each{ |e|
		e.replace "<assign location='testvar#{e['id1']}' expr='testvar#{e['id1']}+testvar#{e['id2']}' />"
	}
	doc.xpath('//conf:concatVars').each{ |e|
		e.replace "<assign location='testvar#{e['id1']}' expr='testvar#{e['id1']}..testvar#{e['id2']}' />"
	}
	doc.xpath('//conf:contentFoo').each{ |e| e.replace %Q{<content expr="'foo'"/>} }
	doc.xpath('//conf:script').each{ |e| e.replace %Q{<script>testvar1 = 1</script>} }
	doc.xpath('//conf:sendToSender').each{ |e|
		e.replace %Q{<send event="#{e['name']}" targetexpr="_event.origin" typeexpr="_event.origintype"/>}
	}

	if a = doc.at_xpath('//@*[namespace-uri()="http://www.w3.org/2005/scxml-conformance"]')
		puts a.parent
		exit
	end
	if a = doc.at_xpath('//conf:*')
		puts a
		exit
	end

	# HACK to remove the now-unused conf: namespace from the root.
	doc.remove_namespaces!
	doc.root.add_namespace(nil,'http://www.w3.org/2005/07/scxml')
end

def get_file(uri)
	Dir.chdir(CACHE) do
		unless File.exist?(uri)
			subdir = File.dirname(uri)
			FileUtils.mkdir_p subdir			
			Dir.chdir(subdir){ `curl -s -L -O #{URI.join BASE, uri}` }
		end
		File.open( uri, 'r:UTF-8', &:read )
	end
end

run! if __FILE__==$0