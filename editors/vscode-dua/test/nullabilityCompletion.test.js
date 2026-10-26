'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {readType,nonNullInner}=require('../typeSyntax'),host=require('../hostCompletion'),modules=require('../moduleIntelligence');
const {documentNames}=require('../language');
const catalog={symbols:{Hoge:{kind:'type',type:'opaque_Hoge'},'m.Hoge':{kind:'type',type:'opaque_Hoge'}},types:{opaque_Hoge:{members:{x:{type:'int',kind:'property'}}}}};
function read(source){const input=host.tokens(source).tokens;const result=readType(input,0,name=>catalog.symbols[name]?.type || (['int','string'].includes(name)?name:null));
 return result && result.next===input.length ? result.type : null;}
test('restricted null exclusion follows the confirmed parser grammar and keeps opaque base IDs',()=>{
 assert.equal(read('Hoge & !null'),'(opaque_Hoge & !null)');
 assert.equal(read('m.Hoge & ! null'),'(opaque_Hoge & !null)');
 assert.equal(read('Hoge[] & !null'),'(opaque_Hoge[] & !null)');
 assert.equal(read('(Hoge & !null)[]'),'(opaque_Hoge & !null)[]');
 assert.equal(read('(Hoge & !null)[string]'),'(opaque_Hoge & !null)[string]');
 assert.equal(read('Hoge delegate(Hoge & !null) & !null'),'(opaque_Hoge delegate((opaque_Hoge & !null)) & !null)');
 for(const source of ['Hoge!','Hoge & int','Hoge & !string','Hoge & !','(Hoge & !null) | int'])assert.equal(read(source),null,source);
 assert.equal(nonNullInner('(opaque_Hoge & !null)'),'opaque_Hoge');
 assert.equal(nonNullInner('(opaque_Hoge & !null)[]'),null);
});
test('nonnullable variable, parameter and return annotations preserve member completion',()=>{
 for(const source of ['Hoge & !null value=unknown(); value.',
  '(m.Hoge & !null) value=unknown(); value.',
  'void f(Hoge & !null value) { value.',
  'Hoge & !null make(){return unknown();} auto value=make(); value.',
  '(Hoge & !null)[] values; values[0].',
  'Hoge[] & !null values=unknown(); values[0].']){
  assert.ok(host.apiCompletions(source,source.length,catalog).some(value=>value.label==='x'),source);
 }
});
test('null-excluded imported aliases and fields follow shared descriptors without exposing private names',()=>{
 const analysis={imports:[{aliasName:'m',key:'types'}],modules:[{key:'types',sourceName:'types.dua',types:[
  {name:'Private',displayType:'Private',type:'opaque_table',declarationKind:'table',fields:{x:'int'},exported:false},
  {name:'Holder',type:'opaque_holder',declarationKind:'table',fields:{child:'(opaque_table & !null)'},exported:false},
  {name:'Required',type:'opaque_alias',declarationKind:'alias',alternatives:['(opaque_table & !null)'],exported:true}
 ],exports:[{name:'Required',kind:'type',type:'opaque_alias'}]}]};
 const effective=modules.catalogWithImports({symbols:{},types:{}},analysis);
 assert.ok(effective.types.opaque_alias.tableConstruction);
 assert.equal(effective.types.opaque_holder.members.child.displayType,'(Private & !null)');
 const source='m.Required value=unknown(); value.';
 assert.ok(host.apiCompletions(source,source.length,effective).some(value=>value.label==='x'));
 assert.equal(effective.symbols.Private,undefined);assert.equal(effective.symbols['m.Private'],undefined);
});
test('declaration-name completion handles restricted and grouped annotations while ignoring comments',()=>{
 const names=documentNames('Hoge & !null required=unknown(); (m.Hoge & !null)[] list=[]; // Hoge & !null fake=null;');
 assert.ok(names.has('required'));assert.ok(names.has('list'));assert.ok(!names.has('fake'));
});
