// Cross-language oracle: the upstream WebCrypto initiator talks to our Python responder.
import {pathToFileURL} from 'node:url';
import readline from 'node:readline';
const {E2ESession} = await import(pathToFileURL(process.argv[2] + '/packages/core/src/e2e.ts'));
const {deriveRoutingToken} = await import(pathToFileURL(process.argv[2] + '/packages/core/src/crypto.ts'));
const lines = readline.createInterface({input: process.stdin});
const code = process.argv[3]; // synthetic test code only
const emit = value => console.log(JSON.stringify(value));
emit({routing: await deriveRoutingToken(code)});
const session = new E2ESession({role: 'initiator', code,
  send: data => emit(typeof data === 'string' ? {s: data} : {b: Buffer.from(data).toString('base64')}),
  onReady: () => session.sendFrame({t: 'hreq', id: 'fixture', method: 'GET', path: '/pair/identity', headers: {}}),
  onFrame: frame => { emit({result: frame}); lines.close(); process.exit(0); },
  onError: error => { emit({error}); process.exit(1); }
});
lines.on('line', async line => {
  const value = JSON.parse(line);
  await session.onMessage(value.s ?? new Uint8Array(Buffer.from(value.b, 'base64')));
});
await session.start();
