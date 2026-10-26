'use strict';
const test = require('node:test'), assert = require('node:assert/strict');
const { importPathContext } = require('../importContext');

test('path import context retains full suffix and UTF-16 replacement range', () => {
  const source = 'auto title = "日本😀";\r\nimport "../common/types.dua" as commonTypes;';
  const offset = source.indexOf('types') + 2;
  const context = importPathContext(source, offset);
  assert.equal(context.specifier, '../common/types.dua');
  assert.equal(context.prefix, '../common/ty');
  assert.equal(source.slice(context.start, context.end), '../common/types.dua');
  assert.equal(context.closed, true);
  assert.equal(context.instance, false);
});

test('unfinished and instance imports have raw path ranges without escaping', () => {
  const source = 'instance import "./日本😀/ty';
  const context = importPathContext(source, source.length);
  assert.equal(context.specifier, './日本😀/ty');
  assert.equal(context.instance, true);
  assert.equal(context.closed, false);
  const windows = String.raw`import ".\common\types.dua";`;
  const result = importPathContext(windows, windows.indexOf('types'));
  assert.equal(result.specifier, String.raw`.\common\types.dua`);
});

test('ordinary strings, calls, comments, interpolation and named imports are not path contexts', () => {
  for (const source of [
    'auto name = "./types.dua', 'loadCharacter("./types.dua',
    '# import "./types.dua', '// import "./types.dua', '/+ import "./types.dua',
    'import i"./types.dua', 'import common.types as commonTypes;',
    'auto text = "import ./types.dua";', 'object.import "./types.dua'
  ]) assert.equal(importPathContext(source, source.length), null, source);
  const multiline = 'import "unfinished\nauto name = 1;';
  assert.equal(importPathContext(multiline, multiline.length), null);
  assert.equal(importPathContext('import "";', -1), null);
});
