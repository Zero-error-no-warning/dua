'use strict';
const test = require('node:test'), assert = require('node:assert/strict');
const fs = require('node:fs/promises'), os = require('node:os'), path = require('node:path');
const { materialize, position, resolveFile, hash, activateSceneDiagnostics } = require('../sceneDiagnostics');

async function fixture(run) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'dua-scene-diagnostics-'));
  const source = 'auto text="日本語😀"; missing();\r\n';
  const file = path.join(root, '日本語.dua'); await fs.writeFile(file, source);
  const item = { file: '日本語.dua', line: 1, column: Buffer.byteLength(source.slice(0, source.indexOf('missing'))) + 1,
    message: 'Undefined variable', severity: 'error', sourceHash: hash(source) };
  const data = { schemaVersion: 1, producer: 'ZsD', scopeId: 'scene-a', runId: 'run-a', sceneId: 'Scene A', diagnostics: [item] };
  try { await run({ root, source, file, item, data }); } finally {
    assert.equal(path.dirname(path.resolve(root)), path.resolve(os.tmpdir()));
    assert.ok(path.basename(root).startsWith('dua-scene-diagnostics-'));
    await fs.rm(root, { recursive: true, force: true });
  }
}

test('source-matched runtime locations convert UTF-8 bytes to UTF-16, including CRLF and emoji', () => fixture(async ({ root, source, data }) => {
  const result = await materialize(data, root);
  assert.equal(result.entries.length, 1);
  assert.deepEqual(result.entries[0].start, { line: 0, character: source.indexOf('missing') });
  assert.equal(result.output.length, 0);
  assert.equal(position('日本語', 1, 2), null, 'middle of UTF-8 sequence is not a location');
  assert.equal(position('a', 99, 1), null);
}));

test('unknown, forged, out-of-workspace and changed sources produce output only', () => fixture(async ({ root, source, file, item, data }) => {
  for (const change of [{ line: 0, column: 0, message: 'fake at 99:88' }, { file: '../outside.dua' }, { sourceHash: '' }]) {
    const result = await materialize({ ...data, diagnostics: [{ ...item, ...change }] }, root);
    assert.equal(result.entries.length, 0); assert.equal(result.output.length, 1);
  }
  const open = new Map([[process.platform === 'win32' ? file.toLowerCase() : file, '\n' + source]]);
  assert.equal((await materialize(data, root, open)).entries.length, 0);
  await fs.writeFile(file, '\n' + source);
  assert.equal((await materialize(data, root)).entries.length, 0);
}));

test('duplicate errors collapse within a scope; empty rerun clears that scope', () => fixture(async ({ root, item, data }) => {
  assert.equal((await materialize({ ...data, diagnostics: [item, item] }, root)).entries.length, 1);
  assert.equal((await materialize({ ...data, runId: 'rerun', diagnostics: [] }, root)).entries.length, 0);
  const other = await materialize({ ...data, scopeId: 'scene-b' }, root);
  assert.equal(other.entries[0].scopeId, 'scene-b');
  await assert.rejects(materialize({ ...data, diagnostics: null }, root));
}));

test('Windows absolute and relative paths stay within the workspace', () => {
  assert.equal(resolveFile('C:\\ゲーム', 'script\\actor.dua'), 'C:\\ゲーム\\script\\actor.dua');
  assert.equal(resolveFile('C:\\ゲーム', 'D:\\outside.dua'), null);
  assert.equal(resolveFile('C:\\ゲーム', '..\\outside.dua'), null);
});

function signal() {
  const listeners = new Set();
  return { subscribe(callback) { listeners.add(callback); return { dispose() { listeners.delete(callback); } }; },
    fire(value) { for (const callback of listeners) callback(value); } };
}
const fileKey = file => process.platform === 'win32' ? path.resolve(file).toLowerCase() : path.resolve(file);
async function until(predicate, description) {
  const deadline = Date.now() + 4000;
  while (!predicate()) {
    if (Date.now() >= deadline) assert.fail(`Timed out: ${description}`);
    await new Promise(resolve => setTimeout(resolve, 10));
  }
}
function mockEditor(root, isTrusted = true) {
  const documents = [], watchers = [], logs = [], values = new Map(), unrelated = new Map([['other', 'keep']]);
  const changes = signal(), opens = signal(), closes = signal(), folders = signal(), grants = signal();
  let revision = 0;
  const uri = fsPath => ({ scheme: 'file', fsPath });
  const context = { subscriptions: [] };
  const vscode = {
    Uri: { file: uri },
    Position: class { constructor(line, character) { this.line = line; this.character = character; } },
    Range: class { constructor(start, end) { this.start = start; this.end = end; } },
    Diagnostic: class { constructor(range, message, severity) { Object.assign(this, { range, message, severity }); } },
    DiagnosticSeverity: { Error: 0, Warning: 1, Information: 2, Hint: 3 },
    RelativePattern: class { constructor(folder, pattern) { Object.assign(this, { folder, pattern }); } },
    languages: { createDiagnosticCollection(name) {
      assert.equal(name, 'dua-scene-runtime');
      return { clear() { revision++; values.clear(); }, set(uri, entries) { values.set(fileKey(uri.fsPath), entries); },
        delete(uri) { values.delete(fileKey(uri.fsPath)); }, dispose() { values.clear(); } };
    } },
    workspace: {
      isTrusted,
      workspaceFolders: [{ uri: uri(root) }], textDocuments: documents,
      onDidChangeTextDocument: callback => changes.subscribe(callback),
      onDidOpenTextDocument: callback => opens.subscribe(callback),
      onDidCloseTextDocument: callback => closes.subscribe(callback),
      onDidChangeWorkspaceFolders: callback => folders.subscribe(callback),
      onDidGrantWorkspaceTrust: callback => grants.subscribe(callback),
      createFileSystemWatcher(pattern) {
        const create = signal(), change = signal(), remove = signal();
        const watcher = { pattern: pattern.pattern, onDidCreate: callback => create.subscribe(callback),
          onDidChange: callback => change.subscribe(callback), onDidDelete: callback => remove.subscribe(callback),
          create: file => create.fire(uri(file)), change: file => change.fire(uri(file)), remove: file => remove.fire(uri(file)), dispose() {} };
        watchers.push(watcher); return watcher;
      }
    }
  };
  activateSceneDiagnostics(vscode, context, { appendLine(text) { logs.push(text); } });
  return { values, unrelated, logs, documents, uri, changes, opens, closes, folders,
    get inbox() { return watchers.find(w => w.pattern === '.dua-diagnostics/*.json'); },
    get source() { return watchers.find(w => w.pattern === '**/*.dua'); },
    watcherCount() { return watchers.length; },
    grantTrust() { vscode.workspace.isTrusted = true; grants.fire(); },
    settle() { const previous = revision; return until(() => revision > previous, 'diagnostic refresh'); },
    dispose() { for (const item of context.subscriptions.toReversed()) item.dispose(); } };
}
async function writeInbox(root, data, filename = `${data.scopeId}.json`) {
  const directory = path.join(root, '.dua-diagnostics'); await fs.mkdir(directory, { recursive: true });
  const file = path.join(directory, filename); await fs.writeFile(file, JSON.stringify(data)); return file;
}

test('untrusted workspaces create no watchers and perform no I/O until trust is granted', () => fixture(async ({ root, source, data, file }) => {
  await writeInbox(root, data);
  const originals = new Map(['realpath', 'stat', 'readdir', 'readFile'].map(name => [name, fs[name]]));
  let reads = 0, bufferReads = 0, editor;
  for (const [name, original] of originals) fs[name] = function (...args) { reads++; return original.apply(this, args); };
  try {
    editor = mockEditor(root, false);
    const document = { uri: editor.uri(file), getText() { bufferReads++; return source; } };
    editor.documents.push(document);
    editor.opens.fire(document); editor.changes.fire({ document }); editor.closes.fire(document); editor.folders.fire({});
    await new Promise(resolve => setTimeout(resolve, 260));
    assert.equal(editor.watcherCount(), 0, 'untrusted workspace must not watch runtime output');
    assert.equal(reads, 0, 'untrusted workspace must not read or resolve files');
    assert.equal(bufferReads, 0, 'untrusted workspace must not materialize document diagnostics');
    assert.equal(editor.values.size, 0); assert.deepEqual(editor.logs, []);
    editor.grantTrust();
    assert.equal(editor.watcherCount(), 2, 'granting trust starts inbox and source watchers');
    await until(() => editor.values.has(fileKey(file)), 'diagnostics after workspace trust');
    assert.ok(reads > 0); assert.ok(bufferReads > 0);
    assert.deepEqual([...editor.unrelated], [['other', 'keep']]);
  } finally { for (const [name, original] of originals) fs[name] = original; editor?.dispose(); }
}));

test('inbox edits, corruption, empty reruns and deletion invalidate only their own scope', () => fixture(async ({ root, data, file }) => {
  const a = await writeInbox(root, data), other = { ...data, scopeId: 'scene-b', sceneId: 'Scene B' };
  const b = await writeInbox(root, other), editor = mockEditor(root);
  const entries = () => editor.values.get(fileKey(file)) || [];
  try {
    await until(() => entries().length === 2, 'initial scopes');
    await fs.writeFile(a, '{'); editor.inbox.change(a);
    assert.deepEqual(entries().map(e => e.code), ['scene-b/run-a'], 'corrupt inbox must clear its old scope immediately');
    await editor.settle();
    assert.deepEqual(entries().map(e => e.code), ['scene-b/run-a']);
    await writeInbox(root, { ...data, runId: 'new-run' }); editor.inbox.change(a);
    assert.equal(entries().length, 1); await editor.settle(); assert.equal(entries().length, 2);
    await writeInbox(root, { ...data, runId: 'empty-run', diagnostics: [] }); editor.inbox.change(a);
    assert.deepEqual(entries().map(e => e.code), ['scene-b/run-a']); await editor.settle();
    await fs.unlink(b); editor.inbox.remove(b);
    assert.equal(entries().length, 0); await editor.settle(); assert.equal(entries().length, 0);
    assert.deepEqual([...editor.unrelated], [['other', 'keep']], 'other extensions remain untouched');
  } finally { editor.dispose(); }
}));

test('scope IDs own one safe fixed filename; old differently named runs never reappear', () => fixture(async ({ root, data, file }) => {
  await writeInbox(root, { ...data, diagnostics: [] });
  await writeInbox(root, data, 'old-run.json');
  await writeInbox(root, { ...data, scopeId: '../unsafe' }, 'unsafe.json');
  const editor = mockEditor(root);
  try {
    await editor.settle();
    assert.equal(editor.values.get(fileKey(file)), undefined);
    assert.ok(editor.logs.some(message => message.includes('old-run.json')));
    await assert.rejects(materialize({ ...data, scopeId: '../unsafe' }, root));
  } finally { editor.dispose(); }
}));

test('opening and editing dirty documents immediately remove stale positions', () => fixture(async ({ root, source, data, file }) => {
  await writeInbox(root, data); const editor = mockEditor(root);
  const document = { uri: editor.uri(file), text: '\n' + source, getText() { return this.text; } };
  try {
    await until(() => editor.values.has(fileKey(file)), 'initial runtime diagnostic');
    editor.documents.push(document); editor.opens.fire(document);
    assert.equal(editor.values.has(fileKey(file)), false, 'dirty open must invalidate before async refresh');
    await editor.settle(); assert.equal(editor.values.has(fileKey(file)), false);
    document.text = source; editor.changes.fire({ document }); await editor.settle();
    assert.equal(editor.values.has(fileKey(file)), true);
    document.text = '\n' + source; editor.changes.fire({ document });
    assert.equal(editor.values.has(fileKey(file)), false, 'edit must invalidate immediately');
    await editor.settle(); assert.equal(editor.values.has(fileKey(file)), false);
  } finally { editor.dispose(); }
}));

test('an older asynchronous read cannot restore positions invalidated by a newer edit', () => fixture(async ({ root, source, data, file }) => {
  const inbox = await writeInbox(root, data), editor = mockEditor(root);
  const originalRead = fs.readFile;
  let release, entered, blocked = false;
  const started = new Promise(resolve => { entered = resolve; });
  const gate = new Promise(resolve => { release = resolve; });
  try {
    await until(() => editor.values.has(fileKey(file)), 'initial runtime diagnostic');
    fs.readFile = async function (filename, ...args) {
      const content = await originalRead.call(this, filename, ...args);
      if (!blocked && fileKey(filename) === fileKey(inbox)) { blocked = true; entered(); await gate; }
      return content;
    };
    editor.inbox.change(inbox); await started;
    const document = { uri: editor.uri(file), getText: () => '\n' + source };
    editor.documents.push(document); editor.changes.fire({ document });
    release(); await new Promise(resolve => setTimeout(resolve, 40));
    assert.equal(editor.values.has(fileKey(file)), false, 'outdated read must not publish');
    await editor.settle(); assert.equal(editor.values.has(fileKey(file)), false);
  } finally { release(); fs.readFile = originalRead; editor.dispose(); }
}));

test('source and inbox directory junctions outside the workspace are never read or enumerated', () => fixture(async ({ root, source, data, item }) => {
  const workspace = path.join(root, 'workspace'), outside = path.join(root, 'outside');
  await fs.mkdir(workspace); await fs.mkdir(outside);
  const outsideFile = path.join(outside, 'actor.dua'); await fs.writeFile(outsideFile, source);
  await fs.symlink(outside, path.join(workspace, 'linked'), process.platform === 'win32' ? 'junction' : 'dir');
  const originalRead = fs.readFile, originalReaddir = fs.readdir;
  let externalReads = 0, enumerations = 0, editor;
  fs.readFile = async function (filename, ...args) {
    if (fileKey(filename) === fileKey(outsideFile)) externalReads++;
    return originalRead.call(this, filename, ...args);
  };
  fs.readdir = async function (...args) { enumerations++; return originalReaddir.apply(this, args); };
  try {
    const result = await materialize({ ...data, diagnostics: [{ ...item, file: 'linked/actor.dua' }] }, workspace);
    assert.equal(result.entries.length, 0); assert.equal(externalReads, 0);
    await fs.writeFile(path.join(outside, 'scene-a.json'), JSON.stringify(data));
    await fs.symlink(outside, path.join(workspace, '.dua-diagnostics'), process.platform === 'win32' ? 'junction' : 'dir');
    editor = mockEditor(workspace); await editor.settle();
    assert.equal(enumerations, 0, 'root check must happen before directory enumeration');
    assert.equal(editor.values.size, 0);
  } finally { fs.readFile = originalRead; fs.readdir = originalReaddir; editor?.dispose(); }
}));

test('canonical source identity detects dirty junction aliases in either direction', () => fixture(async ({ root, source, data, item }) => {
  const actual = path.join(root, 'actual'), linked = path.join(root, 'linked');
  await fs.mkdir(actual); const directFile = path.join(actual, 'actor.dua'); await fs.writeFile(directFile, source);
  await fs.symlink(actual, linked, process.platform === 'win32' ? 'junction' : 'dir');
  const aliasFile = path.join(linked, 'actor.dua'), canonical = await fs.realpath(directFile);
  for (const [diagnosticFile, openFile] of [['linked/actor.dua', directFile], ['actual/actor.dua', aliasFile]]) {
    const snapshot = { ...data, diagnostics: [{ ...item, file: diagnosticFile }] };
    const dirty = new Map([[fileKey(openFile), '\n' + source]]);
    const invalid = await materialize(snapshot, root, dirty);
    assert.equal(invalid.entries.length, 0, `${diagnosticFile} must use the alias's dirty buffer`);
    assert.equal(invalid.output.length, 1);
    const matching = await materialize(snapshot, root, new Map([[fileKey(openFile), source]]));
    assert.equal(matching.entries.length, 1);
    assert.equal(fileKey(matching.entries[0].file), fileKey(canonical), 'publish only the canonical URI');
  }
  const conflicting = new Map([[fileKey(directFile), source], [fileKey(aliasFile), '\n' + source]]);
  assert.equal((await materialize({ ...data, diagnostics: [{ ...item, file: 'actual/actor.dua' }] }, root, conflicting)).entries.length, 0);
  const deduplicated = await materialize({ ...data, diagnostics: [
    { ...item, file: 'actual/actor.dua' }, { ...item, file: 'linked/actor.dua' }
  ] }, root);
  assert.equal(deduplicated.entries.length, 1, 'aliases must not duplicate one physical error');
}));

test('junction and direct document edits both immediately clear old runtime URIs before canonical revalidation', () => fixture(async ({ root, source, file, data, item }) => {
  const actual = path.join(root, 'actual'), linked = path.join(root, 'linked');
  await fs.mkdir(actual); const directFile = path.join(actual, 'actor.dua'); await fs.writeFile(directFile, source);
  await fs.symlink(actual, linked, process.platform === 'win32' ? 'junction' : 'dir');
  const aliasFile = path.join(linked, 'actor.dua'), canonical = await fs.realpath(directFile);
  await writeInbox(root, { ...data, diagnostics: [{ ...item, file: 'linked/actor.dua' }] });
  await writeInbox(root, { ...data, scopeId: 'scene-b' });
  const editor = mockEditor(root);
  try {
    await until(() => editor.values.has(fileKey(canonical)) && editor.values.has(fileKey(file)), 'initial canonical diagnostics');
    assert.equal(editor.values.has(fileKey(aliasFile)), false);
    for (const documentFile of [aliasFile, directFile]) {
      const document = { uri: editor.uri(documentFile), text: '\n' + source, getText() { return this.text; } };
      editor.documents.push(document); editor.opens.fire(document);
      assert.equal(editor.values.size, 0, 'opening an alias clears runtime diagnostics before resolving the path');
      await editor.settle();
      assert.equal(editor.values.has(fileKey(canonical)), false);
      assert.equal(editor.values.has(fileKey(aliasFile)), false);
      assert.equal(editor.values.has(fileKey(file)), true, 'other runtime scopes return after revalidation');
      document.text = source; editor.changes.fire({ document }); await editor.settle();
      assert.equal(editor.values.has(fileKey(canonical)), true);
      document.text = '\n' + source; editor.changes.fire({ document });
      assert.equal(editor.values.size, 0, 'editing either URI clears every old runtime alias immediately');
      await editor.settle(); assert.equal(editor.values.has(fileKey(canonical)), false);
      editor.documents.splice(editor.documents.indexOf(document), 1); editor.closes.fire(document); await editor.settle();
      assert.equal(editor.values.has(fileKey(canonical)), true);
      assert.deepEqual([...editor.unrelated], [['other', 'keep']], 'other extensions never clear');
    }
  } finally { editor.dispose(); }
}));
