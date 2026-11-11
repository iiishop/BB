from pathlib import Path
import difflib, hashlib, json, sys
here=Path(__file__).resolve().parent
source=Path(sys.argv[1])
lock=json.loads((here/'lock.json').read_text())
original=(source/lock['target']).read_text()
assert hashlib.sha256(original.encode()).hexdigest()==lock['original_sha256']
s=original
replacements=[
('const result = slot.needsPost ? await ctx.tools[TOOL_RUNTIME_SCHEDULER].finalize(slot.exec, slot.result) : ctx.tools[TOOL_RUNTIME_SCHEDULER].finish(slot.exec, slot.result);', 'const result = bbRecovery.guardResult(ctx.agents.requireInitiator(), slot.needsPost ? await ctx.tools[TOOL_RUNTIME_SCHEDULER].finalize(slot.exec, slot.result) : ctx.tools[TOOL_RUNTIME_SCHEDULER].finish(slot.exec, slot.result));'),
('return this.setupAndPublish(ownerCtx, options.sessionId, preparation, options.agentOptions ?? {}, options.setup, options.signal, "startup", stored, options.parentAgent);', 'const created = await this.setupAndPublish(ownerCtx, options.sessionId, preparation, options.agentOptions ?? {}, options.setup, options.signal, "startup", stored, options.parentAgent);\n\t\t\ttry { await bbRecovery.ready(created.agent); return created; } catch (error) { await created.dispose(); throw error; }'),
('import { Service }','import * as bbRecovery from "./bb-recovery.mjs";\nimport { Service }'),
('\tsend(message, target, wakeup) {','\tbbDeliver(key, content, options) { return bbRecovery.deliver(this, key, content, options); }\n\tbbConfigure(account, peer) { return bbRecovery.configure(this, account, peer); }\n\tbbEventCursor() { return bbRecovery.cursor(this); }\n\tbbAdvanceCursor(account, cursor) { return bbRecovery.advanceCursor(this, account, cursor); }\n\tbbDeliveryStatus(key) { return bbRecovery.status(this, key); }\n\tbbRecoverDeliveries() { return bbRecovery.recover(this); }\n\tsend(message, target, wakeup) {'),
('const claimed = this.inbox.claim(target, position.turn);','const claimed = this.inbox.claim(target, position.turn);\n\t\tawait bbRecovery.claimed(this, claimed, position);'),
('reason: turnEnds\n\t\t\t\t});','reason: turnEnds\n\t\t\t\t});\n\t\t\t\tawait bbRecovery.afterTurn(this);'),
('} else this.session.append("user/message", message,','} else if (bbRecovery.shouldAppend(this, message)) this.session.append("user/message", message,'),
('const request = this.buildRequest(config, preparedCall, assembly.tools, {', 'await bbRecovery.prepareContinuation(this, turn, step, decision.messages);\n\t\t\tconst request = this.buildRequest(config, preparedCall, assembly.tools, {'),
('const stream = preparedCall?.stream(request)', 'await bbRecovery.beforeModel(this, turn, step, request);\n\t\t\t\tconst stream = preparedCall?.stream(request)'),
('\t\t\t\tlive.settle("assistant/message", () => this.session.append("assistant/message", {','\t\t\t\tawait bbRecovery.modelResult(this, turn, step, message, finish.kind);\n\t\t\t\tlive.settle("assistant/message", () => this.session.append("assistant/message", {'),
('const prepared = await ctx.tools[TOOL_RUNTIME_SCHEDULER].prepare(call.exec);','const cached = await bbRecovery.beforeTool(ctx.agents.requireInitiator(), call.block, turn, step);\n\t\tconst prepared = cached ? {kind: "final-result", exec: call.exec, result: cached} : await ctx.tools[TOOL_RUNTIME_SCHEDULER].prepare(call.exec);'),
('appendToolResult(session, turn, step, call.block, result, callSeqs[committed]);','appendToolResult(session, turn, step, call.block, result, callSeqs[committed]);\n\t\t\tawait bbRecovery.afterTool(ctx.agents.requireInitiator(), call.block, result, turn, step);'),
('return await this.setupAndPublish(ownerCtx, id, preparation, options.agentOptions ?? {}, options.setup, options.signal, "resume", owned, options.parentAgent);','const resumed = await this.setupAndPublish(ownerCtx, id, preparation, options.agentOptions ?? {}, options.setup, options.signal, "resume", owned, options.parentAgent);\n\t\t\t\ttry { await bbRecovery.ready(resumed.agent); await resumed.agent.bbRecoverDeliveries(); return resumed; } catch (error) { await resumed.dispose(); throw error; }'),
]
for a,b in replacements:
 assert s.count(a)==1,(a,s.count(a))
 s=s.replace(a,b)
patch=''.join(difflib.unified_diff(original.splitlines(True),s.splitlines(True),fromfile='a/'+lock['target'],tofile='b/'+lock['target']))
(here/'agent-loop.patch').write_text(patch)
lock.update(patched_sha256=hashlib.sha256(s.encode()).hexdigest(),patch_sha256=hashlib.sha256(patch.encode()).hexdigest(),helper_sha256=hashlib.sha256((here/'recovery.mjs').read_bytes()).hexdigest())
(here/'lock.json').write_text(json.dumps(lock,indent=2)+'\n')
