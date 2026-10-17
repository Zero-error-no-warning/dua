'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const host = require('./hostCompletion');

function key(filename) { const p = path.resolve(filename); return process.platform === 'win32' ? p.toLowerCase() : p; }
function inside(root, filename) { const relative = path.relative(root, filename); return relative !== '..' && !relative.startsWith('..' + path.sep) && !path.isAbsolute(relative); }
// Retain digests, never asset buffers. ctime/inode also invalidate same-size rewrites.
const digestCache = new Map();
function stamp(stat) { return `${stat.size}:${stat.mtimeMs}:${stat.ctimeMs}:${stat.dev}:${stat.ino}`; }
function digest(absolute, stat) {
  const id = key(absolute), version = stamp(stat), cached = digestCache.get(id);
  if (cached?.version === version) return cached.hash;
  const hash = crypto.createHash('sha256').update(fs.readFileSync(absolute)).digest('hex');
  if (stamp(fs.statSync(absolute)) !== version) return null;
  if (digestCache.size >= 512) digestCache.delete(digestCache.keys().next().value);
  digestCache.set(id, { version, hash });
  return hash;
}
function validSource(root, source) {
  if (!source || typeof source.path !== 'string') return false;
  const absolute = path.resolve(root, source.path);
  if (!inside(root, absolute)) return false;
  try {
    const stat = fs.statSync(absolute);
    return stat.isFile() && (source.size === undefined || stat.size === source.size)
      && (source.modifiedMs === undefined || Math.abs(Math.trunc(stat.mtimeMs) - source.modifiedMs) <= 1)
      && (source.sha256 === undefined || digest(absolute, stat) === source.sha256);
  } catch { return false; }
}
function literalPath(input, wrappers = []) {
  if (input.length === 1 && input[0].kind === 'string') return { value: input[0].value, wrapped: false };
  if (input.length === 4 && wrappers.includes(input[0].text) && input[1].text === '(' && input[2].kind === 'string' && input[3].text === ')') return { value: input[2].value, wrapped: true };
  return {};
}

// Scene formats and host-specific names remain in generated metadata, not here.
function createContext(catalog, documentPath) {
  const root = catalog.root;
  const assets = (catalog.assets || []).filter(a => a && a.names && typeof a.names === 'object' && typeof a.type === 'string' && validSource(root, a))
    .map(a => ({ ...a, absolute: key(path.resolve(root, a.path)) }));
  const contexts = (catalog.contexts || []).filter(c => c && typeof c.script === 'string'
    && key(path.resolve(root, c.script)) === key(documentPath)
    && (!c.assetDirectory || typeof c.assetDirectory === 'string')
    && Array.isArray(c.sources) && c.sources.length && c.sources.every(s => validSource(root, s)));
  const symbols = { ...catalog.symbols };
  const names = new Set(contexts.flatMap(c => Object.keys(c.bindings || {})));
  for (const name of names) {
    const values = contexts.map(c => {
      const binding = c.bindings?.[name];
      if (!binding) return { types: [], assets: null };
      return { types: binding.types || (binding.type ? [binding.type] : []),
        assets: Array.isArray(binding.assets) ? binding.assets.map(p => key(path.resolve(root, p))) : null };
    });
    const value = host.combine(values);
    symbols[name] = { kind: 'variable', ...value };
  }
  const effective = { ...catalog, symbols };
  const initial = new Map();
  for (const name of names) if (!name.includes('.')) initial.set(name, { ...symbols[name], symbol: name });
  const directories = [...new Set(contexts.map(c => path.resolve(root, c.assetDirectory || '.')))];
  const context = { catalog: effective, assets, initial, directories, shared: contexts.length > 1 };
  context.resolveCall = (value, args) => {
    const loader = (catalog.assetLoaders || []).find(l => l && typeof l.returnType === 'string' && l.function === value?.symbol
      && (Array.isArray(l.pathArguments) || Number.isInteger(l.pathArgument)));
    if (!loader) return null;
    const literal = (loader.pathArguments || [loader.pathArgument]).map(index => literalPath(args[index] || [], loader.pathWrappers))
      .find(item => typeof item.value === 'string') || {};
    const dirs = literal.wrapped && directories.length ? directories : [root];
    return { types: [loader.returnType],
      assets: typeof literal.value === 'string' ? dirs.map(dir => key(path.resolve(dir, literal.value))) : null,
      uncertain: literal.wrapped && dirs.length > 1 };
  };
  return context;
}

function callAtString(input) {
  const stack = [];
  for (let i = 0; i < input.length; i++) {
    const p = input[i].text;
    if ('([{'.includes(p)) stack.push({ punctuation: p, callee: p === '(' ? host.receiverTokens(input.slice(0, i)) : [], argument: 0, argumentStart: i + 1 });
    else if (')]}'.includes(p)) stack.pop();
    else if (p === ',' && stack.at(-1)?.punctuation === '(') { stack.at(-1).argument++; stack.at(-1).argumentStart = i + 1; }
  }
  const call = stack.at(-1);
  return call?.punctuation === '(' && call.argumentStart === input.length && call.callee.length ? call : null;
}
function stringCompletions(source, offset, context) {
  const parsed = host.tokens(source.slice(0, offset));
  if (parsed.state !== 'string') return [];
  const current = parsed.tokens.at(-1);
  if (current.interpolated) return [];
  const before = parsed.tokens.slice(0, -1), call = callAtString(before);
  if (!call) return [];
  const method = call.callee.at(-1)?.text;
  const hasReceiver = call.callee.at(-2)?.text === '.';
  const receiver = hasReceiver ? call.callee.slice(0, -2) : [];
  const environment = host.environmentAt(before, context.catalog, context.initial, context);
  const value = hasReceiver ? host.resolveExpression(receiver, environment, context.catalog, context) : null;
  const rules = (context.catalog.stringArguments || []).filter(rule => rule && typeof rule.source === 'string' && rule.argument === call.argument
    && (hasReceiver ? rule.method === method && (!value?.types?.length || value.types.includes(rule.receiverType)) : rule.function === method));
  let end = offset;
  while (end < source.length && source[end] !== '\n' && source[end] !== '\r') {
    if (source[end] === '"') break;
    end++;
  }
  const result = [];
  for (const rule of rules) {
    const candidates = context.assets.filter(a => a.type === rule.receiverType
      && (value?.assets ? value.assets.includes(a.absolute) : true));
    for (const asset of candidates) for (const name of Array.isArray(asset.names[rule.source]) ? asset.names[rule.source] : []) {
      // Dua strings are raw: quotes/newlines cannot be represented in one literal.
      if (typeof name !== 'string' || /["\r\n]/.test(name)) continue;
      const status = !value?.assets ? '対象未確定・プロジェクト候補' : context.shared || value.uncertain ? '複数の静的参照候補' : '静的参照';
      result.push({ label: name, insertText: name, kind: 'value',
        detail: `${rule.source} · ${asset.path} · ${status}`,
        documentation: `${context.catalog.origin || 'Host asset'}\n${asset.path}`,
        start: current.quote + 1, end });
    }
  }
  return result;
}

module.exports = { createContext, stringCompletions, validSource, callAtString };
