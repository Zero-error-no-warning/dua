'use strict';
const { execFile } = require('node:child_process');

function request(executable, input, args, analyze = false) {
  let child;
  const promise = new Promise((resolve, reject) => {
    child = execFile(executable, args, { encoding: 'utf8', timeout: 5000, maxBuffer: 16 * 1024 * 1024, windowsHide: true }, (error, stdout) => {
      if (error) { reject(error); return; }
      try {
        const response = JSON.parse(stdout);
        if (!Array.isArray(response.diagnostics) || response.diagnostics.some(item =>
          !Number.isInteger(item.line) || item.line < 0 || !Number.isInteger(item.column) || item.column < 0 || typeof item.message !== 'string')) {
          throw new Error('Invalid dua-check response');
        }
        if (analyze && (response.schemaVersion !== 1 || ['modules', 'imports', 'exports', 'pathCompletions'].some(name => !Array.isArray(response[name])))) throw new Error('Invalid Dua analysis response');
        resolve(analyze ? response : response.diagnostics);
      } catch (error) { reject(error); }
    });
    // A killed or failed checker may close stdin before the source is written.
    child.stdin.on('error', () => {});
    child.stdin.end(input, 'utf8');
  });
  return { promise, cancel: () => child.kill() };
}
function checkSource(executable, source, options = {}) {
  const hostClassTypes = options.hostClassTypes || [];
  return request(executable, hostClassTypes.length ? JSON.stringify({ protocolVersion: 1, source, hostClassTypes }) : source,
    hostClassTypes.length ? ['--request-json'] : []);
}

function analyzeSource(executable, source, options = {}) {
  if (options.moduleContexts?.length > 1) {
    // 同じスクリプトの複数の実行文脈を解析し、全候補で一致する結果だけ確定します。
    const requests = options.moduleContexts.map(modulePaths => analyzeSource(executable, source,
      { ...options, moduleContexts: undefined, modulePaths }));
    return { cancel: () => requests.forEach(value => value.cancel()),
      promise: Promise.all(requests.map(value => value.promise)).then(results => {
        const common = name => results[0][name].filter(value => results.every(result =>
          result[name].some(other => JSON.stringify(other) === JSON.stringify(value))));
        const modules = common('modules');
        return { ...results[0], diagnostics: common('diagnostics'), modules,
          imports: common('imports').filter(value => modules.some(unit => unit.key === value.key)),
          exports: common('exports'), pathCompletions: common('pathCompletions') };
      }) };
  }
  const input = { protocolVersion: 1, operation: 'analyze', source, sourceName: options.sourceName || '',
    modulePaths: options.modulePaths || [], hostClassTypes: options.hostClassTypes || [],
    hostModules: options.hostModules || [], overlays: options.overlays || [] };
  if (typeof options.importPathPrefix === 'string') input.importPathPrefix = options.importPathPrefix;
  return request(executable, JSON.stringify(input), [], true);
}
module.exports = { checkSource, analyzeSource };
