'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const host=require('../hostCompletion');
const language=require('../language');
const {signatureHelp}=require('../signatureHelp');
const catalog={types:{},symbols:{}};
function infer(source,expr){return host.resolveExpression(host.tokens(expr).tokens,host.environmentAt(host.tokens(source).tokens,catalog),catalog)?.types;}
test('Unicode helpers have matching return types and UTF-8 byte indexing remains integer',()=>{
 for(const expr of ['count("あいう")','"あいう".count','"あいう".count()'])assert.deepEqual(infer('',expr),['int']);
 for(const expr of ['charAt("あいう",0)','"あいう".charAt(0)'])assert.deepEqual(infer('',expr),['string']);
 assert.deepEqual(infer('auto c="あいう".charAt(0);','c[0]'),['int']);
 const labels=language.completions('',0).map(item=>item.label);
 assert.ok(labels.includes('count')&&labels.includes('charAt'));
});
test('Unicode helper signatures support global and UFCS forms, with declaration shadowing',()=>{
 for(const source of ['charAt("あいう",','"あいう".charAt(']){
   const hint=signatureHelp(source,source.length,catalog);assert.ok(hint);
   assert.match(hint.signatures[0].label,/int index/);assert.match(hint.signatures[0].label,/string/);
 }
 assert.deepEqual(infer('string count(string s){return "mine";}','count("A")'),['string']);
 assert.deepEqual(infer('int charAt(string s,int i){return 42;}','"A".charAt(0)'),['int']);
 assert.deepEqual(infer('int count=3;','count'),['int']);
});

test('string member completion offers Unicode helpers while honoring shadowing',()=>{
 const list=source=>host.apiCompletions(source,source.length,catalog).map(entry=>entry.label).sort();
 assert.deepEqual(list('"あいう".'),['charAt','count','length']);
 assert.deepEqual(list('int count=3;"A".'),['charAt','length']);
});