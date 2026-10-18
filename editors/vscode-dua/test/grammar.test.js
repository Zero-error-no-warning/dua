'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const textmate = require('vscode-textmate');
const oniguruma = require('vscode-oniguruma');

test('TextMate correctly ends nested comments, nested interpolation, and incomplete strings', async () => {
  await oniguruma.loadWASM(fs.readFileSync(require.resolve('vscode-oniguruma/release/onig.wasm')).buffer);
  const registry = new textmate.Registry({
    onigLib: Promise.resolve({ createOnigScanner: patterns => new oniguruma.OnigScanner(patterns), createOnigString: value => new oniguruma.OnigString(value) }),
    loadGrammar: async () => JSON.parse(fs.readFileSync(path.resolve(__dirname, '../syntaxes/dua.tmLanguage.json'), 'utf8'))
  });
  const grammar = await registry.loadGrammar('source.dua');
  const scopesAt = (result, offset) => result.tokens.find(token => token.startIndex <= offset && token.endIndex > offset).scopes;
  const comment = '/+ # text /+ nested +/ // text +/ auto after = 1;';
  const first = grammar.tokenizeLine(comment);
  assert.ok(scopesAt(first, comment.indexOf('nested')).includes('comment.block.dua'));
  assert.ok(!scopesAt(first, comment.indexOf('after')).includes('comment.block.dua'));
  const interpolation = 'auto text = i"value=$(length(iota(3)) + 1) tail";';
  const second = grammar.tokenizeLine(interpolation);
  assert.ok(scopesAt(second, interpolation.indexOf('+')).includes('meta.interpolation.dua'));
  assert.ok(!scopesAt(second, interpolation.indexOf('tail')).includes('meta.interpolation.dua'));
  const unfinished = grammar.tokenizeLine('auto text = "unfinished');
  const next = grammar.tokenizeLine('long after = 1;', unfinished.ruleStack);
  assert.ok(!scopesAt(next, 5).includes('string.quoted.double.dua'));
  const unfinishedInterpolation = grammar.tokenizeLine('auto text = i"$(length(iota(');
  const afterInterpolation = grammar.tokenizeLine('auto after = 1;', unfinishedInterpolation.ruleStack);
  assert.ok(!scopesAt(afterInterpolation, 5).includes('meta.interpolation.dua'));
  const literalAlias = 'alias Fruit = "Apple" | "日本😀" | string;';
  const aliasTokens = grammar.tokenizeLine(literalAlias);
  assert.ok(scopesAt(aliasTokens, 0).includes('storage.type.dua'));
  for (const value of ['Apple', '日本😀']) {
    assert.ok(scopesAt(aliasTokens, literalAlias.indexOf(value)).includes('string.quoted.double.dua'));
  }
  assert.ok(scopesAt(aliasTokens, literalAlias.indexOf('|')).includes('keyword.operator.dua'));
  assert.ok(scopesAt(aliasTokens, literalAlias.indexOf('string')).includes('support.type.primitive.dua'));
  const afterAlias = grammar.tokenizeLine('Fruit fruit = "Apple";', aliasTokens.ruleStack);
  assert.ok(!scopesAt(afterAlias, 0).includes('string.quoted.double.dua'));
  registry.dispose();
});
