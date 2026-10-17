'use strict';
const fs = require('node:fs/promises');
const path = require('node:path');
const crypto = require('node:crypto');

const hash = source => crypto.createHash('sha256').update(source, 'utf8').digest('hex');
const key = file => process.platform === 'win32' ? path.resolve(file).toLowerCase() : path.resolve(file);
const validScope = scope => typeof scope === 'string' && /^[A-Za-z0-9_-]{1,128}$/.test(scope);
const duaSource = file => typeof file === 'string' && path.extname(file).toLowerCase() === '.dua';
function resolveFile(root, filename) {
  if (typeof filename !== 'string' || !filename || filename.includes('\0')) return null;
  const paths = /^[A-Za-z]:[\\/]/.test(root) ? path.win32 : path;
  const file = paths.resolve(root, filename), relative = paths.relative(root, file);
  return relative === '..' || relative.startsWith('..' + paths.sep) || paths.isAbsolute(relative) ? null : file;
}
function position(source, line, column) {
  if (!Number.isSafeInteger(line) || line < 1 || !Number.isSafeInteger(column) || column < 1) return null;
  const lines = source.split('\n');
  if (line > lines.length) return null;
  const text = lines[line - 1].replace(/\r$/, '');
  let bytes = 0, character = 0;
  for (const char of text) {
    if (bytes === column - 1) break;
    bytes += Buffer.byteLength(char); character += char.length;
  }
  return bytes === column - 1 ? { line: line - 1, character } : null;
}

async function canonicalOpenSources(openSources) {
  const resolved = await Promise.all([...openSources].map(async ([file, source]) => {
    try { return [key(await fs.realpath(file)), source]; } catch { return null; }
  }));
  const sources = new Map();
  for (const view of resolved) if (view) {
    const [id, source] = view;
    // Two open aliases with different buffers cannot share a proven location.
    if (!sources.has(id)) sources.set(id, source);
    else if (sources.get(id) !== source) sources.set(id, null);
  }
  return sources;
}

// Only JSON and source text are read. No script evaluation or subprocesses.
async function materialize(data, root, openSources = new Map(), resolvedOpenSources) {
  if (!data || data.schemaVersion !== 1 || data.producer !== 'ZsD'
    || !validScope(data.scopeId) || typeof data.runId !== 'string'
    || typeof data.sceneId !== 'string' || !Array.isArray(data.diagnostics) || data.diagnostics.length > 256)
    throw new Error('Invalid scene diagnostic snapshot');
  const entries = [], output = [], seen = new Set(), realSeen = new Set(), sources = new Map();
  const realRoot = await fs.realpath(root);
  const relevantOpen = new Map([...openSources].filter(([file]) => duaSource(file)
    && (resolveFile(root, file) || resolveFile(realRoot, file))));
  const openByReal = resolvedOpenSources || await canonicalOpenSources(relevantOpen);
  for (const item of data.diagnostics) {
    if (!item || typeof item.message !== 'string' || !item.message || item.message.length > 16384) continue;
    const message = `[${data.sceneId} / ${data.runId}] ${item.message}`;
    const file = resolveFile(root, item.file);
    const identity = JSON.stringify([file, item.line, item.column, item.message]);
    if (seen.has(identity)) continue; seen.add(identity);
    if (!file || !/^[0-9a-f]{64}$/i.test(item.sourceHash || '')) { output.push(message); continue; }
    // ZsD source modules use .dua. Other source names remain output-only: their
    // open buffers are deliberately not watched or read by this extension.
    if (!duaSource(file)) { output.push(`${message} (runtime locations require a workspace .dua source)`); continue; }
    try {
      const realFile = await fs.realpath(file);
      if (!resolveFile(realRoot, realFile) || !duaSource(realFile)) { output.push(message); continue; }
      const id = key(realFile), realIdentity = JSON.stringify([id, item.line, item.column, item.message]);
      if (realSeen.has(realIdentity)) continue; realSeen.add(realIdentity);
      if (!sources.has(id)) {
        if (openByReal.has(id)) sources.set(id, openByReal.get(id));
        else {
          const stat = await fs.stat(realFile);
          if (stat.size > 1024 * 1024) throw new Error('Source exceeds diagnostic size limit');
          sources.set(id, await fs.readFile(realFile, 'utf8'));
        }
      }
      const source = sources.get(id);
      if (typeof source !== 'string' || Buffer.byteLength(source, 'utf8') > 1024 * 1024
        || hash(source) !== item.sourceHash.toLowerCase()) { output.push(`${message} (source changed; rerun the scene)`); continue; }
      const start = position(source, item.line, item.column);
      if (!start) { output.push(message); continue; }
      entries.push({ file: realFile, start, message: item.message, severity: ['error', 'warning', 'information', 'hint'].includes(item.severity) ? item.severity : 'error',
        scopeId: data.scopeId, runId: data.runId, sceneId: data.sceneId });
    } catch { output.push(message); }
  }
  return { entries, output };
}

function activateSceneDiagnostics(vscode, context, output) {
  const collection = vscode.languages.createDiagnosticCollection('dua-scene-runtime');
  let timer, generation = 0, disposed = false;
  // Each producer scope atomically replaces one fixed scopeId.json inbox.
  // Retain scopes separately so invalidating one inbox never clears another.
  let snapshots = new Map();
  let realWorkspaceRoots = [];
  const notices = new Set(), watchers = [];
  const trusted = () => !disposed && vscode.workspace.isTrusted === true;
  const fileFolders = () => (vscode.workspace.workspaceFolders || []).filter(folder => folder.uri.scheme === 'file');
  function relevantUri(uri) {
    return uri?.scheme === 'file' && duaSource(uri.fsPath)
      && [...fileFolders().map(folder => folder.uri.fsPath), ...realWorkspaceRoots]
        .some(root => resolveFile(root, uri.fsPath));
  }
  const log = text => { if (!notices.has(text)) { if (notices.size > 1024) notices.clear(); notices.add(text); output.appendLine(`ZsD: ${text}`); } };
  function publish() {
    if (!trusted()) return;
    const grouped = new Map();
    for (const snapshot of snapshots.values()) for (const entry of snapshot.entries) {
      const id = key(entry.file);
      if (!grouped.has(id)) grouped.set(id, { file: entry.file, entries: [] });
      grouped.get(id).entries.push(entry);
    }
    collection.clear();
    for (const { file, entries } of grouped.values()) collection.set(vscode.Uri.file(file), entries.map(entry => {
      const start = new vscode.Position(entry.start.line, entry.start.character);
      const diagnostic = new vscode.Diagnostic(new vscode.Range(start, start), entry.message,
        { error: vscode.DiagnosticSeverity.Error, warning: vscode.DiagnosticSeverity.Warning,
          information: vscode.DiagnosticSeverity.Information, hint: vscode.DiagnosticSeverity.Hint }[entry.severity]);
      diagnostic.source = `ZsD Dua · ${entry.sceneId}`; diagnostic.code = `${entry.scopeId}/${entry.runId}`;
      return diagnostic;
    }));
  }
  async function refresh() {
    if (!trusted()) return;
    const current = ++generation, next = new Map();
    const folders = fileFolders();
    const roots = await Promise.all(folders.map(async folder => {
      try { return await fs.realpath(folder.uri.fsPath); } catch { return null; }
    }));
    if (!trusted() || current !== generation) return;
    realWorkspaceRoots = roots.filter(Boolean);
    const open = new Map(vscode.workspace.textDocuments.filter(d => relevantUri(d.uri)).map(d => [key(d.uri.fsPath), d.getText()]));
    const openByReal = await canonicalOpenSources(open);
    for (const [index, folder] of folders.entries()) {
      const root = folder.uri.fsPath, directory = path.join(root, '.dua-diagnostics');
      try {
        const realRoot = roots[index]; if (!realRoot) continue;
        const realDirectory = await fs.realpath(directory);
        if (!resolveFile(realRoot, realDirectory) || !(await fs.stat(realDirectory)).isDirectory()) {
          log('Scene diagnostic directory is outside the workspace'); continue;
        }
        const names = (await fs.readdir(realDirectory)).filter(n => n.endsWith('.json')).sort();
        if (names.length > 128) { log('Too many scene diagnostic files'); continue; }
        for (const name of names) {
          try {
            const filename = path.join(directory, name), realFile = await fs.realpath(filename);
            if (!resolveFile(realRoot, realFile)) continue;
            const stat = await fs.stat(realFile);
            if (!stat.isFile() || stat.size > 512 * 1024) continue;
            const data = JSON.parse(await fs.readFile(realFile, 'utf8'));
            if (!validScope(data?.scopeId) || name !== `${data.scopeId}.json`)
              throw new Error('Scene diagnostic filename does not match its scope');
            const result = await materialize(data, root, open, openByReal);
            result.output.forEach(log);
            next.set(key(filename), result);
          } catch { log(`Ignored malformed or unavailable diagnostic file: ${name}`); }
        }
      } catch (error) { if (error.code !== 'ENOENT') log(`Cannot read scene diagnostics: ${error.message}`); }
    }
    if (!trusted() || current !== generation) return;
    snapshots = next; publish();
  }
  function schedule() {
    if (!trusted()) return;
    generation++; clearTimeout(timer); timer = setTimeout(() => { void refresh(); }, 200);
  }
  function sourceChanged(event) {
    if (!trusted()) return;
    const uri = event?.document?.uri || event?.uri || event;
    if (!relevantUri(uri)) return;
    // Resolving junctions is async. Clear our collection now, then rebuild by
    // canonical identity; otherwise another alias can retain an old squiggle.
    snapshots.clear(); collection.clear();
    schedule();
  }
  function inboxChanged(uri) {
    if (!trusted()) return;
    if (uri?.scheme === 'file') { snapshots.delete(key(uri.fsPath)); publish(); }
    schedule();
  }
  function watch() {
    generation++; clearTimeout(timer);
    realWorkspaceRoots = [];
    watchers.splice(0).forEach(w => w.dispose());
    snapshots.clear(); publish();
    if (!trusted()) return;
    for (const folder of vscode.workspace.workspaceFolders || []) if (folder.uri.scheme === 'file') {
      const watcher = vscode.workspace.createFileSystemWatcher(new vscode.RelativePattern(folder, '.dua-diagnostics/*.json'));
      watcher.onDidCreate(inboxChanged); watcher.onDidChange(inboxChanged); watcher.onDidDelete(inboxChanged); watchers.push(watcher);
      const sourceWatcher = vscode.workspace.createFileSystemWatcher(new vscode.RelativePattern(folder, '**/*.dua'));
      sourceWatcher.onDidCreate(sourceChanged); sourceWatcher.onDidChange(sourceChanged); sourceWatcher.onDidDelete(sourceChanged); watchers.push(sourceWatcher);
    }
    schedule();
  }
  context.subscriptions.push(collection, vscode.workspace.onDidChangeTextDocument(sourceChanged), vscode.workspace.onDidCloseTextDocument(sourceChanged),
    vscode.workspace.onDidOpenTextDocument(sourceChanged),
    vscode.workspace.onDidGrantWorkspaceTrust(watch),
    vscode.workspace.onDidChangeWorkspaceFolders(watch), { dispose() { disposed = true; generation++; clearTimeout(timer); watchers.forEach(w => w.dispose()); } });
  watch();
}
module.exports = { materialize, resolveFile, position, hash, activateSceneDiagnostics };
