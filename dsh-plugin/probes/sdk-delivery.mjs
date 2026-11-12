// Read-only installed-SDK component probe. No profile, network, model or disk session.
// Usage: node dsh-plugin/probes/sdk-delivery.mjs /path/to/@deepseek-ai/dsh
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const root = process.argv[2];
if (!root) throw new Error('Pass the installed @deepseek-ai/dsh package directory');
const packageRoot = resolve(root, 'node_modules/@deepseek-ai');
const serverRoot = resolve(packageRoot, 'dsh-sdk-jsonrpc-server');
const protocolRoot = resolve(packageRoot, 'dsh-sdk-protocol');
const source = await readFile(resolve(serverRoot, 'lib/index.js'));
const protocol = await readFile(resolve(protocolRoot, 'lib/types/types.d.ts'), 'utf8');
const metadata = JSON.parse(await readFile(resolve(serverRoot, 'package.json'), 'utf8'));
const { HarnessSdkJsonRpcServer } = await import(pathToFileURL(resolve(serverRoot, 'lib/index.js')));

// Real SDK dispatcher/prompt/createUserMessage; agent, transport and context are doubles.
// This deliberately does NOT claim real persistence or model/round execution.
const enqueued = [];
const agent = { id: 'synthetic-agent', followup: message => enqueued.push(message) };
const ctx = {
  on: () => () => {},
  get: () => undefined,
  agents: { get: id => id === agent.id ? agent : undefined },
};
const server = new HarnessSdkJsonRpcServer(ctx, { notify: () => {} });
server.initialized = true; // Handshake bypass is confined to this component probe.
server.sessions.set('synthetic-session', { handle: { agent } });
const params = {
  sessionId: 'synthetic-session',
  contentBlocks: [{ type: 'text', text: 'synthetic event: bb-test-1' }],
};
const first = await server.handleRequest('session/prompt', params);
// Simulate the caller losing the receipt, then retrying identical input.
const retry = await server.handleRequest('session/prompt', params);
assert.equal(enqueued.length, 2);
assert.notEqual(first.messageId, retry.messageId);
assert.deepEqual(enqueued[0].content, params.contentBlocks);
assert.deepEqual(enqueued[1].content, params.contentBlocks);
await assert.rejects(server.handleRequest('session/prompt', {
  sessionId: params.sessionId,
  contentBlocks: [
    { type: 'text', text: 'before' },
    { type: 'image', data: 'AA==', mimeType: 'image/png' },
    { type: 'text', text: 'after' },
  ],
}), /requires an attachment store/);
assert.equal(enqueued.length, 2);
const promptFields = protocol.match(/export interface SessionPromptParams \{([\s\S]*?)\n\}/)?.[1];
assert.ok(promptFields);
assert.ok(!/operationId|idempotencyKey|messageId/.test(promptFields));
const requestMap = protocol.split('export interface HarnessSdkRequestMap {')[1];
assert.ok(requestMap);
const methods = [...requestMap.matchAll(/^    '([^']+)':/gm)].map(match => match[1]);
console.log(JSON.stringify({
  scope: 'installed SDK component; synthetic agent/context/transport; no model or persistence',
  package: metadata.name,
  version: metadata.version,
  source_sha256: createHash('sha256').update(source).digest('hex'),
  protocol_sha256: createHash('sha256').update(protocol).digest('hex'),
  checks: {
    identical_prompt_retry_enqueues_two_distinct_message_ids: true,
    missing_attachment_store_rejects_image_before_enqueue: true,
    prompt_has_no_caller_idempotency_field: true,
  },
  declared_request_methods: methods,
  product_acceptance: 'BLOCKED: lost-receipt reconciliation needs a verified adapter contract',
}, null, 2));
