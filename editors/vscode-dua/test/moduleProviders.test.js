'use strict';
const test = require('node:test'), assert = require('node:assert/strict'), Module = require('node:module');
const fs = require('node:fs'), path = require('node:path'), os = require('node:os');
const signal = () => {const listeners=[]; return {event: f => {listeners.push(f); return {dispose(){}};}, fire: e => listeners.forEach(f => f(e))};};
const uri = fsPath => ({scheme:'file', fsPath, toString:() => fsPath});
function document(file, source) {
  return {uri:uri(file), languageId:'dua', source, version:1, isClosed:false,
    getText(){return this.source;}, offsetAt(p){return this.source.split('\n').slice(0,p.line).reduce((n,s)=>n+s.length+1,0)+p.character;},
    positionAt(offset){const lines=this.source.slice(0,offset).split('\n'); return {line:lines.length-1,character:lines.at(-1).length};}};
}
async function until(test) {for(let i=0;i<150;i++){if(test())return; await new Promise(r=>setTimeout(r,20));} throw Error('Timed out waiting for module providers');}
async function fixture(run, checker) {
  const root=fs.mkdtempSync(path.join(os.tmpdir(),'dua-module-providers-'));
  const types=path.join(root,'types.dua'), entry=path.join(root,'main.dua');
  fs.writeFileSync(types,'auto text = "日本😀"; export alias ItemKind = "one" | "two";\nexport ItemKind selected = "one";');
  const main=document(entry,'import "./types.dua" as commonTypes;\ncommonTypes.ItemKind value = "one";');
  fs.writeFileSync(entry,main.source);
  fs.writeFileSync(path.join(root,'.dua-completion.json'),JSON.stringify({schemaVersion:1,symbols:{ListView:{kind:'type',type:'ListView'}},types:{ListView:{kind:'class',members:{}}}}));
  const values=new Map(), other=new Map([['keep','unchanged']]), events={open:signal(),change:signal(),close:signal(),config:signal(),trust:signal()}, watchers=[];
  const disposable=()=>({dispose(){}}), context={subscriptions:[],asAbsolutePath:f=>path.resolve(__dirname,'..',f)};
  let completion, definition;
  const vscode={Uri:{file:uri},CompletionItemKind:{},DiagnosticSeverity:{Error:0},
    Position:class{constructor(line,character){Object.assign(this,{line,character});}},
    Range:class{constructor(start,end){Object.assign(this,{start,end});}},
    Location:class{constructor(uri,range){Object.assign(this,{uri,range});}},
    RelativePattern:class{constructor(baseUri,pattern){Object.assign(this,{baseUri,pattern});}},
    Diagnostic:class{constructor(range,message){Object.assign(this,{range,message});}},
    CompletionItem:class{constructor(label,kind){Object.assign(this,{label,kind});}},
    languages:{createDiagnosticCollection:name=>{assert.equal(name,'dua');return{set:(u,v)=>values.set(u.toString(),v),delete:u=>values.delete(u.toString()),clear:()=>values.clear(),dispose(){}};},
      registerCompletionItemProvider:(selector,provider)=>{completion=provider;return disposable();},
      registerDefinitionProvider:(selector,provider)=>{definition=provider;return disposable();}},
    window:{createOutputChannel:()=>({appendLine(){},dispose(){}}),showWarningMessage(){}},
    workspace:{isTrusted:true,textDocuments:[main],getWorkspaceFolder:value=>value.fsPath.toLowerCase().startsWith(root.toLowerCase()+path.sep)?{uri:uri(root)}:undefined,
      getConfiguration:()=>({get:(key,fallback)=>key==='diagnostics.delay'?0:fallback}),
      onDidOpenTextDocument:events.open.event,onDidChangeTextDocument:events.change.event,onDidCloseTextDocument:events.close.event,
      onDidChangeConfiguration:events.config.event,onDidGrantWorkspaceTrust:events.trust.event,
      createFileSystemWatcher:pattern=>{const create=signal(),change=signal(),remove=signal();const result={pattern,onDidCreate:create.event,onDidChange:change.event,onDidDelete:remove.event,create,change,remove,dispose(){}};watchers.push(result);return result;}}};
  const original=Module._load, file=require.resolve('../extension');delete require.cache[file];
  let extension;
  try {Module._load=function(name,...args){if(name==='vscode')return vscode;if(name==='./checker'&&checker)return checker;if(name==='./sceneDiagnostics')return{activateSceneDiagnostics(){}};return original.call(this,name,...args);};extension=require(file);}
  finally {Module._load=original;}
  extension.activate(context);
  const update=(doc,source)=>{doc.source=source;doc.version++;events.change.fire({document:doc});};
  try {await run({root,types,entry,main,values,events,watchers,vscode,completion,definition,update,other});}
  finally {for(const value of context.subscriptions.toReversed())value?.dispose();delete require.cache[file];await new Promise(r=>setTimeout(r,30));fs.rmSync(root,{recursive:true,force:true});}
}

test('registered providers consume real service export completion, import paths and Unicode definition positions',()=>fixture(async ({main,types,completion,definition,update})=>{
  update(main,'import "./types.dua" as commonTypes;\ncommonTypes.');
  const items=await completion.provideCompletionItems(main,main.positionAt(main.source.length));
  assert.ok(items.some(item=>item.label==='ItemKind'));
  assert.ok(items.some(item=>item.label==='selected'));
  update(main,'import "./types.dua" as commonTypes;\ncommonTypes.ItemKind value = "one";');
  const target=await definition.provideDefinition(main,main.positionAt(main.source.indexOf('ItemKind')+2));
  assert.equal(target.uri.fsPath.toLowerCase(),types.toLowerCase());
  assert.equal(target.range.start.line,0);
  assert.ok(target.range.start.character>20);
  update(main,'import "./ty');
  const candidates=await completion.provideCompletionItems(main,main.positionAt(main.source.length));
  assert.ok(candidates.some(item=>item.label==='./types.dua'&&item.insertText==='./types.dua'));
}));

test('dependency diagnostics use target snapshots; dirty edits and deletes clear stale target locations',()=>fixture(async ({root,main,values,vscode,events,watchers,update,other})=>{
  const bad=path.join(root,'bad.dua'), text='auto title = "日本😀"; int broken = "bad";';
  fs.writeFileSync(bad,text);
  const dependency=document(bad,text);vscode.workspace.textDocuments.push(dependency);
  update(main,'import "./bad.dua";');
  const badEntries=()=>[...values].filter(([name])=>name.toLowerCase().endsWith('bad.dua')).flatMap(([,items])=>items);
  await until(()=>badEntries().some(item=>/expects int/.test(item.message)));
  assert.equal(badEntries()[0].range.start.character,text.indexOf('int broken'));
  update(dependency,'auto title = "日本😀"; int broken = 1;');
  assert.equal(values.size,0,'old dependency locations clear synchronously');
  await new Promise(r=>setTimeout(r,220));
  assert.equal(badEntries().length,0);
  dependency.isClosed=true;vscode.workspace.textDocuments.splice(vscode.workspace.textDocuments.indexOf(dependency),1);events.close.fire(dependency);
  fs.unlinkSync(bad);watchers[0].remove.fire(uri(bad));
  await until(()=>[...values.values()].flat().some(item=>/Cannot resolve|not found/i.test(item.message)));
  assert.equal(badEntries().length,0);
  assert.deepEqual([...other],[['keep','unchanged']]);
}));

test('an overlay edit cancels module queries and old responses cannot restore diagnostics or suggestions', async()=>{
  const requests=[];
  const checker={analyzeSource:(executable,source,options)=>{
    let resolve;const request={source,options,promise:new Promise(done=>{resolve=done;}),resolve:value=>resolve(value),cancel(){this.cancelled=true;}};
    requests.push(request);return request;
  }};
  await fixture(async({main,types,vscode,values,completion,update})=>{
    await until(()=>requests.length===1);
    const querying=completion.provideCompletionItems(main,main.positionAt(main.source.indexOf('ItemKind')+2));
    assert.equal(requests.length,2);
    const dependency=document(types,'export alias ItemKind = "changed";');vscode.workspace.textDocuments.push(dependency);
    update(dependency,'export alias ItemKind = "new";');
    assert.ok(requests[0].cancelled&&requests[1].cancelled);
    const old={schemaVersion:1,diagnostics:[{sourceName:main.uri.fsPath,sourceText:main.source,line:2,column:1,message:'old'}],modules:[],imports:[],exports:[],pathCompletions:[]};
    requests[0].resolve(old);requests[1].resolve(old);
    assert.deepEqual(await querying,[]);
    assert.equal(values.size,0);
    await until(()=>requests.length>=3);
    assert.ok(requests[2].options.overlays.some(value=>value.source===dependency.source));
    for(const request of requests.slice(2))request.resolve({...old,diagnostics:[]});
  },checker);
});

test('a closed dependency outside the workspace is watched using the returned service identity',()=>fixture(async({root,main,values,watchers,update})=>{
  const outside=fs.mkdtempSync(path.join(os.tmpdir(),'dua-external-dependency-'));
  try {
    const file=path.join(outside,'types.dua');fs.writeFileSync(file,'int broken = "bad";');
    const relative=path.relative(root,file).replaceAll('\\','/');
    update(main,`import "${relative}";`);
    const errors=()=>[...values.values()].flat().filter(item=>/expects int/.test(item.message));
    await until(()=>errors().length>0);
    const watcher=watchers.find(w=>w.pattern?.baseUri?.fsPath.toLowerCase()===outside.toLowerCase());
    assert.ok(watcher,'external dependency is observed without a second resolver');
    fs.writeFileSync(file,'int broken = 1;');watcher.change.fire(uri(file));
    assert.equal(values.size,0);
    await new Promise(r=>setTimeout(r,220));assert.equal(errors().length,0);
  } finally {fs.rmSync(outside,{recursive:true,force:true});}
}));

test('registered providers offer unfinished named-table fields and resolve their type declarations',()=>fixture(async({main,types,completion,definition,update})=>{
  fs.writeFileSync(types,'export table Hoge { int x; string label; }');
  update(main,'import "./types.dua" as t; auto value = t.Hoge { x = 1, la');
  const items=await completion.provideCompletionItems(main,main.positionAt(main.source.length));
  const labels=items.filter(item=>item.label==='label');
  assert.equal(labels.length,1);assert.equal(labels[0].insertText,'label = ');
  update(main,'auto text = "日本😀"; table Local { int x; } auto value = Local { x = 1 };');
  const local=await definition.provideDefinition(main,main.positionAt(main.source.lastIndexOf('Local')+2));
  assert.equal(local.uri.fsPath.toLowerCase(),main.uri.fsPath.toLowerCase());
  assert.equal(local.range.start.line,0);
  assert.equal(local.range.start.character,main.source.indexOf('table Local'));
}));

test('registered completion provider follows known UFCS property returns without treating a function value as its result',()=>fixture(async({main,completion,update})=>{
  const prefix='table Result { int count; } Result convert(int n){ return Result {count=n}; } ';
  update(main,prefix+'auto value=(3).convert; value.');
  const items=await completion.provideCompletionItems(main,main.positionAt(main.source.length));
  assert.ok(items.some(item=>item.label==='count'));
  update(main,prefix+'auto value=convert; value.');
  const callable=await completion.provideCompletionItems(main,main.positionAt(main.source.length));
  assert.ok(!callable.some(item=>item.label==='count'));
}));

test('registered providers retain nonnull wrapper completion and imported type definitions',()=>fixture(async({main,types,completion,definition,update})=>{
 fs.writeFileSync(types,'auto text="日本😀"; export table Item{int count;} export alias Required=Item & !null;');
 const prefix='import "./types.dua" as m; m.Item & !null value=m.Item{count=1}; ';
 update(main,prefix+'value.');
 const items=await completion.provideCompletionItems(main,main.positionAt(main.source.length));
 assert.ok(items.some(item=>item.label==='count'));
 update(main,prefix+'auto pending=m.Required {');
 const fields=await completion.provideCompletionItems(main,main.positionAt(main.source.length));
 assert.ok(fields.some(item=>item.label==='count'&&item.insertText==='count = '));
 update(main,prefix);
 const target=await definition.provideDefinition(main,main.positionAt(prefix.indexOf('m.Item &')+3));
 assert.equal(target.uri.fsPath.toLowerCase(),types.toLowerCase());
 assert.equal(target.range.start.character,'auto text="日本😀"; export '.length);
}));

test('registered completion provider retains array and AA element shapes across nullable handles',()=>fixture(async({main,types,completion,update})=>{
 fs.writeFileSync(types,'export table Item{int count;}');
 const prefix='import "./types.dua" as m; m.Item[] source=[m.Item{count=1}]; m.Item[] point=null; point=source; ';
 update(main,prefix+'point[0].');
 const array=await completion.provideCompletionItems(main,main.positionAt(main.source.length));
 assert.ok(array.some(item=>item.label==='count'));
 update(main,prefix+'m.Item[string] mapping=null; mapping["one"].');
 const aa=await completion.provideCompletionItems(main,main.positionAt(main.source.length));
 assert.ok(aa.some(item=>item.label==='count'));
}));
