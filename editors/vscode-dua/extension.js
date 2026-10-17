'use strict';
const vscode = require('vscode');
const path = require('node:path');
const fs = require('node:fs');
const language = require('./language');
const host = require('./hostCompletion');
const { checkSource } = require('./checker');

function activate(context) {
  const diagnostics = vscode.languages.createDiagnosticCollection('dua');
  const output = vscode.window.createOutputChannel('Dua');
  const pending = new Map();
  const reported = new Set();
  const selector = { language: 'dua' };
  const kinds = {
    keyword: vscode.CompletionItemKind.Keyword, type: vscode.CompletionItemKind.TypeParameter,
    function: vscode.CompletionItemKind.Function, variable: vscode.CompletionItemKind.Variable,
    module: vscode.CompletionItemKind.Module, method: vscode.CompletionItemKind.Method,
    property: vscode.CompletionItemKind.Property
  };

  function clear(uri) {
    const key = uri.toString(), state = pending.get(key);
    if (state) { clearTimeout(state.timer); state.request?.cancel(); pending.delete(key); }
    diagnostics.delete(uri);
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
        const custom = config.get('checkerPath', '');
        if (custom && !path.isAbsolute(custom)) throw new Error('dua.checkerPathには絶対パスを指定してください。');
        const executable = custom || context.asAbsolutePath(path.join('bin', process.platform === 'win32' ? 'dua-check.exe' : 'dua-check'));
        if (!fs.existsSync(executable)) throw new Error('Dua診断ツールが見つかりません。拡張のREADMEに従ってビルドするか、dua.checkerPathを設定してください。');
        const source = document.getText();
        if (Buffer.byteLength(source) > 1024 * 1024) throw new Error('Dua診断は1MB以下のファイルに対応しています。');
        state.request = checkSource(executable, source);
        const results = await state.request.promise;
        if (!current()) return;
        diagnostics.set(document.uri, results.map(item => {
          const position = language.diagnosticPosition(source, item);
          const start = new vscode.Position(position.line, position.character);
          const word = document.getWordRangeAtPosition(start);
          const range = word || new vscode.Range(start, document.validatePosition(new vscode.Position(position.line, position.character + 1)));
          const diagnostic = new vscode.Diagnostic(range, item.message, vscode.DiagnosticSeverity.Error);
          diagnostic.source = 'Dua';
          return diagnostic;
        }));
      } catch (error) {
        if (current()) report(`Dua: ${error.message}`);
      } finally {
        if (pending.get(key) === state) pending.delete(key);
      }
    }, config.get('diagnostics.delay', 400));
  }

  context.subscriptions.push(diagnostics, output,
    vscode.languages.registerCompletionItemProvider(selector, {
      provideCompletionItems(document, position) {
        const source = document.getText(), offset = document.offsetAt(position);
        const folder = vscode.workspace.getWorkspaceFolder(document.uri);
        const config = vscode.workspace.getConfiguration('dua', document.uri);
        const catalog = folder?.uri.scheme === 'file' ? host.loadCatalog(folder.uri.fsPath, config.get('completion.metadataFiles', ['.dua-completion.json'])) : null;
        const entries = new Map(language.completions(source, offset).map(entry => [entry.label, entry]));
        if (catalog) for (const entry of host.apiCompletions(source, offset, catalog)) entries.set(entry.label, entry);
        return [...entries.values()].map(entry => {
          const item = new vscode.CompletionItem(entry.label, kinds[entry.kind]);
          item.detail = entry.detail;
          item.documentation = entry.documentation;
          if (entry.start !== undefined) item.range = new vscode.Range(document.positionAt(entry.start), document.positionAt(entry.end));
          return item;
        });
      }
    }, '.', '"'),
    vscode.workspace.onDidOpenTextDocument(schedule),
    vscode.workspace.onDidChangeTextDocument(event => schedule(event.document)),
    vscode.workspace.onDidCloseTextDocument(document => clear(document.uri)),
    vscode.workspace.onDidChangeConfiguration(event => {
      if (event.affectsConfiguration('dua')) vscode.workspace.textDocuments.forEach(schedule);
    }),
    vscode.workspace.onDidGrantWorkspaceTrust(() => vscode.workspace.textDocuments.forEach(schedule)),
    { dispose() { for (const state of pending.values()) { clearTimeout(state.timer); state.request?.cancel(); } pending.clear(); } }
  );
  vscode.workspace.textDocuments.forEach(schedule);
}

module.exports = { activate };
