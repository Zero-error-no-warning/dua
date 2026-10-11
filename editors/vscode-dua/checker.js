'use strict';
const { execFile } = require('node:child_process');

function checkSource(executable, source) {
  let child;
  const promise = new Promise((resolve, reject) => {
    child = execFile(executable, [], { encoding: 'utf8', timeout: 5000, maxBuffer: 1024 * 1024, windowsHide: true }, (error, stdout) => {
      if (error) { reject(error); return; }
      try {
        const response = JSON.parse(stdout);
        if (!Array.isArray(response.diagnostics) || response.diagnostics.some(item =>
          !Number.isInteger(item.line) || item.line < 0 || !Number.isInteger(item.column) || item.column < 0 || typeof item.message !== 'string')) {
          throw new Error('Invalid dua-check response');
        }
        resolve(response.diagnostics);
      } catch (error) { reject(error); }
    });
    // A killed or failed checker may close stdin before the source is written.
    child.stdin.on('error', () => {});
    child.stdin.end(source, 'utf8');
  });
  return { promise, cancel: () => child.kill() };
}
module.exports = { checkSource };
