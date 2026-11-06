'use strict';
const host = require('./hostCompletion');
const language = require('./language');
const standardFunctions = require('./standardFunctions');
const {withoutNullExclusion} = require('./typeSyntax');

const closing = {'(': ')', '[': ']', '{': '}'};
const control = new Set(['if','while','for','foreach', 'foreach_reverse','switch','catch','with','cast','delegate']);

// Reuse completion's lexer; commas in strings, comments and nested arguments are inert.
function callContext(source, offset) {
  const parsed = host.tokens(source.slice(0, offset));
  if (parsed.state === 'comment') return null;
  const input = parsed.tokens, stack = [];
  for (let i = 0; i < input.length; i++) {
    const token = input[i];
    if (token.kind !== 'punctuation') continue;
    if (closing[token.text]) stack.push({open:i, kind:token.text, argument:0});
    else if (')]}'.includes(token.text)) {
      if (closing[stack.at(-1)?.kind] !== token.text) return null;
      stack.pop();
    } else if (token.text === ',' && stack.at(-1)?.kind === '(') stack.at(-1).argument++;
  }
  const calls = [];
  for (const frame of stack) {
    // A callback body is a new expression context, not another argument of its enclosing call.
    if (frame.kind === '{' && input[frame.open-1]?.text === ')') calls.length = 0;
    if (frame.kind !== '(') continue;
    const previous = input[frame.open - 1];
    if (!previous || control.has(previous.text) || !(previous.kind === 'identifier' || [')',']'].includes(previous.text))) continue;
    let callee = host.receiverTokens(input.slice(0, frame.open));
    // receiverTokens spans arithmetic to serve completion; a call target starts after its last operator.
    let depth = 0, start = 0;
    for (let i = 0; i < callee.length; i++) {
      const t = callee[i];
      if (t.kind !== 'punctuation') continue;
      if (closing[t.text]) depth++;
      else if (')]}'.includes(t.text)) depth--;
      else if (!depth && ['+','-','*','/','%','~','?',';',':','!','&','|','<','>'].includes(t.text)) start = i + 1;
    }
    callee = callee.slice(start);
    if (callee.length) calls.push({...frame,callee});
  }
  if (!calls.length) return null;
  const active = calls.at(-1);
  return {input, active, calls, offset};
}

// Only the service request is projected. Never modify an editor buffer or execute code.
// Remove the outer call's unfinished arguments, retaining imports/types after the cursor too.
function analysisSource(source, context) {
  if (!context) return source;
  const frame = context.calls[0], open = context.input[frame.open];
  const full = host.tokens(source).tokens;
  let end = source.length, stack = ['('];
  for (const token of full) {
    if (token.start <= open.start || token.kind !== 'punctuation') continue;
    if (closing[token.text]) stack.push(token.text);
    else if (')]}'.includes(token.text)) {
      if (closing[stack.at(-1)] !== token.text) {end=token.start; break;}
      stack.pop();
      if (!stack.length) {end=token.end; break;}
    } else if (token.text === ';' && !stack.includes('{')) {end=token.start; break;}
  }
  let value = source.slice(0,open.end) + 'null)' + source.slice(end);
  if (end === source.length) {
    const pending = [];
    for (const token of host.tokens(value).tokens) {
      if (token.kind !== 'punctuation') continue;
      if (closing[token.text]) pending.push(token.text);
      else if (')]}'.includes(token.text)) pending.pop();
    }
    for (const open of pending.reverse()) {
      if (open === '{' && !/[;}]\s*$/.test(value)) value += ';';
      value += closing[open];
    }
    if (!/[;}]\s*$/.test(value)) value += ';';
  } else if (source.slice(end).trimStart().startsWith('}')) {
    value = source.slice(0,open.end) + 'null);' + source.slice(end);
  }
  return value;
}

function standardCatalog(catalog) {
  const symbols = {};
  function signature(parameters) {
    return {returnType:'any', parameters:parameters.split(',').map(s=>s.trim()).filter(Boolean).map(name=>({
      type:'any',name:name.replace(/\?|\.\.\./g,''),optional:name.endsWith('?'),variadic:name.endsWith('...')
    }))};
  }
  for (const [name,[label,documentation]] of Object.entries(language.builtins)) {
    symbols[name] = {kind:'function',documentation,signatures:[...label.matchAll(/\(([^)]*)\)/g)].map(match=>signature(match[1]))};
  }
  for (const [module,entries] of Object.entries(language.libraries)) {
    symbols[module] = {kind:'module'};
    for (const [name,parameters] of Object.entries(entries)) symbols[`${module}.${name}`] = {kind:'function',signatures:[signature(parameters)]};
  }
  return {...catalog,symbols:{...symbols,...standardFunctions,...catalog.symbols}};
}

function signatureHelp(source, offset, catalog, context = {}, previous) {
  const site = callContext(source,offset);
  if (!site) return null;
  catalog = standardCatalog(catalog);
  const forward = new Map(context.initial), declarations = new Map();
  // Same declaration/type parser as completion, including declarations later in this document.
  host.environmentAt(host.tokens(source).tokens,catalog,context.initial,{...context,declarations});
  for (const [name,value] of declarations) forward.set(name,value);
  const input = site.input.slice(0,site.active.open - site.active.callee.length);
  const env = host.environmentAt(input,catalog,forward,context);
  let withReceiver;
  for (const scope of host.withScopes(input)) withReceiver = host.resolveExpression(scope.target,env,catalog,{...context,withReceiver});
  const value = host.resolveExpression(site.active.callee,env,catalog,{...context,withReceiver,callTarget:true});
  if (!value || value.uncertain) return null;
  const entries = [...(value.entries || (value.entry ? [value.entry] : []))];
  for (const type of value.types || []) {
    const match = withoutNullExclusion(type).match(/^(.*) delegate\((.*)\)$/);
    if (match) entries.push({signatures:[{returnType:match[1],parameters:host.splitArguments(host.tokens(match[2]).tokens)
      .filter(group=>group.length).map((group,index)=>({type:group.map(token=>token.text).join(''),name:`arg${index}`}))}]});
  }
  const name = site.active.callee.map(token=>token.text).join('');
  const signatures = [], seen = new Set();
  for (const entry of entries) for (const signature of entry.signatures || []) {
    if (!Array.isArray(signature.parameters) || signature.arityKnown === false) continue;
    let label = `${name}(`;
    const parameters = signature.parameters.map((p,index) => {
      if (index) label += ', ';
      const start = label.length;
      label += `${p.lazy?'lazy ':p.reference?'ref ':''}${p.displayType || p.type || 'any'} ${p.name || `arg${index}`}${p.optional?' = …':''}${p.variadic?'...':''}`;
      return {label:[start,label.length]};
    });
    label += `) → ${signature.displayReturnType || entry.displayType || signature.returnType || 'any'}`;
    if (seen.has(label)) continue;
    seen.add(label);
    const activeParameter = parameters.length ? Math.min(site.active.argument,parameters.length-1) : undefined;
    signatures.push({label,documentation:entry.documentation,parameters,activeParameter,
      acceptsArgument:signature.parameters.at(-1)?.variadic || site.active.argument < parameters.length || !parameters.length && !site.active.argument});
  }
  if (!signatures.length) return null;
  const oldLabel = previous?.signatures?.[previous.activeSignature]?.label;
  let activeSignature = signatures.findIndex(s=>s.label===oldLabel && s.acceptsArgument);
  if (activeSignature < 0) activeSignature = Math.max(0,signatures.findIndex(s=>s.acceptsArgument));
  return {signatures:signatures.map(({acceptsArgument,...s})=>s),activeSignature,activeParameter:signatures[activeSignature].activeParameter ?? 0};
}

module.exports = {callContext,analysisSource,signatureHelp};
