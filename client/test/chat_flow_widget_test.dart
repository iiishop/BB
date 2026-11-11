import 'package:bb_client/app.dart';
import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/services/auth_api_client.dart';
import 'package:bb_client/services/auth_service.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/heartbeat_controller.dart';
import 'package:bb_client/ui/chat/chat_composer.dart';
import 'package:bb_client/ui/chat/chat_page.dart';
import 'package:bb_client/ui/chat/users_view.dart';
import 'package:bb_client/ui/home_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_auth_gateway.dart';
import 'support/fake_chat_service.dart';
import 'support/fake_profile_gateway.dart';

const AuthUser _self = AuthUser(account: '10000001', username: 'alice');
final ChatUser _bob = ChatUser(
  account: '10000002',
  username: 'bob',
  avatarUrl: '/avatars/10000002.png',
  avatarVersion: 'v1',
  presence: Presence.online,
  lastContactAt: DateTime.now().toUtc().subtract(const Duration(minutes: 5)),
  lastMessage: UserPreview(
    id: 'm9',
    senderAccount: '10000002',
    senderUsername: 'bob',
    previewBody: '晚上见',
  ),
);
const ChatUser _carol = ChatUser(
  account: '10000003',
  username: 'carol',
  avatarUrl: '/avatars/10000003.png',
  avatarVersion: 'v1',
  presence: Presence.offline,
);

ChatMessage _message({
  required int position,
  required String sender,
  required String target,
  required DateTime at,
  String kind = 'body',
  List<MessagePart> parts = const <MessagePart>[],
  Attachment? attachment,
}) {
  return ChatMessage(
    id: 'm$position',
    position: position,
    senderAccount: sender,
    targetAccount: target,
    createdAt: at,
    kind: kind == 'body' ? ChatMessageKind.body : ChatMessageKind.attachment,
    parts: parts,
    attachment: attachment,
  );
}

void main() {
  late FakeChatService chat;
  late HeartbeatController heartbeat;
  late FakeProfileGateway profile;

  setUp(() {
    final DateTime now = DateTime.now().toUtc();
    final List<ChatMessage> conversation = <ChatMessage>[
      _message(
        position: 1,
        sender: _bob.account,
        target: _self.account,
        at: now.subtract(const Duration(minutes: 10)),
        parts: const <MessagePart>[
          TextPart('文字A'),
          ImagePart('img1'),
          TextPart('文字B'),
        ],
      ),
      _message(
        position: 2,
        sender: _self.account,
        target: _bob.account,
        at: now.subtract(const Duration(minutes: 8)),
        parts: const <MessagePart>[TextPart('收到')],
      ),
      _message(
        position: 3,
        sender: _bob.account,
        target: _self.account,
        at: now.subtract(const Duration(minutes: 5)),
        kind: 'attachment',
        attachment: const Attachment(
          mediaId: 'video1',
          kind: AttachmentKind.video,
          filename: '旅行.mp4',
          mimeType: 'video/mp4',
          byteSize: 2048,
          coverMediaId: 'cover1',
        ),
      ),
    ];
    chat = FakeChatService(
      self: _self,
      users: <ChatUser>[_bob, _carol],
      conversations: <String, List<ChatMessage>>{_bob.account: conversation},
    );
    profile = FakeProfileGateway();
    heartbeat = HeartbeatController(
      auth: AuthService(
        api: AuthApiClient(baseUri: Uri.parse('http://127.0.0.1:1')),
        session: AuthSession(),
      ),
    );
    addTearDown(heartbeat.dispose);
  });

  Widget app() {
    return MaterialApp(
      theme: buildAppTheme(),
      home: HomeView(
        user: _self,
        profile: profile,
        auth: FakeAuthGateway(),
        heartbeat: heartbeat,
        chat: chat,
        onSignedOut: (LogoutResult? _) {},
        onSessionExpired: () {},
      ),
    );
  }

  Future<void> pumpAt(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
  }

  testWidgets('home lists all registered users, not just contacts', (
    WidgetTester tester,
  ) async {
    await pumpAt(tester, const Size(390, 844));

    expect(find.byKey(UsersListView.rowKey(_bob.account)), findsOneWidget);
    expect(find.byKey(UsersListView.rowKey(_carol.account)), findsOneWidget);
    expect(find.byKey(UsersListView.rowKey(_self.account)), findsNothing);
    expect(find.text('bob'), findsOneWidget);
    expect(find.text('bob：晚上见'), findsOneWidget);
    expect(find.text('尚未联系'), findsOneWidget);
    expect(find.text('暂无消息'), findsOneWidget);
    expect(find.text('在线'), findsOneWidget);
    expect(find.text('离线'), findsOneWidget);
    expect(find.byKey(HomeView.avatarEntryKey), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping a user opens ordered chat and the composer sends', (
    WidgetTester tester,
  ) async {
    await pumpAt(tester, const Size(390, 844));
    await tester.tap(find.byKey(UsersListView.rowKey(_bob.account)));
    await tester.pumpAndSettle();

    expect(find.byType(ChatPage), findsOneWidget);
    expect(find.byKey(ChatPage.listKey), findsOneWidget);

    final List<String> texts = tester
        .widgetList<SelectableText>(find.byType(SelectableText))
        .map((SelectableText text) => text.data ?? '')
        .toList();
    expect(texts, containsAllInOrder(<String>['文字A', '文字B']));
    expect(find.byType(Image), findsWidgets, reason: 'body image rendered');
    expect(find.text('旅行.mp4'), findsOneWidget);
    expect(find.text('另存为'), findsOneWidget);
    expect(find.text('下载'), findsOneWidget);
    expect(find.text('播放'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.enterText(find.byKey(ChatComposer.inputKey), '这是新消息');
    await tester.tap(find.byKey(ChatComposer.sendKey));
    await tester.pumpAndSettle();

    expect(find.text('这是新消息'), findsOneWidget);
    expect(chat.sentTexts, contains('这是新消息'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('attachment long-press menu offers 另存为', (
    WidgetTester tester,
  ) async {
    await pumpAt(tester, const Size(390, 844));
    await tester.tap(find.byKey(UsersListView.rowKey(_bob.account)));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('旅行.mp4'));
    await tester.pumpAndSettle();
    expect(find.text('另存为'), findsWidgets);
    expect(find.text('下载'), findsWidgets);

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('wide and compact layouts render without overflow', (
    WidgetTester tester,
  ) async {
    await pumpAt(tester, const Size(1280, 900));
    expect(find.byKey(UsersListView.listKey), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(UsersListView.rowKey(_bob.account)));
    await tester.pumpAndSettle();
    expect(find.byType(ChatPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
