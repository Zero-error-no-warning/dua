'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),os=require('node:os');
const host=require('../hostCompletion'),modules=require('../moduleIntelligence'),{analyzeSource}=require('../checker');
const signature=(parameters,returnType='Result')=>({returnType,parameters:parameters.map(value=>typeof value==='string'?{type:value}:value)});
const catalog={symbols:{Result:{kind:'type',type:'Result'},Host:{kind:'type',type:'Host'},
  convert:{kind:'function',signatures:[signature(['int'])]},
  required:{kind:'function',signatures:[signature(['int','int'])]},
  optional:{kind:'function',signatures:[signature(['int',{type:'int',optional:true}])]},
  variadic:{kind:'function',signatures:[signature(['int',{type:'any',variadic:true}])]},
  gap:{kind:'function',signatures:[signature([]),signature(['int','int','int'])]},
  unknown:{kind:'function',type:'Result'},
  factory:{kind:'function',signatures:[signature(['int'],'function')]},
  length:{kind:'function',signatures:[signature(['any'])]},
  selected:{kind:'function',signatures:[signature(['any'])]},
  total:{kind:'function',signatures:[signature(['int[]'])]},
  helpers:{kind:'module'},'helpers.convert':{kind:'function',signatures:[signature(['int'])]}},
 types:{Result:{members:{value:{kind:'property',type:'int'}}},Host:{members:{
  selected:{kind:'property',type:'int'},read:{kind:'method',signatures:[signature([])]},
  required:{kind:'method',signatures:[signature(['int'])]},unknown:{kind:'method',type:'Result'}}}}};
function resolve(source,extra=catalog){const input=host.tokens(source).tokens;return host.resolveExpression(input,new Map(),extra);}
function infer(source,extra=catalog){const input=host.tokens(source).tokens,env=host.environmentAt(input,extra);return env.get('value');}

test('known UFCS arity permits property results; required, unknown and arity-gap functions remain uncalled',()=>{
 for(const name of ['convert','optional','variadic'])assert.deepEqual(resolve(`(3).${name}`).types,['Result']);
 for(const name of ['required','unknown','gap'])assert.equal(resolve(`(3).${name}`),null);
 assert.deepEqual(resolve('(3).required(2)').types,['Result']);
 assert.deepEqual(resolve('(3).factory').types,['function']);
 assert.deepEqual(resolve('(3).factory()').types,['function']);
 assert.deepEqual(resolve('[1,2].total').types,['Result']);
});

test('members and intrinsic properties win; modules and direct function values are preserved',()=>{
 assert.deepEqual(resolve('Host().selected').types,['int']);
 assert.deepEqual(resolve('Host().read').types,['Result']);
 assert.deepEqual(resolve('Host().read()').types,['Result']);
 assert.deepEqual(resolve('Host().required').types,[]);
 assert.deepEqual(resolve('Host().required(1)').types,['Result']);
 assert.deepEqual(resolve('Host().unknown').types,[]);
 assert.equal(resolve('Host().convert'),null,'host dynamic fields may hide UFCS');
 assert.deepEqual(resolve('[1,2].length').types,['int']);
 assert.deepEqual(resolve('["a":1].keys.length').types,['int']);
 assert.deepEqual(resolve('["a" ~ "b":1].keys.length').types,['int']);
 for(const source of ['convert','helpers.convert']) {
  assert.deepEqual(resolve(source).types,[]);assert.ok(resolve(source).entry.signatures);
 }
 assert.deepEqual(infer('auto value=helpers.convert;').types,[]);
 assert.deepEqual(infer('auto f=helpers.convert; auto value=f(3);').types,['Result']);
});

test('lexically declared functions and aliases preserve scope and callable results without executing code',()=>{
 const types={symbols:{...catalog.symbols},types:{...catalog.types}};
 const prefix='Result build(int n) { return Result {value=n}; } ';
 const source=prefix+'auto value=(3).build; value.';
 assert.ok(host.apiCompletions(source,source.length,types).some(value=>value.label==='value'));
 assert.deepEqual(infer(prefix+'auto value=build;',types).types,[]);
 assert.deepEqual(infer(prefix+'auto value=(3).build();',types).types,['Result']);
 assert.equal(infer(prefix+'{ int build=1; auto value=(3).build; }',types),undefined);
 assert.deepEqual(infer(prefix+'{ int build=1; } auto value=(3).build;',types).types,['Result']);
 const shadow=prefix+'int build=1; auto value=(3).build;';
 assert.deepEqual(infer(shadow,types).types,[]);
});

test('shared checker matches UFCS scalar/array diagnostics and retains conservative table and unknown-arity boundaries',async()=>{
 const root=fs.mkdtempSync(path.join(os.tmpdir(),'dua-ufcs-extension-')),sourceName=path.join(root,'main.dua');
 const exe=path.resolve(__dirname,'../bin/dua-check.exe');
 const analyze=source=>analyzeSource(exe,source,{sourceName,modulePaths:[path.join(root,'?.dua')],hostClassTypes:['ListView']}).promise;
 try{
  for(const source of ['int doubled(int n){return n*2;} int value=(3).doubled;',
    'int total(int[] values){return values[0];} int value=[1,2].total;',
    'int needs(int n,int extra){return extra;} string value=(3).needs;',
    'int doubled(any n){return 2;} table Weapon{int damage;} string value=Weapon{damage=1}.doubled;',
    'ListView view=null; auto values=[1,2]; auto value=values.map;']){
   assert.deepEqual((await analyze(source)).diagnostics,[],source);
  }
  const invalid=await analyze('int doubled(int n){return n*2;} string value=(3).doubled;');
  assert.ok(invalid.diagnostics.some(value=>/expects string.*type int/.test(value.message)));
  fs.writeFileSync(path.join(root,'helpers.dua'),'export table Result { int value; } export Result build(int n){return Result{value=n};}');
  const source='import "./helpers.dua" as h; auto build=h.build; auto value=(3).build;';
  const result=await analyze(source);assert.deepEqual(result.diagnostics,[]);
  const effective=modules.catalogWithImports({symbols:{},types:{}},result,sourceName);
  const offered=source+' value.';
  assert.ok(host.apiCompletions(offered,offered.length,effective).some(value=>value.label==='value'));
  const callable='import "./helpers.dua" as h; auto build=h.build; build.';
  assert.deepEqual(host.apiCompletions(callable,callable.length,effective),[]);
 }finally{fs.rmSync(root,{recursive:true,force:true});}
});
