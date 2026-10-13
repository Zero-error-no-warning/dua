'use strict';

const keywords = 'auto delegate alias struct is cast try catch return if else while for foreach switch case default break continue yield true false null this import export as instance new table'.split(' ');
const types = 'any void bool byte ubyte short ushort int uint long ulong float double real string'.split(' ');
const builtins = {
  error: ['error(value, level?)', 'スクリプトエラーを送出します。'],
  typeof: ['typeof(value)', '値の型情報を取得します。'],
  typeinfo: ['typeinfo(value)', '値の型と型チェーンを取得します。'],
  length: ['length(value)', '文字列・配列・テーブルなどの長さを返します。'],
  len: ['len(value)', 'lengthの別名です。'],
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
  require: ['require(name)', 'モジュールの既定の実体を読み込みます。'],
  addModulePath: ['addModulePath(pattern)', 'モジュール検索パターンを追加します。'],
  setModuleLoaders: ['setModuleLoaders(loaders)', 'モジュールローダーを設定します。'],
  addModuleLoader: ['addModuleLoader(loader)', 'モジュールローダーを追加します。'],
  _ENV: ['_ENV(name)', 'グローバル値を名前で取得します。']
};
const libraries = {
  string: { len: 'value', upper: 'value', lower: 'value', trim: 'value', contains: 'value, needle', replace: 'value, from, to' },
  math: { abs: 'value', floor: 'value', min: 'value, args...', max: 'value, args...' },
  table: { len: 'value', length: 'value', keys: 'value', map: 'value, callback', filter: 'value, callback' },
  utf8: { len: 'value' },
  io: { exists: 'path', readFile: 'path' },
  os: { clock: '', getenv: 'name' },
  time: { nowUnix: '' },
  debug: { type: 'value', traceback: '' },
  json: { encode: 'value' },
  package: { require: 'name', addPath: 'pattern', addLoader: 'loader', clearLoaders: '' }
};

// Preserve UTF-16 offsets while masking strings and nested block comments.
// Dua strings have no backslash escapes. A newline ends an incomplete string.
function maskSource(source) {
  const result = source.split('');
  let state = 'code', depth = 0;
  for (let i = 0; i < source.length; i++) {
    const pair = source.slice(i, i + 2), char = source[i];
    if (state === 'code') {
      if (pair === '/+') { state = 'block'; depth = 1; }
      else if (pair === '//' || char === '#') state = 'line';
      else if (char === '"') state = 'string';
      else continue;
      result[i] = ' ';
      if (pair === '/+' || pair === '//') result[++i] = ' ';
    } else {
      if (char !== '\n' && char !== '\r') result[i] = ' ';
      if (state === 'block') {
        if (pair === '/+') { depth++; result[++i] = ' '; }
        else if (pair === '+/') {
          result[++i] = ' ';
          if (--depth === 0) state = 'code';
        }
      } else if (char === '\n' || (state === 'string' && char === '"')) state = 'code';
    }
  }
  return { text: result.join(''), state };
}

function documentNames(source) {
  const text = maskSource(source).text;
  const names = new Map();
  const declaration = /\b([A-Za-z_]\w*(?:\s*\[[A-Za-z_\w]*\])*)\s+([A-Za-z_]\w*)\s*(?=[=;,(){}])/g;
  const excluded = new Set(keywords.filter(word => !['auto', 'struct', 'table', 'alias'].includes(word)));
  for (const match of text.matchAll(declaration)) {
    if (!excluded.has(match[1])) names.set(match[2], match[1]);
  }
  for (const match of text.matchAll(/\b(?:import\s+([A-Za-z_]\w*)(?:\.[A-Za-z_]\w*)*|as\s+([A-Za-z_]\w*))/g)) {
    names.set(match[2] || match[1], 'module');
  }
  for (const match of text.matchAll(/\bforeach\s*\(\s*([A-Za-z_]\w*)(?:\s*,\s*([A-Za-z_]\w*))?\s*;/g)) {
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
    if (member[1] === 'package') items.push({ label: 'path', kind: 'variable', detail: 'モジュール検索パターン配列' }, { label: 'loaded', kind: 'variable', detail: '読み込み済みモジュール' });
    return items;
  }
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
