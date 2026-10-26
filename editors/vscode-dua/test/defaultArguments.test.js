'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),path=require('node:path');
const {checkSource,analyzeSource}=require('../checker');const exe=path.resolve(__dirname,'../bin/dua-check.exe');
const good=['int f(int a,int b=2,int c=3){return a+b+c;} f(1);f(1,5);f(1,5,6);',
 'auto f=(int a=1,int b=a+2)=>a+b;f();f(2);',
 'auto f=(int a=1){return a;};f();',
 'void f(int a=1):> print(a);',
 'int f(int a=1,int rest...){return a+rest.length;} f();f(2,3,4);',
 'bool f(int[] a=[]){return a==null;} f(null);',
 'Vec3 v=Vec3(1,2,3);v=v*2.0;'];
test('defaults syntax, trailing multi-defaults and original Vec3 inference',async()=>{for(const source of good.filter(x=>!x.includes(':>')))assert.deepEqual(await checkSource(exe,source).promise,[],source);});
test('invalid ordering, missing/default types and wrong call counts remain diagnostic',async()=>{
 for(const source of ['void f(int a=1,int b){}','void f(int a="bad"){}','void f(int a=1,int rest...=2){}',
 'void f(int a,int b=2){} f();','void f(int a=1){} f(1,2);','void f(int a=1){} f("bad");',
 'auto f=(int a="bad")=>a;','int[] a=[1];a~="bad";'])assert.ok((await checkSource(exe,source).promise).length,source);
});
test('export analysis reports minimum argument count for imported completion',async()=>{
 const source='export int f(int a,int b=2,int c=3){return a+b+c;}';const result=await analyzeSource(exe,source,{sourceName:'defaults.dua'}).promise;
 assert.deepEqual(result.diagnostics,[]);const symbol=result.exports.find(x=>x.name==='f');assert.equal(symbol.requiredParameterCount,1);assert.equal(symbol.parameterTypes.length,3);
});
const fs=require('node:fs'),os=require('node:os');
const host=require('../hostCompletion'),intelligence=require('../moduleIntelligence');
test('local and imported signatures preserve all trailing optional parameters',async()=>{
 const empty={symbols:{},types:{},assets:[],contexts:[]};
 const local='int f(int a,int b=2,int c=3){return a+b+c;}\nf';
 const entry=host.environmentAt(host.tokens(local).tokens,empty).get('f').entry;
 assert.deepEqual(entry.signatures[0].parameters.map(x=>!!x.optional),[false,true,true]);
 const ufcs='int add(int a,int b=2){return a+b;}\nauto value=(1).add;';
 assert.deepEqual(host.environmentAt(host.tokens(ufcs).tokens,empty).get('value').types,['int']);
 const root=fs.mkdtempSync(path.join(os.tmpdir(),'dua-default-args-'));
 try{
  fs.writeFileSync(path.join(root,'lib.dua'),'export int f(int a,int b=2,int c=3){return a+b+c;}');
  const source='import "./lib.dua" as lib; auto n=lib.f(1);';
  const analysis=await analyzeSource(exe,source,{sourceName:path.join(root,'main.dua')}).promise;
  assert.deepEqual(analysis.diagnostics,[]);
  const catalog=intelligence.catalogWithImports(empty,analysis,path.join(root,'main.dua'));
  const signature=catalog.symbols['lib.f'].signatures[0];
  assert.deepEqual(signature.parameters.map(x=>!!x.optional),[false,true,true]);
  const bad=await analyzeSource(exe,'import "./lib.dua" as lib;lib.f();',{sourceName:path.join(root,'main.dua')}).promise;
  assert.ok(bad.diagnostics.some(x=>x.message.includes('arguments')));
 }finally{fs.rmSync(root,{recursive:true,force:true});}
});

