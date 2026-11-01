// Runs the unmodified upstream relay-kit fixture. No production configuration or credentials.
import { pathToFileURL } from 'node:url';
const { startRelayServer } = await import(pathToFileURL(process.argv[2] + '/test/fixtures/relay-server.mjs'));
const server = await startRelayServer();
console.log(JSON.stringify({port: server.port}));
process.on('SIGTERM', () => { server.close(); process.exit(0); });
