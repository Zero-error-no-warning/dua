'use strict';
const test = require('node:test'), assert = require('node:assert/strict');
const fs = require('node:fs'), os = require('node:os'), path = require('node:path');
const { createContext, stringCompletions } = require('../assetCompletion');
const { apiCompletions, loadCatalog } = require('../hostCompletion');

function fixture(run) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dua-assets-'));
  function source(filename) { fs.writeFileSync(path.join(root, filename), 'fixture'); const s = fs.statSync(path.join(root, filename)); return { path: filename, size: s.size, modifiedMs: Math.trunc(s.mtimeMs) }; }
  const hero = { ...source('hero.asset'), type: 'Actor', names: { motions: ['Walk', 'Walk 2'], parts: ['Arm', 'Hand "x"'] } };
  const enemy = { ...source('enemy.asset'), type: 'Actor', names: { motions: ['Run'], parts: ['Tail'] } };
  const scene = source('level.scene'); source('actor.dua');
  const catalog = { root, symbols: { makeActor: { kind: 'function', signatures: [{ parameters: [], returnType: 'Actor' }] } },
    types: { Actor: { members: { morph: { kind: 'method' }, part: { kind: 'method' }, morphParts: { kind: 'method' } } } },
    assets: [hero, enemy], contexts: [],
    assetLoaders: [{ function: 'makeActor', returnType: 'Actor', pathArguments: [1, 0], pathWrappers: ['resource'] }],
    stringArguments: [{ receiverType: 'Actor', method: 'morph', argument: 0, source: 'motions' },
      { receiverType: 'Actor', method: 'part', argument: 0, source: 'parts' },
      { receiverType: 'Actor', method: 'morphParts', argument: 0, source: 'parts' },
      { receiverType: 'Actor', method: 'morphParts', argument: 1, source: 'motions' }] };
  function complete(source, marker) { const offset = marker === undefined ? source.length : marker; return stringCompletions(source, offset, createContext(catalog, path.join(root, 'actor.dua'))); }
  try { run({ root, catalog, scene, complete, source }); } finally { fs.rmSync(root, { recursive: true, force: true }); }
}
test('literal loaders and aliases select asset-specific names in each argument', () => fixture(({ complete }) => {
  const start = 'auto a = makeActor(canvas, resource("hero.asset")); auto b = a; ';
  assert.deepEqual(complete(start + 'b.morph("').map(e => e.label), ['Walk', 'Walk 2']);
  assert.deepEqual(complete(start + 'b.part("').map(e => e.label), ['Arm', 'Hand "x"']);
  assert.deepEqual(complete(start + 'b.morphParts("Arm", "').map(e => e.label), ['Walk', 'Walk 2']);
  assert.deepEqual(complete('makeActor("enemy.asset", canvas).morph("').map(e => e.label), ['Run']);
  assert.deepEqual(complete('outer(1, makeActor(canvas, resource("hero.asset")).morphParts("Arm", "').map(e => e.label), ['Walk', 'Walk 2']);
  const conditional = 'auto a = makeActor(canvas, "hero.asset"); if (flag) a = makeActor(canvas, "enemy.asset"); a.morph("';
  assert.deepEqual(complete(conditional).map(e => e.label), ['Walk', 'Walk 2', 'Run']);
  assert.ok(complete(conditional).every(e => e.detail.includes('複数')));
}));
test('comments, nested calls, non-name arguments and interpolation stay untouched', () => fixture(({ complete }) => {
  for (const text of ['# a.morph("', '// a.morph("', '/+ a.morph("', 'auto text = "a.morph(', 'a.morph(i"', 'a.morph(other("', 'a.morphParts("Arm", nested(1, 2), "', 'a.morph("Walk", "']) assert.deepEqual(complete(text), [], text);
  assert.ok(complete('a.morphParts("Arm, (x)", /+ /+ nested +/ +/ "').length);
}));
test('replacement ranges and escapes preserve quotes and replace the suffix', () => fixture(({ complete }) => {
  const source = 'a.part("HaOLD")', offset = source.indexOf('OLD');
  const entry = complete(source, offset).find(e => e.label === 'Hand "x"');
  assert.equal(source.slice(0, entry.start) + entry.insertText + source.slice(entry.end), 'a.part("Hand \\"x\\"")');
}));
test('scene self/scenes contexts filter candidates and mark shared scripts', () => fixture(({ catalog, scene, root, complete }) => {
  catalog.contexts = [{ script: 'actor.dua', assetDirectory: '.', sources: [scene], bindings: {
    self: { type: 'Actor', assets: ['hero.asset'] }, scenes: {}, 'scenes.Player': { type: 'Actor', assets: ['hero.asset'] } } }];
  assert.deepEqual(complete('self.morph("').map(e => e.label), ['Walk', 'Walk 2']);
  assert.deepEqual(complete('import scenes; scenes.Player.morph("').map(e => e.label), ['Walk', 'Walk 2']);
  const context = createContext(catalog, path.join(root, 'actor.dua'));
  assert.ok(apiCompletions('self.', 5, context.catalog, context).some(e => e.label === 'morph'));
  catalog.contexts.push({ ...catalog.contexts[0], bindings: { self: { type: 'Actor', assets: ['enemy.asset'] } } });
  assert.deepEqual(complete('self.morph("').map(e => e.label), ['Walk', 'Walk 2', 'Run']);
  assert.ok(complete('self.morph("').every(e => e.detail.includes('複数')));
  assert.ok(complete('auto a = makeActor(canvas, dynamicPath); a.morph("').every(e => e.detail.includes('対象未確定')));
}));
test('deleted, moved and externally changed sources never retain old names', () => fixture(({ root, complete, catalog }) => {
  fs.renameSync(path.join(root, 'hero.asset'), path.join(root, 'moved.asset'));
  assert.deepEqual(complete('a.morph("').map(e => e.label), ['Run']);
  fs.appendFileSync(path.join(root, 'enemy.asset'), 'changed');
  assert.deepEqual(complete('a.morph("'), []);
  fs.unlinkSync(path.join(root, 'enemy.asset'));
  assert.deepEqual(complete('a.morph("'), []);
  catalog.assets = [];
}));
test('catalog replacements invalidate cached API data; malformed entries are ignored', () => fixture(({ root, catalog }) => {
  const file = path.join(root, '.dua-completion.json');
  fs.writeFileSync(file, JSON.stringify({ ...catalog, schemaVersion: 1 }));
  assert.ok(loadCatalog(root).symbols.makeActor);
  fs.writeFileSync(file, JSON.stringify({ schemaVersion: 1, symbols: { newApi: { kind: 'function' }, bad: null }, types: { bad: null } }));
  assert.deepEqual(Object.keys(loadCatalog(root).symbols), ['newApi']);
  fs.unlinkSync(file); assert.deepEqual(Object.keys(loadCatalog(root).symbols), []);
}));
