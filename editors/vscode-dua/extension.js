'use strict';
const vscode = require('vscode');
const path = require('node:path');
const fs = require('node:fs');
const language = require('./language');
const host = require('./hostCompletion');
const assets = require('./assetCompletion');
const { checkSource, analyzeSource } = require('./checker');
const modules = require('./moduleIntelligence');
const { importPathContext } = require('./importContext');
const tables = require('./tableConstruction');
const { activateSceneDiagnostics } = require('./sceneDiagnostics');

function activate(context) {
  const diagnostics = vscode.languages.createDiagnosticCollection('dua');
  const output = vscode.window.createOutputChannel('Dua');
  activateSceneDiagnostics(vscode, context, output);
  const pending = new Map();
  const ownedResults = new Map(), queries = new Set(), dependencyWatchers = new Map();
  let generation = 0, watching = false;
  const reported = new Set();
  const selector = { language: 'dua' };
  const kinds = {
    keyword: vscode.CompletionItemKind.Keyword, type: vscode.CompletionItemKind.TypeParameter,
    function: vscode.CompletionItemKind.Function, variable: vscode.CompletionItemKind.Variable,
    module: vscode.CompletionItemKind.Module, method: vscode.CompletionItemKind.Method,
    property: vscode.CompletionItemKind.Property, value: vscode.CompletionItemKind.Value,
    folder: vscode.CompletionItemKind.Folder, file: vscode.CompletionItemKind.File
  };

  const fileDocument = document => document.uri.scheme === 'file' && document.languageId === 'dua';
  const uriKey = uri => process.platform === 'win32' ? uri.toString().toLowerCase() : uri.toString();
  function publish() {
    if (!diagnostics.clear) return;
    diagnostics.clear();
    const files = new Map();
    for (const entries of ownedResults.values()) for (const entry of entries) {
      const key = uriKey(entry.uri);
      if (!files.has(key)) files.set(key, { uri: entry.uri, items: new Map() });
      const id = `${entry.diagnostic.range.start.line}:${entry.diagnostic.range.start.character}:${entry.diagnostic.message}`;
      files.get(key).items.set(id, entry.diagnostic);
    }
    for (const { uri, items } of files.values()) diagnostics.set(uri, [...items.values()]);
  }

  function preparation(document) {
    const config = vscode.workspace.getConfiguration('dua', document.uri);
    const custom = config.get('checkerPath', '');
    if (custom && !path.isAbsolute(custom)) throw new Error('dua.checkerPathには絶対パスを指定してください。');
    const executable = custom || context.asAbsolutePath(path.join('bin', process.platform === 'win32' ? 'dua-check.exe' : 'dua-check'));
    if (!fs.existsSync(executable)) throw new Error('Dua診断ツールが見つかりません。');
    const source = document.getText();
    if (Buffer.byteLength(source) > 1024 * 1024) throw new Error('Dua診断は1MB以下のファイルに対応しています。');
    const folder = vscode.workspace.getWorkspaceFolder?.(document.uri);
    const catalog = folder?.uri.scheme === 'file'
      ? host.loadCatalog(folder.uri.fsPath, config.get('completion.metadataFiles', ['.dua-completion.json']))
      : { symbols: {}, types: {}, assets: [], contexts: [], root: '' };
    const options = { hostClassTypes: custom ? [] : host.diagnosticHostTypes(catalog) };
    if (!custom && fileDocument(document)) {
      const root = folder?.uri.fsPath || path.dirname(document.uri.fsPath);
      options.sourceName = document.uri.fsPath;
      const contextual = assets.createContext(catalog, document.uri.fsPath);
      const setting = config.inspect?.('modulePaths');
      const explicit = setting && ['globalValue', 'workspaceValue', 'workspaceFolderValue'].some(name => setting[name] !== undefined);
      options.moduleContexts = modules.modulePathContexts(root, contextual.directories,
        config.get('modulePaths', ['?.dua', '?/init.dua']), explicit);
      options.modulePaths = options.moduleContexts[0];
      options.hostModules = modules.hostModules(contextual.catalog);
      let size = 0;
      options.overlays = vscode.workspace.textDocuments.filter(d => fileDocument(d) && !d.isClosed).map(d => {
        const source = d.getText(); size += Buffer.byteLength(source);
        if (size > 8 * 1024 * 1024) throw new Error('Duaの未保存解析本文は合計8MBまでです。');
        return { sourceName: d.uri.fsPath, source };
      });
    }
    return { executable, source, options, catalog, service: !custom && fileDocument(document) };
  }

  async function query(document, extra, token) {
    if (!vscode.workspace.isTrusted || !fileDocument(document) || token?.isCancellationRequested) return null;
    const prepared = preparation(document);
    if (!prepared.service) return null;
    const version = document.version, epoch = generation;
    const source = Number.isInteger(extra.completionOffset) ? modules.completionSource(prepared.source, extra.completionOffset) : prepared.source;
    const request = analyzeSource(prepared.executable, source, { ...prepared.options, ...extra });
    queries.add(request);
    const cancellation = token?.onCancellationRequested(() => request.cancel());
    try {
      const analysis = await request.promise;
      return !token?.isCancellationRequested && !document.isClosed && document.version === version && generation === epoch ? analysis : null;
    } catch (error) {
      if (token?.isCancellationRequested || document.version !== version || generation !== epoch || document.isClosed) return null;
      throw error;
    } finally { cancellation?.dispose(); queries.delete(request); }
  }

  function refreshAll(excluded) {
    generation++;
    for (const request of queries) request.cancel();
    for (const state of pending.values()) { clearTimeout(state.timer); state.request?.cancel(); }
    pending.clear(); ownedResults.clear(); diagnostics.clear?.();
    for (const document of vscode.workspace.textDocuments) if (!document.isClosed && document.uri.toString() !== excluded) schedule(document);
  }

  function watch() {
    if (watching || !vscode.workspace.isTrusted || !vscode.workspace.createFileSystemWatcher) return;
    watching = true;
    const watcher = vscode.workspace.createFileSystemWatcher('**/*.dua');
    context.subscriptions.push(watcher, watcher.onDidCreate(() => refreshAll()), watcher.onDidChange(() => refreshAll()), watcher.onDidDelete(() => refreshAll()));
  }

  function watchDependencies(analysis) {
    if (!vscode.workspace.isTrusted || !vscode.RelativePattern || !vscode.workspace.createFileSystemWatcher) return;
    for (const unit of analysis.modules || []) {
      if (!unit.key || !path.isAbsolute(unit.sourceName) || dependencyWatchers.has(unit.key)
        || vscode.workspace.getWorkspaceFolder?.(vscode.Uri.file(unit.sourceName))) continue;
      const watcher = vscode.workspace.createFileSystemWatcher(new vscode.RelativePattern(vscode.Uri.file(path.dirname(unit.sourceName)), path.basename(unit.sourceName)));
      const subscriptions = [watcher, watcher.onDidCreate(() => refreshAll()), watcher.onDidChange(() => refreshAll()), watcher.onDidDelete(() => refreshAll())];
      dependencyWatchers.set(unit.key, subscriptions);
      if (dependencyWatchers.size > 256) {
        const oldest = dependencyWatchers.keys().next().value;
        for (const item of dependencyWatchers.get(oldest)) item.dispose();
        dependencyWatchers.delete(oldest);
      }
    }
  }

  function clear(uri) {
    const key = uri.toString(), state = pending.get(key);
    if (state) { clearTimeout(state.timer); state.request?.cancel(); pending.delete(key); }
    diagnostics.delete(uri);
    ownedResults.delete(key); publish();
  }

  function report(message) {
    output.appendLine(message);
    if (!reported.has(message)) {
      reported.add(message);
      vscode.window.showWarningMessage(message);
    }
  }

  function schedule(document) {
    if (document.languageId !== 'dua') return;
    clear(document.uri);
    const config = vscode.workspace.getConfiguration('dua', document.uri);
    if (!config.get('diagnostics.enable', true) || !vscode.workspace.isTrusted) return;
    const key = document.uri.toString();
    const state = { version: document.version };
    pending.set(key, state);
    state.timer = setTimeout(async () => {
      const current = () => pending.get(key) === state && !document.isClosed && document.version === state.version;
      try {
        const prepared = preparation(document), source = prepared.source;
        state.request = prepared.service ? analyzeSource(prepared.executable, source, prepared.options)
          : checkSource(prepared.executable, source, prepared.options);
        const response = await state.request.promise;
        const results = prepared.service ? response : { diagnostics: response };
        if (!current()) return;
        if (prepared.service) watchDependencies(response);
        const entries = [];
        for (const item of modules.diagnosticRecords(results, { sourceName: document.uri.fsPath, sourceText: source })) {
          if (!item.line || !item.column) { output.appendLine(`Dua: ${item.sourceName || ''}: ${item.message}`); continue; }
          const uri = item.sourceName && vscode.Uri ? vscode.Uri.file(item.sourceName) : document.uri;
          const open = vscode.workspace.textDocuments.find(d => uriKey(d.uri) === uriKey(uri));
          if (open && open.getText() !== item.sourceText) continue;
          const position = item.position;
          const start = new vscode.Position(position.line, position.character);
          const end = new vscode.Position(position.line, position.character + 1);
          const range = new vscode.Range(start, end);
          const diagnostic = new vscode.Diagnostic(range, item.message, vscode.DiagnosticSeverity.Error);
          diagnostic.source = 'Dua';
          entries.push({ uri, diagnostic });
        }
        ownedResults.set(key, entries);
        if (diagnostics.clear) publish(); else diagnostics.set(document.uri, entries.map(value => value.diagnostic));
      } catch (error) {
        if (current()) report(`Dua: ${error.message}`);
      } finally {
        if (pending.get(key) === state) pending.delete(key);
      }
    }, config.get('diagnostics.delay', 400));
  }

  context.subscriptions.push(diagnostics, output,
    vscode.languages.registerCompletionItemProvider(selector, {
      async provideCompletionItems(document, position, token) {
        const source = document.getText(), offset = document.offsetAt(position);
        const version = document.version, epoch = generation;
        const folder = vscode.workspace.getWorkspaceFolder(document.uri);
        const config = vscode.workspace.getConfiguration('dua', document.uri);
        let catalog = folder?.uri.scheme === 'file' ? host.loadCatalog(folder.uri.fsPath, config.get('completion.metadataFiles', ['.dua-completion.json']))
          : { symbols: {}, types: {}, assets: [], contexts: [], root: '' };
        let analysis;
        try {
          const pathContext = importPathContext(source, offset);
          analysis = await query(document, pathContext ? { importPathPrefix: pathContext.prefix } : { completionOffset: offset }, token);
          if (analysis) catalog = modules.catalogWithImports(catalog, analysis, document.uri.fsPath);
        } catch (error) { if (!token?.isCancellationRequested) output.appendLine(`Dua: ${error.message}`); }
        if (token?.isCancellationRequested || document.version !== version || generation !== epoch || document.isClosed) return [];
        const entries = new Map(language.completions(source, offset).map(entry => [entry.label, entry]));
        const assetContext = catalog ? assets.createContext(catalog, document.uri.fsPath) : null;
        if (assetContext) for (const entry of host.apiCompletions(source, offset, assetContext.catalog, assetContext)) entries.set(entry.label, entry);
        const stringEntries = assetContext ? assets.stringCompletions(source, offset, assetContext) : [];
        const paths = analysis ? modules.pathCompletions(source, offset, analysis) : [];
        const fields = tables.fieldCompletions(source,offset,catalog);
        for (const entry of fields) entries.set(entry.label,entry);
        return [...entries.values(), ...stringEntries, ...paths].map(entry => {
          const item = new vscode.CompletionItem(entry.label, kinds[entry.kind]);
          item.detail = entry.detail;
          item.documentation = entry.documentation;
          if (entry.insertText !== undefined) item.insertText = entry.insertText;
          if (entry.start !== undefined) item.range = new vscode.Range(document.positionAt(entry.start), document.positionAt(entry.end));
          return item;
        });
      }
    }, '.', '"', '/', '\\'),
    vscode.workspace.onDidOpenTextDocument(document => fileDocument(document) ? refreshAll() : schedule(document)),
    vscode.workspace.onDidChangeTextDocument(event => fileDocument(event.document) ? refreshAll() : schedule(event.document)),
    vscode.workspace.onDidCloseTextDocument(document => { clear(document.uri); if (fileDocument(document)) refreshAll(document.uri.toString()); }),
    vscode.workspace.onDidChangeConfiguration(event => {
      if (event.affectsConfiguration('dua')) refreshAll();
    }),
    vscode.workspace.onDidGrantWorkspaceTrust(() => { watch(); refreshAll(); }),
    { dispose() { for (const request of queries) request.cancel(); for (const state of pending.values()) { clearTimeout(state.timer); state.request?.cancel(); } for (const subscriptions of dependencyWatchers.values()) for (const value of subscriptions) value.dispose(); dependencyWatchers.clear(); pending.clear(); ownedResults.clear(); } }
  );
  if (vscode.languages.registerDefinitionProvider) context.subscriptions.push(vscode.languages.registerDefinitionProvider(selector, {
    async provideDefinition(document, position, token) {
      try {
        const analysis = await query(document, {}, token);
        if (!analysis) return null;
        const prepared = preparation(document);
        const target = modules.definitionAt(prepared.source, document.offsetAt(position), analysis, prepared.catalog, document.uri.fsPath);
        if (!target) return null;
        const where = language.diagnosticPosition(target.sourceText, target);
        const start = new vscode.Position(where.line, where.character);
        return new vscode.Location(vscode.Uri.file(target.sourceName), new vscode.Range(start, start));
      } catch (error) { if (!token?.isCancellationRequested) output.appendLine(`Dua: ${error.message}`); return null; }
    }
  }));
  watch();
  if (vscode.workspace.onDidChangeWorkspaceFolders) context.subscriptions.push(vscode.workspace.onDidChangeWorkspaceFolders(() => refreshAll()));
  vscode.workspace.textDocuments.forEach(schedule);
}

module.exports = { activate };
