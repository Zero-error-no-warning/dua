'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),os=require('node:os');
const {analyzeSource,checkSource}=require('../checker'),modules=require('../moduleIntelligence'),tables=require('../tableConstruction');
const exe=path.resolve(__dirname,'../bin',process.platform==='win32'?'dua-check.exe':'dua-check'),empty={symbols:{},types:{}};
test('member defaults accept omission and retain required, explicit type and null diagnostics',async()=>{
 for(const source of ['table T{int a=1;int b;}auto v=T{b=2};',
  'struct V{int a=1;int b=2;}auto a=V();auto b=V(3);auto c=V({b=4});',
  'table B{int a=1;}table C{...B;int b=2;}alias A=C;auto a=A{};',
  'int seed=3;table T{int seed=99;int x=seed;}auto a=T{};'])
  assert.deepEqual(await checkSource(exe,source).promise,[],source);
 for(const source of ['table T{int a=1;int b;}auto v=T{};','struct V{int a=1;int b;}auto v=V(2);',
  'struct V{int a=1;}auto v=V(null);','table T{int a="bad";}auto v=T{a=1};',
  'struct V{int a="bad";}auto v=V(1);','table T{int[] & !null xs=[];}auto v=T{xs=null};'])
  assert.ok((await checkSource(exe,source).promise).length,source);
});
test('service publishes additive default fields and preserves field order without executing expressions',async()=>{
 const source='export table T{int first=neverExecute();int required;}export struct V{int a=1;int b;}';
 const result=await analyzeSource(exe,source,{sourceName:'member-defaults.dua'}).promise;
 assert.deepEqual(result.diagnostics,[]);
 assert.deepEqual(result.exports.find(x=>x.name==='T').defaultFields,['first']);
 assert.deepEqual(result.exports.find(x=>x.name==='T').fieldOrder,['first','required']);
 const catalog=modules.catalogWithImports(empty,result,'member-defaults.dua');
 const source2=source+'auto x=T{';
 const entries=tables.fieldCompletions(source2,source2.length,catalog);
 assert.ok(entries.find(x=>x.label==='first').detail.includes('省略可'));
 assert.ok(!entries.find(x=>x.label==='required').detail.includes('省略可'));
 assert.deepEqual(catalog.symbols.V.signatures[0].parameters.map(x=>x.optional),[false,false]);
});
test('import, spread and alias propagate defaults, diagnostics and constructor signatures',async()=>{
 const root=fs.mkdtempSync(path.join(os.tmpdir(),'dua-member-defaults-'));
 try{
  fs.writeFileSync(path.join(root,'base.dua'),'export table B{int x=1;int required;}export table C{...B;int y=2;}export struct V{int x=1;int y=2;}');
  const source='import "./base.dua" as lib;alias A=lib.C;auto a=A{required=4};auto v=lib.V();';
  const sourceName=path.join(root,'main.dua'),analysis=await analyzeSource(exe,source,{sourceName}).promise;
  assert.deepEqual(analysis.diagnostics,[]);
  const catalog=modules.catalogWithImports(empty,analysis,sourceName),prefix=source+'auto b=A{';
  const entries=tables.fieldCompletions(prefix,prefix.length,catalog);
  assert.ok(entries.find(x=>x.label==='x').detail.includes('省略可'));
  assert.ok(entries.find(x=>x.label==='y').detail.includes('省略可'));
  assert.deepEqual(catalog.symbols['lib.V'].signatures[0].parameters.map(x=>x.optional),[true,true]);
  const failed=await analyzeSource(exe,'import "./base.dua" as lib;auto x=lib.B{};',{sourceName}).promise;
  assert.ok(failed.diagnostics.some(x=>x.message.includes('required')));
  fs.writeFileSync(path.join(root,'bad.dua'),'export table T{\n int x="bad";\n}');
  const bad=await analyzeSource(exe,'import "./bad.dua" as lib;auto x=lib.T{};',{sourceName}).promise;
  assert.ok(bad.diagnostics.some(x=>x.line===2&&x.sourceName.endsWith('bad.dua')));
 }finally{fs.rmSync(root,{recursive:true,force:true});}
});
