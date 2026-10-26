'use strict';
const fs = require('node:fs');
const path = require('node:path');
const {readType,withoutNullExclusion,splitContainer}=require('./typeSyntax');
const scalarTypes = new Set('bool byte ubyte short ushort int uint long ulong float double real string'.split(' '));

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
        if (source[i++] === '"') { closed = true; break; }
      }
      let value;
      if (closed && !interpolated) value = source.slice(quote + 1, i - 1);
      result.push({ text: source.slice(start, i), kind: 'string', value, start, end: i, quote, closed, interpolated });
      if (!closed && i === source.length) state = 'string';
      continue;
    }
    const number = source.slice(i).match(/^(?:\d+\.\d+|\d+)/);
    if (number) { i+=number[0].length;result.push({text:number[0],kind:'number',start,end:i});continue; }
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
  return { types: entry.signatures?.length || ['function','method'].includes(entry.kind) ? [] : entry.types || (entry.type ? [entry.type] : []), entry, symbol,
    assets: entry.assets || null, typeObject: entry.kind === 'type' };
}
function atomicTypeName(name, catalog) {
  return scalarTypes.has(name) || ['any','void','table','array','associativeArray','function'].includes(name) || catalog.types[name] ? name : catalog.symbols[name]?.kind === 'type' ? catalog.symbols[name].type : null;
}
function catalogTypeName(name,catalog) {
  if(typeof name!=='string')return null;
  const direct=atomicTypeName(name,catalog);if(direct)return direct;
  const input=tokens(name).tokens,type=readType(input,0,name=>atomicTypeName(name,catalog));
  return type?.known && type.next===input.length ? type.type : null;
}
const typeInfo=(name,catalog)=>catalog.types[name] || catalog.types[withoutNullExclusion(name)];
function combine(values) {
  values = values.filter(Boolean);
  if (!values.length) return null;
  const elements=values.map(value=>value.element).filter(Boolean);
  return { types: [...new Set(values.flatMap(v => v.types || []))],
    assets: values.every(v => v.assets) ? [...new Set(values.flatMap(v => v.assets))] : null,
    uncertain: values.some(v => v.uncertain),
    entries: values.flatMap(v => v.entries || (v.entry ? [v.entry] : [])),
    ...(elements.length ? {element:combine(elements)} : {}) };
}
function memberValue(base, name, catalog) {
  if (!base) return null;
  const symbol = base.symbol ? `${base.symbol}.${name}` : null;
  if (symbol && catalog.symbols[symbol]) return entryValue(catalog.symbols[symbol], symbol);
  if (symbol && Object.keys(catalog.symbols).some(key => key.startsWith(symbol + '.'))) return entryValue({ kind: 'module' }, symbol);
  const entries = base.entries || (base.entry ? [base.entry] : []);
  const values = entries.flatMap(entry => entry.members?.[name] ? [entryValue(entry.members[name])] : []);
  values.push(...(base.types || []).flatMap(type => {
    const member = typeInfo(type,catalog)?.members?.[name];
    return member && (!base.typeObject || member.static) ? [entryValue(member)] : [];
  }));
  return combine(values);
}
function callValue(base) {
  if (!base) return null;
  if (base.typeObject) return { types: base.types, assets: null };
  const entries = base.entries || (base.entry ? [base.entry] : []);
  return { types: [...new Set(entries.flatMap(e => (e.signatures || []).map(s => s.returnType)).filter(Boolean))], assets: null };
}
function indexValue(base,catalog) {
  if (!base) return null;
  const types = (base.types || []).flatMap(type => {const container=splitContainer(withoutNullExclusion(type));
    return container ? [container.element] : typeInfo(type,catalog)?.elementTypes || [];});
  return combine([base.element,types.length ? {types,assets:null} : null]);
}
function declaredValue(type) {
  const inner=withoutNullExclusion(type);
  const container=splitContainer(inner);
  return container ? {types:[],assets:null,element:declaredValue(container.element),
    ...(container.key ? {associative:true,keys:declaredValue(container.key)} : {})} : {types:[type],assets:null};
}

function signaturesFor(value) {
  return (value?.entries || (value?.entry ? [value.entry] : [])).flatMap(entry=>entry.signatures || []);
}
function acceptsArity(signature,count) {
  const parameters=signature.parameters;
  if (signature.arityKnown === false || !Array.isArray(parameters)) return false;
  const required=parameters.filter(parameter=>!parameter.optional && !parameter.variadic).length;
  return count>=required && (parameters.at(-1)?.variadic || count<=parameters.length);
}
function returnedValue(signatures) {
  return {types:[...new Set(signatures.map(signature=>signature.returnType).filter(type=>typeof type==='string'))],assets:null};
}
function propertyValue(base,name,catalog,environment,explicit) {
  const entries=base?.entries || (base?.entry ? [base.entry] : []);
  const module=entries.some(entry=>entry.kind==='module');
  const array=base && ('element' in base || base.types?.some(type=>withoutNullExclusion(type).endsWith('[]')));
  if (!module && array && name==='length') return {types:['int'],assets:null};
  if (!module && base?.associative && ['length','keys','values'].includes(name)) {
    return name==='length' ? {types:['int'],assets:null} : {types:[],assets:null,element:name==='keys'?base.keys:base.element};
  }
  const member=memberValue(base,name,catalog);
  if (member) {
    if (!explicit && !module) {
      const signatures=signaturesFor(member).filter(signature=>acceptsArity(signature,0));
      if (signatures.length) return returnedValue(signatures);
    }
    return member;
  }
  // Table/host fields and __index can hide UFCS. Only sealed built-in receivers are inferred here.
  if (!base || module || base.typeObject || !(array || base.associative || base.types?.length && base.types.every(type=>scalarTypes.has(withoutNullExclusion(type))))) return null;
  const callable=environment.get(name) || entryValue(catalog.symbols[name],name);
  const signatures=signaturesFor(callable).filter(signature=> {
    if (!Array.isArray(signature.parameters) || !signature.parameters.length) return false;
    if (!explicit && !acceptsArity(signature,1)) return false;
    const receiver=signature.parameters[0].type;
    return typeof receiver==='string' && (['any','auto'].includes(receiver) || base.types?.includes(receiver)
      || array && receiver.endsWith('[]') || base.associative && /\[[^\]]+\]$/.test(receiver));
  });
  if (!signatures.length) return null;
  return explicit ? entryValue({kind:'function',signatures:signatures.map(signature=>({...signature,parameters:signature.parameters.slice(1)}))}) : returnedValue(signatures);
}

function resolveExpression(input, environment, catalog, context = {}) {
  let index = 0;
  function read() {
    const first = input[index++];
    if (!first) return null;
    let value,strictWithMember=false;
    if(first.text==='with' && input[index]?.text==='('){
      let start=++index,depth=1;
      while(index<input.length && depth){if(input[index].text==='(')depth++;if(input[index].text===')')depth--;if(depth)index++;}
      if(depth)return null;
      const target=resolveExpression(input.slice(start,index++),environment,catalog,context);
      const result=resolveExpression(input.slice(index),environment,catalog,{...context,withReceiver:target});
      index=input.length;return result;
    }
    else if(first.text==='.'){
      const name=input[index++];
      if(!context.withReceiver || name?.kind!=='identifier')return null;
      value=memberValue(context.withReceiver,name.text,catalog);
      strictWithMember=true;
    }
    else if (first.text === '(') { value = read(); if (input[index]?.text !== ')') return null; index++; }
    else if (first.text === '[') {
      const start = index; let depth = 1;
      while (index < input.length && depth) {
        if (input[index].text === '[') depth++;
        if (input[index].text === ']') depth--;
        if (depth) index++;
      }
      if (depth) return null;
      const groups = splitArguments(input.slice(start,index++));
      const colon=groups.map(group=> {
        let depth=0;
        for(let i=0;i<group.length;i++) {const text=group[i].text;if(!depth&&text===':')return i;
          if('([{'.includes(text))depth++;if(')]}'.includes(text))depth--;}
        return -1;
      });
      const associative=colon.some(index=>index>=0);
      const elements = groups.map((group,i)=>resolveExpression(associative?group.slice(colon[i]+1):group,environment,catalog,context));
      value = {types:[],assets:null,element:combine(elements),...(associative?{associative:true,
        keys:combine(groups.map((group,i)=>resolveExpression(group.slice(0,colon[i]),environment,catalog,context)))}:{})};
    }
    else if (first.kind === 'number') value={types:[first.text.includes('.')?'double':'int'],assets:null};
    else if (first.kind === 'string') value={types:['string'],assets:null};
    else if (['true','false'].includes(first.text)) value={types:['bool'],assets:null};
    else if (first.kind === 'identifier') {
      let end = index, name = first.text;
      while (input[end]?.text === '.' && input[end + 1]?.kind === 'identifier') {name += '.' + input[end + 1].text;end += 2;}
      if (input[end]?.text === '{' && catalog.symbols[name]?.kind === 'type') {
        value=entryValue(catalog.symbols[name],name); index=end;
      } else value = environment.get(first.text) || entryValue(catalog.symbols[first.text]
        || (Object.keys(catalog.symbols).some(key => key.startsWith(first.text + '.')) ? { kind: 'module' } : null), first.text);
    }
    else return null;
    while (index < input.length) {
      const next = input[index];
      if (next.text === '.' && input[index + 1]?.kind === 'identifier') {
        index += 2; value = strictWithMember ? memberValue(value,input[index-1].text,catalog)
          : propertyValue(value,input[index-1].text,catalog,environment,input[index]?.text==='(');
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
      } else if (next.text === '{' && value?.typeObject) {
        let depth = 1; index++;
        while (index < input.length && depth) {
          if (input[index].text === '{') depth++;
          if (input[index].text === '}') depth--;
          index++;
        }
        if (depth) return null;
        value = {types:value.types,assets:null};
      } else if (next.text === '[' && input[index + 1]?.kind === 'string' && input[index + 2]?.text === ']') {
        value = indexValue(value,catalog) || memberValue(value, input[index + 1].value, catalog); index += 3;
      } else if (next.text === '[') {
        let depth = 1; index++;
        while (index < input.length && depth) {
          if (input[index].text === '[') depth++;
          if (input[index].text === ']') depth--;
          index++;
        }
        if (depth) return null;
        value = indexValue(value,catalog);
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
    if (t.text === 'alias' && catalog.symbols[input[i + 1]?.text]?.kind === 'type') {
      while (i < input.length && input[i].text !== ';') i++;
      continue;
    }
    if (t.text === '{') {
      scopes.push(new Map());
      // A typed parameter hides an outer binding even before it is assigned.
      let close = i - 1;
      if (input[close]?.text === '>') close -= 2;
      if (input[close]?.text === ')') {
        let open = close, depth = 1;
        while (--open >= 0 && depth) { if (input[open].text === ')') depth++; if (input[open].text === '(') depth--; }
        open++;
        if (!['if', 'while', 'for', 'foreach', 'switch', 'catch', 'with'].includes(input[open - 1]?.text)) {
          for (let p of splitArguments(input.slice(open + 1, close))) {
            const equal = p.findIndex(t => t.text === '=');
            if (equal >= 0) p = p.slice(0, equal);
            const name = p.at(-1), type = p.slice(0, -1).map(t => t.text).join('');
            const resolved = catalogTypeName(type, catalog);
            if (name?.kind === 'identifier') set(name.text, resolved ? declaredValue(resolved) : {types:[],assets:null}, true);
          }
        }
      }
      continue;
    }
    if (t.text === '}') { if (scopes.length > 1) scopes.pop(); continue; }
    if (t.text === 'import' && input[i + 1]?.kind === 'identifier') {
      const name = input[i + 1].text, alias = input[i + 2]?.text === 'as' ? input[i + 3]?.text : name;
      if (alias) set(alias, entryValue(catalog.symbols[name] || { kind: 'module' }, name), true);
    }
    let name, expression, declaration = false, declaredType;
    if (t.kind === 'identifier' || t.text==='(') {
      const annotation=readType(input,i,name=>atomicTypeName(name,catalog));
      const typeName=t.text,resolved=annotation?.known ? annotation.type : null;
      const next=annotation?.next || i+1;
      if ((resolved || typeName==='auto') && input[next]?.kind==='identifier' && input[next+1]?.text==='(') {
        let close=next+2,depth=1;
        while (close<input.length && depth) {if(input[close].text==='(')depth++;if(input[close].text===')')depth--;if(depth)close++;}
        if (!depth && input[close+1]?.text==='{') {
          const groups=splitArguments(input.slice(next+2,close)).filter(group=>group.length);
          const parameters=groups.map(group=> {
            const equal=group.findIndex(token=>token.text==='=');
            let declaration=equal<0?group:group.slice(0,equal);
            const variadic=declaration.slice(-3).every(token=>token.text==='.') && declaration.length>=4;
            if(variadic)declaration=declaration.slice(0,-3);
            const name=declaration.at(-1);
            const rawType=declaration.slice(0,-1).map(token=>token.text).join('');
            const type=catalogTypeName(rawType,catalog);
            return name?.kind==='identifier' && (type || !rawType || rawType==='auto')
              ? {name:name.text,type:type || 'any',optional:equal>=0,variadic} : null;
          });
          if(parameters.every(Boolean))set(input[next].text,entryValue({kind:'function',signatures:[{returnType:resolved || 'any',parameters}]},input[next].text),true);
          else set(input[next].text,entryValue({kind:'function'},input[next].text),true);
          i=close;continue;
        }
      }
      if (resolved && input[next]?.kind === 'identifier') {
        if (input[next + 1]?.text === ';') {
          set(input[next].text, declaredValue(resolved), true); i = next + 1; continue;
        }
        if (input[next + 1]?.text === '=') {
          declaredType = resolved; name = input[next].text; expression = next + 2; declaration = true;
        }
      }
    }
    if (t.kind === 'identifier' && (catalog.types[t.text] || /^(?:auto|bool|int|long|double|float|string|[A-Z]\w*)$/.test(t.text))) {
      let next = i + 1;
      while (input[next]?.text === '[') {
        let depth = 1; next++;
        while (next < input.length && depth) { if (input[next].text === '[') depth++; if (input[next].text === ']') depth--; next++; }
        if (depth) break;
      }
      if (input[next]?.kind === 'identifier' && input[next + 1]?.text === ';') {
        set(input[next].text, { types: next === i + 1 && catalog.types[t.text] ? [t.text] : [], assets: null }, true); i = next + 1; continue;
      }
    }
    if (!name && t.kind === 'identifier' && input[i + 1]?.kind === 'identifier' && input[i + 2]?.text === '=') {
      declaredType = t.text; name = input[i + 1].text; expression = i + 3; declaration = true;
    } else if (!name && t.kind === 'identifier' && input[i + 1]?.text === '=' && input[i - 1]?.text !== '.'
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
    const value = (catalogTypeName(declaredType,catalog) ? declaredValue(declaredType) : null)
      || resolveExpression(input.slice(expression, end), lookup, catalog, context);
    set(name, value, declaration, conditionalBefore(i)); i = end;
  }
  return lookup;
}

function receiverTokens(input) {
  let start = input.length, depth = 0;
  while (start > 0) {
    const p = input[start - 1].text;
    const nested = depth > 0;
    if (!depth && p === '}' && start < input.length && !['.','['].includes(input[start]?.text)) break;
    if (')]}'.includes(p)) depth++;
    if ('([{'.includes(p)) { if (!depth) break; depth--; }
    if (!depth && [';', '=', ',', '{', '}', 'return'].includes(p) && !(p === '{' && nested)) break;
    start--;
  }
  return input.slice(start);
}
function detail(label, entry) {
  return (entry.signatures || []).map(s => `${label}(${(s.parameters || []).map(p => `${p.displayType || p.type} ${p.name}${p.optional ? ' = …' : ''}${p.variadic ? '...' : ''}`).join(', ')}) → ${entry.displayType || s.returnType}`).join('\n') || `${label}${entry.type ? ': ' + (entry.displayType || entry.type) : ''}`;
}

// 完成前の式でも、括弧・引数・文境界を越えてwith対象を漏らさない。
function withScopes(input){
  const result=[];
  for(let i=0;i<input.length;i++){
    if(input[i].text!=='with'||input[i+1]?.text!=='(')continue;
    let end=i+2,depth=1;
    for(;end<input.length;end++){if(input[end].text==='(')depth++;if(input[end].text===')'&&!--depth)break;}
    if(depth)continue;
    const bodyStart=end+1;let stop=bodyStart,stack=[];
    for(;stop<input.length;stop++){
      const text=input[stop].text;
      if(!stack.length && [';',',',')',']','}'].includes(text))break;
      if('([{'.includes(text))stack.push(text);
      else if(')]}'.includes(text))stack.pop();
    }
    if(stop===input.length)result.push({target:input.slice(i+2,end),bodyStart});
  }
  return result;
}
function withCompletionReceiver(input,dotIndex,environment,catalog,context){
  const scopes=withScopes(input.slice(0,dotIndex));
  if(!scopes.length)return null;
  let target=null;
  for(const scope of scopes)target=resolveExpression(scope.target,environment,catalog,{...context,withReceiver:target});
  const body=input.slice(scopes.at(-1).bodyStart,dotIndex);
  let start=0,depth=0;
  for(let i=0;i<body.length;i++){
    const text=body[i].text;
    if('([{'.includes(text))depth++;
    else if(')]}'.includes(text))depth--;
    if(!depth && ['+','-','*','/','%','~','?',';',',',':','return','=>'].includes(text))start=i+1;
  }
  const receiver=receiverTokens(body.slice(start));
  return {value:receiver.length?resolveExpression(receiver,environment,catalog,{...context,withReceiver:target}):target};
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
    const fullEnv=environmentAt(input.slice(0,partial?-2:-1),catalog,context.initial,context);
    const scoped=withCompletionReceiver(input,input.length-(partial?2:1),fullEnv,catalog,context);
    const value = scoped ? scoped.value : resolveExpression(receiver, env, catalog, context);
    if (value?.symbol) {
      const prefix = value.symbol + '.';
      for (const [key, entry] of Object.entries(catalog.symbols)) {
        const name = key.slice(prefix.length);
        if (key.startsWith(prefix) && !name.includes('.')) entries.set(name, entry);
      }
    }
    // 型内のenumもカタログに記述されたメンバーだけをたどります。
    for (const entry of value?.entries || (value?.entry ? [value.entry] : [])) {
      for (const [name, member] of Object.entries(entry.members || {})) entries.set(name, member);
    }
    for (const type of value?.types || []) for (const [name, entry] of Object.entries(typeInfo(type,catalog)?.members || {})) {
      if (!value.typeObject || entry.static) entries.set(name, entry);
    }
  } else for (const [name, entry] of Object.entries(catalog.symbols)) if (!name.includes('.')) entries.set(name, entry);
  return [...entries].filter(([name]) => !name.startsWith('__')).map(([label, entry]) => ({
    label, kind: entry.kind || 'variable', detail: detail(label, entry), documentation: entry.documentation || catalog.origin || 'Host API',
    start: partial?.start ?? offset, end: offset
  }));
}

const catalogCache = new Map();
const record = value => value && typeof value === 'object' && !Array.isArray(value);
function cleanEntry(value, depth = 0) {
  if (!record(value)) return null;
  const entry = {};
  for (const name of ['kind', 'type']) if (typeof value[name] === 'string') entry[name] = value[name];
  if (typeof value.static === 'boolean') entry.static = value.static;
  if (depth < 16 && record(value.members)) {
    entry.members = Object.create(null);
    for (const [name, valueMember] of Object.entries(value.members)) {
      const member = cleanEntry(valueMember, depth + 1);
      if (member) entry.members[name] = member;
    }
  }
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
          if (['class', 'struct', 'union', 'aggregate'].includes(value.kind)) data.types[name].kind = value.kind;
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

function diagnosticHostTypes(catalog) {
  const names = new Set(Object.entries(catalog?.types || {}).filter(([, value]) => value.kind === 'class').map(([name]) => name));
  for (const [name, symbol] of Object.entries(catalog?.symbols || {})) {
    if (symbol.kind === 'type' && catalog.types[symbol.type]?.kind === 'class') names.add(name);
  }
  return [...names].filter(name => /^[A-Za-z_]\w*$/.test(name) && name.length <= 256
    && !/^(?:auto|any|void|null|bool|byte|ubyte|short|ushort|int|uint|long|ulong|float|double|real|string|array|table|associativeArray|function)$/.test(name)).sort().slice(0, 4096);
}

module.exports = { tokens, splitArguments, resolveExpression, environmentAt, receiverTokens, apiCompletions, loadCatalog, combine, diagnosticHostTypes,withScopes };
