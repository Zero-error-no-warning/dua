'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const executable = path.resolve(__dirname, '../bin', process.platform === 'win32' ? 'dua-check.exe' : 'dua-check');

function check(input) {
  const child = spawnSync(executable, [], { input, encoding: 'utf8', timeout: 15000 });
  assert.ifError(child.error);
  assert.equal(child.status, 0, child.stderr);
  return JSON.parse(child.stdout);
}

test('checker rejects invalid protocol fields with a JSON diagnostic and no secondary failure', () => {
  const cases = [
    [{ source: 42 }, /source.*string/],
    [{ source: null }, /source.*string/],
    [{ sourceName: 42 }, /sourceName.*string/],
    [{ modulePaths: 'bad' }, /modulePaths.*array/],
    [{ modulePaths: [42] }, /modulePaths.*strings/],
    [{ hostClassTypes: [false] }, /hostClassTypes.*strings/],
    [{ overlays: {} }, /overlays.*array/],
    [{ overlays: [null] }, /object/],
    [{ overlays: [{ sourceName: 'file.dua', source: false }] }, /source.*string/],
    [{ hostModules: [null] }, /hostModules.*objects/],
    [{ hostModules: [{ name: 'host', exports: {} }] }, /exports.*array/],
    [{ hostModules: [{ name: 'host', exportsComplete: 1 }] }, /exportsComplete.*boolean/],
    [{ hostModules: [{ name: 'host', exports: [{ name: 'f', parameterTypes: [1] }] }] }, /parameterTypes.*strings/],
    [{ hostModules: [{ name: 'host', exports: [{ name: 'f', parameterLazy: [1] }] }] }, /parameterLazy.*boolean/],
    [{ sourceBoundary: { root: 42 } }, /root.*string/],
    [{ importPathPrefix: 42 }, /importPathPrefix.*string/]
  ];
  for (const [fields, message] of cases) {
    const result = check(JSON.stringify({ source: 'return 42;', sourceName: 'input.dua', ...fields }));
    assert.equal(result.schemaVersion, 1);
    assert.equal(result.diagnostics.length, 1, JSON.stringify(fields));
    assert.match(result.diagnostics[0].message, message);
    assert.equal(result.diagnostics[0].line, 0);
  }
});

test('checker preserves structured and plain-text protocols and never executes the source', () => {
  for (const source of ['return 42;', '{ auto value = 42; }', '\uFEFFreturn 42;', 'error("must not run");']) {
    assert.deepEqual(check(source).diagnostics, []);
    assert.deepEqual(check(JSON.stringify({ source, sourceName: 'input.dua' })).diagnostics, []);
  }
});
