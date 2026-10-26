'use strict';
const host = require('./hostCompletion');
const nodePath = require('node:path');
const { diagnosticPosition } = require('./language');
const { importPathContext } = require('./importContext');
const tables = require('./tableConstruction');
const {nonNullInner,splitContainer}=require('./typeSyntax');

// 解決・同一性・公開範囲はserviceが返す情報を使い、ここでは表示へ変換します。
function hostModules(catalog) {
  const modules = new Map();
  for (const context of catalog?.contexts || []) for (const [name, value] of Object.entries(context.bindings || {})) {
    if (value.kind === 'module' && !name.includes('.') && !name.startsWith('__')) modules.set(name, []);
  }
  for (const [path, entry] of Object.entries(catalog?.symbols || {})) {
    const split = path.lastIndexOf('.');
    if (split < 0) { if (entry.kind === 'module') modules.set(path, modules.get(path) || []); continue; }
    const name = path.slice(0, split), member = path.slice(split + 1);
    if (name.includes('.') || catalog.symbols[name]?.kind !== 'module') continue;
    if (name.split('.').some(piece => piece.startsWith('__')) || member.startsWith('__')) continue;
    const values = modules.get(name) || [];
    const signatures = entry.signatures || [];
    const exact = signatures.length === 1 && Array.isArray(signatures[0].parameters)
      && signatures[0].parameters.every(p => !p.optional && !p.variadic);
    const returns = [...new Set(signatures.map(value => value.returnType))];
    const types = entry.types || (entry.type ? [entry.type] : []);
    values.push({ name: member, kind: entry.kind === 'type' ? 'type' : signatures.length ? 'function' : 'variable',
      type: signatures.length ? (returns.length === 1 ? returns[0] : 'any') : (types.length === 1 ? types[0] : 'any'),
      parameterTypes: exact ? signatures[0].parameters.map(p => p.type) : [],
      variadic: signatures.length > 0 && !exact,
      ...(typeof entry.runtimeValue === 'boolean' ? { runtimeValue: entry.runtimeValue } : {}) });
    modules.set(name, values);
  }
  // ホストのカタログは静的な候補の集合であり、実行時moduleの全exportを保証しません。
  return [...modules].map(([name, exports]) => ({ name, exports, exportsComplete: false }));
}

function moduleSearchPaths(workspaceRoot, directories, patterns, explicit) {
  return modulePathContexts(workspaceRoot, directories, patterns, explicit)[0];
}

function modulePathContexts(workspaceRoot, directories, patterns, explicit) {
  const bases = !explicit && directories.length ? [...new Set(directories)] : [workspaceRoot];
  return bases.map(base => [...new Set(patterns.filter(value => typeof value === 'string')
    .map(value => nodePath.isAbsolute(value) ? value : nodePath.resolve(base, value)))]);
}

function catalogWithImports(catalog, analysis, sourceName) {
  const symbols = { ...catalog.symbols };
  const types = { ...catalog.types }, descriptors = new Map();
  for (const unit of analysis?.modules || []) for (const type of unit.types || []) descriptors.set(type.type, type);
  function displayType(id,seen=new Set()) {
    if(seen.has(id))return id;seen.add(id);
    if(descriptors.get(id)?.displayType)return descriptors.get(id).displayType;
    const inner=nonNullInner(id);
    if(inner!==null)return '('+displayType(inner,seen)+' & !null)';
    const container=splitContainer(id);
    return container ? displayType(container.element,new Set(seen))+'['+(container.key?displayType(container.key,new Set(seen)):'')+']' : id;
  }
  function membersFor(id, seen = new Set()) {
    if (seen.has(id)) return {};
    seen.add(id);
    const description = descriptors.get(id);
    if (!description) return nonNullInner(id)!==null ? membersFor(nonNullInner(id),seen) : types[id]?.members || {};
    if (description.declarationKind === 'alias' && description.alternatives?.length) {
      const combined = {};
      for (const alternative of description.alternatives) for (const [name,member] of Object.entries(membersFor(alternative,new Set(seen)))) {
        const previous = combined[name];
        combined[name] = previous && previous.type !== member.type
          ? {kind:'property',type:'any',types:[...new Set([...(previous.types || [previous.type]),...(member.types || [member.type])])]} : member;
      }
      return combined;
    }
    const inherited=Object.assign({},...(description.baseTypes || []).map(type=>membersFor(type,new Set(seen))));
    return {...inherited,...Object.fromEntries(Object.entries(description.fields || {}).map(([name, type]) => [name, {
      kind:'property',type,displayType:displayType(type)}]))};
  }
  function constructible(id, seen = new Set()) {
    if (seen.has(id)) return false;
    seen.add(id);
    const type = descriptors.get(id);
    return type?.declarationKind === 'table' || nonNullInner(id)!==null && constructible(nonNullInner(id),seen)
      || type?.declarationKind === 'alias' && type.alternatives?.length === 1 && constructible(type.alternatives[0],seen);
  }
  function elementTypes(id,seen=new Set()) {
    if (seen.has(id)) return [];
    seen.add(id);
    if(nonNullInner(id)!==null)return elementTypes(nonNullInner(id),seen);
    const container=splitContainer(id);
    if(container)return [container.element];
    return (descriptors.get(id)?.alternatives || []).flatMap(value=>elementTypes(value,new Set(seen)));
  }
  for (const id of descriptors.keys()) types[id] = { members: membersFor(id), tableConstruction: constructible(id), elementTypes:elementTypes(id) };
  const sameFile = (left,right) => left && right && nodePath.resolve(left).toLowerCase() === nodePath.resolve(right).toLowerCase();
  for (const unit of analysis?.modules || []) if (sameFile(unit.sourceName,sourceName)) {
    for (const type of unit.types || []) symbols[type.name] = {kind:'type',type:type.type,displayType:type.displayType || type.name};
  }
  for (const item of analysis?.imports || []) {
    if (!item.aliasName) continue;
    const target = analysis.modules.find(unit => unit.key === item.key);
    // ホストmoduleの詳細は既存カタログを保ちます。
    if (!target) continue;
    symbols[item.aliasName] = { kind: 'module' };
    for (const value of target.exports || []) {
      symbols[`${item.aliasName}.${value.name}`] = {
        kind: value.kind, type: value.type, displayType: value.displayType || value.type, nominalValue: value.nominalValue === true,
        documentation: value.kind === 'type' && types[value.type]?.tableConstruction ? '公開されたnamed table型' : value.kind === 'type' && !value.runtimeValue ? '公開された型alias（実行時の値・constructorなし）' : 'import先の公開宣言',
        ...(value.kind === 'function' ? { signatures: [{ returnType: value.type,
          parameters: (value.parameterTypes || []).map((type, index) => ({ type, displayType:displayType(type), name: `arg${index}`,
            ...(Number.isInteger(value.requiredParameterCount) && index >= value.requiredParameterCount ? {optional:true} : {}),
            variadic:value.variadic === true && index === value.parameterTypes.length-1 })) }] } : {})
      };
    }
  }
  // 型IDはserviceのまま。export型をグローバルな単純名へ追加しません。
  return { ...catalog, symbols, types };
}

// 補完要求だけの仮想本文です。未入力メンバーを識別子で埋め、解決はserviceに任せます。
function completionSource(source, offset) {
  if (importPathContext(source, offset)) return source;
  const construction = tables.completionProjection(source,offset);
  if (construction !== null) return construction;
  const parsed = host.tokens(source.slice(0, offset));
  if (parsed.state !== 'code') return source;
  const tail = parsed.tokens.at(-1);
  let value = source;
  const dot = tail?.text === '.' ? parsed.tokens.length - 1
    : tail?.kind === 'identifier' && parsed.tokens.at(-2)?.text === '.' ? parsed.tokens.length - 2 : -1;
  if (dot > 0 && parsed.tokens[dot - 1].kind === 'identifier') {
    let begin = dot - 1, end = offset;
    while (begin >= 2 && parsed.tokens[begin - 1].text === '.' && parsed.tokens[begin - 2].kind === 'identifier') begin -= 2;
    while (end < source.length && /[A-Za-z_0-9]/.test(source[end])) end++;
    value = source.slice(0, parsed.tokens[begin].start) + '__dua_completion' + source.slice(end);
  } else if (tail?.text === '.') value = source.slice(0, offset) + '__dua_completion' + source.slice(offset);
  if (source.slice(offset).trim() === '' && (tail?.text === '.' || tail?.kind === 'identifier')) value += ';';
  return value;
}

function pathCompletions(source, offset, analysis) {
  const context = importPathContext(source, offset);
  if (!context) return [];
  return (analysis.pathCompletions || []).map(candidate => ({ label: candidate.label,
    insertText: candidate.label, detail: candidate.sourceName,
    kind: candidate.directory ? 'folder' : 'file', start: context.start, end: context.end }));
}

function definitionAt(source, offset, analysis, catalog, sourceName) {
  const context = importPathContext(source, offset);
  if (context) {
    const item = analysis.imports.find(item => item.pathImport && item.request === context.specifier);
    const target = item && analysis.modules.find(unit => unit.key === item.key);
    return target?.sourceName ? { sourceName: target.sourceName, sourceText: target.sourceText, line: 1, column: 1 } : null;
  }
  const input = host.tokens(source).tokens;
  for (let i = 0; i < input.length; i++) if (input[i].text === 'import' && input[i + 1]?.kind === 'identifier') {
    const first = input[i + 1];
    let end = i + 2, request = first.text;
    while (input[end]?.text === '.' && input[end + 1]?.kind === 'identifier') { request += '.' + input[end + 1].text; end += 2; }
    if (offset < first.start || offset > input[end - 1].end) continue;
    const item = analysis.imports.find(item => !item.pathImport && item.request === request);
    const target = item && analysis.modules.find(unit => unit.key === item.key);
    return target?.sourceName ? {sourceName:target.sourceName,sourceText:target.sourceText,line:1,column:1} : null;
  }
  const index = input.findIndex(token => token.kind === 'identifier' && offset >= token.start && offset <= token.end);
  if (index < 0) return null;
  const token = input[index];
  const constructing = input[index + 1]?.text === '{';
  const qualified = input[index - 1]?.text === '.' && input[index - 2]?.kind === 'identifier';
  const alias = qualified ? input[index - 2] : token;
  const item = analysis.imports.find(item => item.aliasName === alias.text);
  if (item) {
    const effective = catalogWithImports(catalog, analysis);
    const env = host.environmentAt(input.slice(0, qualified ? index - 2 : index), effective);
    const binding = env.get(alias.text);
    if (!constructing && binding && binding.symbol !== alias.text) return null;
    const target = analysis.modules.find(unit => unit.key === item.key);
    if (!qualified) return target?.sourceName ? { sourceName: target.sourceName, sourceText: target.sourceText, line: 1, column: 1 } : null;
    const value = target?.exports.find(value => value.name === token.text);
    if (!value?.sourceName || value.line < 1 || value.column < 1) return null;
    const owner = analysis.modules.find(unit => unit.sourceName === value.sourceName);
    return owner ? { ...value, sourceText: owner.sourceText } : null;
  }
  if (!qualified) {
    const unit = analysis.modules.find(unit => sourceName ? nodePath.resolve(unit.sourceName).toLowerCase() === nodePath.resolve(sourceName).toLowerCase() : unit.sourceText === source);
    const type = unit?.types?.find(type => type.name === token.text);
    if (type?.line > 0 && type.column > 0) {
      const effective = catalogWithImports(catalog,analysis,unit.sourceName);
      const env = host.environmentAt(input.slice(0,index),effective);
      const binding = env.get(token.text);
      if (!constructing && binding && !binding.typeObject) return null;
      return {...type,sourceName:unit.sourceName,sourceText:unit.sourceText};
    }
  }
  return null;
}

function diagnosticRecords(analysis, fallback) {
  return analysis.diagnostics.map(value => {
    const sourceName = value.sourceName || fallback.sourceName;
    const sourceText = typeof value.sourceText === 'string' ? value.sourceText : fallback.sourceText;
    return { ...value, sourceName, sourceText, position: diagnosticPosition(sourceText, value) };
  });
}

module.exports = { hostModules, catalogWithImports, pathCompletions, definitionAt, diagnosticRecords, completionSource, moduleSearchPaths, modulePathContexts };

