'use strict';
const test = require('node:test'), assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path');
const { tokens } = require('../hostCompletion');
const { maskSource, documentNames, completions } = require('../language');
const { importPathContext } = require('../importContext');
const { pathCompletions } = require('../moduleIntelligence');
const { decodeStringContent, encodeStringContent } = require('../stringSyntax');
const { checkSource } = require('../checker');

test('strings decode escapes and keep source token ranges through nested interpolation', () => {
  const raw = String.raw`"a\nb\rc\t\0\"\\"`;
  assert.equal(tokens(raw).tokens[0].value, 'a\nb\rc\t\0"\\');
  assert.equal(tokens(String.raw`"bad\q"`).tokens[0].value, undefined);
  assert.equal(decodeStringContent('abc\\', true), 'abc');
  for (const text of ['a\nb\rc\t\0"\\', '日本😀', '']) assert.equal(decodeStringContent(encodeStringContent(text)), text);
  for (const literal of [
    String.raw`i" $("test") "`, String.raw`i"$("a\"(b)")"`,
    String.raw`i"$(i"nested $("value")")"`, String.raw`i "$("spaced")"`,
    String.raw`i /+ prefix +/ "$("comment")"`,
    String.raw`i"$(1 /+ ) " /+ nested +/ +/ + 2)"`,
    'i"$(1 // ) " ignored\n + 2)"', 'i"$(1 # ) " ignored\n + 2)"',
    String.raw`i"$$(()"`
  ]) {
    const source = 'return ' + literal + '; auto after = 1;';
    const parsed = tokens(source), string = parsed.tokens[1];
    assert.equal(string.kind, 'string', source);
    assert.equal(string.text, literal, source);
    assert.equal(string.closed, true, source);
    assert.equal(parsed.state, 'code');
    assert.equal(parsed.tokens[2].text, ';');
    assert.equal(source.slice(string.start, string.end), literal);
  }
});

test('masking retains expression code, hides quoted fake declarations and recovers after literal newline', () => {
  const source = String.raw`auto text = i"$("int fake = 1;\"still string") $(i"$("int nested = 2;")")"; int real = 3;`;
  const masked = maskSource(source);
  assert.equal(masked.text.length, source.length);
  assert.equal(masked.state, 'code');
  const names = documentNames(source);
  assert.ok(names.has('real'));
  assert.ok(!names.has('fake') && !names.has('nested'));
  for (const unfinished of [String.raw`"a\"still`, String.raw`i"$("a\"still`]) {
    assert.equal(maskSource(unfinished).state, 'string');
    assert.equal(tokens(unfinished).state, 'string');
  }
  assert.equal(maskSource('i"$(1 // comment').state, 'comment');
  assert.equal(maskSource('i"$(1 + ').state, 'code');
  assert.ok(completions('i"$(math.', 9).some(x => x.label === 'abs'));
  assert.ok(documentNames('"unfinished\nint after = 1;').has('after'));
});

test('escaped import paths are decoded for resolution and encoded for insertion', () => {
  const source = String.raw`import ".\\common\\types.dua";`;
  const offset = source.indexOf('types') + 2, context = importPathContext(source, offset);
  assert.equal(context.specifier, '.\\common\\types.dua');
  assert.equal(context.prefix, '.\\common\\ty');
  assert.equal(source.slice(context.start, context.end), String.raw`.\\common\\types.dua`);
  const entries = pathCompletions(source, offset, { pathCompletions: [{ label: '.\\common\\types.dua', sourceName: 'test' }] });
  assert.equal(entries[0].insertText, String.raw`.\\common\\types.dua`);
  assert.equal(importPathContext(String.raw`import "bad\q";`, 12), null);
});

test('TextMate scopes escapes, quoted expressions, nested interpolation and multiline comments', async () => {
  const textmate = require('vscode-textmate'), oniguruma = require('vscode-oniguruma');
  await oniguruma.loadWASM(fs.readFileSync(require.resolve('vscode-oniguruma/release/onig.wasm')).buffer);
  const registry = new textmate.Registry({
    onigLib: Promise.resolve({ createOnigScanner: patterns => new oniguruma.OnigScanner(patterns), createOnigString: value => new oniguruma.OnigString(value) }),
    loadGrammar: async () => JSON.parse(fs.readFileSync(path.resolve(__dirname, '../syntaxes/dua.tmLanguage.json'), 'utf8'))
  });
  const grammar = await registry.loadGrammar('source.dua');
  const at = (result, offset) => result.tokens.find(t => t.startIndex <= offset && t.endIndex > offset).scopes;
  const source = String.raw`auto x = i"\n$("a\"(b)") $(i"nested $("value")") tail"; auto after = 1;`;
  const result = grammar.tokenizeLine(source);
  assert.ok(at(result, source.indexOf('\\n')).includes('constant.character.escape.dua'));
  assert.ok(at(result, source.indexOf('\\"')).includes('constant.character.escape.dua'));
  assert.ok(at(result, source.indexOf('(b)')).includes('string.quoted.double.dua'));
  assert.ok(at(result, source.indexOf('value')).includes('string.quoted.double.dua'));
  assert.ok(!at(result, source.indexOf('tail')).includes('meta.interpolation.dua'));
  assert.ok(!at(result, source.indexOf('after')).some(s => s.startsWith('string.')));
  const invalid = grammar.tokenizeLine(String.raw`"bad\q"`);
  assert.ok(at(invalid, 4).includes('invalid.illegal.escape.dua'));
  const line = grammar.tokenizeLine('i"$(1 // ) " comment');
  const next = grammar.tokenizeLine('+ 2) tail"; auto done = 1;', line.ruleStack);
  assert.ok(at(next, 0).includes('meta.interpolation.dua'));
  assert.ok(!at(next, 6).includes('meta.interpolation.dua'));
  assert.ok(!at(next, 18).some(s => s.startsWith('string.')));
  const commented = String.raw`i"$(1 /+ ) " /+ nested +/ +/ + 2) tail";`;
  const commentTokens = grammar.tokenizeLine(commented);
  assert.ok(at(commentTokens, commented.indexOf('nested')).includes('comment.block.dua'));
  assert.ok(at(commentTokens, commented.indexOf('+ 2')).includes('meta.interpolation.dua'));
  assert.ok(!at(commentTokens, commented.indexOf('tail')).includes('meta.interpolation.dua'));
  registry.dispose();
});

test('rebuilt checker accepts strings and reports original invalid escape byte positions', async () => {
  const executable = process.env.DUA_STRING_CHECKER || path.resolve(__dirname, '../bin', process.platform === 'win32' ? 'dua-check.exe' : 'dua-check');
  for (const source of [
    String.raw`return i" $("test") ";`, String.raw`return "\n\r\t\0\"\\";`,
    String.raw`return i"$(i"nested $("value")")";`,
    String.raw`return i"$(1 /+ ) " /+ nested +/ +/ + 2)";`,
    'return i"$(1 // ) " comment\n + 2)";',
    String.raw`alias Escaped = "a\"b\n"; Escaped value = "a\"b\n";`
  ]) assert.deepEqual(await checkSource(executable, source).promise, [], source);
  for (const source of [String.raw`return "日本\q";`, String.raw`return i"日本$("bad\q")";`]) {
    const errors = await checkSource(executable, source).promise;
    assert.equal(errors.length, 1, source);
    assert.match(errors[0].message, /Invalid string escape/);
    assert.equal(errors[0].column, Buffer.byteLength(source.slice(0, source.indexOf('\\q'))) + 1);
  }
  for (const source of ['return "unfinished', 'return i"$(1', 'return i"$("unfinished', 'return "trailing\\']) {
    const errors = await checkSource(executable, source).promise;
    assert.ok(errors.length > 0, source);
  }
});
