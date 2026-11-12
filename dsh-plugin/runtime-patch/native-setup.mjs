// Compose inside an already verified, isolated native host. No personal profile discovery.
import assert from 'node:assert/strict';
import {isAbsolute} from 'node:path';
import {localTransport} from './local-bridge.mjs';
import {setupRuntimeBridge} from './runtime-bridge.mjs';
export function productMcpConfig({origin,pluginDirectory,server_name='bb'}){
 localTransport(origin); // strict loopback validation, no request
 assert.ok(isAbsolute(pluginDirectory),'pluginDirectory must be absolute');
 assert.match(server_name,/^[A-Za-z0-9_]{1,30}$/);
 return {transport:'stdio',serverName:server_name,command:'uv',args:['run','--project',pluginDirectory,'--locked','bb-dsh-plugin'],env:{BB_CLIENT_BASE_URL:origin},toolCallTimeoutMs:130000,failOnStartupError:true};
}
export function setupProductBridge({mcpModule,pluginDirectory,...options},onReady){
 const config=productMcpConfig({...options,pluginDirectory});
 const bind=setupRuntimeBridge(options,onReady);
 return async(ctx,agent)=>{
  // Cordis owns this Agent-scoped MCP subprocess and disposes it with the Agent.
  await ctx.plugin(mcpModule,config);
  return bind(ctx,agent);
 };
}
