import assert from 'node:assert/strict';
import http from 'node:http';
import net from 'node:net';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { startFixtureStation } from './station.mjs';

const fixtureDir = path.dirname(fileURLToPath(import.meta.url));
const stationPath = path.join(fixtureDir, 'station.mjs');
const TIMEOUT_MS = 2_500;
const MAX_BODY = 64 * 1024;

async function spawnStation(mode, credentials = {}) {
  const args = [stationPath, '--auth-mode', mode, '--chunk-bytes', '4', '--interval-ms', '20'];
  for (const [option, value] of Object.entries(credentials)) args.push(`--${option}`, value);
  const child = spawn(process.execPath, args, { stdio: ['ignore', 'pipe', 'pipe'] });
  let stdout = ''; let stderr = '';
  child.stderr.on('data', (chunk) => { stderr += chunk; });
  const urls = await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`station startup timed out: ${stderr}`)), TIMEOUT_MS);
    child.once('exit', (code) => { clearTimeout(timer); reject(new Error(`station exited with ${code}: ${stderr}`)); });
    child.stdout.on('data', (chunk) => {
      stdout += chunk;
      const line = stdout.split('\n').find((candidate) => candidate.startsWith('{'));
      if (line) { clearTimeout(timer); resolve(JSON.parse(line)); }
    });
  });
  return {
    ...urls,
    async close() {
      if (child.exitCode !== null) return;
      child.kill('SIGTERM');
      await Promise.race([
        new Promise((resolve) => child.once('exit', resolve)),
        new Promise((_, reject) => setTimeout(() => reject(new Error('station shutdown timed out')), TIMEOUT_MS)),
      ]);
    },
  };
}

function request(base, pathname, options = {}) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { req.destroy(new Error('request timed out')); }, options.timeoutMs ?? TIMEOUT_MS);
    const req = http.request(`${base}${pathname}`, options, (response) => {
      const chunks = []; let length = 0;
      response.on('data', (chunk) => {
        length += chunk.length;
        if (length > MAX_BODY) { req.destroy(new Error('response body exceeded test bound')); return; }
        chunks.push(chunk);
      });
      response.on('end', () => { clearTimeout(timer); resolve({ status: response.statusCode, headers: response.headers, body: Buffer.concat(chunks) }); });
    });
    req.on('error', (error) => { clearTimeout(timer); reject(error); });
    req.end(options.body);
  });
}

async function json(base, pathname, options = {}) {
  const response = await request(base, pathname, options);
  return { ...response, json: JSON.parse(response.body.toString('utf8')) };
}

function postJson(base, pathname, body) {
  const encoded = Buffer.from(JSON.stringify(body));
  return json(base, pathname, { method: 'POST', body: encoded, headers: { 'content-type': 'application/json', 'content-length': encoded.length } });
}

function basic(username, password) {
  return { authorization: `Basic ${Buffer.from(`${username}:${password}`, 'utf8').toString('base64')}` };
}

async function readStream(base, pathname, headers = {}) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => req.destroy(new Error('stream timed out')), TIMEOUT_MS);
    const req = http.get(`${base}${pathname}`, { headers }, (response) => {
      if (response.statusCode !== 200) {
        const chunks = [];
        response.on('data', (chunk) => chunks.push(chunk));
        response.on('end', () => { clearTimeout(timer); resolve({ status: response.statusCode, body: Buffer.concat(chunks) }); });
        return;
      }
      const chunks = []; let length = 0;
      response.on('data', (chunk) => {
        chunks.push(chunk); length += chunk.length;
        if (length >= 16) { clearTimeout(timer); req.destroy(); resolve({ status: 200, body: Buffer.concat(chunks).subarray(0, 16) }); }
      });
    });
    req.on('error', (error) => { clearTimeout(timer); if (error.code !== 'ECONNRESET') reject(error); });
  });
}

async function withStation(mode, credentials, action) {
  const station = await spawnStation(mode, credentials);
  try { await action(station); } finally { await station.close(); }
}

test('serves the closed public API contract and paced MP3', async () => {
  await withStation('public', {}, async ({ primary }) => {
    const health = await json(primary, '/api/health');
    assert.deepEqual(health.json, { ok: true });
    const state = await json(primary, '/api/state');
    assert.deepEqual(Object.keys(state.json).sort(), ['history', 'privacy', 'theme', 'upcoming']);
    assert.equal(state.json.theme.active, 'fixture-dark');
    assert.equal(state.json.upcoming[0].title, 'Fixture Next');
    assert.equal(state.json.history[0].t, '2030-01-01T11:55:00.000Z');
    assert.deepEqual(state.json.privacy, { privatePlayer: false, listenerAuth: false });
    const nowPlaying = await json(primary, '/api/now-playing');
    assert.deepEqual(Object.keys(nowPlaying.json).sort(), ['listeners', 'nowPlaying', 'stream', 'streamOnline']);
    assert.equal(nowPlaying.json.nowPlaying.title, 'Fixture Track primary');
    assert.deepEqual(nowPlaying.json.listeners, { current: 7, peak: 11 });
    assert.equal(nowPlaying.json.stream.format, 'mp3');
    const session = await json(primary, '/api/session');
    assert.deepEqual(Object.keys(session.json), ['messages']);
    assert.deepEqual(Object.keys(session.json.messages[0]), ['t', 'role', 'kind', 'text']);
    const themes = await json(primary, '/api/themes');
    assert.equal(themes.json.active, 'fixture-dark');
    assert.deepEqual(Object.keys(themes.json.themes[0]).sort(), ['id', 'name', 'tokens']);
    assert.equal(themes.json.themes[0].tokens['--accent'], '#ff3366');
    const schedule = await json(primary, '/api/schedule');
    assert.deepEqual(Object.keys(schedule.json).sort(), ['personas', 'schedule', 'shows']);
    assert.equal(schedule.json.personas[0].id, 'fixture-dj');
    assert.equal(schedule.json.shows[0].personaId, 'fixture-dj');
    assert.deepEqual(Object.keys(schedule.json.schedule), ['0', '1', '2', '3', '4', '5', '6']);
    for (const day of Object.values(schedule.json.schedule)) assert.equal(day.length, 24);
    for (const response of [health, state, nowPlaying, session, themes, schedule]) {
      assert.equal(response.status, 200);
      assert.equal(response.headers['content-type'], 'application/json; charset=utf-8');
    }
    const audio = (await readStream(primary, '/stream.mp3')).body;
    assert.ok(audio.subarray(0, 3).equals(Buffer.from('ID3')) || (audio[0] === 0xff && (audio[1] & 0xe0) === 0xe0));
    assert.equal((await request(primary, '/api/not-public')).status, 404);
  });
});

test('applies Unicode Basic auth independently to API and stream', async () => {
  const username = 'synthetic-üser'; const password = 'päss:雪';
  await withStation('basic', { 'basic-username': username, 'basic-password': password }, async ({ primary }) => {
    assert.equal((await request(primary, '/api/health')).status, 401);
    assert.equal((await request(primary, '/stream.mp3')).status, 401);
    assert.equal((await request(primary, '/api/health', { headers: basic(username, password) })).status, 200);
    assert.equal((await readStream(primary, '/stream.mp3', basic(username, password))).status, 200);
    const stats = (await json(primary, '/_fixture/stats')).json;
    assert.deepEqual(stats.counters['/api/health'], { requests: 2, authorizationPresent: 1, listenerAuthPresent: 0, successes: 1 });
    assert.deepEqual(stats.counters['/stream.mp3'], { requests: 2, authorizationPresent: 1, listenerAuthPresent: 0, successes: 1 });
    assert.doesNotMatch(JSON.stringify(stats), /synthetic|päss|雪/);
  });
});

test('listener password works alone and in combined mode', async () => {
  const listener = 'listen synthetic /?&雪';
  await withStation('listener', { 'listener-password': listener }, async ({ primary }) => {
    const denied = await postJson(primary, '/api/station-auth', { password: 'wrong' });
    assert.equal(denied.status, 401); assert.deepEqual(denied.json, { ok: false });
    const accepted = await postJson(primary, '/api/station-auth', { password: listener });
    assert.equal(accepted.status, 200); assert.deepEqual(accepted.json, { ok: true });
    assert.equal((await readStream(primary, '/stream.mp3')).status, 403);
    assert.equal((await readStream(primary, `/stream.mp3?auth=${encodeURIComponent(listener)}`)).status, 200);
  });
  await withStation('combined', {
    'basic-username': 'combo-user', 'basic-password': 'combo-basic', 'listener-password': listener,
  }, async ({ primary }) => {
    const headers = basic('combo-user', 'combo-basic');
    assert.equal((await postJson(primary, '/api/station-auth', { password: listener })).status, 401);
    const body = Buffer.from(JSON.stringify({ password: listener }));
    assert.equal((await request(primary, '/api/station-auth', { method: 'POST', body, headers: { ...headers, 'content-length': body.length } })).status, 200);
    assert.equal((await readStream(primary, `/stream.mp3?auth=${encodeURIComponent(listener)}`, headers)).status, 200);
    assert.equal((await readStream(primary, '/stream.mp3', headers)).status, 403);
  });
});

test('redirects to the isolated second origin and counts each destination request', async () => {
  await withStation('public', {}, async ({ primary, redirect }) => {
    assert.equal((await postJson(primary, '/_fixture/config', { path: '/api/health', redirect: true })).status, 200);
    const response = await request(primary, '/api/health');
    assert.equal(response.status, 307);
    assert.equal(response.headers.location, `${redirect}/api/health`);
    assert.equal((await request(redirect, '/api/health')).status, 200);
    const primaryStats = (await json(primary, '/_fixture/stats')).json;
    const redirectStats = (await json(redirect, '/_fixture/stats')).json;
    assert.equal(primaryStats.counters['/api/health'].requests, 1);
    assert.equal(redirectStats.counters['/api/health'].requests, 1);
  });
});

test('failure, delay, and stream drop controls are bounded and observable', async () => {
  await withStation('public', {}, async ({ primary }) => {
    await postJson(primary, '/_fixture/config', { path: '/api/state', failures: 1, delayMs: 80 });
    const started = Date.now();
    assert.equal((await request(primary, '/api/state')).status, 503);
    assert.ok(Date.now() - started >= 60);
    assert.equal((await request(primary, '/api/state')).status, 200);

    const dropped = new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('drop was not observed')), TIMEOUT_MS);
      const stream = http.get(`${primary}/stream.mp3`, (response) => {
        response.once('data', async () => {
          try { await postJson(primary, '/_fixture/drop', {}); }
          catch (error) { clearTimeout(timer); reject(error); }
        });
        response.once('aborted', () => { clearTimeout(timer); resolve(); });
        response.once('error', (error) => { clearTimeout(timer); if (error.code === 'ECONNRESET') resolve(); else reject(error); });
      });
      stream.once('error', (error) => { clearTimeout(timer); if (error.code === 'ECONNRESET') resolve(); else reject(error); });
    });
    await dropped;
    assert.equal((await json(primary, '/_fixture/stats')).json.activeStreams, 0);
    const oversized = await request(primary, '/_fixture/config', { method: 'POST', body: Buffer.alloc(1025), headers: { 'content-length': 1025 } });
    assert.equal(oversized.status, 413);
  });
});

test('rejects non-literal-loopback binds and incomplete auth configuration', async () => {
  for (const [args, message] of [
    [['--host', 'localhost'], /literal loopback/],
    [['--auth-mode', 'basic'], /requires a non-empty synthetic username and password/],
    [['--auth-mode', 'listener'], /requires a non-empty synthetic listener password/],
  ]) {
    const child = spawn(process.execPath, [stationPath, ...args], { stdio: ['ignore', 'pipe', 'pipe'], env: {} });
    let stderr = ''; child.stderr.on('data', (chunk) => { stderr += chunk; });
    const code = await new Promise((resolve) => child.once('exit', resolve));
    assert.equal(code, 1); assert.match(stderr, message);
  }
});

test('programmatic startup validates the same bounded options as the CLI', async () => {
  for (const [options, message] of [
    [{ host: 'localhost' }, /literal loopback/],
    [{ port: 65536 }, /--port/],
    [{ chunkBytes: 0 }, /--chunk-bytes/],
    [{ authMode: 'basic' }, /requires a non-empty synthetic username and password/],
    [{ authMode: 'listener' }, /requires a non-empty synthetic listener password/],
  ]) await assert.rejects(startFixtureStation(options), message);
});

test('a failed primary bind closes the redirect origin it already opened', async () => {
  const blocker = http.createServer();
  await new Promise((resolve, reject) => { blocker.once('error', reject); blocker.listen(0, '127.0.0.1', resolve); });
  const primaryPort = blocker.address().port;
  const redirectProbe = net.createServer();
  await new Promise((resolve, reject) => { redirectProbe.once('error', reject); redirectProbe.listen(0, '127.0.0.1', resolve); });
  const redirectPort = redirectProbe.address().port;
  await new Promise((resolve) => redirectProbe.close(resolve));
  try {
    await assert.rejects(startFixtureStation({ port: primaryPort, redirectPort }), /EADDRINUSE/);
    const reusable = net.createServer();
    await new Promise((resolve, reject) => { reusable.once('error', reject); reusable.listen(redirectPort, '127.0.0.1', resolve); });
    await new Promise((resolve) => reusable.close(resolve));
  } finally {
    await new Promise((resolve) => blocker.close(resolve));
  }
});

test('closing cancels delayed responses and malformed request targets get 400', async () => {
  const station = await startFixtureStation({ intervalMs: 20, chunkBytes: 4 });
  await postJson(station.primary, '/_fixture/config', { path: '/api/state', delayMs: 2000 });
  const pending = http.get(`${station.primary}/api/state`);
  let receivedResponse = false;
  pending.once('response', () => { receivedResponse = true; });
  const connected = new Promise((resolve) => pending.once('socket', (socket) => socket.connecting ? socket.once('connect', resolve) : resolve()));
  const ended = new Promise((resolve) => { pending.once('error', resolve); pending.once('close', resolve); });
  await connected;
  await station.close();
  await ended;
  assert.equal(receivedResponse, false);

  const next = await startFixtureStation({ intervalMs: 20, chunkBytes: 4 });
  try {
    const { port } = new URL(next.primary);
    const reply = await new Promise((resolve, reject) => {
      const socket = net.connect(Number(port), '127.0.0.1', () => socket.write('GET http://[ HTTP/1.1\r\nHost: fixture\r\nConnection: close\r\n\r\n'));
      let data = '';
      socket.on('data', (chunk) => { data += chunk; });
      socket.on('end', () => resolve(data));
      socket.on('error', reject);
    });
    assert.match(reply, /^HTTP\/1\.1 400 /);
    assert.match(reply, /"error":"invalid_url"/);
  } finally { await next.close(); }
});
