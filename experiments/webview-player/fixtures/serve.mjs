#!/usr/bin/env node

import { readFile } from 'node:fs/promises';
import http from 'node:http';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const CONTROL_BODY_LIMIT = 1024;
const defaults = {
  file: path.join(path.dirname(fileURLToPath(import.meta.url)), 'tone.mp3'),
  host: '127.0.0.1',
  port: 0,
  chunkBytes: 1600,
  intervalMs: 100,
};

function usage() {
  return `Usage: node serve.mjs [options]\n\n` +
    `  --file PATH          MP3 file to loop (default: fixtures/tone.mp3)\n` +
    `  --host HOST          Loopback address (default: 127.0.0.1)\n` +
    `  --port PORT          Listen port, 0 chooses a free port (default: 0)\n` +
    `  --chunk-bytes N      Bytes sent per interval (default: 1600)\n` +
    `  --interval-ms N      Delay between chunks (default: 100)\n`;
}

function positiveInteger(value, name, { allowZero = false } = {}) {
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < (allowZero ? 0 : 1)) {
    throw new Error(`${name} must be ${allowZero ? 'a non-negative' : 'a positive'} integer`);
  }
  return parsed;
}

function parseArgs(argv) {
  const options = { ...defaults };
  const names = {
    '--file': ['file', String],
    '--host': ['host', String],
    '--port': ['port', (value) => {
      const port = positiveInteger(value, '--port', { allowZero: true });
      if (port > 65535) throw new Error('--port must be an integer from 0 to 65535');
      return port;
    }],
    '--chunk-bytes': ['chunkBytes', (value) => positiveInteger(value, '--chunk-bytes')],
    '--interval-ms': ['intervalMs', (value) => positiveInteger(value, '--interval-ms')],
  };
  for (let index = 0; index < argv.length; index += 2) {
    const option = argv[index];
    if (option === '--help') {
      process.stdout.write(usage());
      process.exit(0);
    }
    const mapping = names[option];
    const value = argv[index + 1];
    if (!mapping || value === undefined) throw new Error(`unknown or incomplete option: ${option}`);
    options[mapping[0]] = mapping[1](value);
  }
  if (options.host !== '127.0.0.1' && options.host !== '::1') {
    throw new Error('--host must be a loopback address');
  }
  return options;
}

function isLoopback(address) {
  return address === '127.0.0.1' || address === '::1' || address === '::ffff:127.0.0.1';
}

function sendJson(response, status, value, extraHeaders = {}) {
  const body = Buffer.from(`${JSON.stringify(value)}\n`);
  response.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': body.length,
    'cache-control': 'no-store',
    connection: 'close',
    ...extraHeaders,
  });
  response.end(body);
}

function readControlBody(request, response, action) {
  const declaredLength = Number(request.headers['content-length'] ?? 0);
  if (Number.isFinite(declaredLength) && declaredLength > CONTROL_BODY_LIMIT) {
    request.resume();
    sendJson(response, 413, { error: 'request_too_large' });
    return;
  }

  let length = 0;
  let complete = false;
  request.on('data', (chunk) => {
    length += chunk.length;
    if (!complete && length > CONTROL_BODY_LIMIT) {
      complete = true;
      sendJson(response, 413, { error: 'request_too_large' });
    }
  });
  request.on('end', () => {
    if (!complete) action();
  });
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const audio = await readFile(options.file);
  if (audio.length === 0) throw new Error(`MP3 file is empty: ${options.file}`);

  const streams = new Set();
  const sockets = new Set();
  let totalConnections = 0;

  const server = http.createServer((request, response) => {
    const url = new URL(request.url ?? '/', 'http://fixture.invalid');

    if (url.pathname === '/stream.mp3') {
      if (request.method !== 'GET') {
        sendJson(response, 405, { error: 'method_not_allowed' }, { allow: 'GET' });
        return;
      }

      totalConnections += 1;
      let offset = 0;
      let timer;
      let closed = false;
      const stream = { response, cleanup };
      streams.add(stream);

      function cleanup() {
        if (closed) return;
        closed = true;
        clearTimeout(timer);
        streams.delete(stream);
      }

      function sendChunk() {
        if (closed || response.destroyed) return;
        const end = Math.min(offset + options.chunkBytes, audio.length);
        const writable = response.write(audio.subarray(offset, end));
        offset = end === audio.length ? 0 : end;
        if (writable) timer = setTimeout(sendChunk, options.intervalMs);
        else response.once('drain', () => { timer = setTimeout(sendChunk, options.intervalMs); });
      }

      response.writeHead(200, {
        'content-type': 'audio/mpeg',
        'cache-control': 'no-store',
        connection: 'close',
      });
      response.on('close', cleanup);
      response.on('error', cleanup);
      sendChunk();
      return;
    }

    const control = url.pathname.startsWith('/_fixture/');
    if (control && !isLoopback(request.socket.remoteAddress)) {
      sendJson(response, 403, { error: 'loopback_only' });
      return;
    }

    if (url.pathname === '/_fixture/stats') {
      if (request.method !== 'GET') {
        sendJson(response, 405, { error: 'method_not_allowed' }, { allow: 'GET' });
        return;
      }
      sendJson(response, 200, {
        activeConnections: streams.size,
        totalConnections,
      });
      return;
    }

    if (url.pathname === '/_fixture/reset' || url.pathname === '/_fixture/drop') {
      if (request.method !== 'POST') {
        sendJson(response, 405, { error: 'method_not_allowed' }, { allow: 'POST' });
        return;
      }
      readControlBody(request, response, () => {
        if (url.pathname === '/_fixture/reset') totalConnections = 0;
        else {
          for (const stream of [...streams]) {
            stream.cleanup();
            stream.response.destroy();
          }
        }
        sendJson(response, 200, {
          activeConnections: streams.size,
          totalConnections,
        });
      });
      return;
    }

    sendJson(response, 404, { error: 'not_found' });
  });

  server.on('connection', (socket) => {
    sockets.add(socket);
    socket.on('close', () => sockets.delete(socket));
  });

  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(options.port, options.host, resolve);
  });

  const address = server.address();
  const displayHost = address.address.includes(':') ? `[${address.address}]` : address.address;
  process.stdout.write(`http://${displayHost}:${address.port}\n`);

  function shutdown() {
    for (const stream of [...streams]) {
      stream.cleanup();
      stream.response.destroy();
    }
    server.close(() => process.exit(0));
    for (const socket of sockets) socket.destroy();
  }
  process.once('SIGINT', shutdown);
  process.once('SIGTERM', shutdown);
}

main().catch((error) => {
  process.stderr.write(`${error.message}\n`);
  process.exitCode = 1;
});
