'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const host=require('../hostCompletion');
test('lazy parameters retain their value type and signature flag',()=>{
  const catalog={symbols:{},types:{},assets:[],contexts:[]};
  const env=host.environmentAt(host.tokens('int twice(lazy int value){return value+value;} twice').tokens,catalog);
  const parameter=env.get('twice').entry.signatures[0].parameters[0];
  assert.equal(parameter.type,'int');
  assert.equal(parameter.lazy,true);
  assert.equal(parameter.optional,false);
});
test('lazy parameter hides an outer binding with the parameter value type',()=>{
  const catalog={symbols:{},types:{},assets:[],contexts:[]};
  const env=host.environmentAt(host.tokens('string value="x"; int f(lazy int value){ value').tokens,catalog);
  assert.deepEqual(env.get('value').types,['int']);
});
test('analysis preserves exported lazy flags and diagnoses unsupported defaults',async()=>{
  const {analyzeSource,checkSource}=require('../checker');
  const executable=require('node:path').resolve(__dirname,'../bin', process.platform === 'win32' ? 'dua-check.exe' : 'dua-check');
  const analysis=await analyzeSource(executable,'export int twice(lazy int value){return value+value;}',{sourceName:'lazy.dua'}).promise;
  assert.deepEqual(analysis.diagnostics,[]);
  assert.deepEqual(analysis.exports.find(value=>value.name==='twice').parameterLazy,[true]);
  const errors=await checkSource(executable,'int bad(lazy int value=1){return value;}').promise;
  assert.ok(errors.some(error=>error.message.includes('Lazy default')));
});
