'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { checkSource,analyzeSource } = require('../checker');
const executable=path.resolve(__dirname,'../bin/dua-check.exe');
test('overloaded host binary operators do not imply a numeric result',async()=>{
 for(const expr of ['v * 2.0','2.0 * v','v / 2.0','v + v','v % v','v ~ v','(v * 2.0) * 3.0']){
  assert.deepEqual(await checkSource(executable,'Vec3 v=Vec3(1,2,3);v='+expr+';').promise,[],expr);
 }
 assert.deepEqual(await checkSource(executable,'alias V=Vec3; V v=Vec3(1,2,3);v=v*2.0;').promise,[]);
 assert.deepEqual(await checkSource(executable,'Vec3 v=Vec3(1,2,3);double dot=v%v;').promise,[]);
});
test('numeric inference and real type mismatches remain diagnostic',async()=>{
 for(const code of ['Vec3 v=3.0;','int n=1;n=n*2.0;','int n=1;n=n/2;','string s=1.0*2.0;','int[] n=[1];n=n~"bad";','ArrayNode[] a=[];OtherNode other=OtherNode();a~=other;']){
  assert.ok((await checkSource(executable,code).promise).length>0,code);
 }
 for(const code of ['int n=1;n=n*2;','double n=1.0;n=n*2.0;','int[] n=[1];n=n~2;'])assert.deepEqual(await checkSource(executable,code).promise,[],code);
});
test('module graph uses the same conservative overload inference',async()=>{
 const source='Vec3 v=Vec3(1,2,3);v=v*2.0;';
 assert.deepEqual((await analyzeSource(executable,source,{sourceName:'vector.dua'}).promise).diagnostics,[]);
 assert.deepEqual(await checkSource(executable,'table V {int x;} V v=V{x=1};v=v*2;').promise,[]);
});
