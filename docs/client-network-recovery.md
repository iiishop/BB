# 客户端网络恢复与诊断

## 范围与行为

- `EventFeed` 保留 2 秒轮询和每个 consumer/peer 的持久游标。WebSocket 只是提示；失败或断开后用可取消 Timer 重连，等抖动退避依次为 0.5–1 秒、1–2 秒、2–4 秒……上限 15–30 秒。稳定连接至少 30 秒后才重置退避，避免「握手成功后立刻断开」形成热循环。
- `start` 幂等；连接中的尝试与已连接 socket 都有单实例保护。`stop`/`dispose` 取消重连，旧连接/迟到握手不能覆盖新代连接。周期检查跟踪登录身份变化；重连成功立即补跑持久回放，游标和 ACK 规则未改。
- 源码没有现成 `WidgetsBindingObserver`/`AppLifecycleListener` 传入这一同时服务 GUI 和 standalone 的层，因此没有添加虚假的前台生命周期。恢复调度后沿用已有 Timer 检查连接；未实现操作系统级后台常驻或推送。
- `HttpTransport.send` 集中实现整次网络请求 deadline（open、upload flush、headers、完整 body），不是每一阶段重新给一份预算。deadline/显式取消会 abort 当前 request、cancel body subscription；不会 force-close 整个共享池，也没有自动重试。
- Auth/Chat/Space/Profile 的所有 HTTP 入口接入同一机制；业务 JSON/schema/error envelope 仍由原 API 处理。Chat 的上传、下载继续用 **120 秒**媒体预算，普通 JSON 和 probe 仍用各自原预算。禁止自动跟随重定向以避免凭据外带/写请求重放；3xx 由原业务层判为非预期响应。
- 其余 `media_source`、`avatar_source`、`media_stream_proxy` 未迁移，避免扩散到九份业务。WebSocket 握手使用独立 HttpClient，超时时实际关闭握手 TCP，不影响 HTTP keep-alive 池。

## GUI 与事件消费者的真实链路

- `client/lib/main.dart:219–225` 为 GUI 创建 ChatService 并调用 `chat.start()`，因此 GUI 进程确实也启动同一 EventFeed；`chat_service.dart:129/189` 分别创建/启动 EventFeed。没有第二套 GUI WebSocket 实现。
- **但聊天消息 UI 并不读取 EventFeed/WS**：`ui/chat/chat_page.dart:187–191` 的 3 秒 Timer 调 `_pollNew`，`400–458` 经 `ChatService.loadConversation` 做 HTTP 增量读取；失败 catch 后 finally 释放 `_fetching`，后续 tick 可继续。`_fetchedThrough` 只在成功合并后前移。这是原有恢复路径，不是本 PR 新增的 GUI WS 恢复。
- 用户列表 `ui/chat/users_view.dart:61` 与在线状态 `services/presence_directory.dart:111` 默认 30 秒；Space `ui/space/space_controller.dart` 默认 20 秒事件轮询。它们的 HTTP 请求经此次共同 API 传输层受总 deadline/取消约束，但没有改 GUI 调度，也没有对其新增 resume 生命周期。
- 所以本 PR 的真实 WS 断连回归证明的是 **EventFeed 事件消费者链路**；共同 HTTP 修复惠及 GUI，不能据此声称 Windows/Android GUI 的断网恢复已实机验证。完整 headless widget 回归不等于平台真机验证。

## 查询安全诊断

诊断是**进程内内存查询，非持久采集**，进程退出即丢失；没有日志上报/磁盘保存。

`HttpTransport.diagnostics` 返回进程内最多 100 条不可变快照，包含 service、phase、kind、原异常 runtime type、elapsed、UTC 时间，HTTP 错误响应另有 status。Auth/Chat/Space/Profile 都可查询：

```dart
import 'package:bb_client/services/http_transport.dart';

final recentChat = HttpTransport.diagnostics
    .where((entry) => entry.service == 'chat')
    .map((entry) => {
      'phase': entry.phase.name,
      'kind': entry.kind.name,
      'error_type': entry.errorType,
      'elapsed_ms': entry.elapsed.inMilliseconds,
      'at': entry.at.toIso8601String(),
      'status': entry.status,
    })
    .toList();
```

只保留允许的元数据；不保存异常对象/文本、请求/响应正文、headers、token、账号、URL（包括路径和查询串）。没有新建对外诊断 HTTP 接口。对用户仍为原 `AuthFailure` 的 `upstream_unavailable` / `upstream_timeout` 等稳定错误，不泄漏底层 exception 文本。显式取消沿用 `upstream_unavailable`，内部 kind 为 `cancelled`，不增加业务错误码。

## 取消的边界

- `RequestCancellation` 是 transport 层的显式取消句柄；完成后移除监听，长期 token 不持有已完成请求。业务入口此次主要用自动 deadline 取消，不新增九套业务 cancel API。
- dart:io 的 `HttpClient.openUrl` 尚未返回 request 时没有逐请求取消 DNS/连接建立的 API。调用者按 deadline/取消及时返回；迟到 request 会立即 abort，**在写入任何应用 headers/body 前停止**。连接建立另受原 connectionTimeout 约束。没有为强行中断它而关闭整个共享池或重做平台 socket 栈。
- 客户端 abort 不能撤销服务端已经接收并提交的写操作。结果仍可能不确定，须沿用原 nonce/operation 查询与业务对账。此修改未向写操作添加任何网络自动重试，也未修改既有带幂等机制的 ChatService 对账逻辑。

## TDD 实录（工作目录 client）

前置：`export PATH=/home/iiishop/flutter/bin:$PATH`。

以下每个核心 tracer 均先观测 RED，再实现 GREEN；补充边界回归用于验证同一路径。

| 命令（均使用 `flutter test --no-pub … --reporter expanded`） | RED 实际结果 | 后续 GREEN |
| --- | --- | --- |
| `test/network_deadline_test.dart --plain-name 'auth deadline'` | 预期 upstream_timeout，实际返回 LoginResult | 通过；公共 send + Auth 接入 |
| `test/network_deadline_test.dart --plain-name 'chat exposes'` | 预期诊断数 1，实际 0 | 通过；Chat 共同入口接入 |
| `test/network_deadline_test.dart --plain-name 'space exposes'` | 预期诊断数 1，实际 0 | 通过；Space 共同入口接入 |
| `test/network_deadline_test.dart --plain-name 'profile exposes'` | 预期诊断数 1，实际 0 | 通过；Profile 共同入口接入 |
| `test/event_feed_reconnect_test.dart`（当时仅 disconnect 一例） | 5 秒内没有第二次真实 WS 连接 | 通过；加入重连 Timer、退避和防重复 |
| `test/event_feed_reconnect_test.dart --plain-name 'running feed follows'` | 身份切换后等不到新连接 | 通过；已有 Timer 跟踪身份 |
| `test/network_deadline_test.dart --plain-name 'chat media has'` | 预期超时，实际返回 MediaResponse | 通过；媒体读取接入整体预算 |
| `test/network_deadline_test.dart --plain-name 'media probe deadline'` | 预期超时，实际返回 MediaProbe | 通过；probe drain 纳入总预算 |
| `test/event_feed_reconnect_test.dart --plain-name 'WebSocket handshake timeout'` | 调用已超时，但服务端 1 秒内没看到 TCP 关闭 | 通过；握手 timeout 关闭专用 client |
| `test/http_transport_test.dart --plain-name 'deadline aborts a stalled upload'` | phase 预期 sending，实际 headers | 通过；flush 上传后才进入 headers 阶段 |
| `test/event_feed_reconnect_test.dart --plain-name 'reconnect replays after an active old snapshot completes'` | 释放旧空快照后 5 秒仍没有新回放 | 通过；握手后的补跑等待旧轮询完成，再检查运行状态/epoch/身份并执行新回放 |

测试构造曾发现 HttpServer 默认 bufferOutput 导致流式测试实际仍在等 headers，初始用例意外通过；设 `bufferOutput = false` 后真实持续 body 的原漏洞才 RED，未把意外通过当修复证据。静态分析最初发现导入/格式化产生的 info；清理后重跑。

### 真实本地网络覆盖

- 原生 HttpServer/WebSocket：首次握手失败、断线重连、退避时间增长、重复 start、登录/换号/退出、dispose 取消退避与拒绝迟到握手。
- WS 断线期间生成事件，在 **30 秒周期轮询之前**靠重连立即回放；源游标继续前进且不重复追加。既有 consumer backfill 测试保持通过。
- 裸 ServerSocket：slow headers、slow body，deadline 和显式 cancel 的四组合均从服务端观测连接关闭；POST 只出现一次；停读导致的大上传被 deadline 截断并诊断为 sending。
- 持续小 chunk 的 body 不能用 idle timeout 无限延长 Auth/Chat 媒体请求；probe drain 也受完整预算。
- 原生 TCP 包装器只延迟 openUrl 的 Future 完成：deadline/取消之后让真实 request 迟到，服务端仍收到 **零条写请求**，后续请求仍能正常使用池。
- 同一 transport 的并发 HTTP 请求：取消一个正在接收 body 的请求，另一请求仍完成；下一次请求复用未被取消请求的同一 TCP 连接。
- 原生 TLS 协议不匹配保留 tls/opening，HTTP 截断 body 保留 http/body；四个 API 断连均保留 socket/opening。keep-alive 连接复用与旧 idle socket 恢复保持通过。

## 验证与未覆盖

- Linux 无 GUI：`flutter analyze --no-pub` 无问题；最终 `flutter test --no-pub --reporter json` **883 通过、14 跳过、0 失败**。定向网络/WS 三文件 **27 通过**。JSON 原始执行记录在 `/tmp/bb-network-test-results-final.jsonl`（临时文件，不入库）。
- 独立只读审查找出「旧空快照吞掉重连补跑」竞态后，新增真实 HTTP/WS RED 用例并修复，父执行会话实跑 GREEN。子执行器曾被 sandbox 的 Flutter SDK 缓存写权限挡住，那次退出 1 不是有效 RED；有效 RED/GREEN 均由主执行会话完成。
- 未运行 Windows GUI/安装包、Android 真机、Linux GUI/integration_test、真实公网隧道切换或断网演练；条件式 live/真实后端测试跳过不视为通过。
- 未实测长时间稳定连接的 30 秒退避重置、最终 30 秒上限的全时长等待、操作系统 DNS 强制取消、服务端已提交写请求的撤销（后者本就不可保证）。
- 不修改 BB-live、Clash、DSH、SurfCore；不重启线上服务，不发版、不合并。
