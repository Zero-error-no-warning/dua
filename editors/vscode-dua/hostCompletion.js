'use strict';
const fs = require('node:fs');
const path = require('node:path');

// A small non-executing token reader; punctuation inside strings/comments is inert.
function tokens(source) {
  const result = [];
  let i = 0, state = 'code';
  while (i < source.length) {
    const start = i, c = source[i], pair = source.slice(i, i + 2);
    if (/\s/.test(c)) { i++; continue; }
    if (c === '#' || pair === '//') {
      while (i < source.length && source[i] !== '\n') i++;
      if (i === source.length) state = 'comment';
      continue;
    }
    if (pair === '/+') {
      i += 2;
      let depth = 1;
      while (i < source.length && depth) {
        const p = source.slice(i, i + 2);
        if (p === '/+') { depth++; i += 2; }
        else if (p === '+/') { depth--; i += 2; }
        else i++;
      }
      if (depth) state = 'comment';
      continue;
    }
    if (c === '"' || (c === 'i' && source[i + 1] === '"')) {
      const interpolated = c === 'i';
      if (interpolated) i++;
      const quote = i++;
      let closed = false;
      while (i < source.length && source[i] !== '\n' && source[i] !== '\r') {
        if (source[i] === '\\') i += Math.min(2, source.length - i);
        else if (source[i++] === '"') { closed = true; break; }
      }
      let value;
      if (closed && !interpolated) { try { value = JSON.parse(source.slice(quote, i)); } catch {} }
      result.push({ text: source.slice(start, i), kind: 'string', value, start, end: i, quote, closed, interpolated });
      if (!closed && i === source.length) state = 'string';
      continue;
    }
    const identifier = source.slice(i).match(/^[A-Za-z_]\w*/);
    if (identifier) { i += identifier[0].length; result.push({ text: identifier[0], kind: 'identifier', start, end: i }); }
    else { i++; result.push({ text: c, kind: 'punctuation', start, end: i }); }
  }
  return { tokens: result, state };
}

function splitArguments(input) {
  const groups = [[]];
  let depth = 0;
  for (const token of input) {
    if ('([{'.includes(token.text)) depth++;
    if (')]}'.includes(token.text)) depth--;
    if (token.text === ',' && depth === 0) groups.push([]);
    else groups.at(-1).push(token);
  }
  return groups;
}

function entryValue(entry, symbol) {
  if (!entry) return null;
  return { types: entry.types || (entry.type ? [entry.type] : []), entry, symbol,
    assets: entry.assets || null, typeObject: entry.kind === 'type' };
}
function combine(values) {
  values = values.filter(Boolean);
  if (!values.length) return null;
  return { types: [...new Set(values.flatMap(v => v.types || []))],
    assets: values.every(v => v.assets) ? [...new Set(values.flatMap(v => v.assets))] : null,
    uncertain: values.some(v => v.uncertain),
    entries: values.flatMap(v => v.entries || (v.entry ? [v.entry] : [])) };
}
function memberValue(base, name, catalog) {
  if (!base) return null;
  const symbol = base.symbol ? `${base.symbol}.${name}` : null;
  if (symbol && catalog.symbols[symbol]) return entryValue(catalog.symbols[symbol], symbol);
  if (symbol && Object.keys(catalog.symbols).some(key => key.startsWith(symbol + '.'))) return entryValue({ kind: 'module' }, symbol);
  const values = (base.types || []).flatMap(type => {
    const member = catalog.types[type]?.members?.[name];
    return member && (!base.typeObject || member.static) ? [entryValue(member)] : [];
  });
  return combine(values);
}
function callValue(base) {
  if (!base) return null;
  if (base.typeObject) return { types: base.types, assets: null };
  const entries = base.entries || (base.entry ? [base.entry] : []);
  return { types: [...new Set(entries.flatMap(e => (e.signatures || []).map(s => s.returnType)).filter(Boolean))], assets: null };
}

function resolveExpression(input, environment, catalog, context = {}) {
  let index = 0;
  function read() {
    const first = input[index++];
    if (!first) return null;
    let value;
    if (first.text === '(') { value = read(); if (input[index]?.text !== ')') return null; index++; }
    else if (first.kind === 'identifier') value = environment.get(first.text) || entryValue(catalog.symbols[first.text]
      || (Object.keys(catalog.symbols).some(key => key.startsWith(first.text + '.')) ? { kind: 'module' } : null), first.text);
    else return null;
    while (index < input.length) {
      const next = input[index];
      if (next.text === '.' && input[index + 1]?.kind === 'identifier') {
        index += 2; value = memberValue(value, input[index - 1].text, catalog);
      } else if (next.text === '(') {
        const start = ++index;
        let depth = 1;
        while (index < input.length && depth) {
          if (input[index].text === '(') depth++;
          if (input[index].text === ')') depth--;
          if (depth) index++;
        }
        if (depth) return null;
        const args = splitArguments(input.slice(start, index++));
        value = context.resolveCall?.(value, args, context) || callValue(value);
      } else if (next.text === '[' && input[index + 1]?.kind === 'string' && input[index + 2]?.text === ']') {
        value = memberValue(value, input[index + 1].value, catalog); index += 3;
      } else break;
    }
    return value;
  }
  const value = read();
  return index === input.length ? value : null;
}

function environmentAt(input, catalog, initial = new Map(), context = {}) {
  const scopes = [new Map(initial)];
  const lookup = { get(name) { for (let i = scopes.length - 1; i >= 0; i--) if (scopes[i].has(name)) return scopes[i].get(name); } };
  function set(name, value, declaration, conditional = false) {
    const scope = declaration ? scopes.at(-1) : [...scopes].reverse().find(s => s.has(name)) || scopes.at(-1);
    if (!declaration && (conditional || scope !== scopes.at(-1))) value = { ...combine([scope.get(name) || { types: [], assets: null }, value || { types: [], assets: null }]), uncertain: true };
    scope.set(name, value || { types: [], assets: null });
  }
  function conditionalBefore(index) {
    let depth = 0;
    for (let i = index - 1; i >= 0; i--) {
      const p = input[i].text;
      if (')]}'.includes(p)) depth++;
      if ('([{'.includes(p)) { if (!depth) break; depth--; }
      if (!depth && [';', '{', '}'].includes(p)) break;
      if (!depth && ['if', 'else', 'while', 'for', 'foreach', 'case'].includes(p)) return true;
    }
    return false;
  }
  for (let i = 0; i < input.length; i++) {
    const t = input[i];
    if (t.text === '{') { scopes.push(new Map()); continue; }
    if (t.text === '}') { if (scopes.length > 1) scopes.pop(); continue; }
    if (t.text === 'import' && input[i + 1]?.kind === 'identifier') {
      const name = input[i + 1].text, alias = input[i + 2]?.text === 'as' ? input[i + 3]?.text : name;
      if (alias) set(alias, entryValue(catalog.symbols[name] || { kind: 'module' }, name), true);
    }
    let name, expression, declaration = false, declaredType;
    if (t.kind === 'identifier' && input[i + 1]?.kind === 'identifier' && input[i + 2]?.text === '=') {
      declaredType = t.text; name = input[i + 1].text; expression = i + 3; declaration = true;
    } else if (t.kind === 'identifier' && input[i + 1]?.text === '=' && input[i - 1]?.text !== '.'
      && input[i + 2]?.text !== '=') { name = t.text; expression = i + 2; }
    if (!name) continue;
    let end = expression, depth = 0;
    while (end < input.length) {
      const p = input[end].text;
      if (!depth && (p === ';' || p === '}')) break;
      if ('([{'.includes(p)) depth++;
      if (')]}'.includes(p)) { if (!depth) break; depth--; }
      end++;
    }
    if (end === input.length) continue;
    const value = resolveExpression(input.slice(expression, end), lookup, catalog, context)
      || (catalog.types[declaredType] ? { types: [declaredType], assets: null } : null);
    set(name, value, declaration, conditionalBefore(i)); i = end;
  }
  return lookup;
}

function receiverTokens(input) {
  let start = input.length, depth = 0;
  while (start > 0) {
    const p = input[start - 1].text;
    if (!depth && p === '}') break;
    if (')]}'.includes(p)) depth++;
    if ('([{'.includes(p)) { if (!depth) break; depth--; }
    if (!depth && [';', '=', ',', '{', '}', 'return'].includes(p)) break;
    start--;
  }
  return input.slice(start);
}
function detail(label, entry) {
  return (entry.signatures || []).map(s => `${label}(${(s.parameters || []).map(p => `${p.type} ${p.name}${p.optional ? ' = …' : ''}${p.variadic ? '...' : ''}`).join(', ')}) → ${s.returnType}`).join('\n') || `${label}${entry.type ? ': ' + entry.type : ''}`;
}
function apiCompletions(source, offset, catalog, context = {}) {
  const parsed = tokens(source.slice(0, offset));
  if (parsed.state !== 'code') return [];
  const input = parsed.tokens;
  const partial = input.at(-1)?.kind === 'identifier' ? input.at(-1) : null;
  const dot = partial ? input.at(-2) : input.at(-1);
  const entries = new Map();
  if (dot?.text === '.') {
    const receiver = receiverTokens(input.slice(0, partial ? -2 : -1));
    const env = environmentAt(input.slice(0, input.length - receiver.length - (partial ? 2 : 1)), catalog, context.initial, context);
    const value = resolveExpression(receiver, env, catalog, context);
    if (value?.symbol) {
      const prefix = value.symbol + '.';
      for (const [key, entry] of Object.entries(catalog.symbols)) {
        const name = key.slice(prefix.length);
        if (key.startsWith(prefix) && !name.includes('.')) entries.set(name, entry);
      }
    }
    for (const type of value?.types || []) for (const [name, entry] of Object.entries(catalog.types[type]?.members || {})) {
      if (!value.typeObject || entry.static) entries.set(name, entry);
    }
  } else for (const [name, entry] of Object.entries(catalog.symbols)) if (!name.includes('.')) entries.set(name, entry);
  return [...entries].filter(([name]) => !name.startsWith('__')).map(([label, entry]) => ({
    label, kind: entry.kind || 'variable', detail: detail(label, entry), documentation: catalog.origin || 'Host API',
    start: partial?.start ?? offset, end: offset
  }));
}

const catalogCache = new Map();
const record = value => value && typeof value === 'object' && !Array.isArray(value);
function cleanEntry(value) {
  if (!record(value)) return null;
  const entry = {};
  for (const name of ['kind', 'type']) if (typeof value[name] === 'string') entry[name] = value[name];
  if (typeof value.static === 'boolean') entry.static = value.static;
  if (Array.isArray(value.signatures)) entry.signatures = value.signatures.filter(s => record(s) && typeof s.returnType === 'string' && Array.isArray(s.parameters))
    .map(s => ({ returnType: s.returnType, parameters: s.parameters.filter(p => record(p) && typeof p.name === 'string' && typeof p.type === 'string') }));
  return entry;
}
function loadCatalog(root, metadataFiles = ['.dua-completion.json']) {
  const result = { symbols: Object.create(null), types: Object.create(null), assets: [], contexts: [], stringArguments: [], assetLoaders: [], root };
  for (const filename of Array.isArray(metadataFiles) ? metadataFiles : []) {
    if (typeof filename !== 'string') continue;
    const absolute = path.resolve(root, filename);
    if (!absolute.startsWith(path.resolve(root) + path.sep)) continue;
    try {
      const stat = fs.statSync(absolute), stamp = `${stat.mtimeMs}:${stat.ctimeMs}:${stat.size}`;
      if (stat.size > 16 * 1024 * 1024) continue;
      let cached = catalogCache.get(absolute);
      if (!cached || cached.stamp !== stamp) {
        const parsed = JSON.parse(fs.readFileSync(absolute, 'utf8'));
        if (parsed?.schemaVersion !== 1 || !record(parsed.symbols) || !record(parsed.types)) continue;
        const data = { ...parsed, symbols: Object.create(null), types: Object.create(null) };
        for (const [name, value] of Object.entries(parsed.symbols)) { const entry = cleanEntry(value); if (entry) data.symbols[name] = entry; }
        for (const [name, value] of Object.entries(parsed.types)) if (record(value?.members)) {
          const members = Object.create(null);
          for (const [member, v] of Object.entries(value.members)) { const entry = cleanEntry(v); if (entry) members[member] = entry; }
          data.types[name] = { members };
        }
        cached = { stamp, data };
        if (catalogCache.size >= 32) catalogCache.clear();
        catalogCache.set(absolute, cached);
      }
      const data = cached.data;
      Object.assign(result.symbols, data.symbols); Object.assign(result.types, data.types);
      result.origin = data.origin || filename;
      for (const key of ['assets', 'contexts', 'stringArguments', 'assetLoaders']) if (Array.isArray(data[key])) result[key].push(...data[key]);
    } catch { /* A missing/partially replaced catalog must not break language features. */ }
  }
  for (const name of Object.keys(result.symbols)) if (name.includes('.')) {
    const parent = name.split('.')[0];
    if (!result.symbols[parent]) result.symbols[parent] = { kind: 'module' };
  }
  return result;
}

module.exports = { tokens, splitArguments, resolveExpression, environmentAt, receiverTokens, apiCompletions, loadCatalog, combine };
