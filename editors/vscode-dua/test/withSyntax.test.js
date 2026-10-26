'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const {apiCompletions,withScopes,tokens}=require('../hostCompletion');
const {resolveExpression,environmentAt}=require('../hostCompletion');
const {documentNames,completions}=require('../language');
const catalog={symbols:{Vec:{kind:'type',type:'Vec'}},types:{Vec:{members:{x:{kind:'property',type:'int'},child:{kind:'property',type:'Other'}}},Other:{members:{y:{kind:'property',type:'int'}}}}};
const labels=source=>apiCompletions(source,source.length,catalog).map(x=>x.label).sort();
test('with keyword and declaration name',()=>{
 assert.ok(completions('wi',2).some(x=>x.label==='with'));
 assert.equal(documentNames('table Hoge with meta {int x;}').get('Hoge'),'table');
 assert.ok(!documentNames('table Hoge with meta {int x;}').has('meta'));
});
test('leading dot targets, nested targets and normal names',()=>{
 assert.deepEqual(labels('Vec v; with(v) .'),['child','x']);
 assert.deepEqual(labels('Vec v; with(v) 2 + .'),['child','x']);
 assert.deepEqual(labels('Vec v; with(v) .child.'),['y']);
 assert.deepEqual(labels('Vec v; with(v) with(.child) .'),['y']);
 assert.deepEqual(labels('Vec v; with(v) .x; .'),[]);
 assert.deepEqual(labels('Vec v; with(v) .missing.'),[]);
 assert.deepEqual(completions('Vec v; with(v) .',19),[]);
});
test('with boundaries and strings/comments',()=>{
 assert.equal(withScopes(tokens('with(v) .x; after').tokens).length,0);
 assert.equal(withScopes(tokens('f(with(v) .x, after').tokens).length,0);
 assert.deepEqual(labels('Vec v; // with(v) .'),[]);
});
test('leading-dot chains do not resolve outer UFCS functions',()=>{
 const source='Vec v;';const env=environmentAt(tokens(source).tokens,catalog);
 const withReceiver=resolveExpression(tokens('v').tokens,env,catalog);
 const scoped={...catalog,symbols:{...catalog.symbols,fallback:{kind:'function',signatures:[{parameters:[{type:'Other',name:'value'}],returnType:'Vec'}]}}};
 assert.deepEqual(resolveExpression(tokens('.child.fallback()').tokens,env,scoped,{withReceiver})?.types||[],[]);
});
