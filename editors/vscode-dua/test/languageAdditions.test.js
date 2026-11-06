'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const path=require('node:path');
const {checkSource}=require('../checker');
const {apiCompletions}=require('../hostCompletion');
const {signatureHelp}=require('../signatureHelp');
const executable=path.resolve(__dirname,'../bin/dua-check.exe');

test('checker accepts language additions and implicit floating conversion',async()=>{
  for(const source of [
    'double f(double x){return x;}double x=f(1);x=2;',
    'alias Number=double|int;Number x=1;',
    'void bump(ref int n){n+=1;}int n=0;bump(n:n);',
    'any actor=null;auto x=actor?.position?.x ?? 0;',
    'int f(int a=1,int b=2){try{return a+b;}finally{int cleanup=1;}}auto x=f(b:4);',
    'import math;import random;import string;double n=math.sqrt(9);auto text=string.format("%d",3);'
  ])assert.deepEqual(await checkSource(executable,source).promise,[],source);
});

test('checker rejects bad ref arguments and named argument misuse',async()=>{
  for(const source of [
    'void f(ref double x){}int x=1;f(x);',
    'void f(ref int x){}f(1);',
    'int f(int a){return a;}f(missing:1);',
    'int f(int a){return a;}f(a:1,a:2);',
    'any x=null;x?.value=1;',
    'try{}finally{return 1;}'
  ])assert.ok((await checkSource(executable,source).promise).length>0,source);
});

test('ref parameters retain typed completion and signature labels',()=>{
  const catalog={symbols:{Actor:{kind:'type',type:'Actor'}},types:{Actor:{members:{hp:{kind:'property',type:'int'}}}}};
  const source='void update(ref Actor actor){actor.';
  assert.ok(apiCompletions(source,source.length,catalog).some(item=>item.label==='hp'));
  const call='void update(ref int value){}int n=1;update(';
  const result=signatureHelp(call,call.length,catalog);
  assert.match(result.signatures[0].label,/ref int value/);
});
