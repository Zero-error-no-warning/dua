'use strict';
const { spawnSync } = require('node:child_process');
const path = require('node:path');
const result = spawnSync('dub', ['build', '--compiler=dmd', '--config=vscode-check', '--build=release'], {
  cwd: path.resolve(__dirname, '../../..'), stdio: 'inherit'
});
if (result.error) console.error(result.error.message);
process.exit(result.status ?? 1);
