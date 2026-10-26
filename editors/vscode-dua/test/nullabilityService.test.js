'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),os=require('node:os');
const {analyzeSource}=require('../checker'),modules=require('../moduleIntelligence'),host=require('../hostCompletion');
const {fieldCompletions}=require('../tableConstruction'),{diagnosticPosition}=require('../language');
const exe=path.resolve(__dirname,'../bin/dua-check.exe'),empty={symbols:{},types:{}};
async function fixture(run){
 const root=fs.mkdtempSync(path.join(os.tmpdir(),'dua-nullable-extension-')),sourceName=path.join(root,'main.dua');
 fs.writeFileSync(path.join(root,'types.dua'),'auto text="日本😀"; export table Item { int count; } export alias Required=Item & !null; export table Owner { Item child; Required required; }');
 const analyze=source=>analyzeSource(exe,source,{sourceName,modulePaths:[path.join(root,'?.dua')],hostClassTypes:['ListView']}).promise;
 try{await run({root,sourceName,analyze});}finally{fs.rmSync(root,{recursive:true,force:true});}
}
test('shared checker accepts default nullable tables and explicit nonnull initialization across aliases, fields and containers',()=>fixture(async({analyze})=>{
 const declarations='table Item{int count;} alias Required=Item & !null; ';
 for(const tail of ['Item value=null;',
  'Required value=Item{count=1}; value=Item{count=2};',
  'Item & !null value=Item{count=1};',
  'Item maybe=Item{count=1}; Required value=cast(Required) maybe;',
  'Required echo(Required value){return value;} Required value=echo(Item{count=1});',
  '(Item & !null)[] values=[Item{count=1}];',
  'Item[] & !null values=[null,Item{count=1}];',
  '(Item & !null)[string] values=["one":Item{count=1}];',
  'alias Mixed=Item & !null | null; Mixed value=null;',
  'table Owner{Item child; Required required;} auto owner=Owner{child=null,required=Item{count=1}};',
  'ListView value=null;',
  'alias RequiredView=ListView & !null; RequiredView value=unknown();']){
   assert.deepEqual((await analyze(declarations+tail)).diagnostics,[],tail);
 }
}));
test('shared checker rejects excluded null, omitted initialization/fields, nullable-to-required transfer and unsupported syntax',()=>fixture(async({analyze})=>{
 const declarations='table Item{int count;} alias Required=Item & !null; ';
 const missed=[];
 for(const tail of ['Required value=null;','Item & !null value=null;',
  'Item value;','Required value;',
  'Required value=Item{count=1}; value=null;',
  'Item maybe=Item{count=1}; Required value=maybe;',
  'Required echo(Required value){return value;} echo(null);',
  'Required missing(){return null;}',
  '(Item & !null)[] values=[null];',
  'Item[] & !null values=null;',
  '(Item & !null)[string] values=["one":null];',
  'table Owner{Item child;} auto owner=Owner{};',
  'Item! value=Item{count=1};','Item? value=Item{count=1};',
  'Item & int value=Item{count=1};','Item & !string value=Item{count=1};',
  'ListView & !null value=null;','struct Point{int x;} Point value=null;',
  'int value=null;','string value=null;']){
   if(!(await analyze(declarations+tail)).diagnostics.length)missed.push(tail);
 }
 assert.deepEqual(missed,[],'rejected cases without a static diagnostic');
}));
test('real wrapper IDs retain imported shape, field candidates, display types and Unicode declaration positions',()=>fixture(async({analyze,sourceName})=>{
 const source='import "./types.dua" as m; m.Item optional=null; m.Item & !null required=m.Item{count=1}; '
  +'m.Owner owner=m.Owner{child=null,required=m.Item{count=2}}; '
  +'export (m.Item & !null)[] values=[m.Item{count=3}]; export m.Item[] & !null array=[null];';
 const analysis=await analyze(source);assert.deepEqual(analysis.diagnostics,[]);
 const catalog=modules.catalogWithImports(empty,analysis,sourceName);
 for(const tail of ['required.','owner.required.','values[0].','array[0].']){
  const input=source+' '+tail;
  assert.ok(host.apiCompletions(input,input.length,catalog).some(entry=>entry.label==='count'),tail);
 }
 const pending=source+' auto value=m.Required {';
 assert.deepEqual(fieldCompletions(pending,pending.length,catalog).map(value=>value.label),['count']);
 const target=modules.definitionAt(source,source.indexOf('m.Item &')+3,analysis,empty,sourceName);
 assert.ok(target?.sourceName.endsWith('types.dua'));
 assert.equal(diagnosticPosition(target.sourceText,target).character,target.sourceText.indexOf('table Item'));
 const unit=analysis.modules.find(unit=>unit.sourceName===sourceName);
 const values=unit.exports.find(value=>value.name==='values'),array=unit.exports.find(value=>value.name==='array');
 assert.match(values.type,/^\(.* & !null\)\[\]$/);assert.match(array.type,/^\(.*\[\] & !null\)$/);
 const owner=catalog.symbols['m.Owner'].type;
 assert.ok(catalog.types[owner].members.required.displayType.includes('Required'));
 assert.ok(!catalog.types[owner].members.required.displayType.includes('__dua_module_'));
}));
