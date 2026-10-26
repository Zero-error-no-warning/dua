'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path'),os=require('node:os');
const {analyzeSource}=require('../checker'), modules=require('../moduleIntelligence'),host=require('../hostCompletion');
const tables=require('../tableConstruction');
const exe=path.resolve(__dirname,'../bin/dua-check.exe'),empty={symbols:{},types:{}};
const declarations='table Hoge { int x; string label; } table Other { bool enabled; } alias Both = Hoge | Other; alias Same = Hoge;\n';
async function fixture(run){
 const root=fs.mkdtempSync(path.join(os.tmpdir(),'dua-named-table-')), sourceName=path.join(root,'main.dua');
 fs.writeFileSync(path.join(root,'types.dua'),'export table Hoge { int x; string label; } table Secret { int hidden; } export alias Same = Hoge;');
 const analyze=source=>analyzeSource(exe,source,{sourceName,modulePaths:[path.join(root,'?.dua')]}).promise;
 try{await run({root,sourceName,analyze});}finally{fs.rmSync(root,{recursive:true,force:true});}
}

test('unfinished constructions obtain local and imported fields through a service-only projection',()=>fixture(async({sourceName,analyze})=>{
 for(const tail of ['auto value = Hoge {','void f() { auto value = Hoge { x =','auto values = [Hoge { label = "one", x',
   'auto value = Hoge { label = Other { en']){
  const source=declarations+tail,projection=modules.completionSource(source,source.length);
  const result=await analyze(projection);
  assert.deepEqual(result.diagnostics,[],projection);
  const catalog=modules.catalogWithImports(empty,result,sourceName);
  const entries=tables.fieldCompletions(source,source.length,catalog).map(value=>value.label);
  assert.deepEqual(entries,tail.endsWith('x =')?[]:tail.includes('Other {')?['enabled']:tail.includes('label = "one"')?['x']:['label','x']);
 }
 const source='import "./types.dua" as t; auto value = t.Hoge { x = 1, la';
 const result=await analyze(modules.completionSource(source,source.length));
 assert.deepEqual(result.diagnostics,[]);
 const catalog=modules.catalogWithImports(empty,result,sourceName);
 assert.deepEqual(tables.fieldCompletions(source,source.length,catalog).map(value=>value.label),['label']);
 assert.equal(catalog.symbols.Secret,undefined);assert.equal(catalog.symbols['t.Secret'],undefined);
 assert.equal(catalog.symbols.Hoge,undefined);
}));

test('field edits respect comments, strings, value slots, shadows and existing assignments',()=>fixture(async({sourceName,analyze})=>{
 const result=await analyze(declarations),catalog=modules.catalogWithImports(empty,result,sourceName);
 for(const tail of ['# Hoge {','auto text = "Hoge {','auto value = Hoge { x = unknown.',
  'auto value = Missing {','auto value = Both {','auto value = Hoge { x = {']){
  const source=declarations+tail;assert.deepEqual(tables.fieldCompletions(source,source.length,catalog),[],tail);
 }
 const shadow=declarations+'int Hoge = 1; auto value = Hoge {';
 assert.deepEqual(tables.fieldCompletions(shadow,shadow.length,catalog).map(value=>value.label),['label','x']);
 const source=declarations+'auto value = Same { laOLD = "one" };',offset=source.indexOf('OLD');
 const entry=tables.fieldCompletions(source,offset,catalog).find(value=>value.label==='label');
 assert.equal(source.slice(0,entry.start)+entry.insertText+source.slice(entry.end),declarations+'auto value = Same { label = "one" };');
}));

test('named values retain exact type IDs through declarations, union arrays and indexing',()=>fixture(async({sourceName,analyze})=>{
 const result=await analyze(declarations),catalog=modules.catalogWithImports(empty,result,sourceName);
 const cases=[['auto value = Hoge { x = 1 }; value.',['label','x']],
  ['Hoge value = Hoge { x = 1 }; value.',['label','x']],
  ['Hoge { x = 1 }.',['label','x']],
  ['auto values = [Hoge { x = 1 }, Other { enabled = true }]; values[0].',['enabled','label','x']],
  ['Both[] values = [Hoge { x = 1 }]; values[index].',['enabled','label','x']],
  ['Both[][] values; values[0][0].',['enabled','label','x']]];
 for(const [tail,expected]of cases){const source=declarations+tail;
  assert.deepEqual(host.apiCompletions(source,source.length,catalog).map(value=>value.label).sort(),expected,tail);}
 const source='import "./types.dua" as t; auto value = t.Hoge { x = 1 }; value.';
 const imported=await analyze('import "./types.dua" as t;');
 assert.deepEqual(host.apiCompletions(source,source.length,modules.catalogWithImports(empty,imported,sourceName)).map(value=>value.label).sort(),['label','x']);
}));

test('constructor type definitions use shared declaration positions without exposing private imports',()=>fixture(async({sourceName,analyze})=>{
 const source=declarations+'auto value = Hoge { x = 1 };';
 const result=await analyze(declarations);
 const local=modules.definitionAt(source,source.lastIndexOf('Hoge')+2,result,empty,sourceName);
 assert.equal(local.sourceName,sourceName);assert.equal(local.line,1);assert.equal(local.column,1);
 const imported='import "./types.dua" as t; auto value = t.Hoge { x = 1 };';
 const analysis=await analyze('import "./types.dua" as t;');
 assert.ok(modules.definitionAt(imported,imported.lastIndexOf('Hoge')+2,analysis,empty,sourceName)?.sourceName.endsWith('types.dua'));
 const hidden=imported.replace('t.Hoge','t.Secret');
 assert.equal(modules.definitionAt(hidden,hidden.lastIndexOf('Secret')+2,analysis,empty,sourceName),null);
}));
