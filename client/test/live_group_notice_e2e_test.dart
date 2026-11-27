import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/models/group_models.dart';
import 'package:bb_client/services/auth_api_client.dart';
import 'package:bb_client/services/auth_service.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/avatar_cache.dart';
import 'package:bb_client/services/chat_api_client.dart';
import 'package:bb_client/services/chat_ledger.dart';
import 'package:bb_client/services/chat_service.dart';
import 'package:bb_client/services/conversation_access.dart';
import 'package:bb_client/services/group_api_client.dart';
import 'package:bb_client/services/group_service.dart';
import 'package:bb_client/services/media_disk_cache.dart';
import 'package:bb_client/services/media_source.dart';
import 'package:bb_client/services/session_store.dart';
import 'package:flutter_test/flutter_test.dart';

final Uint8List _png1x1 = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC',
);

class _UserHarness {
  _UserHarness({
    required this.user,
    required this.auth,
    required this.chatApi,
    required this.access,
    required this.groups,
    required this.shared,
    required this.disk,
  });

  final AuthUser user;
  final AuthService auth;
  final ChatApiClient chatApi;
  final ConversationAccessController access;
  final GroupService groups;
  final SharedConversationService shared;
  final MediaDiskCache disk;

  String get token => auth.session.identity!.token;

  Future<void> dispose() async {
    shared.dispose();
  }
}

/// Real FastAPI verification for DEA-502 against isolated bb-server (`5fa6b446`).
///
/// Opt-in: set `BB_LIVE_GROUP_SERVER_URL=http://127.0.0.1:<port>` against an
/// isolated bb-server instance. Without the env var the group is SKIPPED.
void main() {
  final String? rawUrl = Platform.environment['BB_LIVE_GROUP_SERVER_URL']
      ?.trim();
  final String? configuredUrl = (rawUrl != null && rawUrl.isNotEmpty)
      ? rawUrl
      : null;

  group(
    'live group and notice contract against isolated bb-server',
    skip: configuredUrl == null
        ? 'BB_LIVE_GROUP_SERVER_URL 未设置：未执行真实 FastAPI 群聊与通知联调（SKIP，不算 PASS）'
        : null,
    () {
      late Directory tempRoot;
      late Uri baseUri;
      late _UserHarness alice;
      late _UserHarness bob;
      late _UserHarness charlie;

      Future<_UserHarness> registerUser(String prefix) async {
        final AuthSession session = AuthSession();
        final AuthService auth = AuthService(
          api: AuthApiClient(baseUri: baseUri),
          session: session,
          store: SessionStore.atPath('${tempRoot.path}/session-$prefix.json'),
        );
        final String suffix =
            '${DateTime.now().microsecondsSinceEpoch % 10000000}';
        final AuthUser created = await auth.register(
          username: '${prefix}_$suffix',
          password: 'Secret42',
        );
        await auth.login(account: created.account, password: 'Secret42');

        final ChatApiClient chatApi = ChatApiClient(baseUri: baseUri);
        final ConversationAccessController access =
            ConversationAccessController();
        final MediaDiskCache disk = MediaDiskCache(
          directory: Directory('${tempRoot.path}/disk-$prefix'),
        );
        registerDiskCachePurger(access: access, disk: disk, serverUri: baseUri);
        final GroupService groups = GroupService(
          api: GroupApiClient(baseUri: baseUri),
          session: session,
          avatarCache: AvatarCache(
            directory: Directory('${tempRoot.path}/group-avatars-$prefix'),
          ),
          access: access,
        );
        final SharedConversationService shared = SharedConversationService(
          api: chatApi,
          session: session,
          access: access,
        );
        // Ensure ledger directory / baseline compiles with ChatService untouched.
        final ChatService chat = ChatService(
          api: chatApi,
          session: session,
          ledger: ChatLedger.inMemory(),
          cacheRoot: Directory('${tempRoot.path}/chat-$prefix'),
          webSocketHints: false,
        );
        addTearDown(chat.dispose);

        return _UserHarness(
          user: created,
          auth: auth,
          chatApi: chatApi,
          access: access,
          groups: groups,
          shared: shared,
          disk: disk,
        );
      }

      setUp(() async {
        baseUri = Uri.parse(configuredUrl!);
        tempRoot = await Directory.systemTemp.createTemp('bb_live_group_');
        alice = await registerUser('alice');
        bob = await registerUser('bob');
        charlie = await registerUser('charlie');
      });

      tearDown(() async {
        await alice.dispose();
        await bob.dispose();
        await charlie.dispose();
        if (await tempRoot.exists()) {
          await tempRoot.delete(recursive: true);
        }
      });

      test('shared HTTP+WS /events?include_groups=true cursor, notification.available (accept/reject & approve/reject), group messaging, media & revocation', () async {
        // 1. Alice creates a group inviting Bob and opens WS stream with
        // include_groups=true.
        final GroupProfile created = await alice.groups.createGroup(
          operationId: 'op-live-grp-1',
          name: 'LiveTestGroup',
          description: 'isolated server verification',
          invitees: <String>[bob.user.account],
          avatar: MediaSource(
            bytes: _png1x1,
            filename: 'g.png',
            mimeType: 'image/png',
          ),
        );
        expect(created.isOwner, isTrue);
        expect(created.groupNumber, matches(RegExp(r'^\d{8}$')));

        // 2. Bob verifies HTTP & WebSocket /events?include_groups=true share
        // the same event_id cursor for notification.available.
        final Completer<ServerEvent> bobWsEvent = Completer<ServerEvent>();
        final WebSocket bobWs = await bob.chatApi.connectAllEvents(
          bob.token,
          includeGroups: true,
        );
        final StreamSubscription<dynamic> wsSub = bobWs.listen((dynamic raw) {
          if (raw is String && !bobWsEvent.isCompleted) {
            final ServerEvent parsed = ServerEvent.fromJson(jsonDecode(raw));
            if (parsed.isNotificationAvailable) {
              bobWsEvent.complete(parsed);
            }
          }
        });
        final ServerEvent wsInviteNotice = await bobWsEvent.future.timeout(
          const Duration(seconds: 5),
        );
        await wsSub.cancel();
        await bobWs.close();

        final ServerEventPage httpInvitePage = await bob.chatApi.events(
          token: bob.token,
          afterEventId: 0,
          includeGroups: true,
        );
        final ServerEvent httpInviteNotice = httpInvitePage.items.firstWhere(
          (ServerEvent e) => e.isNotificationAvailable,
        );
        expect(httpInviteNotice.eventId, wsInviteNotice.eventId);
        expect(httpInviteNotice.notificationId, wsInviteNotice.notificationId);
        expect(
          await bob.shared.applyServerEvent(bob.user.account, httpInviteNotice),
          ServerEventDisposition.notificationAvailable,
        );

        // Continue HTTP replay from shared cursor -> no duplicate event.
        final ServerEventPage afterCursor = await bob.chatApi.events(
          token: bob.token,
          afterEventId: wsInviteNotice.eventId,
          includeGroups: true,
        );
        expect(
          afterCursor.items.where(
            (ServerEvent e) => e.eventId <= wsInviteNotice.eventId,
          ),
          isEmpty,
        );

        // 3. Bob looks up persistent notification_id -> invitation has
        // accept/reject -> mark read & accept.
        final Notice? bobNotice = await bob.groups.findNoticeById(
          wsInviteNotice.notificationId,
        );
        expect(bobNotice, isNotNull);
        expect(bobNotice!.type, 'group_invitation');
        expect(
          bobNotice.actions.map((NoticeAction a) => a.id).toList(),
          <String>['accept', 'reject'],
        );
        final Notice readNotice = await bob.groups.markNoticeRead(bobNotice.id);
        expect(readNotice.read, isTrue);
        final Notice acceptedNotice = await bob.groups.executeNoticeAction(
          notificationId: bobNotice.id,
          actionId: 'accept',
        );
        expect(acceptedNotice.state, NoticeState.processed);

        // Bob sees the group via /chat/conversations with its group_number.
        final SharedConversationPage bobChats = await bob.shared
            .listSharedConversations();
        final GroupConversationItem bobGroupItem = bobChats.items
            .whereType<GroupConversationItem>()
            .single;
        expect(bobGroupItem.groupNumber, created.groupNumber);

        // 4. Charlie looks up group by 8-digit group_number and applies.
        final GroupProfile foundByCharlie = await charlie.groups.findGroup(
          created.groupNumber,
        );
        expect(foundByCharlie.role, isNull);
        expect(foundByCharlie.canApply, isTrue);
        await charlie.groups.applyToGroup(
          conversation: foundByCharlie.conversation,
        );

        // Alice receives notification.available on HTTP /events?include_groups=true,
        // inspects application actions [approve, reject], and approves.
        final ServerEventPage aliceEvents = await alice.chatApi.events(
          token: alice.token,
          includeGroups: true,
        );
        final ServerEvent aliceAppEvent = aliceEvents.items.lastWhere(
          (ServerEvent e) => e.isNotificationAvailable,
        );
        final Notice? aliceNotice = await alice.groups.findNoticeById(
          aliceAppEvent.notificationId,
        );
        expect(aliceNotice, isNotNull);
        expect(aliceNotice!.type, 'group_application');
        expect(
          aliceNotice.actions.map((NoticeAction a) => a.id).toList(),
          <String>['approve', 'reject'],
        );
        final Notice approvedNotice = await alice.groups.executeNoticeAction(
          notificationId: aliceNotice.id,
          actionId: 'approve',
        );
        expect(approvedNotice.state, NoticeState.processed);

        // 5. Alice uploads media & sends text+media in group; Charlie reads
        // history and caches media, then Alice removes Charlie -> access
        // revoked + disk cache purged.
        final SendOutcome bodyOutcome = await alice.shared.sendGroupBodyOutcome(
          conversation: created.conversation,
          operationId: 'op-live-msg-1',
          content: <OutgoingPart>[
            const OutgoingText('hello real server group'),
            OutgoingImage(
              MediaSource(
                bytes: _png1x1,
                filename: 'photo.png',
                mimeType: 'image/png',
              ),
            ),
          ],
        );
        expect(bodyOutcome.failure, isNull);
        final String sentMediaId = bodyOutcome.message!.parts
            .whereType<ImagePart>()
            .single
            .mediaId;
        final SendOutcome attOutcome = await alice.shared
            .sendGroupAttachmentOutcome(
              conversation: created.conversation,
              operationId: 'op-live-att-1',
              attachment: OutgoingAttachment(
                source: MediaSource(
                  bytes: Uint8List.fromList(utf8.encode('hello document')),
                  filename: 'doc.txt',
                  mimeType: 'text/plain',
                ),
              ),
            );
        expect(attOutcome.failure, isNull);

        final MessagePage charlieHistory = await charlie.shared
            .loadConversationHistory(conversation: created.conversation);
        expect(
          charlieHistory.items.any(
            (ChatMessage m) =>
                m.kind == ChatMessageKind.system &&
                (m.systemText?.isNotEmpty ?? false),
          ),
          isTrue,
        );
        final Uint8List downloadedBytes = await charlie.shared
            .loadScopedMediaBytes(
              conversation: created.conversation,
              mediaId: sentMediaId,
            );
        expect(downloadedBytes, isNotEmpty);

        final String tag = ConversationAccessController.diskScopeTag(
          server: baseUri.toString(),
          account: charlie.user.account,
          conversationId: created.conversation.id,
        );
        final String diskKey = 'chat-original-$tag|$sentMediaId';
        await charlie.disk.write(diskKey, downloadedBytes);
        expect(await charlie.disk.read(diskKey), isNotNull);

        // Remove Charlie -> Charlie receives conversation.access_changed(active: false).
        await alice.groups.removeGroupMember(
          conversation: created.conversation,
          account: charlie.user.account,
        );
        final ServerEventPage charlieReplay = await charlie.chatApi.events(
          token: charlie.token,
          includeGroups: true,
        );
        final ServerEvent revokedEvent = charlieReplay.items.lastWhere(
          (ServerEvent e) => e.isAccessChanged,
        );
        expect(
          await charlie.shared.applyServerEvent(
            charlie.user.account,
            revokedEvent,
          ),
          ServerEventDisposition.groupAccessRevoked,
        );
        expect(
          charlie.access.isRevoked(
            charlie.user.account,
            created.conversation.id,
          ),
          isTrue,
        );
        expect(await charlie.disk.read(diskKey), isNull);

        // 6. Verify reject flows (invite reject & application reject).
        final GroupProfile group2 = await alice.groups.createGroup(
          operationId: 'op-live-grp-2',
          name: 'RejectFlowGroup',
          invitees: <String>[charlie.user.account],
        );
        final ServerEventPage charlieNoticeEvents = await charlie.chatApi
            .events(token: charlie.token, includeGroups: true);
        final ServerEvent charlieInviteEvent = charlieNoticeEvents.items
            .lastWhere((ServerEvent e) => e.isNotificationAvailable);
        final Notice? inviteToReject = await charlie.groups.findNoticeById(
          charlieInviteEvent.notificationId,
        );
        expect(
          inviteToReject?.actions.map((NoticeAction a) => a.id).toList(),
          <String>['accept', 'reject'],
        );
        final Notice rejectedInvite = await charlie.groups.executeNoticeAction(
          notificationId: inviteToReject!.id,
          actionId: 'reject',
        );
        expect(rejectedInvite.state, NoticeState.processed);

        await charlie.groups.applyToGroup(conversation: group2.conversation);
        final ServerEventPage aliceRejectEvents = await alice.chatApi.events(
          token: alice.token,
          includeGroups: true,
        );
        final ServerEvent aliceApp2 = aliceRejectEvents.items.lastWhere(
          (ServerEvent e) => e.isNotificationAvailable,
        );
        final Notice? appToReject = await alice.groups.findNoticeById(
          aliceApp2.notificationId,
        );
        expect(
          appToReject?.actions.map((NoticeAction a) => a.id).toList(),
          <String>['approve', 'reject'],
        );
        final Notice rejectedApp = await alice.groups.executeNoticeAction(
          notificationId: appToReject!.id,
          actionId: 'reject',
        );
        expect(rejectedApp.state, NoticeState.processed);
      });
    },
  );
}
