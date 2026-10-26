'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const fs = require('node:fs');
const { checkSource, analyzeSource } = require('../checker');
const executable = path.resolve(__dirname, '../bin', process.platform === 'win32' ? 'dua-check.exe' : 'dua-check');

test('checker accepts array trailing commas and rejects missing elements', async () => {
  const types = 'alias ItemType = "weapon" | "armor"; '
    + 'table Modifier { string name; ItemType targetType; } '
    + 'table ItemInfo { uint id; string itemID; uint count; string name; Modifier[] modifier; } ';
  const source = types + 'ItemInfo[] inventory = [\n'
    + '{ id = 1, itemID = "knife_001", count = 1, name = "Knife", modifier = [] },\n];';
  assert.deepEqual(await checkSource(executable, source).promise, []);
  for (const literal of ['[]', '[1]', '[1,]', '[1, 2,]', '[[], [1,],]']) {
    assert.deepEqual(await checkSource(executable, 'auto a = ' + literal + ';').promise, [], literal);
  }
  for (const literal of ['[,]', '[1,,]', '[1,,2]']) {
    const errors = await checkSource(executable, 'auto a = ' + literal + ';').promise;
    assert.equal(errors.length, 1, literal);
    assert.match(errors[0].message, /Unexpected token comma/);
  }
});

test('checker reports real syntax and type errors, and accepts modules and host bindings', async () => {
  const typeErrors = await checkSource(executable, 'int count = "wrong";').promise;
  assert.equal(typeErrors.length, 1);
  assert.match(typeErrors[0].message, /expects int/);
  assert.equal(typeErrors[0].line, 1);
  const syntaxErrors = await checkSource(executable, 'auto s = "日本😀"; auto missing = ;').promise;
  assert.equal(syntaxErrors.length, 1);
  assert.match(syntaxErrors[0].message, /at 1:\d+$/);
  for (const source of ['export instance int hp = 100;', 'return hostFunction(hostValue);', 'while (true) {}', 'error("must never run");']) {
    assert.deepEqual(await checkSource(executable, source).promise, [], source);
  }
  const root = process.env.DUA_TEST_SOURCE_ROOT || path.resolve(__dirname, '../../..');
  for (const file of ['examples/module-instances/main.dua', 'examples/module-instances/movement.dua', 'examples/module-instances/actor/init.dua']) {
    const sourceName = path.join(root, file), directory = path.join(root, 'examples/module-instances');
    assert.deepEqual((await analyzeSource(executable, fs.readFileSync(sourceName, 'utf8'), {
      sourceName, modulePaths:[path.join(directory, '?.dua'), path.join(directory, '?/init.dua')]
    }).promise).diagnostics, [], file);
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

test('checker diagnoses invalid values for string literal unions', async () => {
  const source = 'alias Fruit = "Apple" | "Orange";\nFruit fruit = "Banana";';
  const diagnostics = await checkSource(executable, source).promise;
  assert.equal(diagnostics.length, 1);
  assert.match(diagnostics[0].message, /expects Fruit/);
  assert.equal(diagnostics[0].line, 2);
  assert.ok(diagnostics[0].column > 0);
});

test('host class metadata permits null through declarations, assignments, aliases and function signatures', async () => {
  const hostClassTypes = ['HostWidget', 'OtherWidget'];
  for (const source of [
    'HostWidget list = null; OtherWidget other = null; list = null;',
    'alias WidgetAlias = HostWidget; WidgetAlias list = null;',
    'HostWidget echo(HostWidget value) { return value; } HostWidget list = echo(null);',
    'HostWidget missing() { return null; }',
    'void run() { HostWidget local = null; { OtherWidget other = null; } }',
    'auto nothing = null; HostWidget list = nothing;',
    'error("must never execute"); HostWidget list = null;'
  ]) assert.deepEqual(await checkSource(executable, source, { hostClassTypes }).promise, [], source);
});

test('host metadata retains real errors for structs, primitives, unknown types and wrong values', async () => {
  for (const source of [
    'ValuePoint value = null;', 'Unknown value = null;', 'int value = null;',
    'string value = null;', 'bool value = null;',
    'struct Record { int n; } Record value = null;',
    'alias Number = int; Number value = null;',
    'alias HostWidget = int; HostWidget value = null;',
    'struct HostWidget { int n; } HostWidget value = null;',
    'HostWidget value = 3;', 'HostWidget value = "wrong";',
    'ValuePoint missing() { return null; }',
    'int run(int value) { return value; } run(null);'
  ]) assert.ok((await checkSource(executable, source, { hostClassTypes: ['HostWidget'] }).promise).length > 0, source);
  // 旧形式のchecker入力は従来の挙動を保持し、根拠のないnull許容を追加しません。
  assert.ok((await checkSource(executable, 'HostWidget value = null;').promise).length > 0);
  assert.ok((await checkSource(executable, 'int value = null;', { hostClassTypes: ['int'] }).promise).length > 0);
});

test('source struct shadows do not change outer host-class nullability', async () => {
  const source = 'HostWidget outer = null; void run() { struct HostWidget { int n; } HostWidget local = null; } HostWidget later = null;';
  const errors = await checkSource(executable, source, { hostClassTypes: ['HostWidget'] }).promise;
  assert.equal(errors.length, 1);
  assert.match(errors[0].message, /local/);
});

test('source table types and their aliases accept null independently of host class metadata', async () => {
  for (const hostClassTypes of [[],['HostWidget']]) for (const source of [
    'table Record { int n; } Record value=null; value=null;',
    'table HostWidget { int n; } HostWidget value=null;',
    'table Record { int n; } alias Alias=Record; Alias value=null;',
    'table Record { int n; } Record echo(Record value){return value;} Record value=echo(null);',
    'table Record { int n; } Record missing(){return null;}'
  ]) assert.deepEqual(await checkSource(executable,source,{hostClassTypes}).promise,[],source);
});
