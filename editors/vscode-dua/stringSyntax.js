'use strict';

const escapes = { n: '\n', r: '\r', t: '\t', 0: '\0', '"': '"', '\\': '\\' };

// 不完全な入力を投げずに走査する。診断そのものはランタイムと同じcheckerに任せる。
function decodeStringContent(raw, partial = false) {
  let value = '';
  for (let i = 0; i < raw.length; i++) {
    if (raw[i] !== '\\') { value += raw[i]; continue; }
    if (++i === raw.length) return partial ? value : undefined;
    if (!Object.hasOwn(escapes, raw[i])) return undefined;
    value += escapes[raw[i]];
  }
  return value;
}

function encodeStringContent(value) {
  return value.replace(/[\\"\n\r\t\0]/g, ch => ({ '\\': '\\\\', '"': '\\"', '\n': '\\n', '\r': '\\r', '\t': '\\t', '\0': '\\0' })[ch]);
}

function scanner(source) {
  const ranges = [];
  const mask = (start, end) => { if (end > start) ranges.push([start, end]); };
  function quoted(quote, interpolated) {
    let i = quote + 1, literal = quote;
    while (i < source.length) {
      const ch = source[i];
      if (ch === '"') { mask(literal, ++i); return { end: i, closed: true, state: 'code' }; }
      if (ch === '\n' || ch === '\r') { mask(literal, i); return { end: i, closed: false, state: 'code' }; }
      if (ch === '\\') {
        i++;
        if (i < source.length && source[i] !== '\n' && source[i] !== '\r') i++;
        continue;
      }
      if (interpolated && source.slice(i, i + 2) === '$$') { i += 2; continue; }
      if (interpolated && source.slice(i, i + 2) === '$(') {
        mask(literal, i + 2);
        const expression = code(i + 2, true);
        i = expression.end;
        if (!expression.closed) return { end: i, closed: false, state: expression.state };
        literal = i++;
        continue;
      }
      i++;
    }
    mask(literal, i);
    return { end: i, closed: false, state: 'string' };
  }
  function code(start, expression = false) {
    let i = start, depth = 1, prefix = false;
    while (i < source.length) {
      const ch = source[i], pair = source.slice(i, i + 2);
      if (ch === '#' || pair === '//') {
        const from = i;
        while (i < source.length && source[i] !== '\n') i++;
        mask(from, i);
        if (i === source.length) return { end: i, closed: false, state: 'comment' };
        continue;
      }
      if (pair === '/+') {
        const from = i;
        let nesting = 1; i += 2;
        while (i < source.length && nesting) {
          const pair = source.slice(i, i + 2);
          if (pair === '/+') { nesting++; i += 2; }
          else if (pair === '+/') { nesting--; i += 2; }
          else i++;
        }
        mask(from, i);
        if (nesting) return { end: i, closed: false, state: 'comment' };
        continue;
      }
      if (ch === '"') {
        const string = quoted(i, prefix); i = string.end; prefix = false;
        if (!string.closed && i === source.length) return string;
        continue;
      }
      const identifier = source.slice(i).match(/^[A-Za-z_]\w*/);
      if (identifier) { prefix = identifier[0] === 'i'; i += identifier[0].length; continue; }
      if (!/\s/.test(ch)) prefix = false;
      if (expression && ch === '(') depth++;
      if (expression && ch === ')' && --depth === 0) return { end: i, closed: true, state: 'code' };
      i++;
    }
    return { end: i, closed: !expression, state: 'code' };
  }
  return { quoted, code, ranges };
}

function scanQuotedString(source, quote, interpolated = false) {
  return scanner(source).quoted(quote, interpolated);
}

function maskStringsAndComments(source) {
  const scan = scanner(source), result = scan.code(0), text = source.split('');
  for (const [start, end] of scan.ranges) {
    for (let i = start; i < end; i++) if (text[i] !== '\n' && text[i] !== '\r') text[i] = ' ';
  }
  return { text: text.join(''), state: result.state };
}

module.exports = { decodeStringContent, encodeStringContent, scanQuotedString, maskStringsAndComments };
