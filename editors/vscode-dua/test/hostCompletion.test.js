'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { apiCompletions, tokens, loadCatalog } = require('../hostCompletion');
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
