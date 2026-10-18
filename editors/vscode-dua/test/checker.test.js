'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const fs = require('node:fs');
const { checkSource } = require('../checker');
const executable = path.resolve(__dirname, '../bin', process.platform === 'win32' ? 'dua-check.exe' : 'dua-check');

test('checker reports real syntax and type errors, and accepts modules and host bindings', async () => {
  const typeErrors = await checkSource(executable, 'int count = "wrong";').promise;
  assert.equal(typeErrors.length, 1);
  assert.match(typeErrors[0].message, /expects int/);
  assert.equal(typeErrors[0].line, 1);
  const syntaxErrors = await checkSource(executable, 'auto s = "日本😀"; auto missing = ;').promise;
  assert.equal(syntaxErrors.length, 1);
  assert.match(syntaxErrors[0].message, /at 1:\d+$/);
  for (const source of ['export instance int hp = 100;', 'return hostFunction(hostValue);', 'while (true) {}', 'error("must never run");', 'import missingModule;']) {
    assert.deepEqual(await checkSource(executable, source).promise, [], source);
  }
  const root = path.resolve(__dirname, '../../..');
  for (const file of ['examples/module-instances/main.dua', 'examples/module-instances/movement.dua', 'examples/module-instances/actor/init.dua']) {
    assert.deepEqual(await checkSource(executable, fs.readFileSync(path.join(root, file), 'utf8')).promise, [], file);
  }
});

test('missing checker is rejected without crashing on closed stdin', async () => {
  await assert.rejects(checkSource(path.join(__dirname, 'missing-checker'), 'auto x = 1;').promise, /ENOENT/);
});

test('checker accepts string literal aliases through the editor diagnostics protocol', async () => {
  const source = 'alias Fruit = "Apple" | "日本😀";\n'
    + 'alias Single = "Apple";\n'
    + 'alias Mixed = Fruit | int;\n'
    + 'Fruit choose(Fruit value) { return value; }\n'
    + 'Fruit fruit = choose("Apple"); fruit = "日本😀";\n'
    + 'Fruit[] basket = ["Apple", "日本😀"];\n'
    + 'Single single = "Apple"; Mixed mixed = 1;\n';
  assert.deepEqual(await checkSource(executable, source).promise, []);
});
