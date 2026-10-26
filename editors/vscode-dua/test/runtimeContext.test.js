'use strict';
const test = require('node:test'), assert = require('node:assert/strict');
const fs = require('node:fs'), os = require('node:os'), path = require('node:path');
const { createContext } = require('../assetCompletion');
const intelligence = require('../moduleIntelligence');
const { analyzeSource } = require('../checker');
const executable = path.resolve(__dirname, '../bin/dua-check.exe');

test('validated runtime contexts preserve native module kinds and known member types', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dua-runtime-context-'));
  try {
    const file = path.join(root, 'level.scene'); fs.writeFileSync(file, 'fixture');
    const stat = fs.statSync(file);
    const catalog = {root, symbols:{}, types:{}, contexts:[{script:'script/main.dua', assetDirectory:'sceneItem',
      sources:[{path:'level.scene', size:stat.size, modifiedMs:Math.trunc(stat.mtimeMs)}],
      bindings:{scenes:{kind:'module'}, 'scenes.player':{kind:'variable',type:'Character'}}}]};
    const context = createContext(catalog, path.join(root,'script/main.dua'));
    assert.deepEqual(context.directories, [path.join(root,'sceneItem')]);
    assert.equal(context.catalog.symbols.scenes.kind, 'module');
    const scenes = intelligence.hostModules(context.catalog).find(value => value.name === 'scenes');
    assert.equal(scenes.exportsComplete, false);
    assert.equal(scenes.exports.find(value => value.name === 'player').type, 'Character');
  } finally { fs.rmSync(root, {recursive:true,force:true}); }
});

test('default paths use validated runtime directories; explicit settings retain workspace semantics', () => {
  const root = path.resolve('workspace'), scene = path.join(root,'sceneItem'), other = path.join(root,'other');
  const patterns = ['?.dua','?/init.dua'];
  assert.deepEqual(intelligence.modulePathContexts(root,[scene,scene,other],patterns,false),
    [scene,other].map(base => patterns.map(pattern => path.resolve(base,pattern))));
  assert.deepEqual(intelligence.moduleSearchPaths(root,[scene],patterns,true), patterns.map(pattern => path.resolve(root,pattern)));
  assert.deepEqual(intelligence.moduleSearchPaths(root,[],patterns,false), patterns.map(pattern => path.resolve(root,pattern)));
  const absolute = path.join(other,'?.dua');
  assert.deepEqual(intelligence.moduleSearchPaths(root,[scene],[absolute],false),[absolute]);
});

test('native signatures remain precise only when a single required parameter list is known', () => {
  const catalog = {symbols:{api:{kind:'module'},
    'api.fixed':{signatures:[{returnType:'int',parameters:[{type:'int'}]}]},
    'api.optional':{signatures:[{returnType:'int',parameters:[{type:'int',optional:true}]}]},
    'api.overloaded':{signatures:[{returnType:'int',parameters:[]},{returnType:'string',parameters:[{type:'string'}]}]}}};
  const members = intelligence.hostModules(catalog)[0].exports;
  assert.deepEqual(members.find(value=>value.name==='fixed').parameterTypes,['int']);
  assert.equal(members.find(value=>value.name==='fixed').variadic,false);
  for (const name of ['optional','overloaded']) {
    const member = members.find(value=>value.name===name);
    assert.deepEqual(member.parameterTypes,[]); assert.equal(member.variadic,true);
  }
  assert.equal(members.find(value=>value.name==='overloaded').type,'any');
});

test('shared scripts retain only service results confirmed in every runtime context', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(),'dua-shared-context-'));
  try {
    const dirs = ['a','b'].map(name=>path.join(root,name));
    for (const dir of dirs) fs.mkdirSync(dir);
    fs.writeFileSync(path.join(dirs[0],'values.dua'),'export int count = 1;');
    fs.writeFileSync(path.join(dirs[1],'values.dua'),'export string count = "one";');
    const options = {sourceName:path.join(root,'main.dua'),moduleContexts:dirs.map(dir=>[path.join(dir,'?.dua')])};
    const source = 'import values as v; int count = v.count; int certain = "bad";';
    const result = await analyzeSource(executable,source,options).promise;
    assert.equal(result.diagnostics.length,1);
    assert.match(result.diagnostics[0].message,/certain/);
    assert.equal(intelligence.definitionAt(source,source.indexOf('v.count')+3,result,{symbols:{},types:{}}),null);
    assert.ok(!intelligence.catalogWithImports({symbols:{},types:{}},result).symbols['v.count']);
  } finally {fs.rmSync(root,{recursive:true,force:true});}
});

test('partial native modules allow unknown values while sealed source exports and known type errors remain', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(),'dua-partial-host-'));
  try {
    fs.writeFileSync(path.join(root,'closed.dua'),'int privateValue = 1; export int count = 1;');
    const options = {sourceName:path.join(root,'main.dua'), modulePaths:[path.join(root,'?.dua')],
      hostClassTypes:['ListView'],hostModules:[{name:'scenes',exportsComplete:false,exports:[{name:'count',kind:'variable',type:'int'}]}]};
    const result = await analyzeSource(executable,'import scenes; auto value = scenes.runtimeOnly; ListView view = null;',options).promise;
    assert.deepEqual(result.diagnostics,[]);
    const complete = await analyzeSource(executable,'import scenes; auto value = scenes.runtimeOnly;',
      {...options,hostModules:[{...options.hostModules[0],exportsComplete:true}]}).promise;
    assert.ok(complete.diagnostics.some(value=>/runtimeOnly/.test(value.message)));
    const defaultPartial = await analyzeSource(executable,'import scenes; auto value = scenes.runtimeOnly;',
      {...options,hostModules:[{name:'scenes',exports:[]}]}).promise;
    assert.deepEqual(defaultPartial.diagnostics,[]);
    const bad = await analyzeSource(executable,'import scenes; import closed; int bad = "no"; string count = scenes.count; auto value = closed.privateValue;',options).promise;
    assert.ok(bad.diagnostics.some(value=>/bad/.test(value.message)));
    assert.ok(bad.diagnostics.some(value=>/count/.test(value.message)));
    assert.ok(bad.diagnostics.some(value=>/privateValue/.test(value.message)));
  } finally {fs.rmSync(root,{recursive:true,force:true});}
});
