import 'dart:convert';
import 'dart:typed_data';

import 'package:bb_client/app.dart';
import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/models/group_models.dart';
import 'package:bb_client/models/profile_models.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/avatar_cache.dart';
import 'package:bb_client/services/chat_api_client.dart';
import 'package:bb_client/services/conversation_access.dart';
import 'package:bb_client/services/group_api_client.dart';
import 'package:bb_client/services/group_service.dart';
import 'package:bb_client/ui/chat/chat_composer.dart';
import 'package:bb_client/ui/chat/chat_header.dart';
import 'package:bb_client/ui/chat/chat_page.dart';
import 'package:bb_client/ui/chat/media_viewer.dart';
import 'package:bb_client/ui/chat/message_bubble.dart';
import 'package:bb_client/ui/profile/group_profile_panel.dart';
import 'package:bb_client/ui/profile/profile_artwork.dart';
import 'package:bb_client/ui/profile/profile_details.dart';
import 'package:bb_client/ui/profile/profile_panel.dart';
import 'package:bb_client/ui/widgets/profile_avatar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/avatar_fixtures.dart';
import 'support/fake_chat_service.dart';
import 'support/fake_profile_gateway.dart';

const AuthUser _self = AuthUser(account: '10000001', username: 'alice');
const ChatUser _bob = ChatUser(
  account: '10000002',
  username: '重名成员',
  avatarUrl: '/avatars/10000002.png',
  avatarVersion: 'v-bob',
  presence: Presence.online,
);
const ChatUser _carol = ChatUser(
  account: '10000003',
  username: '重名成员',
  avatarUrl: '/avatars/10000003.png',
  avatarVersion: 'v-carol',
  presence: Presence.offline,
);

final String _groupId = 'group:${'a1b2c3d4' * 4}';

GroupConversationItem _group() => GroupConversationItem(
  conversation: ConversationRef.group(_groupId),
  groupNumber: '20000001',
  displayName: '测试群聊',
  lastMessage: null,
  lastActivityAt: DateTime.utc(2026, 11, 28, 12),
  latestPosition: 3,
  historyThrough: 3,
  membershipRevision: 1,
  avatarUrl: '',
  avatarVersion: 'gv0',
);

class _FakeGroupApiClient extends GroupApiClient {
  _FakeGroupApiClient() : super(baseUri: Uri.parse('http://127.0.0.1:1'));

  @override
  Future<GroupProfile> findGroup({
    required String token,
    required String groupNumber,
  }) async {
    return GroupProfile(
      conversation: ConversationRef.group(_groupId),
      groupNumber: groupNumber,
      name: '测试群聊',
      description: '群聊简介',
      avatarUrl: '',
      avatarVersion: 'gv0',
      status: GroupStatus.active,
      role: GroupRole.owner,
      canInvite: true,
      allowMemberInvites: false,
    );
  }

  @override
  Future<GroupMemberPage> listGroupMembers({
    required String token,
    required ConversationRef conversation,
    String afterAccount = '',
    int limit = 50,
    bool includeCounts = false,
  }) async {
    return GroupMemberPage(
      items: const <GroupMember>[],
      counts: includeCounts
          ? const GroupMemberCounts(online: 2, total: 3)
          : null,
    );
  }
}

class _FakeSharedConversationService extends SharedConversationService {
  _FakeSharedConversationService({
    required this.messages,
    required super.session,
    required super.access,
  }) : super(api: ChatApiClient(baseUri: Uri.parse('http://127.0.0.1:1')));

  final List<ChatMessage> messages;

  @override
  Future<MessagePage> loadConversationHistory({
    required ConversationRef conversation,
    int? afterPosition,
    int? beforePosition,
    int limit = 100,
    AuthIdentity? captured,
  }) async {
    if (afterPosition != null && afterPosition > 0) {
      return MessagePage(
        items: const <ChatMessage>[],
        nextPosition: afterPosition,
        hasMore: false,
      );
    }
    return MessagePage(
      items: messages,
      nextPosition: messages.isEmpty ? 0 : messages.last.position,
      hasMore: false,
    );
  }
}

void main() {
  final Uint8List customCoverA = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
  );

  FakeProfileGateway buildProfiles() {
    final FakeProfileGateway gateway = FakeProfileGateway();
    gateway.profiles[_self.account] = const Profile(
      account: '10000001',
      username: 'alice',
      signature: 'self signature',
      avatarUrl: '/avatars/10000001.png',
      avatarVersion: 'v-self',
    );
    gateway.profiles[_bob.account] = const Profile(
      account: '10000002',
      username: '重名成员',
      signature: '我是二号成员',
      avatarUrl: '/avatars/10000002.png',
      avatarVersion: 'v-bob',
    );
    gateway.profiles[_carol.account] = const Profile(
      account: '10000003',
      username: '重名成员',
      signature: '我是三号成员',
      avatarUrl: '/avatars/10000003.png',
      avatarVersion: 'v-carol',
    );
    gateway.avatars[_self.account] = selfIdenticon;
    gateway.avatars[_bob.account] = peerIdenticon;
    gateway.avatars[_carol.account] = peerReplacedAvatar;
    gateway.covers[_bob.account] = CoverImage(
      account: _bob.account,
      bytes: customCoverA,
      version: 'sha256-${'a' * 64}',
      mimeType: 'image/png',
      isDefault: false,
    );
    return gateway;
  }

  Finder coverMemoryImages() => find.descendant(
    of: find.byKey(ProfileSeaCover.coverKey),
    matching: find.byType(Image),
  );

  MemoryImage shownCover(WidgetTester tester) =>
      tester.widget<Image>(coverMemoryImages().first).image as MemoryImage;

  testWidgets(
    'direct chat message avatar and header avatar open the same peer profile with cover and no edit controls',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final FakeProfileGateway profiles = buildProfiles();
      final DateTime base = DateTime.utc(2026, 11, 28, 10);
      final ChatMessage msg = ChatMessage(
        id: 'dm-1',
        position: 1,
        senderAccount: _bob.account,
        senderUsername: _bob.username,
        targetAccount: _self.account,
        createdAt: base,
        kind: ChatMessageKind.body,
        parts: const <MessagePart>[TextPart('私聊问候')],
      );
      final FakeChatService chat = FakeChatService(
        self: _self,
        users: const <ChatUser>[_bob],
        conversations: <String, List<ChatMessage>>{
          _bob.account: <ChatMessage>[msg],
        },
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: ChatPage(peer: _bob, chat: chat, profile: profiles),
        ),
      );
      await tester.pumpAndSettle();

      // 1) Tap left-side message avatar.
      await tester.tap(find.byKey(MessageBubble.avatarKeyFor(msg.identity)));
      await tester.pumpAndSettle();

      expect(find.byType(PersonProfilePanel), findsOneWidget);
      expect(find.text('BB号 ${_bob.account}'), findsOneWidget);
      expect(find.text('我是二号成员'), findsOneWidget);
      expect(shownCover(tester).bytes, customCoverA);
      expect(find.byKey(ProfilePanel.editProfileKey), findsNothing);
      expect(find.byKey(ProfilePanel.changeCoverKey), findsNothing);
      expect(find.byKey(ProfilePanel.editNicknameKey), findsNothing);

      await tester.tap(find.byType(CloseButton));
      await tester.pumpAndSettle();
      expect(find.byType(PersonProfilePanel), findsNothing);

      // 2) Tap direct-chat header avatar -> same peer profile surface.
      await tester.tap(find.byKey(ChatHeader.headerProfileKey));
      await tester.pumpAndSettle();

      expect(find.byType(PersonProfilePanel), findsOneWidget);
      expect(find.text('BB号 ${_bob.account}'), findsOneWidget);
      expect(shownCover(tester).bytes, customCoverA);
    },
  );

  for (final Size viewport in const <Size>[Size(390, 844), Size(1280, 900)]) {
    testWidgets(
      'group chat duplicate-name senders open their own profiles and covers while header keeps group profile ($viewport)',
      (WidgetTester tester) async {
        tester.view.physicalSize = viewport;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        final FakeProfileGateway profiles = buildProfiles();
        final DateTime base = DateTime.utc(2026, 11, 28, 10);
        final ChatMessage m1 = ChatMessage(
          id: 'gm-1',
          position: 1,
          senderAccount: _bob.account,
          senderUsername: '重名成员',
          conversation: ConversationRef.group(_groupId),
          createdAt: base,
          kind: ChatMessageKind.body,
          parts: const <MessagePart>[TextPart('来自二号')],
        );
        final ChatMessage m2 = ChatMessage(
          id: 'gm-2',
          position: 2,
          senderAccount: _carol.account,
          senderUsername: '重名成员',
          conversation: ConversationRef.group(_groupId),
          createdAt: base.add(const Duration(seconds: 5)),
          kind: ChatMessageKind.body,
          parts: const <MessagePart>[TextPart('来自三号')],
        );
        final ChatMessage mSelf = ChatMessage(
          id: 'gm-3',
          position: 3,
          senderAccount: _self.account,
          senderUsername: _self.username,
          conversation: ConversationRef.group(_groupId),
          createdAt: base.add(const Duration(seconds: 10)),
          kind: ChatMessageKind.body,
          parts: const <MessagePart>[TextPart('我自己的消息')],
        );

        final FakeChatService chat = FakeChatService(
          self: _self,
          users: const <ChatUser>[_bob, _carol],
        );
        final AuthSession session = AuthSession()
          ..establish(token: 'tok-alice', user: _self);
        final ConversationAccessController access =
            ConversationAccessController();
        final GroupService groups = GroupService(
          api: _FakeGroupApiClient(),
          session: session,
          avatarCache: AvatarCache(),
          access: access,
        );
        final _FakeSharedConversationService shared =
            _FakeSharedConversationService(
              messages: <ChatMessage>[m1, m2, mSelf],
              session: session,
              access: access,
            );

        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: ChatPage(
              group: _group(),
              chat: chat,
              profile: profiles,
              groups: groups,
              shared: shared,
              embedded: viewport.width >= 900,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Own message carries no left-side avatar.
        expect(
          find.byKey(MessageBubble.avatarKeyFor(mSelf.identity)),
          findsNothing,
        );

        // Tap first duplicate-name sender -> account 10000002 with custom cover.
        await tester.tap(find.byKey(MessageBubble.avatarKeyFor(m1.identity)));
        await tester.pumpAndSettle();
        expect(find.byType(PersonProfilePanel), findsOneWidget);
        expect(find.byType(GroupProfilePanel), findsNothing);
        expect(find.text('BB号 ${_bob.account}'), findsOneWidget);
        expect(find.text('我是二号成员'), findsOneWidget);
        expect(shownCover(tester).bytes, customCoverA);

        await tester.tap(find.byType(CloseButton));
        await tester.pumpAndSettle();

        // Tap second duplicate-name sender -> account 10000003 with default cover (no cross-user leak).
        await tester.tap(find.byKey(MessageBubble.avatarKeyFor(m2.identity)));
        await tester.pumpAndSettle();
        expect(find.byType(PersonProfilePanel), findsOneWidget);
        expect(find.byType(GroupProfilePanel), findsNothing);
        expect(find.text('BB号 ${_carol.account}'), findsOneWidget);
        expect(find.text('我是三号成员'), findsOneWidget);
        expect(find.byKey(ProfileSeaCover.defaultCoverKey), findsOneWidget);

        await tester.tap(find.byType(CloseButton));
        await tester.pumpAndSettle();

        // Tap group header avatar -> still opens GroupProfilePanel, not PersonProfilePanel.
        await tester.tap(find.byKey(ChatHeader.headerProfileKey));
        await tester.pumpAndSettle();
        expect(find.byType(GroupProfilePanel), findsOneWidget);
        expect(find.byType(PersonProfilePanel), findsNothing);
        expect(
          find.descendant(
            of: find.byType(GroupProfilePanel),
            matching: find.text('群号 20000001'),
          ),
          findsOneWidget,
        );
      },
    );
  }

  testWidgets(
    'returning from sender profile preserves the historic scroll position',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final FakeProfileGateway profiles = buildProfiles();
      final DateTime base = DateTime.utc(2026, 11, 28, 9);
      final List<ChatMessage> thread = <ChatMessage>[
        for (int i = 1; i <= 60; i += 1)
          ChatMessage(
            id: 'h$i',
            position: i,
            senderAccount: i.isOdd ? _bob.account : _self.account,
            senderUsername: i.isOdd ? _bob.username : _self.username,
            targetAccount: i.isOdd ? _self.account : _bob.account,
            createdAt: base.add(Duration(minutes: i * 10)),
            kind: ChatMessageKind.body,
            parts: <MessagePart>[TextPart('历史第 $i 条消息内容')],
          ),
      ];
      final FakeChatService chat = FakeChatService(
        self: _self,
        users: const <ChatUser>[_bob],
        conversations: <String, List<ChatMessage>>{_bob.account: thread},
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: ChatPage(peer: _bob, chat: chat, profile: profiles),
        ),
      );
      await tester.pumpAndSettle();

      final ListView list = tester.widget<ListView>(
        find.byKey(ChatPage.listKey),
      );
      final ScrollController controller = list.controller!;
      final double maxBefore = controller.position.maxScrollExtent;
      expect(
        controller.position.pixels,
        moreOrLessEquals(maxBefore, epsilon: 1),
      );

      // Scroll up into history so older message h15 is on screen.
      for (int i = 0; i < 6; i += 1) {
        await tester.drag(find.byKey(ChatPage.listKey), const Offset(0, 450));
        await tester.pump();
      }
      await tester.pumpAndSettle();

      final double offsetBeforeTap = controller.position.pixels;
      expect(offsetBeforeTap, lessThan(maxBefore - 100));

      // Find any currently visible incoming message avatar in the viewport.
      final Finder visibleBobAvatars = find.byWidgetPredicate(
        (Widget w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith(
              'chat-message-avatar-h',
            ),
      );
      expect(visibleBobAvatars, findsWidgets);
      await tester.tap(visibleBobAvatars.first);
      await tester.pumpAndSettle();

      expect(find.byType(PersonProfilePanel), findsOneWidget);
      expect(find.text('BB号 ${_bob.account}'), findsOneWidget);

      await tester.tap(find.byType(CloseButton));
      await tester.pumpAndSettle();

      expect(find.byType(PersonProfilePanel), findsNothing);
      expect(
        controller.position.pixels,
        moreOrLessEquals(offsetBeforeTap, epsilon: 0.5),
        reason: 'returning from sender profile must restore the exact scroll offset',
      );
    },
  );

  testWidgets(
    'media tap, text body, and failed retry gestures stay isolated from message avatar tap',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final FakeProfileGateway profiles = buildProfiles();
      final DateTime base = DateTime.utc(2026, 11, 28, 10);
      final ChatMessage photoMsg = ChatMessage(
        id: 'pm-1',
        position: 1,
        senderAccount: _bob.account,
        senderUsername: _bob.username,
        targetAccount: _self.account,
        createdAt: base,
        kind: ChatMessageKind.body,
        parts: const <MessagePart>[ImagePart('media-photo-1')],
      );
      final ChatMessage textMsg = ChatMessage(
        id: 'tm-1',
        position: 2,
        senderAccount: _carol.account,
        senderUsername: _carol.username,
        targetAccount: _self.account,
        createdAt: base.add(const Duration(minutes: 6)),
        kind: ChatMessageKind.body,
        parts: const <MessagePart>[TextPart('可复制的正文内容')],
      );
      final FakeChatService chat = FakeChatService(
        self: _self,
        users: const <ChatUser>[_bob, _carol],
        conversations: <String, List<ChatMessage>>{
          _bob.account: <ChatMessage>[photoMsg, textMsg],
        },
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: ChatPage(peer: _bob, chat: chat, profile: profiles),
        ),
      );
      await tester.pumpAndSettle();

      // Tapping the photo opens MediaViewer, NOT PersonProfilePanel.
      await tester.tap(
        find.byKey(const ValueKey<String>('chat-media-media-photo-1')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(MediaViewer), findsOneWidget);
      expect(find.byType(PersonProfilePanel), findsNothing);

      await tester.tap(find.byKey(MediaViewer.closeKey));
      await tester.pumpAndSettle();
      expect(find.byType(MediaViewer), findsNothing);

      // Tapping the photo message's left avatar opens PersonProfilePanel, NOT MediaViewer.
      await tester.tap(
        find.byKey(MessageBubble.avatarKeyFor(photoMsg.identity)),
      );
      await tester.pumpAndSettle();
      expect(find.byType(PersonProfilePanel), findsOneWidget);
      expect(find.byType(MediaViewer), findsNothing);
      expect(find.text('BB号 ${_bob.account}'), findsOneWidget);

      await tester.tap(find.byType(CloseButton));
      await tester.pumpAndSettle();

      // Message body remains SelectableText and tapping it does not open profile.
      expect(find.byType(SelectableText), findsWidgets);
      await tester.tap(find.text('可复制的正文内容'));
      await tester.pumpAndSettle();
      expect(find.byType(PersonProfilePanel), findsNothing);

      // Failed outgoing message retry works without triggering profile navigation.
      chat.failBody = true;
      await tester.enterText(find.byKey(ChatComposer.inputKey), '重试消息');
      await tester.pump();
      await tester.tap(find.byKey(ChatComposer.sendKey));
      await tester.pumpAndSettle();
      expect(find.byKey(MessageBubble.failedKey), findsOneWidget);

      chat.failBody = false;
      await tester.tap(find.byKey(MessageBubble.failedKey));
      await tester.pumpAndSettle();
      expect(find.byKey(MessageBubble.failedKey), findsNothing);
      expect(find.byType(PersonProfilePanel), findsNothing);
    },
  );

  testWidgets(
    'peer cover read failure keeps PersonProfilePanel usable with packaged default cover',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final FakeProfileGateway profiles = buildProfiles()
        ..coverFailure = const AuthFailure(
          status: 503,
          code: 'storage_unavailable',
          message: '存储暂不可用',
        );

      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(
            body: PersonProfilePanel(account: _bob.account, gateway: profiles),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(PersonProfilePanel), findsOneWidget);
      expect(find.text('BB号 ${_bob.account}'), findsOneWidget);
      expect(find.byKey(ProfileSeaCover.defaultCoverKey), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final Size viewport in const <Size>[Size(390, 844), Size(1280, 900)]) {
    testWidgets(
      'DEA-514 v3 floating nameplate has no dividers/borders, supports 200% text and read-only cues ($viewport)',
      (WidgetTester tester) async {
        tester.view.physicalSize = viewport;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        final FakeProfileGateway profiles = buildProfiles();
        profiles.profiles[_carol.account] = const Profile(
          account: '10000003',
          username: '重名成员很长昵称测试换行',
          signature: null,
          avatarUrl: '/avatars/10000003.png',
          avatarVersion: 'v-carol',
        );

        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            builder: (BuildContext context, Widget? child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(2.0)),
              child: child!,
            ),
            home: Scaffold(
              body: Builder(
                builder: (BuildContext context) => Center(
                  child: ElevatedButton(
                    onPressed: () => openPersonProfile(
                      context,
                      account: _carol.account,
                      gateway: profiles,
                    ),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();

        expect(find.byType(PersonProfilePanel), findsOneWidget);
        expect(find.byKey(PersonProfilePanel.plateKey), findsOneWidget);
        expect(find.byKey(PersonProfilePanel.readonlyPillKey), findsOneWidget);
        expect(find.byKey(PersonProfilePanel.readonlyNoteKey), findsOneWidget);
        expect(find.text('仅可查看'), findsOneWidget);
        expect(find.text('资料由对方维护，仅可查看'), findsOneWidget);
        expect(find.text('还没有签名'), findsOneWidget);

        // No accent lines or dividers anywhere in the floating nameplate page.
        expect(
          find.descendant(
            of: find.byType(PersonProfilePanel),
            matching: find.byType(Divider),
          ),
          findsNothing,
        );
        final Container plate = tester.widget<Container>(
          find.byKey(PersonProfilePanel.plateKey),
        );
        final BoxDecoration plateDecoration =
            plate.decoration! as BoxDecoration;
        expect(plateDecoration.border, isNull);

        // Nameplate overlaps cover bottom seam, signature sits below nameplate.
        final Rect coverRect = tester.getRect(
          find.byKey(ProfileSeaCover.coverKey),
        );
        final Rect plateRect = tester.getRect(
          find.byKey(PersonProfilePanel.plateKey),
        );
        final Rect sigRect = tester.getRect(
          find.byKey(PersonProfilePanel.signatureKey),
        );
        expect(plateRect.top, lessThan(coverRect.bottom));
        expect(sigRect.top, greaterThan(plateRect.bottom));

        // Phone shows back arrow icon; desktop shows close icon inside CloseButton.
        expect(find.byType(CloseButton), findsOneWidget);
        if (viewport.width < 600) {
          expect(coverRect.height, closeTo(320, 0.5));
          expect(find.byIcon(Icons.arrow_back_rounded), findsOneWidget);
        } else {
          expect(
            tester.getSize(find.byKey(ProfilePanelFrame.desktopCardKey)),
            const Size(440, 620),
          );
          expect(coverRect.height, closeTo(230.0, 0.5));
          expect(find.byIcon(Icons.close_rounded), findsOneWidget);
        }

        expect(tester.binding.transientCallbackCount, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'v3 live motion: press scale, staggered entrance, return preserves scroll position, and reduced motion settles immediately',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final FakeProfileGateway profiles = buildProfiles();
      final DateTime base = DateTime.utc(2026, 11, 28, 9);
      final List<ChatMessage> thread = <ChatMessage>[
        for (int i = 1; i <= 50; i += 1)
          ChatMessage(
            id: 'anim-$i',
            position: i,
            senderAccount: i.isOdd ? _bob.account : _self.account,
            senderUsername: i.isOdd ? _bob.username : _self.username,
            targetAccount: i.isOdd ? _self.account : _bob.account,
            createdAt: base.add(Duration(minutes: i * 10)),
            kind: ChatMessageKind.body,
            parts: <MessagePart>[TextPart('动效历史第 $i 条消息')],
          ),
      ];
      final FakeChatService chat = FakeChatService(
        self: _self,
        users: const <ChatUser>[_bob],
        conversations: <String, List<ChatMessage>>{_bob.account: thread},
      );

      final ValueNotifier<bool> reduceMotion = ValueNotifier<bool>(false);
      addTearDown(reduceMotion.dispose);

      await tester.pumpWidget(
        ValueListenableBuilder<bool>(
          valueListenable: reduceMotion,
          builder: (BuildContext context, bool reduced, Widget? _) =>
              MaterialApp(
                theme: buildAppTheme(),
                builder: (BuildContext context, Widget? child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(disableAnimations: reduced),
                  child: child!,
                ),
                home: ChatPage(peer: _bob, chat: chat, profile: profiles),
              ),
        ),
      );
      await tester.pumpAndSettle();

      // Scroll up into history before opening profile.
      final ScrollController scrollController = tester
          .widget<ListView>(find.byKey(ChatPage.listKey))
          .controller!;
      for (int i = 0; i < 5; i += 1) {
        await tester.drag(find.byKey(ChatPage.listKey), const Offset(0, 400));
        await tester.pump();
      }
      await tester.pumpAndSettle();
      final double savedOffset = scrollController.position.pixels;

      final Finder visibleAvatar = find
          .byWidgetPredicate(
            (Widget w) =>
                w.key is ValueKey<String> &&
                (w.key! as ValueKey<String>).value.startsWith(
                  'chat-message-avatar-anim-',
                ),
          )
          .first;

      // Press feedback scales message avatar down to 0.94 over 120 ms, then back to 1.0 on release.
      final TestGesture gesture = await tester.startGesture(
        tester.getCenter(visibleAvatar),
      );
      await tester.pump(const Duration(milliseconds: 140));
      final AnimatedScale pressedScale = tester.widget<AnimatedScale>(
        find
            .ancestor(
              of: find.descendant(
                of: visibleAvatar,
                matching: find.byType(ProfileAvatar),
              ),
              matching: find.byType(AnimatedScale),
            )
            .first,
      );
      expect(pressedScale.scale, closeTo(0.94, 0.001));
      await gesture.up();
      await tester.pumpAndSettle();

      // Open profile under live animations; settle completes within < 2s (no loops).
      expect(find.byType(PersonProfilePanel), findsOneWidget);
      expect(tester.binding.transientCallbackCount, 0);
      expect(find.text('BB号 ${_bob.account}'), findsOneWidget);

      // Press feedback on the profile close glass button too.
      final Finder closeFinder = find.byType(CloseButton);
      final TestGesture closeGesture = await tester.startGesture(
        tester.getCenter(closeFinder),
      );
      await tester.pump(const Duration(milliseconds: 140));
      final AnimatedScale closeScale = tester.widget<AnimatedScale>(
        find
            .ancestor(of: closeFinder, matching: find.byType(AnimatedScale))
            .first,
      );
      expect(closeScale.scale, closeTo(0.94, 0.001));
      await closeGesture.up();
      await tester.pumpAndSettle();

      // Returned to chat at the exact scroll offset.
      expect(find.byType(PersonProfilePanel), findsNothing);
      expect(
        scrollController.position.pixels,
        moreOrLessEquals(savedOffset, epsilon: 0.5),
      );

      // With system reduce-motion enabled, opening skips entrance and ring sweep
      // immediately (plate opacity is 1.0 and ring turns is 0 without settling).
      reduceMotion.value = true;
      await tester.pump();
      await tester.tap(visibleAvatar);
      await tester.pump();
      await tester.pump();
      expect(find.byType(PersonProfilePanel), findsOneWidget);
      expect(find.byKey(PersonProfilePanel.plateKey), findsOneWidget);
      final Opacity plateOpacity = tester.widget<Opacity>(
        find
            .ancestor(
              of: find.byKey(PersonProfilePanel.plateKey),
              matching: find.byType(Opacity),
            )
            .first,
      );
      expect(plateOpacity.opacity, 1.0);
      final RotationTransition ring = tester.widget<RotationTransition>(
        find.byKey(ScallopedAvatar.ringRotationKey),
      );
      expect(ring.turns.value, 0.0);
      await tester.pumpAndSettle();
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'desktop peer profile stays 440x620 on 1040x720 with short signature, shrinks on small windows, and scrolls long content',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1040, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final FakeProfileGateway profiles = buildProfiles();
      profiles.profiles[_bob.account] = const Profile(
        account: '10000002',
        username: '林晓',
        signature: '只潜水，偶尔冒泡。',
        avatarUrl: '/avatars/10000002.png',
        avatarVersion: 'v-bob',
      );
      profiles.profiles[_carol.account] = Profile(
        account: '10000003',
        username: '长签名成员',
        signature: List<String>.filled(
          24,
          '这是一段用于验证桌面端固定高度卡片可正常滚动的长签名内容。',
        ).join('\n'),
        avatarUrl: '/avatars/10000003.png',
        avatarVersion: 'v-carol',
      );

      Widget harness() => MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  ElevatedButton(
                    onPressed: () => openPersonProfile(
                      context,
                      account: _bob.account,
                      gateway: profiles,
                    ),
                    child: const Text('open-short'),
                  ),
                  ElevatedButton(
                    onPressed: () => openPersonProfile(
                      context,
                      account: _carol.account,
                      gateway: profiles,
                    ),
                    child: const Text('open-long'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      // 1. Standard 1040x720 desktop with 1.0 text scale & short signature -> 440x620.
      await tester.pumpWidget(harness());
      await tester.tap(find.text('open-short'));
      await tester.pumpAndSettle();

      final Rect shortCardRect = tester.getRect(
        find.byKey(ProfilePanelFrame.desktopCardKey),
      );
      final Rect shortCoverRect = tester.getRect(
        find.byKey(ProfileSeaCover.coverKey),
      );
      expect(shortCardRect.size, const Size(440, 620));
      expect(shortCoverRect.height, closeTo(230, 0.5));
      expect(shortCoverRect.top, closeTo(shortCardRect.top, 0.5));
      expect(find.text('只潜水，偶尔冒泡。'), findsOneWidget);
      expect(find.text('资料由对方维护，仅可查看'), findsOneWidget);

      await tester.tap(find.byType(CloseButton));
      await tester.pumpAndSettle();

      // 2. Long signature on 1040x720 stays 440x620 and scrolls internally.
      await tester.tap(find.text('open-long'));
      await tester.pumpAndSettle();

      final Rect longCardRect = tester.getRect(
        find.byKey(ProfilePanelFrame.desktopCardKey),
      );
      expect(longCardRect.size, const Size(440, 620));
      final Finder profileScrollable = find
          .descendant(
            of: find.byType(PersonProfilePanel),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.byKey(PersonProfilePanel.readonlyNoteKey),
        200,
        scrollable: profileScrollable,
      );
      await tester.pumpAndSettle();
      final Rect noteRect = tester.getRect(
        find.byKey(PersonProfilePanel.readonlyNoteKey),
      );
      expect(noteRect.bottom, lessThanOrEqualTo(longCardRect.bottom + 0.5));

      // Scroll back to the header so CloseButton is inside the viewport, then close.
      await tester.drag(profileScrollable, const Offset(0, 1200));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(CloseButton));
      await tester.pumpAndSettle();
      expect(find.byType(PersonProfilePanel), findsNothing);

      // 3. Small desktop window (700x480) shrinks cleanly within viewport & scrolls.
      tester.view.physicalSize = const Size(700, 480);
      await tester.pumpAndSettle();
      await tester.tap(find.text('open-short'));
      await tester.pumpAndSettle();

      final Rect smallCardRect = tester.getRect(
        find.byKey(ProfilePanelFrame.desktopCardKey),
      );
      expect(smallCardRect.width, 440);
      expect(smallCardRect.height, closeTo(480 - AppSpacing.lg * 2, 0.5));
      expect(smallCardRect.bottom, lessThanOrEqualTo(480));
      expect(find.text('只潜水，偶尔冒泡。'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byKey(PersonProfilePanel.readonlyNoteKey),
        120,
        scrollable: profileScrollable,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
