'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { completions, diagnosticPosition, documentNames } = require('../language');

test('completes declarations and standard library members', () => {
  const source = 'struct Vec { int x; }\nVec[] points = [];\nint add(int left, int right) { return left + right; }\nimport actor as Actor;\nforeach (index, value; points) {}\n';
  const labels = completions(source, source.length).map(item => item.label);
  for (const name of ['auto', 'double', 'iota', 'Vec', 'points', 'add', 'left', 'right', 'Actor', 'index', 'value']) assert.ok(labels.includes(name), name);
  assert.deepEqual(completions('math.', 5).map(item => item.label), ['abs', 'floor', 'min', 'max']);
  assert.ok(completions('package.lo', 10).some(item => item.label === 'loaded'));
  assert.deepEqual(completions('object.', 7), []);
});

test('excludes comments, strings, and fake declarations from completion', () => {
  const source = '/+ # nested /+ inner +/ // still block +/\nauto realName = 1;\n// auto fakeName = 2;\nauto text = "int pretend = 3;";\n';
  const names = documentNames(source);
  assert.ok(names.has('realName'));
  assert.ok(!names.has('fakeName'));
  assert.ok(!names.has('pretend'));
  for (const prefix of ['# comment ', '// comment ', '/+ outer /+ inner +/ ', 'auto s = "hello ']) assert.deepEqual(completions(prefix, prefix.length), []);
  assert.ok(completions('auto s = "unfinished\nauto ', 26).length > 0);
});

test('converts diagnostic byte columns, CRLF, EOF and parser locations', () => {
  const source = 'auto s = "日本😀"; auto bad = ;\r\n';
  const column = Buffer.byteLength(source.slice(0, source.indexOf(';', source.indexOf('bad')))) + 1;
  assert.deepEqual(diagnosticPosition(source, { line: 1, column, message: '' }), { line: 0, character: source.indexOf(';', source.indexOf('bad')) });
  assert.deepEqual(diagnosticPosition(source, { line: 0, column: 0, message: `Unexpected token at 1:${column}` }), { line: 0, character: source.indexOf(';', source.indexOf('bad')) });
  assert.deepEqual(diagnosticPosition('x\r\n', { line: 2, column: 1, message: '' }), { line: 1, character: 0 });
  assert.deepEqual(diagnosticPosition('x', { line: 99, column: 99, message: '' }), { line: 0, character: 1 });
});
