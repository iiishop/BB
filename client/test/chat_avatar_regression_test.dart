import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/models/profile_models.dart';
import 'package:bb_client/services/auth_api_client.dart';
import 'package:bb_client/services/auth_service.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/heartbeat_controller.dart';
import 'package:bb_client/ui/chat/chat_format.dart';
import 'package:bb_client/ui/chat/chat_page.dart';
import 'package:bb_client/ui/chat/users_view.dart';
import 'package:bb_client/ui/home_view.dart';
import 'package:bb_client/ui/widgets/profile_avatar.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/avatar_fixtures.dart';
import 'support/fake_auth_gateway.dart';
import 'support/fake_chat_service.dart';
import 'support/fake_profile_gateway.dart';

/// DEA-472 permanent regression: the chat AppBar and message bubbles render the
/// bytes fetched from the server avatar route instead of drawing initials.
///
/// These cases drive the public [HomeView] navigation path so the regression
/// still compiles against the pre-fix client and fails on its assertions
/// (initials instead of avatars, one request per bubble instead of per account).
const AuthUser _self = AuthUser(account: '10000001', username: 'alice');
const ChatUser _bob = ChatUser(
  account: '10000002',
  username: 'bob',
  avatarUrl: '/avatars/10000002.png',
  avatarVersion: 'v-bob',
  presence: Presence.online,
);

List<ChatMessage> _thread() {
  final DateTime base = DateTime.utc(2026, 1, 1, 12);
  return <ChatMessage>[
    for (int position = 1; position <= 30; position++)
      ChatMessage(
        id: 'm$position',
        position: position,
        senderAccount: position.isEven ? _self.account : _bob.account,
        targetAccount: position.isEven ? _bob.account : _self.account,
        createdAt: base.add(Duration(seconds: position)),
        kind: ChatMessageKind.body,
        parts: <MessagePart>[TextPart('msg $position')],
      ),
  ];
}

FakeProfileGateway _profileGateway() {
  final FakeProfileGateway gateway = FakeProfileGateway();
  gateway.profile = const Profile(
    account: '10000001',
    username: 'alice',
    signature: null,
    avatarUrl: '/avatars/10000001.png',
    avatarVersion: 'v-alice',
  );
  gateway.avatars[_self.account] = selfIdenticon;
  gateway.avatars[_bob.account] = peerIdenticon;
  return gateway;
}

class _Harness {
  _Harness(this.tester)
    : profile = _profileGateway(),
      chat = FakeChatService(
        self: _self,
        users: const <ChatUser>[_bob],
        conversations: <String, List<ChatMessage>>{_bob.account: _thread()},
      ) {
    heartbeat = HeartbeatController(
      auth: AuthService(
        api: AuthApiClient(baseUri: Uri.parse('http://127.0.0.1:1')),
        session: AuthSession(),
      ),
    );
  }

  final WidgetTester tester;
  final FakeProfileGateway profile;
  final FakeChatService chat;
  late final HeartbeatController heartbeat;

  Future<void> pump() async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(heartbeat.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: HomeView(
          user: _self,
          profile: profile,
          auth: FakeAuthGateway(),
          heartbeat: heartbeat,
          chat: chat,
          onSignedOut: (LogoutResult? _) {},
          onSessionExpired: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openChat() async {
    await tester.tap(find.byKey(UsersListView.rowKey(_bob.account)));
    await tester.pumpAndSettle();
    expect(find.byType(ChatPage), findsOneWidget);
  }

  List<ProfileAvatar> avatars() =>
      tester.widgetList<ProfileAvatar>(find.byType(ProfileAvatar)).toList();

  int loads(String account) => profile.loadAvatarByAccount[account] ?? 0;
}

void main() {
  testWidgets('chat avatars come from the server and 30-message scroll asks '
      'once per account, re-entry revalidates the changed image', (
    WidgetTester tester,
  ) async {
    final _Harness harness = _Harness(tester);
    await harness.pump();

    final int selfBefore = harness.loads(_self.account);
    final int peerBefore = harness.loads(_bob.account);
    await harness.openChat();

    // AppBar + both senders use real bytes; each account asked exactly once.
    expect(harness.loads(_self.account), selfBefore + 1);
    expect(harness.loads(_bob.account), peerBefore + 1);

    List<ProfileAvatar> avatars = harness.avatars();
    final List<ProfileAvatar> appBarAvatars = avatars
        .where((ProfileAvatar avatar) => avatar.size == 36)
        .toList();
    expect(appBarAvatars, hasLength(1));
    expect(listEquals(appBarAvatars.single.bytes, peerIdenticon), isTrue);

    final List<ProfileAvatar> bubbleAvatars = avatars
        .where((ProfileAvatar avatar) => avatar.size == 32)
        .toList();
    expect(
      bubbleAvatars.any(
        (ProfileAvatar avatar) => listEquals(avatar.bytes, peerIdenticon),
      ),
      isTrue,
      reason: 'peer bubbles render the fetched image, not the username initial',
    );
    expect(
      bubbleAvatars.any(
        (ProfileAvatar avatar) => listEquals(avatar.bytes, selfIdenticon),
      ),
      isTrue,
      reason:
          'own bubbles render the signed-in account image, not a hardcoded 我',
    );
    expect(find.text('我'), findsNothing);
    expect(find.text(initialsOf(_bob.username)), findsNothing);

    // Scroll through all 30 messages. A per-bubble fetch would add requests.
    for (int i = 0; i < 6; i++) {
      await tester.drag(find.byKey(ChatPage.listKey), const Offset(0, 500));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(
      find.text('msg 1'),
      findsOneWidget,
      reason: 'scrolled to the first message',
    );
    expect(harness.loads(_self.account), selfBefore + 1);
    expect(harness.loads(_bob.account), peerBefore + 1);

    // Leave and re-enter after the peer changes the avatar: one revalidation
    // request per account and the new bytes replace the old image.
    await tester.pageBack();
    await tester.pumpAndSettle();
    harness.profile.avatars[_bob.account] = peerReplacedAvatar;
    final int selfReenterBefore = harness.loads(_self.account);
    final int peerReenterBefore = harness.loads(_bob.account);
    await harness.openChat();
    expect(harness.loads(_self.account), selfReenterBefore + 1);
    expect(harness.loads(_bob.account), peerReenterBefore + 1);

    avatars = harness.avatars();
    final List<ProfileAvatar> reenteredAppBar = avatars
        .where((ProfileAvatar avatar) => avatar.size == 36)
        .toList();
    expect(reenteredAppBar, hasLength(1));
    expect(
      listEquals(reenteredAppBar.single.bytes, peerReplacedAvatar),
      isTrue,
      reason: 're-entering the conversation fetches the replaced avatar',
    );
    expect(find.text('我'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('offline avatars end in the placeholder without retries', (
    WidgetTester tester,
  ) async {
    final _Harness harness = _Harness(tester);
    harness.profile.avatarFailure = upstreamUnavailable;
    await harness.pump();

    final int selfBefore = harness.loads(_self.account);
    final int peerBefore = harness.loads(_bob.account);
    await harness.openChat();
    expect(harness.loads(_self.account), selfBefore + 1);
    expect(harness.loads(_bob.account), peerBefore + 1);

    final List<ProfileAvatar> avatars = harness.avatars();
    expect(avatars, isNotEmpty);
    for (final ProfileAvatar avatar in avatars) {
      expect(avatar.bytes, isNull);
      expect(avatar.loading, isFalse);
    }
    expect(find.byIcon(Icons.person_outline_rounded), findsWidgets);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('我'), findsNothing);
    expect(find.text(initialsOf(_bob.username)), findsNothing);

    // Staying on the page must not retry or leave a spinner running.
    await tester.pump(const Duration(seconds: 5));
    expect(harness.loads(_self.account), selfBefore + 1);
    expect(harness.loads(_bob.account), peerBefore + 1);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('timeout ends the loading spinner in the avatar placeholder', (
    WidgetTester tester,
  ) async {
    final _Harness harness = _Harness(tester);
    harness.profile.avatarDelay = const Duration(seconds: 10);
    harness.profile.avatarFailure = upstreamTimeout;

    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(harness.heartbeat.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: HomeView(
          user: _self,
          profile: harness.profile,
          auth: FakeAuthGateway(),
          heartbeat: harness.heartbeat,
          chat: harness.chat,
          onSignedOut: (LogoutResult? _) {},
          onSessionExpired: () {},
        ),
      ),
    );
    // Let the user list arrive while the avatar request is still pending.
    for (int i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.byKey(UsersListView.rowKey(_bob.account)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(ChatPage), findsOneWidget);
    expect(
      find.byType(CircularProgressIndicator),
      findsWidgets,
      reason: 'the pending avatar request is visible as loading',
    );

    // The client timeout fires; the visit is terminal, not an endless spinner.
    await tester.pump(const Duration(seconds: 10));
    await tester.pump();

    final List<ProfileAvatar> avatars = harness.avatars();
    expect(avatars, isNotEmpty);
    for (final ProfileAvatar avatar in avatars) {
      expect(avatar.bytes, isNull);
      expect(avatar.loading, isFalse);
    }
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byIcon(Icons.person_outline_rounded), findsWidgets);
    expect(find.text('我'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
