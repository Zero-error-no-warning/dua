'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),path=require('node:path'),fs=require('node:fs'),os=require('node:os');
const {analyzeSource}=require('../checker'),modules=require('../moduleIntelligence'),host=require('../hostCompletion');
const exe=path.resolve(__dirname,'../bin/dua-check.exe');
async function fixture(run){
 const root=fs.mkdtempSync(path.join(os.tmpdir(),'dua-nullable-array-')),sourceName=path.join(root,'main.dua');
 fs.writeFileSync(path.join(root,'types.dua'),'export table Item{int count;} export alias RequiredItem=Item & !null;');
 const analyze=source=>analyzeSource(exe,source,{sourceName,modulePaths:[path.join(root,'?.dua')],hostClassTypes:['ListView']}).promise;
 try{await run({sourceName,analyze});}finally{fs.rmSync(root,{recursive:true,force:true});}
}
// Confirmed nullable-array handoff; not an expectation of the old 0.6.2 checker.
test('typed array handles accept null, empty arrays and assignment to existing arrays',()=>fixture(async({analyze})=>{
 for(const source of ['int[] absent=null; int[] empty=[]; absent=empty; absent=null;',
  'int[] array1=[1,2,3]; int[] array2=[4,5,6]; int[] pointArray=null; pointArray=array1; pointArray[0]=9; pointArray=array2;',
  'int[] values=null; auto count=values.length; foreach(value;values){}',
  'int[] values=null; bool same=values==[];',
  'int[] values; int[string] mapping;',
  'int[string] mapping=null; auto count=mapping.length; auto keys=mapping.keys; foreach(key,value;mapping){}',
  'array values=null; associativeArray mapping=null;',
  'int[][] values=[null];',
  'alias Numbers=int[]; Numbers value=null;',
  'int[] echo(int[] value){return value;} int[] value=echo(null);',
  'int[] missing(){return null;}',
  'table Item{int count;} (Item & !null)[] absent=null;',
  'table Holder{int[] values;} auto holder=Holder{values=null};',
  'int[] & !null value=[];',
  'int[] maybe=[1]; int[] & !null value=cast(int[] & !null) maybe;']){
   assert.deepEqual((await analyze(source)).diagnostics,[],source);
 }
}));
test('nonnull containers and elements retain distinct rejection rules',()=>fixture(async({analyze})=>{
 const missed=[];
 for(const source of ['int[] & !null value=null;',
  'int[] & !null value=[]; value=null;',
  'int[] maybe=[1]; int[] & !null value=maybe;',
  'int[] & !null missing(){return null;}',
  'void take(int[] & !null value){} take(null);',
  'table Item{int count;} (Item & !null)[] value=[null];',
  'int[] value=[null];',
  '(int[] & !null)[] value=[null];',
  'int[string] value=["one":null];',
  'int[string] & !null value=null;',
  'int[] & !null value;',
  'alias Numbers=int[]; Numbers value;',
  'table Holder{int[] values;} auto holder=Holder{};']){
   if(!(await analyze(source)).diagnostics.length)missed.push(source);
 }
 assert.deepEqual(missed,[]);
}));
test('array export IDs and imported element shape remain intact when the container is nullable',()=>fixture(async({analyze,sourceName})=>{
 const source='import "./types.dua" as m; export m.Item[] optional=null; export (m.Item & !null)[] requiredElements=null; '
  +'export m.Item[] & !null requiredContainer=[];';
 const analysis=await analyze(source);assert.deepEqual(analysis.diagnostics,[]);
 const unit=analysis.modules.find(unit=>unit.sourceName===sourceName),catalog=modules.catalogWithImports({symbols:{},types:{}},analysis,sourceName);
 assert.ok(unit.exports.find(value=>value.name==='optional').type.endsWith('[]'));
 assert.match(unit.exports.find(value=>value.name==='requiredElements').type,/^\(.* & !null\)\[\]$/);
 assert.match(unit.exports.find(value=>value.name==='requiredContainer').type,/^\(.*\[\] & !null\)$/);
 // Completion shows declared element shape; it does not prove a currently-null container is safe to index.
 for(const name of ['optional','requiredElements','requiredContainer']){
  const input=source+' '+name+'[0].';
  assert.ok(host.apiCompletions(input,input.length,catalog).some(value=>value.label==='count'),name);
 }
}));
