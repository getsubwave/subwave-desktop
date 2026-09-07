#!/usr/bin/env node

import { readFile } from 'node:fs/promises';
import http from 'node:http';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const BODY_LIMIT = 1024;
const MAX_STREAMS = 16;
const PUBLIC_PATHS = new Set([
  '/api/health', '/api/state', '/api/now-playing', '/api/session',
  '/api/themes', '/api/schedule', '/api/station-auth', '/stream.mp3',
]);
const defaultFile = path.join(path.dirname(fileURLToPath(import.meta.url)), 'tone.mp3');

function usage() {
  return `Usage: node station.mjs [options]\n\n` +
    `  --file PATH                 MP3 file to loop (default: fixtures/tone.mp3)\n` +
    `  --host 127.0.0.1|::1       Literal loopback bind (default: 127.0.0.1)\n` +
    `  --port PORT                Primary port; 0 chooses a free port\n` +
    `  --redirect-port PORT       Redirect destination port; 0 chooses a free port\n` +
    `  --chunk-bytes N            Stream bytes per interval (default: 1600)\n` +
    `  --interval-ms N            Stream pacing interval (default: 100)\n` +
    `  --auth-mode MODE           public, basic, listener, or combined\n` +
    `  --basic-username VALUE     Synthetic Basic username (or FIXTURE_BASIC_USERNAME)\n` +
    `  --basic-password VALUE     Synthetic Basic password (or FIXTURE_BASIC_PASSWORD)\n` +
    `  --listener-password VALUE  Synthetic listener password (or FIXTURE_LISTENER_PASSWORD)\n`;
}

function integer(value, name, { zero = false, maximum = Number.MAX_SAFE_INTEGER } = {}) {
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < (zero ? 0 : 1) || parsed > maximum) {
    throw new Error(`${name} must be an integer from ${zero ? 0 : 1} to ${maximum}`);
  }
  return parsed;
}

function defaultOptions(env = process.env) {
  return {
    file: defaultFile, host: '127.0.0.1', port: 0, redirectPort: 0,
    chunkBytes: 1600, intervalMs: 100, authMode: 'public',
    basicUsername: env.FIXTURE_BASIC_USERNAME,
    basicPassword: env.FIXTURE_BASIC_PASSWORD,
    listenerPassword: env.FIXTURE_LISTENER_PASSWORD,
  };
}

function validateOptions(input, env = process.env) {
  const options = { ...defaultOptions(env), ...input };
  if (typeof options.file !== 'string' || !options.file) throw new Error('file must be a non-empty path');
  if (!['127.0.0.1', '::1'].includes(options.host)) throw new Error('--host must be a literal loopback address');
  options.port = integer(options.port, '--port', { zero: true, maximum: 65535 });
  options.redirectPort = integer(options.redirectPort, '--redirect-port', { zero: true, maximum: 65535 });
  options.chunkBytes = integer(options.chunkBytes, '--chunk-bytes');
  options.intervalMs = integer(options.intervalMs, '--interval-ms');
  if (!['public', 'basic', 'listener', 'combined'].includes(options.authMode)) throw new Error('--auth-mode must be public, basic, listener, or combined');
  if (['basic', 'combined'].includes(options.authMode) &&
      (![options.basicUsername, options.basicPassword].every(value => typeof value === 'string' && value.length > 0))) {
    throw new Error('Basic auth mode requires a non-empty synthetic username and password');
  }
  if (['listener', 'combined'].includes(options.authMode) &&
      !(typeof options.listenerPassword === 'string' && options.listenerPassword.length > 0)) {
    throw new Error('listener auth mode requires a non-empty synthetic listener password');
  }
  return options;
}

function parseArgs(argv, env = process.env) {
  const options = defaultOptions(env);
  const mappings = {
    '--file': ['file', String], '--host': ['host', String],
    '--port': ['port', (v) => integer(v, '--port', { zero: true, maximum: 65535 })],
    '--redirect-port': ['redirectPort', (v) => integer(v, '--redirect-port', { zero: true, maximum: 65535 })],
    '--chunk-bytes': ['chunkBytes', (v) => integer(v, '--chunk-bytes')],
    '--interval-ms': ['intervalMs', (v) => integer(v, '--interval-ms')],
    '--auth-mode': ['authMode', String], '--basic-username': ['basicUsername', String],
    '--basic-password': ['basicPassword', String], '--listener-password': ['listenerPassword', String],
  };
  for (let i = 0; i < argv.length; i += 2) {
    if (argv[i] === '--help') { process.stdout.write(usage()); process.exit(0); }
    const mapping = mappings[argv[i]];
    if (!mapping || argv[i + 1] === undefined) throw new Error(`unknown or incomplete option: ${argv[i]}`);
    options[mapping[0]] = mapping[1](argv[i + 1]);
  }
  return validateOptions(options, env);
}

function isLoopback(address) {
  return address === '127.0.0.1' || address === '::1' || address === '::ffff:127.0.0.1';
}

function sendJson(response, status, value, headers = {}) {
  if (response.destroyed || response.headersSent) return;
  const body = Buffer.from(`${JSON.stringify(value)}\n`);
  response.writeHead(status, {
    'content-type': 'application/json; charset=utf-8', 'content-length': body.length,
    'cache-control': 'no-store', connection: 'close', ...headers,
  });
  response.end(body);
}

function readJson(request, response, action) {
  const declared = Number(request.headers['content-length'] ?? 0);
  if (Number.isFinite(declared) && declared > BODY_LIMIT) {
    request.resume(); sendJson(response, 413, { error: 'request_too_large' }); return;
  }
  const chunks = [];
  let length = 0;
  let done = false;
  request.on('data', (chunk) => {
    length += chunk.length;
    if (length <= BODY_LIMIT) chunks.push(chunk);
    else if (!done) { done = true; sendJson(response, 413, { error: 'request_too_large' }); }
  });
  request.on('end', () => {
    if (done) return;
    try { action(chunks.length ? JSON.parse(Buffer.concat(chunks).toString('utf8')) : {}); }
    catch { sendJson(response, 400, { error: 'invalid_json' }); }
  });
}

function publicPayload(pathname, originName) {
  const emptyDay = () => Array(24).fill(null);
  const payloads = {
    '/api/health': { status: 'on-air' },
    '/api/state': {
      theme: { active: 'fixture-dark' },
      upcoming: [{ title: 'Fixture Next', artist: 'Fixture Artist', requestedBy: null }],
      history: [{ title: 'Fixture Previous', artist: 'Fixture Artist', t: '2030-01-01T11:55:00.000Z' }],
      privacy: { privatePlayer: false, listenerAuth: false },
    },
    '/api/now-playing': {
      nowPlaying: { title: `Fixture Track ${originName}`, artist: 'Fixture Artist', album: 'Fixture Album', duration: 180, timestamp: 1893499200 },
      listeners: { current: 7, peak: 11 },
      stream: { opusEnabled: true, flacEnabled: true, aacEnabled: true, format: 'mp3', bitrate: 128 },
      streamOnline: true,
    },
    '/api/session': { messages: [{ t: '2030-01-01T12:00:00.000Z', role: 'assistant', kind: 'speech', text: `Fixture Session ${originName}` }] },
    '/api/themes': { active: 'fixture-dark', themes: [{ id: 'fixture-dark', name: 'Fixture Dark', tokens: { '--bg': '#101010', '--ink': '#ffffff', '--muted': '#999999', '--accent': '#ff3366', '--field': '#202020', '--soft-border': '#333333', '--overlay': '#000000' } }] },
    '/api/schedule': {
      personas: [{ id: 'fixture-dj', name: 'Fixture DJ' }],
      shows: [{ id: 'fixture-show', name: 'Fixture Show', topic: 'Fixture Radio', personaId: 'fixture-dj' }],
      schedule: Object.fromEntries(Array.from({ length: 7 }, (_, day) => [String(day), emptyDay()])),
    },
  };
  return payloads[pathname];
}

async function createOrigin({ name, options, audio, redirectBase }) {
  const sockets = new Set();
  const streams = new Set();
  const counters = Object.create(null);
  const controls = Object.create(null);
  const delayed = new Set();

  function count(pathname, request, listenerPresent = false) {
    const entry = counters[pathname] ??= { requests: 0, authorizationPresent: 0, listenerAuthPresent: 0, successes: 0 };
    entry.requests += 1;
    if (request.headers.authorization !== undefined) entry.authorizationPresent += 1;
    if (listenerPresent) entry.listenerAuthPresent += 1;
    return entry;
  }

  function basicAllowed(request) {
    if (!['basic', 'combined'].includes(options.authMode)) return true;
    const expected = `Basic ${Buffer.from(`${options.basicUsername}:${options.basicPassword}`, 'utf8').toString('base64')}`;
    return request.headers.authorization === expected;
  }

  const server = http.createServer((request, response) => {
    let url;
    try { url = new URL(request.url ?? '/', 'http://fixture.invalid'); }
    catch { sendJson(response, 400, { error: 'invalid_url' }); return; }
    if (url.pathname.startsWith('/_fixture/')) {
      if (!isLoopback(request.socket.remoteAddress)) { sendJson(response, 403, { error: 'loopback_only' }); return; }
      if (url.pathname === '/_fixture/stats' && request.method === 'GET') {
        sendJson(response, 200, { origin: name, activeStreams: streams.size, counters }); return;
      }
      if (url.pathname === '/_fixture/config' && request.method === 'POST') {
        readJson(request, response, (body) => {
          if (!PUBLIC_PATHS.has(body.path)) { sendJson(response, 400, { error: 'invalid_path' }); return; }
          const delayMs = integer(body.delayMs ?? 0, 'delayMs', { zero: true, maximum: 2000 });
          const failures = integer(body.failures ?? 0, 'failures', { zero: true, maximum: 100 });
          if (![undefined, false, true].includes(body.redirect)) { sendJson(response, 400, { error: 'invalid_redirect' }); return; }
          controls[body.path] = { delayMs, failures, redirect: body.redirect === true };
          sendJson(response, 200, { path: body.path, delayMs, failures, redirect: body.redirect === true });
        });
        return;
      }
      if (url.pathname === '/_fixture/reset' && request.method === 'POST') {
        readJson(request, response, () => { for (const key of Object.keys(counters)) delete counters[key]; sendJson(response, 200, { ok: true }); }); return;
      }
      if (url.pathname === '/_fixture/drop' && request.method === 'POST') {
        readJson(request, response, () => { for (const stream of [...streams]) stream.drop(); sendJson(response, 200, { activeStreams: streams.size }); }); return;
      }
      sendJson(response, request.method === 'GET' || request.method === 'POST' ? 404 : 405, { error: 'not_found' }); return;
    }

    if (!PUBLIC_PATHS.has(url.pathname)) { sendJson(response, 404, { error: 'not_found' }); return; }
    const listenerPresent = url.pathname === '/stream.mp3' && url.searchParams.has('auth');
    const counter = count(url.pathname, request, listenerPresent);
    const control = controls[url.pathname] ?? { delayMs: 0, failures: 0, redirect: false };
    const respond = () => {
      if (request.destroyed || response.destroyed || response.writableEnded) return;
      if (control.failures > 0) { control.failures -= 1; sendJson(response, 503, { error: 'fixture_failure' }); return; }
      if (control.redirect && redirectBase) { response.writeHead(307, { location: `${redirectBase}${url.pathname}${url.search}` }); response.end(); return; }
      if (!basicAllowed(request)) { sendJson(response, 401, { error: 'basic_auth_required' }, { 'www-authenticate': 'Basic realm="fixture"' }); return; }

      if (url.pathname === '/api/station-auth') {
        if (request.method !== 'POST') { sendJson(response, 405, { error: 'method_not_allowed' }, { allow: 'POST' }); return; }
        readJson(request, response, (body) => {
          const present = typeof body.password === 'string' && body.password.length > 0;
          counter.listenerAuthPresent += Number(present);
          if (['listener', 'combined'].includes(options.authMode) && body.password !== options.listenerPassword) {
            sendJson(response, 401, { ok: false }); return;
          }
          counter.successes += 1; sendJson(response, 200, { ok: true });
        });
        return;
      }
      if (request.method !== 'GET') { sendJson(response, 405, { error: 'method_not_allowed' }, { allow: 'GET' }); return; }
      if (url.pathname === '/stream.mp3') {
        if (['listener', 'combined'].includes(options.authMode) && url.searchParams.get('auth') !== options.listenerPassword) {
          sendJson(response, 403, { error: 'listener_auth_required' }); return;
        }
        if (streams.size >= MAX_STREAMS) { sendJson(response, 503, { error: 'stream_capacity' }); return; }
        counter.successes += 1;
        let offset = 0; let timer; let closed = false;
        const stream = { drop() { cleanup(); response.destroy(); } };
        streams.add(stream);
        function cleanup() { if (closed) return; closed = true; clearTimeout(timer); streams.delete(stream); }
        function sendChunk() {
          if (closed || response.destroyed) return;
          const end = Math.min(offset + options.chunkBytes, audio.length);
          const writable = response.write(audio.subarray(offset, end));
          offset = end === audio.length ? 0 : end;
          if (writable) timer = setTimeout(sendChunk, options.intervalMs);
          else response.once('drain', () => {
            if (!closed && !response.destroyed) timer = setTimeout(sendChunk, options.intervalMs);
          });
        }
        response.writeHead(200, { 'content-type': 'audio/mpeg', 'cache-control': 'no-store', connection: 'close' });
        response.on('close', cleanup); response.on('error', cleanup); sendChunk(); return;
      }
      counter.successes += 1; sendJson(response, 200, publicPayload(url.pathname, name));
    };
    if (control.delayMs) {
      const timer = setTimeout(() => { delayed.delete(timer); respond(); }, control.delayMs);
      delayed.add(timer);
      response.once('close', () => { clearTimeout(timer); delayed.delete(timer); });
    } else respond();
  });
  server.on('connection', (socket) => { sockets.add(socket); socket.on('close', () => sockets.delete(socket)); });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(name === 'primary' ? options.port : options.redirectPort, options.host, resolve); });
  const address = server.address();
  const host = address.address.includes(':') ? `[${address.address}]` : address.address;
  return {
    base: `http://${host}:${address.port}`,
    close: () => new Promise((resolve) => {
      for (const timer of delayed) clearTimeout(timer);
      delayed.clear();
      for (const stream of [...streams]) stream.drop();
      server.close(resolve); for (const socket of sockets) socket.destroy();
    }),
  };
}

export async function startFixtureStation(options) {
  options = validateOptions(options);
  const audio = await readFile(options.file);
  if (!audio.length) throw new Error(`MP3 file is empty: ${options.file}`);
  const redirect = await createOrigin({ name: 'redirect', options, audio, redirectBase: null });
  let primary;
  try { primary = await createOrigin({ name: 'primary', options, audio, redirectBase: redirect.base }); }
  catch (error) { await redirect.close(); throw error; }
  return { primary: primary.base, redirect: redirect.base, close: async () => { await primary.close(); await redirect.close(); } };
}

async function main() {
  const station = await startFixtureStation(parseArgs(process.argv.slice(2)));
  process.stdout.write(`${JSON.stringify({ primary: station.primary, redirect: station.redirect })}\n`);
  let closing = false;
  const shutdown = async () => { if (closing) return; closing = true; await station.close(); process.exit(0); };
  process.once('SIGINT', shutdown); process.once('SIGTERM', shutdown);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((error) => { process.stderr.write(`${error.message}\n`); process.exitCode = 1; });
}

export { parseArgs };
