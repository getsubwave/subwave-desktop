import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { after, before, test } from 'node:test';
import { fileURLToPath } from 'node:url';

const fixtureDir = path.dirname(fileURLToPath(import.meta.url));
const serverPath = path.join(fixtureDir, 'serve.mjs');
let processHandle;
let baseUrl;
let tempDir;

function request(pathname, options = {}) {
  return new Promise((resolve, reject) => {
    const request = http.request(`${baseUrl}${pathname}`, options, (response) => {
      const chunks = [];
      response.on('data', (chunk) => chunks.push(chunk));
      response.on('end', () => resolve({
        status: response.statusCode,
        headers: response.headers,
        body: Buffer.concat(chunks),
      }));
    });
    request.on('error', reject);
    request.end(options.body);
  });
}

async function stats() {
  const response = await request('/_fixture/stats');
  assert.equal(response.status, 200);
  return JSON.parse(response.body.toString('utf8'));
}

async function waitFor(predicate, message) {
  const deadline = Date.now() + 2_000;
  while (Date.now() < deadline) {
    if (await predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  assert.fail(message);
}

before(async () => {
  tempDir = await mkdtemp(path.join(os.tmpdir(), 'subwave-fixture-'));
  const tonePath = path.join(tempDir, 'tone.mp3');
  await writeFile(tonePath, Buffer.from('ID3tone!'));

  processHandle = spawn(process.execPath, [serverPath,
    '--file', tonePath,
    '--chunk-bytes', '4',
    '--interval-ms', '20',
  ], { stdio: ['ignore', 'pipe', 'pipe'] });

  baseUrl = await new Promise((resolve, reject) => {
    let stdout = '';
    let stderr = '';
    const timeout = setTimeout(() => reject(new Error(`fixture startup timed out: ${stderr}`)), 2_000);
    processHandle.stderr.on('data', (chunk) => { stderr += chunk; });
    processHandle.on('exit', (code) => reject(new Error(`fixture exited with ${code}: ${stderr}`)));
    processHandle.stdout.on('data', (chunk) => {
      stdout += chunk;
      const match = stdout.match(/http:\/\/127\.0\.0\.1:\d+/);
      if (match) {
        clearTimeout(timeout);
        resolve(match[0]);
      }
    });
  });
});

after(async () => {
  if (processHandle && processHandle.exitCode === null) {
    processHandle.kill('SIGTERM');
    await new Promise((resolve) => processHandle.once('exit', resolve));
  }
  if (tempDir) await rm(tempDir, { recursive: true });
});

test('streams the MP3 repeatedly over one throttled connection', async () => {
  await request('/_fixture/reset', { method: 'POST' });

  const received = await new Promise((resolve, reject) => {
    const request = http.get(`${baseUrl}/stream.mp3`, (response) => {
      assert.equal(response.statusCode, 200);
      assert.equal(response.headers['content-type'], 'audio/mpeg');
      const chunks = [];
      let length = 0;
      response.on('data', (chunk) => {
        chunks.push(chunk);
        length += chunk.length;
        if (length >= 16) {
          request.destroy();
          resolve(Buffer.concat(chunks).subarray(0, 16));
        }
      });
    });
    request.on('error', (error) => {
      if (error.code !== 'ECONNRESET') reject(error);
    });
  });

  assert.deepEqual(received, Buffer.from('ID3tone!ID3tone!'));
  await waitFor(async () => (await stats()).activeConnections === 0, 'stream connection was not cleaned up');
  assert.deepEqual(await stats(), { activeConnections: 0, totalConnections: 1 });
});

test('reset preserves an active stream while resetting its total', async () => {
  await request('/_fixture/reset', { method: 'POST' });

  await new Promise((resolve, reject) => {
    let receivedBytes = 0;
    let resetStarted = false;
    let bytesAtReset;
    const streamRequest = http.get(`${baseUrl}/stream.mp3`, (response) => {
      response.on('data', async (chunk) => {
        receivedBytes += chunk.length;
        if (!resetStarted) {
          resetStarted = true;
          try {
            assert.deepEqual(await stats(), { activeConnections: 1, totalConnections: 1 });
            const reset = await request('/_fixture/reset', { method: 'POST' });
            assert.equal(reset.status, 200);
            assert.deepEqual(JSON.parse(reset.body.toString('utf8')), {
              activeConnections: 1,
              totalConnections: 0,
            });
            bytesAtReset = receivedBytes;
          } catch (error) {
            streamRequest.destroy();
            reject(error);
          }
          return;
        }
        if (bytesAtReset !== undefined && receivedBytes > bytesAtReset) {
          streamRequest.destroy();
          resolve();
        }
      });
    });
    streamRequest.on('error', (error) => {
      if (error.code !== 'ECONNRESET') reject(error);
    });
  });

  await waitFor(async () => (await stats()).activeConnections === 0, 'reset stream was not cleaned up');
  assert.deepEqual(await stats(), { activeConnections: 0, totalConnections: 0 });
});

test('drop disconnects every active stream and preserves totals', async () => {
  await request('/_fixture/reset', { method: 'POST' });
  const closed = new Promise((resolve, reject) => {
    const streamRequest = http.get(`${baseUrl}/stream.mp3`, (response) => {
      response.once('data', async () => {
        try {
          const beforeDrop = await stats();
          assert.deepEqual(beforeDrop, { activeConnections: 1, totalConnections: 1 });
          const dropped = await request('/_fixture/drop', { method: 'POST' });
          assert.equal(dropped.status, 200);
        } catch (error) {
          reject(error);
        }
      });
      response.once('aborted', resolve);
      response.once('error', (error) => {
        if (error.code === 'ECONNRESET') resolve();
        else reject(error);
      });
    });
    streamRequest.on('error', (error) => {
      if (error.code === 'ECONNRESET') resolve();
      else reject(error);
    });
  });

  await closed;
  await waitFor(async () => (await stats()).activeConnections === 0, 'dropped stream stayed active');
  assert.deepEqual(await stats(), { activeConnections: 0, totalConnections: 1 });
});

test('control endpoints enforce methods and body limits', async () => {
  const wrongMethod = await request('/_fixture/drop');
  assert.equal(wrongMethod.status, 405);
  assert.equal(wrongMethod.headers.allow, 'POST');

  const oversized = await request('/_fixture/reset', {
    method: 'POST',
    body: Buffer.alloc(1_025),
    headers: { 'content-length': '1025' },
  });
  assert.equal(oversized.status, 413);

  assert.equal((await request('/missing')).status, 404);
});

test('refuses non-loopback binds and ports outside the TCP range', async () => {
  for (const [args, message] of [
    [['--host', '0.0.0.0'], /--host must be a loopback address/],
    [['--host', 'localhost'], /--host must be a loopback address/],
    [['--port', '65536'], /--port must be an integer from 0 to 65535/],
  ]) {
    const child = spawn(process.execPath, [serverPath, ...args], {
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let stderr = '';
    child.stderr.on('data', (chunk) => { stderr += chunk; });
    const code = await new Promise((resolve) => child.once('exit', resolve));
    assert.equal(code, 1);
    assert.match(stderr, message);
  }
});
