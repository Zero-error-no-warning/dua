'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),path=require('node:path');
const {analyzeSource}=require('../checker');
const host=require('../hostCompletion'),modules=require('../moduleIntelligence');
const exe=path.resolve(__dirname,'../bin/dua-check.exe'),sourceName=path.resolve(__dirname,'with-entry.dua');
const analyze=source=>analyzeSource(exe,source,{sourceName}).promise;
test('checker analyzes with types and leading member completions without exposing meta fields',async()=>{
 const source='auto meta={}; export table Vec with meta {int x;int y;} Vec v=Vec{x=1,y=2}; auto n=with(v) .x+.y;';
 const result=await analyze(source);assert.deepEqual(result.diagnostics,[]);
 const catalog=modules.catalogWithImports({symbols:{},types:{}},result,sourceName);
 const prefix=source+' auto pending=with(v) .';
 const projected=modules.completionSource(prefix,prefix.length);
 const projection=await analyze(projected);assert.deepEqual(projection.diagnostics,[]);
 const completed=host.apiCompletions(prefix,prefix.length,catalog).map(entry=>entry.label).sort();
 assert.deepEqual(completed,['x','y']);
 const type=result.modules.flatMap(unit=>unit.types).find(type=>type.name==='Vec');
 assert.deepEqual(Object.keys(type.fields).sort(),['x','y']);
});
test('checker reports outside dot, unsupported assignments and bad with targets',async()=>{
 for(const source of ['return .x;','auto t={x=1};with(t) .x=2;','return with(2) 3;','auto meta=2;table A with meta{int x;}']){
  const result=await analyze(source);assert.ok(result.diagnostics.length,source);
  assert.ok(result.diagnostics[0].line>0&&result.diagnostics[0].column>0);
 }
});
