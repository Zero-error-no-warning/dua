'use strict';
const test = require('node:test'), assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), os = require('node:os');
const sig = require('../signatureHelp'), host = require('../hostCompletion'), modules = require('../moduleIntelligence');
const {analyzeSource} = require('../checker');
const empty = {symbols:{},types:{}};
const parameters = (...types)=>types.map((type,i)=>({type,name:`p${i}`}));
const method = {kind:'method',signatures:[{returnType:'void',parameters:parameters('double','double')}]};
const catalog = {symbols:{make:{kind:'function',signatures:[{returnType:'Actor',parameters:[]}]},
  choose:{kind:'function',signatures:[{returnType:'int',parameters:parameters('int')},{returnType:'string',parameters:parameters('string','int')}]},
  Actor:{kind:'type',type:'Actor',signatures:[{returnType:'Actor',parameters:parameters('string')}]},
  'Actor.create':{kind:'function',signatures:[{returnType:'Actor',parameters:parameters('int')}]}
},types:{Actor:{members:{move:method,again:{kind:'method',signatures:[{returnType:'Actor',parameters:[]}]}}}}};
function help(source, metadata=empty) {
  const offset = source.indexOf('|');
  source = source.replace('|','');
  return sig.signatureHelp(source,offset<0?source.length:offset,metadata);
}

test('local declarations, aliases, forward declarations, scope and shadowing',()=>{
  const declaration = 'uint total(uint count, string label = "a") { return count; }\n';
  const result = help(declaration+'total(1, |);');
  assert.equal(result.signatures[0].label,'total(uint count, string label = …) → uint');
  assert.equal(result.activeParameter,1);
  assert.equal(result.signatures[0].label.slice(...result.signatures[0].parameters[1].label),'string label = …');
  assert.match(help('total(|);\n'+declaration).signatures[0].label,/uint count/);
  assert.match(help(declaration+'auto alias = total; alias(|);').signatures[0].label,/alias\(uint count/);
  assert.equal(help(declaration+'{ int total = 1; total(|); }'),null);
  assert.match(help(declaration+'{ int total = 1; } total(|);').signatures[0].label,/uint count/);
  assert.equal(help('void local(int count|) {}'),null);
  assert.equal(help('if (true|) {}'),null);
  assert.equal(help('unknown(|);'),null);
  assert.equal(help('void outer(any callback){} outer((){ int unrelated=1; | });'),null);
  assert.equal(help('int delegate(int,string) callback = unknown; callback(1,|);').activeParameter,1);
});

test('argument positions survive nested calls, collections, strings, comments and multiple lines',()=>{
  const prefix='void outer(any a, any b, any c) {} void inner(any x, any y) {}\n';
  for (const body of ['outer(inner(1, 2), |);','outer([1,2], |);','outer({a=1,b=2}, |);',
    'outer("comma, paren ) and \\" quote", |);','outer(i"nested $(inner(1,2))", |);',
    'outer(1, /+ nested /+ , +/ ) +/ |);','outer(\n1,\n|);']) {
    const result=help(prefix+body);
    assert.ok(result,body);assert.equal(result.activeParameter,1,body);assert.match(result.signatures[0].label,/^outer\(/);
  }
  assert.match(help(prefix+'outer(inner(1, |), 2);').signatures[0].label,/^inner\(/);
  assert.equal(help(prefix+'outer("incomplete , |').activeParameter,0);
  assert.equal(help(prefix+'outer(1, // comment , |'),null);
  assert.equal(help(prefix+'outer(1,2); |'),null);
});

test('host reflected methods, constructors, chained calls, UFCS, with and overloads',()=>{
  for(const source of ['Actor actor=null; actor.move(1, |);','make().move(1, |);','make().again().move(1, |);',
    'auto actor=make(); with(actor) .move(1, |);','int n = 1 + make().move(1, |);']) {
    const result=help(source,catalog);assert.ok(result,source);assert.equal(result.activeParameter,1);assert.match(result.signatures[0].label,/double p1/);
  }
  assert.match(help('Actor(|);',catalog).signatures[0].label,/string p0/);
  assert.match(help('Actor.create(|);',catalog).signatures[0].label,/int p0/);
  assert.equal(help('choose(1, |);',catalog).activeSignature,1);
  assert.equal(help('choose(|);',catalog).signatures.length,2);
  const local='int plus(int receiver, int amount) { return receiver+amount; } int n=1; n.plus(|);';
  assert.equal(help(local).signatures[0].label,'n.plus(int amount) → int');
});

test('lazy, variadic, optional and standard-library signatures reuse existing metadata',()=>{
  const source='any collect(lazy int first, any rest...) { return rest; } collect(1,2,|);';
  const result=help(source);assert.ok(result);assert.equal(result.activeParameter,1);
  assert.match(result.signatures[0].label,/lazy int first, any rest\.\.\./);
  assert.match(help('map([1,2], |);').signatures[0].label,/any callback/);
  assert.equal(help('math.max(1,2,3,|);').activeParameter,1);
  assert.equal(help('iota(1,|);').signatures.length,2);
});

test('unfinished-call service projection keeps declarations after cursor and never changes original source',async()=>{
  const executable=path.resolve(__dirname,'../bin',process.platform==='win32'?'dua-check.exe':'dua-check');
  const root=fs.mkdtempSync(path.join(os.tmpdir(),'dua-signature-'));
  const imported=path.join(root,'values.dua'), sourceName=path.join(root,'main.dua');
  fs.writeFileSync(imported,'export alias Count = uint; export Count read(Count amount, string label = "x") { return amount; }');
  try {
    for(const body of ['n.read(|);','n.read(1, |);','void run() { n.read(1, |); }',
      'void run() { n.read(1, |}', 'void run() { n.read(1, |', 'n.read(other(1,|']) {
      const text='import values as n;\n'+body, offset=text.indexOf('|'), source=text.replace('|','');
      const projected=sig.analysisSource(source,sig.callContext(source,offset));
      const result=await analyzeSource(executable,projected,{sourceName,modulePaths:[path.join(root,'?.dua')]}).promise;
      assert.equal(result.imports.length,1,body+'\n'+projected+'\n'+JSON.stringify(result.diagnostics));
      if(!body.includes('other(')) {
        const resolved=modules.catalogWithImports(empty,result,sourceName);
        const help=sig.signatureHelp(source,offset,resolved);
        assert.ok(help,body);assert.match(help.signatures[0].label,/Count amount, string label = …/);
      }
    }
    const source='import values as n; n.read(|); struct Later { int member; }'.replace('|','');
    const offset=source.indexOf('read(')+5;
    const result=await analyzeSource(executable,sig.analysisSource(source,sig.callContext(source,offset)),{sourceName,modulePaths:[path.join(root,'?.dua')],
      overlays:[{sourceName:imported,source:'export uint read(uint changed, string label="new") { return changed; }'}]}).promise;
    assert.ok(result.modules.find(m=>m.sourceName===sourceName)?.types.some(t=>t.name==='Later'));
    assert.match(sig.signatureHelp(source,offset,modules.catalogWithImports(empty,result,sourceName)).signatures[0].label,/uint changed/);
  } finally {fs.rmSync(root,{recursive:true,force:true});}
});

test('native module aliases retain all reflected overloads instead of an unknown zero-argument summary',async()=>{
  const executable=path.resolve(__dirname,'../bin',process.platform==='win32'?'dua-check.exe':'dua-check');
  const catalog={symbols:{native:{kind:'module'},'native.overload':{kind:'function',signatures:[
    {returnType:'int',parameters:[{type:'int',name:'number'}]},
    {returnType:'string',parameters:[{type:'string',name:'text'}]}
  ]}},types:{}};
  const source='import native as n; n.overload(';
  const result=await analyzeSource(executable,sig.analysisSource(source,sig.callContext(source,source.length)),{
    sourceName:path.join(os.tmpdir(),'dua-native-signature.dua'),hostModules:modules.hostModules(catalog)
  }).promise;
  const resolved=modules.catalogWithImports(catalog,result);
  const help=sig.signatureHelp(source,source.length,resolved);
  assert.deepEqual(help.signatures.map(s=>s.label),['n.overload(int number) → int','n.overload(string text) → string']);
  const missing=modules.catalogWithImports(empty,result);
  assert.equal(sig.signatureHelp(source,source.length,missing),null,'unknown host arity is not advertised as a zero-parameter function');
});

test('local annotations keep readable aliases while retaining opaque identities for inference',()=>{
  const catalog={symbols:{Item:{kind:'type',type:'__dua_module_123_Item',displayType:'Item'}},types:{'__dua_module_123_Item':{members:{}}}};
  const result=help('Item echo(Item item){return item;} echo(|);',catalog);
  assert.equal(result.signatures[0].label,'echo(Item item) → Item');
});
