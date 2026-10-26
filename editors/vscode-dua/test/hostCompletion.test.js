'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { apiCompletions, tokens, loadCatalog, diagnosticHostTypes } = require('../hostCompletion');
const catalog = {
  symbols: { makeActor: { kind: 'function', signatures: [{ parameters: [{ name: 'path', type: 'string' }], returnType: 'Actor' }] },
    Vec: { kind: 'type', type: 'Vec' }, 'Vec.zero': { kind: 'property', type: 'Vec' } },
  types: { Actor: { members: { move: { kind: 'method', signatures: [{ parameters: [{ name: 'x', type: 'double' }, { name: 'y', type: 'double', optional: true }], returnType: 'void' }] },
    position: { kind: 'property', type: 'Vec' } } }, Vec: { members: { x: { kind: 'property', type: 'double' } } } }
};
function complete(source) { return apiCompletions(source, source.length, catalog); }
function labels(source) { return complete(source).map(e => e.label); }

test('host functions, static members, typed returns, aliases and properties', () => {
  assert.ok(labels('mak').includes('makeActor'));
  assert.deepEqual(labels('Vec.'), ['zero']);
  assert.deepEqual(labels('auto actor = makeActor("a"); actor.'), ['move', 'position']);
  assert.deepEqual(labels('auto actor = makeActor("a"); auto b = actor; b.position.'), ['x']);
  assert.deepEqual(labels('makeActor(nested(1, 2)).position.'), ['x']);
  assert.match(complete('makeActor("a").mo')[0].detail, /double y = …/);
});

test('host completion respects strings, comments, reassignment and block scope', () => {
  for (const source of ['# actor.', '// actor.', '/+ /+ nested +/ actor.', 'auto text = "actor.', 'auto text = i"actor.']) assert.deepEqual(labels(source), []);
  assert.deepEqual(labels('auto a = makeActor("a"); a = unknown(); a.'), []);
  assert.deepEqual(labels('{ auto a = makeActor("a"); } a.'), []);
  assert.deepEqual(labels('auto a = makeActor("a"); { auto a = unknown(); } a.'), ['move', 'position']);
  assert.equal(tokens(String.raw`"escaped \\"; // "`).state, 'comment');
});

test('string literal type aliases leave host completion and token boundaries intact', () => {
  const prefix = 'alias Fruit = "Apple" | "日本😀" | "actor.move({;"; Fruit fruit = "Apple";\n';
  assert.deepEqual(labels(prefix + 'auto actor = makeActor("a"); actor.'), ['move', 'position']);
  assert.deepEqual(labels('alias Fruit = "Apple" | "actor.'), []);
  const parsed = tokens('alias Fruit = "Apple" | "日本😀";');
  assert.equal(parsed.state, 'code');
  assert.deepEqual(parsed.tokens.filter(token => token.kind === 'string').map(token => token.value), ['Apple', '日本😀']);
});

test('catalog loading tolerates absent, malformed and unsupported files', () => {
  const fs = require('node:fs'), os = require('node:os'), path = require('node:path');
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dua-catalog-'));
  try {
    assert.deepEqual(Object.keys(loadCatalog(root).symbols), []);
    fs.writeFileSync(path.join(root, '.dua-completion.json'), '{');
    assert.deepEqual(Object.keys(loadCatalog(root).symbols), []);
    fs.writeFileSync(path.join(root, '.dua-completion.json'), JSON.stringify({ ...catalog, schemaVersion: 1 }));
    assert.ok(loadCatalog(root).symbols.makeActor);
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});

test('loaded module type aliases retain nested enum members without executing getters', () => {
  const fs = require('node:fs'), os = require('node:os'), path = require('node:path');
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dua-nested-enum-'));
  try {
    const data = { schemaVersion: 1,
      symbols: { 'view.Brush': { kind: 'variable', type: 'Brush' } },
      types: { Brush: { members: {
        Mode: { kind: 'module', static: true, members: {
          solid: { kind: 'value', type: 'int' }, wire: { kind: 'value', type: 'int' }
        } },
        Normal: { kind: 'property', static: true, type: 'Brush' },
        width: { kind: 'property', type: 'int' }
      } } }
    };
    fs.writeFileSync(path.join(root, '.dua-completion.json'), JSON.stringify(data));
    const loaded = loadCatalog(root);
    for (const source of ['view.Brush.Mode.', 'import view as v; v.Brush.Mode.',
      'auto mode = view.Brush.Mode; mode.']) {
      assert.deepEqual(apiCompletions(source, source.length, loaded).map(e => e.label), ['solid', 'wire'], source);
    }
    const source = 'view.Brush.Normal.';
    assert.ok(apiCompletions(source, source.length, loaded).some(e => e.label === 'width'));
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});

test('diagnostics use explicit class descriptors and registered type aliases, with old catalog compatibility', () => {
  const fs = require('node:fs'), os = require('node:os'), path = require('node:path');
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dua-class-metadata-'));
  try {
    const data = { schemaVersion: 1,
      symbols: { PublicWidget: { kind: 'type', type: 'NativeWidget' },
        instance: { kind: 'variable', type: 'NativeWidget' },
        'view.Widget': { kind: 'type', type: 'NativeWidget' } },
      types: { NativeWidget: { kind: 'class', members: { caption: { type: 'string' } } },
        Vec: { kind: 'struct', members: {} }, OldWidget: { members: {} },
        int: { kind: 'class', members: {} }, 'injected()': { kind: 'class', members: {} } }
    };
    const file = path.join(root, '.dua-completion.json');
    fs.writeFileSync(file, JSON.stringify(data));
    const current = loadCatalog(root);
    assert.deepEqual(diagnosticHostTypes(current), ['NativeWidget', 'PublicWidget']);
    assert.equal(current.types.Vec.kind, 'struct');
    for (const value of Object.values(data.types)) delete value.kind;
    fs.writeFileSync(file, JSON.stringify(data));
    const legacy = loadCatalog(root);
    assert.deepEqual(diagnosticHostTypes(legacy), []);
    const source = 'NativeWidget item; item.';
    assert.ok(apiCompletions(source, source.length, legacy).some(e => e.label === 'caption'));
    fs.unlinkSync(file);
    assert.deepEqual(diagnosticHostTypes(loadCatalog(root)), []);
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});
