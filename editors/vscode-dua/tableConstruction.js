'use strict';
const { tokens } = require('./hostCompletion');

// This is an editing context, not a parser or a type resolver. Types come from the shared service.
function constructionContext(source, offset) {
  const parsed = tokens(source.slice(0, offset));
  if (parsed.state !== 'code') return null;
  const input = parsed.tokens, stack = [];
  for (let i = 0; i < input.length; i++) {
    const token = input[i];
    if ('([{'.includes(token.text)) {
      let start = i - 1;
      if (token.text === '{' && input[start]?.kind === 'identifier') {
        while (start >= 2 && input[start - 1].text === '.' && input[start - 2].kind === 'identifier') start -= 2;
        if (['table','struct','alias','else','try','finally','do','export'].includes(input[start - 1]?.text)
          || ['else','try','finally','do'].includes(input[start]?.text)) start = i;
      } else start = i;
      stack.push({open:i, token, typeStart:start, named:start<i});
    } else if (')]}'.includes(token.text)) {
      if ('([{'.indexOf(stack.at(-1)?.token.text) === ')]}'.indexOf(token.text)) stack.pop();
    }
  }
  const projection = stack.find(frame => frame.named);
  if (!projection) return null;
  const active = stack.at(-1);
  let segment = active.open + 1, depth = 0;
  const assigned = new Set();
  for (let i = active.open + 1; i < input.length; i++) {
    const value = input[i].text;
    if (!depth && value === '=') {
      if (input[segment]?.kind === 'identifier' && i === segment + 1) assigned.add(input[segment].text);
    }
    if (!depth && value === ',') segment = i + 1;
    if ('([{'.includes(value)) depth++;
    if (')]}'.includes(value)) depth--;
  }
  const tail = input.slice(segment), field = active.named && (tail.length === 0 || tail.length === 1 && tail[0].kind === 'identifier');
  return {input, projection, active, assigned, field, partial:field ? tail[0] : null};
}

function completionProjection(source, offset) {
  const context = constructionContext(source, offset);
  if (!context) return null;
  const {input,projection} = context;
  const full = tokens(source).tokens;
  let end = source.length, depth = 1;
  for (const token of full.filter(token => token.start > input[projection.open].start)) {
    if (token.text === '{') depth++;
    if (token.text === '}' && --depth === 0) {end=token.end;break;}
  }
  let value = source.slice(0,input[projection.typeStart].start) + 'null' + source.slice(end);
  const stack = [];
  for (const token of tokens(value).tokens) {
    if ('([{'.includes(token.text)) stack.push(token.text);
    else if (')]}'.includes(token.text)) stack.pop();
  }
  if (end === source.length) {
    for (const open of stack.reverse()) {
      if (open === '{' && !/[;}]\s*$/.test(value)) value += ';';
      value += {'(':')','[':']','{':'}'}[open];
    }
    if (!/[;}]\s*$/.test(value)) value += ';';
  }
  return value;
}

function fieldCompletions(source, offset, catalog) {
  const context = constructionContext(source,offset);
  if (!context?.field) return [];
  const {input,active,assigned,partial} = context;
  // Named construction targets live in the module type namespace, independently of value bindings.
  const name = input.slice(active.typeStart,active.open).map(token=>token.text).join('');
  const type = catalog.symbols[name];
  if (type?.kind !== 'type') return [];
  const description = catalog.types[type.type];
  if (!description?.tableConstruction) return [];
  let end=offset;
  while (end<source.length && /[A-Za-z_0-9]/.test(source[end])) end++;
  const suffix = /^\s*=/.test(source.slice(end)) ? '' : ' = ';
  return Object.entries(description.members || {}).filter(([name])=>!assigned.has(name) && !name.startsWith('__'))
    .map(([label,entry])=>({label,kind:'property',detail:`${label}: ${entry.displayType || entry.type}`,
      documentation:'named table field',start:partial?.start ?? offset,end,insertText:label + suffix}));
}

module.exports = {constructionContext,completionProjection,fieldCompletions};
