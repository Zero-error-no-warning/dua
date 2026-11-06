'use strict';
const {readType}=require('./typeSyntax');
const {tokens}=require('./hostCompletion');

const keywords = 'auto lazy ref delegate alias struct is cast try catch finally return if else while for foreach foreach_reverse switch case default break continue yield true false null this import export as instance new table with'.split(' ');
const types = 'any void bool byte ubyte short ushort int uint long ulong float double real string'.split(' ');
const builtins = {
  error: ['error(value, level?)', 'スクリプトエラーを送出します。'],
  typeof: ['typeof(value)', '値の型情報を取得します。'],
  typeinfo: ['typeinfo(value)', '値の型と型チェーンを取得します。'],
  length: ['length(value)', '文字列・配列・テーブルなどの長さを返します。'],
  len: ['len(value)', 'lengthの別名です。'],
  count: ['count(text)', 'UTF-8文字列のUnicodeコードポイント数を返します（バイト数ではありません）。'],
  charAt: ['charAt(text, index)', '0始まりのUnicodeコードポイントを1文字のstringで返します。結合文字は個別です。'],
  iota: ['iota(end) / iota(start, end, step?)', '終了値を含まない整数配列を生成します。'],
  rawget: ['rawget(table, key)', 'メタメソッドを使わずに値を取得します。'],
  rawset: ['rawset(table, key, value)', 'メタメソッドを使わずに値を設定します。'],
  setmetatable: ['setmetatable(table, meta)', 'メタテーブルを設定します。'],
  getmetatable: ['getmetatable(table)', 'メタテーブルを取得します。'],
  setmetatableWithType: ['setmetatableWithType(table, meta, names...)', 'メタテーブルと型情報を設定します。'],
  pcall: ['pcall(callback, args...)', '保護呼び出しの結果を配列で返します。'],
  xpcall: ['xpcall(callback, errHandler, args...)', 'エラーハンドラー付きの保護呼び出しです。'],
  map: ['map(collection, callback)', '各要素を変換します。'],
  filter: ['filter(collection, callback)', '条件に合う要素を選別します。'],
  sorted: ['sorted(array, comparator?)', '元の配列を変更せず安定ソートした配列を返します。'],
  reduce: ['reduce(array, initial, callback)', '左からcallback(accumulator, value)を適用します。'],
  require: ['require(name)', 'モジュールの既定の実体を読み込みます。'],
  addModulePath: ['addModulePath(pattern)', 'モジュール検索パターンを追加します。'],
  setModuleLoaders: ['setModuleLoaders(loaders)', 'モジュールローダーを設定します。'],
  addModuleLoader: ['addModuleLoader(loader)', 'モジュールローダーを追加します。'],
  _ENV: ['_ENV(name)', 'グローバル値を名前で取得します。']
};
const libraries = {
  string: { len: 'value', upper: 'value', lower: 'value', trim: 'value', contains: 'value, needle', replace: 'value, from, to', split: 'text, separator', join: 'parts, separator', format: 'format, args...' },
  math: { abs: 'value', floor: 'value', min: 'value, args...', max: 'value, args...', exp: 'x', fmod: 'x, y', fmax: 'x, y', fmin: 'x, y', sqrt: 'x', log: 'x', sin: 'x', cos: 'x', tan: 'x', clamp: 'x, low, high' },
  table: { len: 'value', length: 'value', keys: 'value', map: 'value, callback', filter: 'value, callback' },
  utf8: { len: 'value', chars: 'text' },
  algorithm: { clamp: 'x, low, high' },
  random: { Random: 'seed?', uniform01: 'rng?', unpredictableSeed: '', seed: 'seed', uniform: 'low, high, boundaries?, rng?', choice: 'array, rng?', dice: 'weights..., rng?' },
  io: { exists: 'path', readFile: 'path' },
  os: { clock: '', getenv: 'name' },
  time: { nowUnix: '' },
  debug: { type: 'value', traceback: '' },
  json: { encode: 'value', decode: 'text' },
  package: { require: 'name', addPath: 'pattern', addLoader: 'loader', clearLoaders: '' }
};

// UTF-16位置を保ち、補間式のコードだけを残す。
const { maskStringsAndComments } = require('./stringSyntax');
function maskSource(source) { return maskStringsAndComments(source); }

function documentNames(source) {
  const text = maskSource(source).text;
  const names = new Map();
  for(const match of text.matchAll(/\b(table|struct)\s+([A-Za-z_]\w*)\b/g))names.set(match[2],match[1]);
  const declaration = /\b([A-Za-z_]\w*(?:\s*\[[A-Za-z_\w]*\])*)\s+([A-Za-z_]\w*)\s*(?=[=;,(){}])/g;
  const excluded = new Set(keywords.filter(word => !['auto', 'struct', 'table', 'alias'].includes(word)));
  for (const match of text.matchAll(declaration)) {
    if (!excluded.has(match[1])) names.set(match[2], match[1]);
  }
  const input=tokens(source).tokens;
  for(let i=0;i<input.length;i++) {
    if(excluded.has(input[i].text) || !['identifier'].includes(input[i].kind) && input[i].text!=='(')continue;
    const annotation=readType(input,i,name=>name);
    if(!annotation || !input.slice(i,annotation.next).some(token=>token.text==='&'))continue;
    const name=input[annotation.next],after=input[annotation.next+1]?.text;
    if(name?.kind==='identifier' && ['=',';',',','(',')','{','}'].includes(after))names.set(name.text,annotation.type);
  }
  for (const match of text.matchAll(/\b(?:import\s+([A-Za-z_]\w*)(?:\.[A-Za-z_]\w*)*|as\s+([A-Za-z_]\w*))/g)) {
    names.set(match[2] || match[1], 'module');
  }
  for (const match of text.matchAll(/\b(?:foreach|foreach_reverse)\s*\(\s*([A-Za-z_]\w*)(?:\s*,\s*([A-Za-z_]\w*))?\s*;/g)) {
    names.set(match[1], 'iterator');
    if (match[2]) names.set(match[2], 'iterator');
  }
  return names;
}

function completions(source, offset) {
  if (maskSource(source.slice(0, offset)).state !== 'code') return [];
  const prefix = source.slice(0, offset);
  const member = prefix.match(/\b([A-Za-z_]\w*)\s*\.\s*[A-Za-z_\w]*$/);
  if (member) {
    const lib = libraries[member[1]];
    if (!lib) return [];
    const items = Object.entries(lib).map(([label, args]) => ({ label, kind: 'function', detail: `${member[1]}.${label}(${args})` }));
    if (member[1] === 'math') items.push({label:'PI',kind:'variable',detail:'円周率'});
    if (member[1] === 'package') items.push({ label: 'path', kind: 'variable', detail: 'モジュール検索パターン配列' }, { label: 'loaded', kind: 'variable', detail: '読み込み済みモジュール' });
    return items;
  }
  // 先頭ドットや式の結果へのmember補完に、外側の名前を混ぜない。
  if(/\.\s*[A-Za-z_\w]*$/.test(prefix))return [];
  const items = new Map();
  for (const label of keywords) items.set(label, { label, kind: 'keyword' });
  for (const label of types) items.set(label, { label, kind: 'type' });
  for (const [label, [detail, documentation]] of Object.entries(builtins)) items.set(label, { label, kind: 'function', detail, documentation });
  for (const label of Object.keys(libraries)) {
    if (!items.has(label)) items.set(label, { label, kind: 'module', detail: 'Dua 標準ライブラリ' });
  }
  for (const [label, detail] of documentNames(source)) items.set(label, { label, kind: 'variable', detail: `このファイルの宣言: ${detail}` });
  return [...items.values()];
}

// Lexer columns count UTF-8 bytes; VS Code columns count UTF-16 code units.
function diagnosticPosition(source, diagnostic) {
  let line = diagnostic.line, column = diagnostic.column;
  if (!line || !column) {
    const match = diagnostic.message.match(/ at (\d+):(\d+)$/);
    if (match) { line = Number(match[1]); column = Number(match[2]); }
  }
  const lines = source.split('\n');
  const lineIndex = Math.min(Math.max((line || 1) - 1, 0), lines.length - 1);
  let bytes = 0, character = 0;
  for (const char of lines[lineIndex].replace(/\r$/, '')) {
    if (bytes + Buffer.byteLength(char) > (column || 1) - 1) break;
    bytes += Buffer.byteLength(char);
    character += char.length;
  }
  return { line: lineIndex, character };
}

module.exports = { completions, documentNames, diagnosticPosition, maskSource, builtins, libraries };
