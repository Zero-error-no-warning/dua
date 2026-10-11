'use strict';
// Run with VS Code's --extensionTestsPath (not with node --test).
const vscode = require('vscode');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

async function waitFor(predicate) {
  const deadline = Date.now() + 10000;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await new Promise(resolve => setTimeout(resolve, 50));
  }
  throw new Error('Timed out waiting for Dua diagnostics');
}

async function run() {
  const resultPath = path.resolve(__dirname, '../../../.dub/vscode-host-result.json');
  try {
    const extension = vscode.extensions.getExtension('dua-lang.dua-language');
    assert.ok(extension, 'Dua extension is registered');
    await extension.activate();
    const document = await vscode.workspace.openTextDocument({ language: 'dua', content: 'int wrong = "text";\nmath.\n' });
    const editor = await vscode.window.showTextDocument(document);
    const result = await vscode.commands.executeCommand('vscode.executeCompletionItemProvider', document.uri, new vscode.Position(1, 5));
    for (const name of ['abs', 'floor', 'min', 'max']) assert.ok(result.items.some(item => item.label === name), name);
    await editor.edit(edit => edit.replace(new vscode.Range(new vscode.Position(1, 0), new vscode.Position(1, 5)), 'auto text = "日本😀"; auto missing = ;'));
    await waitFor(() => vscode.languages.getDiagnostics(document.uri).some(item => item.source === 'Dua' && /Unexpected token/.test(item.message)));
    const syntax = vscode.languages.getDiagnostics(document.uri).find(item => /Unexpected token/.test(item.message));
    assert.equal(syntax.range.start.line, 1);
    assert.equal(syntax.range.start.character, document.lineAt(1).text.lastIndexOf(';'));
    await editor.edit(edit => edit.delete(new vscode.Range(new vscode.Position(1, 0), document.lineAt(1).range.end)));
    await waitFor(() => vscode.languages.getDiagnostics(document.uri).some(item => /expects int/.test(item.message)));
    await editor.edit(edit => edit.replace(new vscode.Range(new vscode.Position(0, 0), document.lineAt(0).range.end), 'int wrong = 1;'));
    await waitFor(() => vscode.languages.getDiagnostics(document.uri).length === 0);
    fs.writeFileSync(resultPath, JSON.stringify({ ok: true, checks: ['activation', 'member completion', 'Unicode syntax position', 'type diagnostic', 'diagnostic clearing'] }, null, 2));
  } catch (error) {
    fs.writeFileSync(resultPath, JSON.stringify({ ok: false, error: error.stack }, null, 2));
    throw error;
  }
}
module.exports = { run };
