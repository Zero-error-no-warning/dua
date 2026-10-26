'use strict';
const test = require('node:test'), assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), os = require('node:os');
const { analyzeSource } = require('../checker');
const intelligence = require('../moduleIntelligence');
const host = require('../hostCompletion');
const { diagnosticPosition } = require('../language');
const executable = path.resolve(__dirname, '../bin/dua-check.exe');
const empty = { symbols: {}, types: {} };
async function fixture(run) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dua-import-extension-'));
  fs.mkdirSync(path.join(root, 'common'));
  const sourceName = path.join(root, 'main.dua');
  const types = path.join(root, 'common/types.dua');
  const sourceText = 'auto text = "日本😀"; export alias ItemKind = "knife" | "food";\n'
    + 'alias Secret = int; export ItemKind selected = "knife";\n'
    + 'export ItemKind choose(ItemKind value) { return value; }\n';
  fs.writeFileSync(types, sourceText);
  const analyze = (source, extra = {}) => analyzeSource(executable, source, {
    sourceName, modulePaths: [path.join(root, '?.dua'), path.join(root, '?/init.dua')], hostClassTypes: ['ListView'], ...extra
  }).promise;
  try { await run({ root, sourceName, types, sourceText, analyze }); }
  finally { fs.rmSync(root, { recursive: true, force: true }); }
}

test('real service supplies paths, normalized identities and public export completion without flattening types', () => fixture(async ({analyze}) => {
  const source = 'import "./common/types.dua" as commonTypes;\nimport "./common/../common/types.dua" as second;\n'
    + 'commonTypes.ItemKind selected = commonTypes.selected; ListView list = null;';
  const result = await analyze(source, {importPathPrefix: './co'});
  assert.deepEqual(result.diagnostics, []);
  assert.equal(result.imports[0].key, result.imports[1].key);
  assert.equal(result.modules.filter(m => m.key === result.imports[0].key).length, 1);
  assert.ok(result.pathCompletions.some(c => c.label === './common/' && c.directory));
  const catalog = intelligence.catalogWithImports(empty, result);
  assert.ok(catalog.symbols['commonTypes.ItemKind']);
  assert.equal(catalog.symbols.ItemKind, undefined);
  assert.equal(catalog.symbols['commonTypes.Secret'], undefined);
  assert.equal(catalog.symbols['commonTypes.ItemKind'].type, catalog.symbols['second.ItemKind'].type);
  const partial = source + '\ncommonTypes.';
  const offered = host.apiCompletions(partial, partial.length, catalog).map(e => e.label);
  for (const name of ['ItemKind', 'selected', 'choose']) assert.ok(offered.includes(name), name);
  assert.ok(!offered.includes('Secret'));
  const shadow = source + '\n{ int commonTypes = 3; commonTypes.';
  assert.deepEqual(host.apiCompletions(shadow, shadow.length, catalog), []);
}));

test('real definition targets use service snapshots and UTF-8 export positions', () => fixture(async ({sourceName, analyze}) => {
  const source = 'import "./common/types.dua" as commonTypes;\ncommonTypes.ItemKind item = commonTypes.selected;';
  const result = await analyze(source);
  const alias = intelligence.definitionAt(source, source.indexOf('ItemKind') + 2, result, empty);
  assert.ok(alias && alias.sourceName !== sourceName);
  const position = diagnosticPosition(alias.sourceText, alias);
  assert.equal(position.line, 0);
  assert.ok(position.character > alias.sourceText.indexOf('😀'));
  assert.ok(alias.column - 1 > position.character, 'byte columns are converted against the target text');
  const imported = intelligence.definitionAt(source, source.indexOf('types.dua') + 2, result, empty);
  assert.equal(imported.sourceName, alias.sourceName);
  assert.equal(imported.line, 1);
  const named = 'import common.types as named; named.ItemKind value = "one";';
  const namedResult = await analyze(named);
  const namedTarget = intelligence.definitionAt(named, named.indexOf('types') + 2, namedResult, empty);
  assert.equal(namedTarget.sourceName, alias.sourceName);
  const privateReference = source + '\ncommonTypes.Secret';
  assert.equal(intelligence.definitionAt(privateReference, privateReference.indexOf('Secret') + 2, result, empty), null);
}));

test('overlays replace dependency text and include unsaved new files in service path results', () => fixture(async ({root, types, analyze}) => {
  const source = 'import "./common/types.dua" as t; t.ItemKind value = "new";';
  const result = await analyze(source, { overlays: [
    {sourceName: types, source: 'export alias ItemKind = "new";'},
    {sourceName: path.join(root, 'common/new.dua'), source: 'export int number = 1;'}
  ], importPathPrefix: './common/n' });
  assert.deepEqual(result.diagnostics, []);
  assert.ok(result.modules.some(m => m.sourceText === 'export alias ItemKind = "new";'));
  assert.ok(result.pathCompletions.some(c => c.label === './common/new.dua'));
}));

test('missing, cyclic and private-type diagnostics retain their own file snapshots', () => fixture(async ({root, analyze}) => {
  const missing = await analyze('import "./missing.dua";');
  assert.ok(missing.diagnostics.some(d => /not found|Cannot resolve/i.test(d.message)));
  const privateType = await analyze('import "./common/types.dua" as t; t.Secret x = 1;');
  assert.ok(privateType.diagnostics.length > 0);
  fs.writeFileSync(path.join(root, 'a.dua'), 'import "./b.dua";');
  fs.writeFileSync(path.join(root, 'b.dua'), 'import "./a.dua";');
  const cycle = await analyze('import "./a.dua";');
  assert.ok(cycle.diagnostics.some(d => /cycl/i.test(d.message)));
  fs.writeFileSync(path.join(root, 'bad.dua'), 'auto text = "日本😀"; int broken = "bad";');
  const bad = await analyze('import "./bad.dua";');
  const records = intelligence.diagnosticRecords(bad, {sourceName:'unused', sourceText:''});
  const error = records.find(d => /expects int/.test(d.message));
  assert.ok(error?.sourceName.endsWith('bad.dua'));
  assert.equal(error.position.character, error.sourceText.indexOf('int broken'));
}));

test('native module metadata is passed through while host class null and real value-type errors remain', () => fixture(async ({analyze}) => {
  const catalog = {symbols: { ui: {kind:'module'}, 'ui.newListView': {kind:'function', signatures:[{returnType:'ListView', parameters:[]}]},
    Vec2: {kind:'type', type:'Vec2'}}, types:{ListView:{kind:'class', members:{}}, Vec2:{kind:'struct', members:{}}}};
  const result = await analyze('import ui; ListView view = null; Vec2 point = null;', {hostModules: intelligence.hostModules(catalog)});
  assert.equal(result.diagnostics.length, 1);
  assert.match(result.diagnostics[0].message, /point/);
}));

test('incomplete member completion uses a virtual input and the same service graph', () => fixture(async ({analyze}) => {
  const source = 'import "./common/types.dua" as t;\nt.';
  const projected = intelligence.completionSource(source, source.length);
  const analysis = await analyze(projected);
  const catalog = intelligence.catalogWithImports(empty, analysis);
  assert.ok(host.apiCompletions(source, source.length, catalog).some(value => value.label === 'ItemKind'));
  assert.ok(projected.includes('__dua_completion;'));
  const annotation = 'import "./common/types.dua" as t;\nt.I value = "knife";';
  const offset = annotation.indexOf('t.I') + 3;
  const typed = await analyze(intelligence.completionSource(annotation, offset));
  const offered = host.apiCompletions(annotation, offset, intelligence.catalogWithImports(empty, typed));
  assert.ok(offered.some(value => value.label === 'ItemKind'));
}));

test('opaque type descriptors follow exported aliases without exposing private type names', () => {
  const analysis = {imports:[{aliasName:'t', key:'types'}], modules:[{key:'types', exports:[
    {name:'Public', kind:'type', type:'opaque_alias'}, {name:'record', kind:'variable', type:'opaque_alias'}
  ], types:[{name:'Private', type:'opaque_private', declarationKind:'table', fields:{count:'int'}, exported:false},
    {name:'Public', type:'opaque_alias', declarationKind:'alias', alternatives:['opaque_private'], exported:true}]}]};
  const catalog = intelligence.catalogWithImports(empty, analysis);
  for (const source of ['t.Public item; item.', 't.Public item = unknown(); item.',
    'void f(t.Public item) { item.', 't.record.']) {
    assert.ok(host.apiCompletions(source, source.length, catalog).some(value => value.label === 'count'), source);
  }
  assert.equal(catalog.symbols.Private, undefined);
  assert.equal(catalog.symbols['t.Private'], undefined);
});

test('actual private shapes follow public aliases and same basenames retain distinct type IDs', () => fixture(async ({root, types, analyze}) => {
  fs.writeFileSync(types, 'table Internal { int count; } export alias Public = Internal; export Public record = {count=1};');
  fs.mkdirSync(path.join(root, 'other'));
  fs.writeFileSync(path.join(root, 'other/types.dua'), 'export alias Public = string;');
  const source = 'import "./common/types.dua" as t; import "./other/types.dua" as other; t.Public item = {count=2};';
  const result = await analyze(source);
  assert.deepEqual(result.diagnostics, []);
  const catalog = intelligence.catalogWithImports(empty, result);
  assert.notEqual(catalog.symbols['t.Public'].type, catalog.symbols['other.Public'].type);
  const prefix = source + '\nitem.';
  assert.ok(host.apiCompletions(prefix, prefix.length, catalog).some(entry => entry.label === 'count'));
  assert.equal(catalog.symbols['t.Internal'], undefined);
}));

test('context-declared native modules remain known without leaking type tables as modules', () => fixture(async ({analyze}) => {
  const catalog = {symbols: {Font:{kind:'type',type:'Font'},'Font.Type':{kind:'module'},'Font.Type.Normal':{kind:'property',type:'int'}},
    contexts:[{bindings:{scenes:{kind:'module'}}}], types:{Font:{kind:'struct',members:{}}}};
  const metadata = intelligence.hostModules(catalog);
  assert.deepEqual(metadata.map(item => item.name), ['scenes']);
  const result = await analyze('import scenes; ListView view = null;', {hostModules:metadata});
  assert.deepEqual(result.diagnostics, []);
}));
