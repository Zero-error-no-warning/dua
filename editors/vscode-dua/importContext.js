'use strict';
const { tokens } = require('./hostCompletion');

// 未完成のimport文字列でも補完範囲を示します。パス解決やファイル読込はしません。
function importPathContext(source, offset) {
  if (!Number.isInteger(offset) || offset < 0 || offset > source.length) return null;
  const input = tokens(source).tokens;
  for (let i = 1; i < input.length; i++) {
    const value = input[i], keyword = input[i - 1];
    if (value.kind !== 'string' || value.interpolated || keyword.text !== 'import'
      || keyword.kind !== 'identifier' || input[i - 2]?.text === '.') continue;
    const start = value.quote + 1, end = value.end - (value.closed ? 1 : 0);
    if (offset < start || offset > end) continue;
    return {
      importStart: keyword.start, start, end, closed: value.closed,
      specifier: source.slice(start, end), prefix: source.slice(start, offset),
      instance: input[i - 2]?.text === 'instance'
    };
  }
  return null;
}

module.exports = { importPathContext };
