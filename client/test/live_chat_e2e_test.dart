import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/services/auth_api_client.dart';
import 'package:bb_client/services/auth_service.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/chat_api_client.dart';
import 'package:bb_client/services/chat_ledger.dart';
import 'package:bb_client/services/chat_service.dart';
import 'package:bb_client/services/media_source.dart';
import 'package:bb_client/services/session_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// Real FastAPI chain for STEP-3 chat.
///
/// Opt-in: start `bb-server` yourself, then run
/// `BB_LIVE_SERVER_URL=http://127.0.0.1:8171 flutter test test/live_chat_e2e_test.dart`.
/// Without the environment variable the whole group is SKIPPED, not PASS.
void main() {
  final String? configured = Platform.environment['BB_LIVE_SERVER_URL'];
  final String? rawBase = (configured != null && configured.trim().isNotEmpty)
      ? configured.trim()
      : null;

  group(
    'live chat chain',
    skip: rawBase == null
        ? 'BB_LIVE_SERVER_URL 未设置：未执行真实 FastAPI 聊天链路（SKIP，不算 PASS）'
        : null,
    () {
      final Uri baseUri = Uri.parse(rawBase ?? 'http://127.0.0.1:8171');
      late Directory root;
      late AuthService authA;
      late AuthService authB;
      late AuthService authC;
      late ChatService chatA;
      late ChatService chatB;
      late ChatService chatC;
      late AuthUser userA;
      late AuthUser userB;
      late AuthUser userC;

      Future<AuthUser> createAccount(String label) async {
        final AuthApiClient api = AuthApiClient(baseUri: baseUri);
        final AuthService service = AuthService(
          api: api,
          session: AuthSession(),
          store: SessionStore.atPath('${root.path}/session-$label.json'),
        );
        final String username =
            '${label}_${DateTime.now().microsecondsSinceEpoch % 100000000}';
        final AuthUser registered = await service.register(
          username: username,
          password: 'Secret42',
        );
        await service.login(account: registered.account, password: 'Secret42');
        return registered;
      }

      ChatService newChat(AuthService auth, String label) {
        return ChatService(
          api: ChatApiClient(baseUri: baseUri),
          session: auth.session,
          ledger: ChatLedger.atPath('${root.path}/ledger-$label.json'),
          cacheRoot: Directory('${root.path}/cache-$label'),
          eventPollInterval: const Duration(milliseconds: 300),
          webSocketHints: false,
        );
      }

      setUpAll(() async {
        root = await Directory.systemTemp.createTemp('bb-live-chat-');
        authA = AuthService(
          api: AuthApiClient(baseUri: baseUri),
          session: AuthSession(),
          store: SessionStore.atPath('${root.path}/session-a.json'),
        );
        final String usernameA =
            'a_${DateTime.now().microsecondsSinceEpoch % 100000000}';
        userA = await authA.register(
          username: 'chat_a_$usernameA',
          password: 'Secret42',
        );
        await authA.login(account: userA.account, password: 'Secret42');
        userB = await createAccount('b');
        authB = AuthService(
          api: AuthApiClient(baseUri: baseUri),
          session: AuthSession(),
          store: SessionStore.atPath('${root.path}/session-b.json'),
        );
        await authB.login(account: userB.account, password: 'Secret42');
        userC = await createAccount('c');
        authC = AuthService(
          api: AuthApiClient(baseUri: baseUri),
          session: AuthSession(),
          store: SessionStore.atPath('${root.path}/session-c.json'),
        );
        await authC.login(account: userC.account, password: 'Secret42');
        chatA = newChat(authA, 'a');
        chatB = newChat(authB, 'b');
        chatC = newChat(authC, 'c');
        chatA.start();
        chatB.start();
        chatC.start();
      });

      tearDownAll(() async {
        await chatA.dispose();
        await chatB.dispose();
        await chatC.dispose();
        if (await root.exists()) {
          await root.delete(recursive: true);
        }
      });

      test(
        'ordered text/image send, real blocks, receipts, ACK gap and ACL',
        () async {
          final Uint8List red = base64Decode(_redPng);
          final Uint8List green = base64Decode(_greenPng);
          final SendOutcome sent = await chatA.sendBody(
            targetAccount: userB.account,
            content: <OutgoingPart>[
              const OutgoingText('文字A'),
              OutgoingImage(
                MediaSource(
                  bytes: red,
                  filename: 'red.png',
                  mimeType: 'image/png',
                ),
              ),
              const OutgoingText('文字B'),
              OutgoingImage(
                MediaSource(
                  bytes: green,
                  filename: 'green.png',
                  mimeType: 'image/png',
                ),
              ),
            ],
          );
          expect(sent.message, isNotNull, reason: sent.failure?.message);
          final ChatMessage message = sent.message!;
          expect(message.kind, ChatMessageKind.body);
          expect(message.parts.length, 4);
          expect((message.parts[0] as TextPart).text, '文字A');
          expect((message.parts[1] as ImagePart).mediaId, isNotEmpty);
          expect((message.parts[2] as TextPart).text, '文字B');
          expect((message.parts[3] as ImagePart).mediaId, isNotEmpty);
          expect(
            (message.parts[1] as ImagePart).mediaId,
            isNot((message.parts[3] as ImagePart).mediaId),
            reason: 'two distinct images must stay distinct and ordered',
          );

          final UserPage users = await chatB.listUsers();
          final ChatUser rowA = users.items.firstWhere(
            (ChatUser user) => user.account == userA.account,
          );
          expect(rowA.presence, Presence.online);
          expect(rowA.lastMessage, isNotNull);
          expect(rowA.lastMessage!.senderAccount, userA.account);
          expect(rowA.lastMessage!.previewBody, contains('文字A'));
          final ChatUser rowC = users.items.firstWhere(
            (ChatUser user) => user.account == userC.account,
          );
          expect(rowC.lastMessage, isNull);
          expect(
            users.items.any((ChatUser u) => u.account == userB.account),
            isFalse,
          );

          final VisibleMessagePage read = await chatB.readMessages(
            peerAccount: userA.account,
            consumerSession: 'consumer-order',
          );
          expect(read.items, hasLength(1));
          final VisibleMessage visible = read.items.single;
          expect(visible.presentation, isNotNull);
          expect(visible.blocks.length, 4);
          expect((visible.blocks[0] as VisibleTextBlock).text, '文字A');
          expect(
            (visible.blocks[1] as VisibleImageBlock).mimeType,
            'image/png',
          );
          expect(
            base64Decode((visible.blocks[1] as VisibleImageBlock).data),
            red,
          );
          expect((visible.blocks[2] as VisibleTextBlock).text, '文字B');
          expect(
            base64Decode((visible.blocks[3] as VisibleImageBlock).data),
            green,
          );

          // ACK before any confirmation is a gap, never a silent advance.
          await expectLater(
            chatB.ackMessages(
              peerAccount: userA.account,
              consumerSession: 'consumer-order',
              throughPosition: 1,
            ),
            throwsA(
              isA<AuthFailure>().having(
                (AuthFailure f) => f.code,
                'code',
                'consumption_gap',
              ),
            ),
          );
          final List<String> confirmed = await chatB.confirmPresentation(
            consumerSession: 'consumer-order',
            attemptId: 'attempt-1',
            requestDigest: 'digest-1',
            receiptIds: <String>[visible.presentation!.receiptId],
          );
          expect(confirmed, <String>[visible.presentation!.receiptId]);
          final int consumed = await chatB.ackMessages(
            peerAccount: userA.account,
            consumerSession: 'consumer-order',
            throughPosition: 1,
          );
          expect(consumed, 1);
          expect(
            await chatB.ackMessages(
              peerAccount: userA.account,
              consumerSession: 'consumer-order',
              throughPosition: 1,
            ),
            1,
          );

          // Third account cannot read the pair or its media.
          final MessagePage thirdView = await chatC.loadConversation(
            peerAccount: userA.account,
          );
          expect(thirdView.items, isEmpty);
          await expectLater(
            chatC.mediaBytes((message.parts[1] as ImagePart).mediaId),
            throwsA(
              isA<AuthFailure>().having(
                (AuthFailure f) => f.status,
                'status',
                404,
              ),
            ),
          );

          // Retry with the same operation id is the same message.
          final SendOutcome replay = await chatA.sendBody(
            targetAccount: userB.account,
            operationId: sent.operationId,
            content: <OutgoingPart>[
              const OutgoingText('文字A'),
              OutgoingImage(
                MediaSource(
                  bytes: red,
                  filename: 'red.png',
                  mimeType: 'image/png',
                ),
              ),
              const OutgoingText('文字B'),
              OutgoingImage(
                MediaSource(
                  bytes: green,
                  filename: 'green.png',
                  mimeType: 'image/png',
                ),
              ),
            ],
          );
          expect(replay.message!.id, message.id);

          // Changed content under the same operation id is a conflict.
          await expectLater(
            chatA.sendBody(
              targetAccount: userB.account,
              operationId: sent.operationId,
              content: <OutgoingPart>[const OutgoingText('changed')],
            ),
            throwsA(
              isA<AuthFailure>().having(
                (AuthFailure f) => f.status,
                'status',
                409,
              ),
            ),
          );
        },
      );

      test('attachment metadata only, async download, durable event and video cover', () async {
        await chatB.subscribeEvents(
          consumerSession: 'consumer-dl',
          peerAccount: userA.account,
        );

        final Directory media = Directory('${root.path}/videos')
          ..createSync(recursive: true);
        final String videoPath = '${media.path}/clip.mp4';
        final ProcessResult generated = await Process.run('ffmpeg', <String>[
          '-y',
          '-f',
          'lavfi',
          '-i',
          'color=c=purple:s=64x64:d=1',
          '-pix_fmt',
          'yuv420p',
          '-movflags',
          '+faststart',
          videoPath,
        ]);
        expect(generated.exitCode, 0, reason: 'ffmpeg fixture creation');
        final OutgoingAttachment video = OutgoingAttachment(
          source: MediaSource(
            path: videoPath,
            filename: 'clip.mp4',
            mimeType: 'video/mp4',
          ),
        );
        final SendOutcome videoSent = await chatA.sendAttachment(
          targetAccount: userB.account,
          attachment: video,
        );
        expect(
          videoSent.message,
          isNotNull,
          reason: videoSent.failure?.message,
        );
        final Attachment videoMeta = videoSent.message!.attachment!;
        expect(videoMeta.kind, AttachmentKind.video);
        expect(videoMeta.coverMediaId, isNotNull);

        final Uint8List pdfBytes = Uint8List.fromList(
          utf8.encode('%PDF-1.4\n1 0 obj<<>>endobj\ntrailer<<>>\n%%EOF\n'),
        );
        final SendOutcome pdfSent = await chatA.sendAttachment(
          targetAccount: userB.account,
          attachment: OutgoingAttachment(
            source: MediaSource(
              bytes: pdfBytes,
              filename: '../../unsafe name.pdf',
              mimeType: 'application/pdf',
            ),
          ),
        );
        expect(pdfSent.message, isNotNull, reason: pdfSent.failure?.message);
        final Attachment pdf = pdfSent.message!.attachment!;
        expect(pdf.filename.contains('/'), isFalse);

        final VisibleMessagePage read = await chatB.readMessages(
          peerAccount: userA.account,
          consumerSession: 'consumer-dl',
        );
        final VisibleMessage videoVisible = read.items.firstWhere(
          (VisibleMessage item) => item.message.id == videoSent.message!.id,
        );
        expect(videoVisible.blocks.first, isA<VisibleTextBlock>());
        expect(
          videoVisible.blocks.any(
            (VisibleBlock block) => block is VisibleImageBlock,
          ),
          isTrue,
          reason: 'the real video cover is an image block',
        );
        final VisibleMessage pdfVisible = read.items.firstWhere(
          (VisibleMessage item) => item.message.id == pdfSent.message!.id,
        );
        expect(
          pdfVisible.blocks.whereType<VisibleImageBlock>(),
          isEmpty,
          reason: 'attachment originals are not downloaded for a read',
        );

        final DownloadTask started = await chatB.downloads.start(
          operationId: 'dl-pdf-1',
          consumerSession: 'consumer-dl',
          mediaId: pdf.mediaId,
        );
        expect(
          started.status,
          anyOf(
            DownloadStatus.pending,
            DownloadStatus.running,
            DownloadStatus.succeeded,
          ),
        );
        DownloadTask task = started;
        final DateTime deadline = DateTime.now().add(
          const Duration(seconds: 20),
        );
        while (!task.status.terminal && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          task = (await chatB.downloads.get(
            taskId: task.taskId,
            consumerSession: 'consumer-dl',
          ))!;
        }
        expect(task.status, DownloadStatus.succeeded);
        expect(task.actualPath, isNotNull);
        expect(await File(task.actualPath!).readAsBytes(), pdfBytes);
        expect(
          task.actualPath!,
          startsWith('${root.path}/cache-b/'),
          reason: 'downloads stay inside the client cache',
        );

        final DownloadTask again = await chatB.downloads.start(
          operationId: 'dl-pdf-1',
          consumerSession: 'consumer-dl',
          mediaId: pdf.mediaId,
        );
        expect(again.taskId, task.taskId);

        LocalEventPage events = await chatB.readEvents(
          consumerSession: 'consumer-dl',
          afterCursor: 0,
        );
        final DateTime eventDeadline = DateTime.now().add(
          const Duration(seconds: 10),
        );
        while (events.items.isEmpty && DateTime.now().isBefore(eventDeadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          events = await chatB.readEvents(
            consumerSession: 'consumer-dl',
            afterCursor: 0,
          );
        }
        expect(
          events.items.any(
            (LocalEventEntry entry) =>
                entry.event.type == LocalEventType.downloadSucceeded &&
                entry.event.taskId == task.taskId,
          ),
          isTrue,
        );
        final LocalEventPage waited = await chatB.waitEvents(
          consumerSession: 'consumer-dl',
          afterCursor: 0,
          timeoutSeconds: 30,
        );
        expect(waited.reason, 'events');
        expect(waited.items, isNotEmpty);
      });

      test('wait returns an arriving message before timeout', () async {
        final MessagePage before = await chatB.loadConversation(
          peerAccount: userA.account,
        );
        final int seen = before.nextPosition;
        final Future<VisibleMessagePage> waiting = chatB.waitMessages(
          peerAccount: userA.account,
          consumerSession: 'consumer-wait',
          seenPosition: seen,
          timeoutSeconds: 30,
        );
        await Future<void>.delayed(const Duration(milliseconds: 400));
        final SendOutcome sent = await chatA.sendBody(
          targetAccount: userB.account,
          content: <OutgoingPart>[const OutgoingText('等待中的新消息')],
        );
        expect(sent.message, isNotNull);
        final VisibleMessagePage result = await waiting;
        expect(result.reason, 'messages');
        expect(result.items, isNotEmpty);
        expect(
          result.items.any(
            (VisibleMessage item) =>
                (item.message.parts.first as TextPart).text == '等待中的新消息',
          ),
          isTrue,
        );
        final VisibleMessagePage backlog = await chatB.waitMessages(
          peerAccount: userA.account,
          consumerSession: 'consumer-wait-2',
          seenPosition: 0,
          timeoutSeconds: 30,
        );
        expect(backlog.reason, 'messages');
        expect(backlog.items, isNotEmpty);
      });
    },
  );
}

const String _redPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAFElEQVR4nGP8z8Dwn4GBgYGJAQoAHxcCAk+Uzr4AAAAASUVORK5CYII=';
const String _greenPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAFElEQVR4nGNk+M/wn4GBgYGJAQoAHhgCAu/QjeYAAAAASUVORK5CYII=';
