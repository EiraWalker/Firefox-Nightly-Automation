import test from 'node:test';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
test('native consent waits for enabled Allow without bypassing scope or offscreen checks', () => {
  const result=spawnSync('pwsh.exe',['-NoProfile','-NonInteractive','-File',fileURLToPath(new URL('./consent-ready-fixture.ps1',import.meta.url))],{encoding:'utf8',windowsHide:true});
  assert.equal(result.status,0,result.stderr);
  assert.equal(JSON.parse(result.stdout.trim()).passed,6);
});
