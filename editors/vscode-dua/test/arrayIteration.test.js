'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const {checkSource}=require('../checker');
const {completions,documentNames}=require('../language');
const executable=path.resolve(__dirname,'../bin',process.platform==='win32'?'dua-check.exe':'dua-check');

test('checker accepts resize/reverse in ordinary and suspended functions',async()=>{
  for(const source of [
    'int[] a;a.length=4;a.length+=2;foreach_reverse(i,v;a){int n=i+v;}',
    'alias Numbers=int[];Numbers a=[];uint size=2;a.length=size;foreach_reverse(v;a){int n=v;}',
    'long lo=-2;uint hi=3;foreach_reverse(i;lo..hi){if(i==1)continue;}',
    'auto co=coroutine.create((){int[][] a;a.length=2;a[1].length=3;foreach_reverse(i,v;a){yield i;v.length=0;}return a.length;});'
  ])assert.deepEqual(await checkSource(executable,source).promise,[],source);
});

test('checker rejects bad length types, non-lvalues and reverse targets/bodies',async()=>{
  for(const source of [
    'int[] a=[];a.length=1.5;', 'int[] a=[];a.length=true;',
    'int[] a=[];a.length="3";', 'int[] a=[];a[0..0].length=2;',
    'int[] get(){return [1];}get().length=2;', 'int[int] a;a.length=3;',
    'foreach_reverse(v;"abc"){}', 'foreach_reverse(v;{a=1}){}',
    'foreach_reverse(v;[1:2]){}', 'foreach_reverse(i,v;0..3){}',
    'foreach_reverse(i;0..3){int wrong="bad";}',
    'int[] a=[1];foreach_reverse(i,v;a){string wrong=v;}'
  ])assert.ok((await checkSource(executable,source).promise).length>0,source);
});

test('reverse keyword, iterators and snippet complete',()=>{
  const source='foreach_reverse(index,value;[1,2]){}\n';
  const labels=completions(source,source.length).map(x=>x.label);
  for(const name of ['foreach_reverse','index','value'])assert.ok(labels.includes(name),name);
  assert.equal(documentNames(source).get('index'),'iterator');
  const snippets=JSON.parse(fs.readFileSync(path.resolve(__dirname,'../snippets/dua.json'),'utf8'));
  assert.equal(snippets['Foreach reverse'].prefix,'foreach_reverse');
  assert.match(snippets['Foreach reverse'].body[0],/^foreach_reverse \(/);
});

test('TextMate highlights reverse iteration as control flow',async()=>{
  const textmate=require('vscode-textmate'),oniguruma=require('vscode-oniguruma');
  await oniguruma.loadWASM(fs.readFileSync(require.resolve('vscode-oniguruma/release/onig.wasm')).buffer);
  const registry=new textmate.Registry({
    onigLib:Promise.resolve({createOnigScanner:p=>new oniguruma.OnigScanner(p),createOnigString:s=>new oniguruma.OnigString(s)}),
    loadGrammar:async()=>JSON.parse(fs.readFileSync(path.resolve(__dirname,'../syntaxes/dua.tmLanguage.json'),'utf8'))
  });
  const grammar=await registry.loadGrammar('source.dua');
  const result=grammar.tokenizeLine('foreach_reverse(i,v;items){yield v;}');
  assert.ok(result.tokens[0].scopes.includes('keyword.control.dua'));
  registry.dispose();
});
