'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const {tokens,resolveExpression,environmentAt}=require('../hostCompletion');
const catalog={types:{},symbols:{}};
function inferred(source,expr){
 const environment=environmentAt(tokens(source).tokens,catalog);
 return resolveExpression(tokens(expr).tokens,environment,catalog)?.types;
}
test('string indexing and length infer an integer byte for all UTF-8 text',()=>{
 for(const text of ['A','日本','😀','é']){
   const source=`string text="${text}";auto byte=text[0];auto size=text.length;`;
   assert.deepEqual(inferred(source,'byte'),['int']);
   assert.deepEqual(inferred(source,'size'),['int']);
   assert.deepEqual(inferred('',`"${text}"[0]`),['int']);
 }
 assert.equal(inferred('string text="AB";','text[0..1]'),undefined);
});
test('indexed array strings support chained indexing without treating tables as strings',()=>{
 assert.deepEqual(inferred('string[] text=["A"];','text[0][0]'),['int']);
 assert.deepEqual(inferred('string[] text=["A"];','text[0].length'),['int']);
 assert.equal(inferred('auto t={a="A"};','t["a"]'),undefined); // Dynamic table fields remain unknown.
});
