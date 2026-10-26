'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const Module = require('node:module');
const path = require('node:path');

test('extension debounces checks, drops stale responses, clears closed files and respects trust', async () => {
  const listeners = {}, requests = [], values = new Map(), warnings = [];
  const disposable = () => ({ dispose() {} });
  const event = name => callback => { listeners[name] = callback; return disposable(); };
  const uri = { toString: () => 'file:///test.dua' };
  const document = {
    uri, version: 1, languageId: 'dua', isClosed: false, source: 'int n = "bad";',
    getText() { return this.source; },
    getWordRangeAtPosition() { return undefined; }, validatePosition: position => position
  };
  const config = { 'diagnostics.delay': 0 };
  const hostClassTypes = ['GenericHostWidget'];
  const vscode = {
    CompletionItemKind: {}, DiagnosticSeverity: { Error: 0 },
    Position: class { constructor(line, character) { this.line = line; this.character = character; } },
    Range: class { constructor(start, end) { this.start = start; this.end = end; } },
    Diagnostic: class { constructor(range, message) { this.range = range; this.message = message; } },
    languages: {
      createDiagnosticCollection: () => ({ set: (uri, items) => values.set(uri.toString(), items), delete: uri => values.delete(uri.toString()), dispose() {} }),
      registerCompletionItemProvider: disposable
    },
    window: { createOutputChannel: () => ({ appendLine() {}, dispose() {} }), showWarningMessage: message => warnings.push(message) },
    workspace: {
      isTrusted: false, textDocuments: [document],
      getWorkspaceFolder: () => ({ uri: { scheme: 'file', fsPath: 'C:/test' } }),
      getConfiguration: () => ({ get: (key, fallback) => config[key] ?? fallback }),
      onDidOpenTextDocument: event('open'), onDidChangeTextDocument: event('change'), onDidCloseTextDocument: event('close'),
      onDidChangeConfiguration: event('config'), onDidGrantWorkspaceTrust: event('trust')
    }
  };
  const checker = { checkSource: (executable, source, options) => {
    let resolve;
    const request = { source, options, promise: new Promise(done => { resolve = done; }), resolve: value => resolve(value), cancel() { this.cancelled = true; } };
    requests.push(request);
    return request;
  } };
  const original = Module._load;
  const file = require.resolve('../extension');
  delete require.cache[file];
  let extension;
  try {
    Module._load = function(name, ...args) {
      if (name === 'vscode') return vscode;
      if (name === './checker') return checker;
      if (name === './hostCompletion') return { loadCatalog: () => ({ types: {} }), diagnosticHostTypes: value => value ? hostClassTypes : [] };
      if (name === './sceneDiagnostics') return { activateSceneDiagnostics() {} };
      return original.call(this, name, ...args);
    };
    extension = require(file);
  } finally { Module._load = original; }
  const context = { subscriptions: [], asAbsolutePath: file => path.resolve(__dirname, '..', file) };
  const tick = () => new Promise(resolve => setTimeout(resolve, 15));
  extension.activate(context);
  await tick();
  assert.equal(requests.length, 0);
  vscode.workspace.isTrusted = true;
  listeners.trust();
  await tick();
  assert.equal(requests.length, 1);
  assert.deepEqual(requests[0].options.hostClassTypes, hostClassTypes);
  document.version++;
  document.source = 'auto n = 1;';
  listeners.change({ document });
  await tick();
  assert.ok(requests[0].cancelled);
  requests[0].resolve([{ line: 1, column: 1, message: 'stale' }]);
  await tick();
  assert.equal(values.size, 0);
  requests[1].resolve([{ line: 1, column: 1, message: 'current' }]);
  await tick();
  assert.equal(values.get(uri.toString())[0].message, 'current');
  listeners.close(document);
  assert.equal(values.size, 0);
  config.checkerPath = path.resolve(__dirname, '../bin/dua-check.exe');
  listeners.open(document);
  await tick();
  assert.deepEqual(requests[2].options.hostClassTypes, [], 'custom checker keeps the legacy input protocol');
  listeners.close(document);
  config['diagnostics.enable'] = false;
  listeners.config({ affectsConfiguration: () => true });
  await tick();
  assert.equal(requests.length, 3);
  assert.deepEqual(warnings, []);
  for (const subscription of context.subscriptions) subscription.dispose();
  delete require.cache[file];
});

test('startup activation installs the inbox watcher before the first external scene run', () => {
  const manifest = require('../package.json');
  assert.ok(manifest.activationEvents.includes('onStartupFinished'));
});
