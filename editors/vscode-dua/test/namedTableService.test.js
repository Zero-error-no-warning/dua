'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),os=require('node:os');
const {analyzeSource}=require('../checker');
const modules=require('../moduleIntelligence'),host=require('../hostCompletion');
const exe=path.resolve(__dirname,'../bin/dua-check.exe'),empty={symbols:{},types:{}};
async function fixture(run){
 const root=fs.mkdtempSync(path.join(os.tmpdir(),'dua-named-service-')),sourceName=path.join(root,'main.dua');
 fs.writeFileSync(path.join(root,'types.dua'),'export table Hoge { int x; string label; } table Secret { int hidden; }');
 const analyze=source=>analyzeSource(exe,source,{sourceName,modulePaths:[path.join(root,'?.dua')],hostClassTypes:['ListView']}).promise;
 try{await run({analyze,sourceName});}finally{fs.rmSync(root,{recursive:true,force:true});}
}
test('shared service accepts local/imported named constructions and preserves union array elements',()=>fixture(async({analyze,sourceName})=>{
 const source='import "./types.dua" as t; table Other { bool enabled; } alias Both = t.Hoge | Other; '
  +'Both[] values = [t.Hoge { x = 1, label = "one" }, Other { enabled = true }]; ListView view = null;';
 const result=await analyze(source);
 assert.deepEqual(result.diagnostics,[]);
 const catalog=modules.catalogWithImports(empty,result,sourceName);
 const completed=source+' values[0].';
 assert.deepEqual(host.apiCompletions(completed,completed.length,catalog).map(entry=>entry.label).sort(),['enabled','label','x']);
 const target=modules.definitionAt(source,source.indexOf('t.Hoge {')+3,result,empty,sourceName);
 assert.ok(target?.sourceName.endsWith('types.dua'));
}));
test('shared service retains invalid-initializer, nominal-type and private-import diagnostics',()=>fixture(async({analyze})=>{
 for(const source of ['table Hoge { int x; } auto value = Hoge { x = "wrong" };',
  'table Hoge { int x; } auto value = Hoge {};',
  'table Hoge { int x; } auto value = Hoge { x = 1, x = 2 };',
  'import "./types.dua" as t; auto value = t.Secret { hidden = 1 };',
  'table A { int x; } table B { int x; } A value=B{x=1};',
  'table A { int x; } table B { int x; } alias U=A|B; auto value=U{x=1};']){
   const result=await analyze(source);assert.ok(result.diagnostics.length>0,source);
 }
}));
test('single aliases, inherited fields, partial type input and value-name shadows follow the runtime type namespace',()=>fixture(async({analyze,sourceName})=>{
 const source='auto text="日本😀"; table Base { int base; } table Child { ...Base; int own; } alias Same = Child; int Child = 1; '
  +'export auto value = Same {base=1,own=2,extra=3}; auto shadowed = Child {base=1,own=2};';
 const result=await analyze(source);assert.deepEqual(result.diagnostics,[]);
 const catalog=modules.catalogWithImports(empty,result,sourceName);
 const prefix=source+' auto pending=Same {';
 assert.deepEqual(require('../tableConstruction').fieldCompletions(prefix,prefix.length,catalog).map(value=>value.label),['base','own']);
 const complete=source+' shadowed.';
 assert.deepEqual(host.apiCompletions(complete,complete.length,catalog).map(value=>value.label).sort(),['base','own']);
 const definition=modules.definitionAt(source,source.lastIndexOf('Child {')+2,result,empty,sourceName);
 assert.ok(definition?.sourceName===sourceName);
 const unit=result.modules.find(unit=>unit.sourceName===sourceName);
 assert.ok(unit.typeConstructions.length>=2);
 const start=require('../language').diagnosticPosition(source,unit.typeConstructions[0]);
 assert.equal(source.split('\n')[start.line].slice(start.character,start.character+4),'Same');
 assert.equal(unit.exports.find(value=>value.name==='value').nominalValue,true);
 const incomplete=source+' auto pending=Sa';
 const offered=host.apiCompletions(incomplete,incomplete.length,catalog);
 assert.ok(offered.some(value=>value.label==='Same'&&value.kind==='type'));
}));
