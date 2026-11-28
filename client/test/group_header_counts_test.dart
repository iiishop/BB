import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bb_client/app.dart';
import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/models/group_models.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/avatar_cache.dart';
import 'package:bb_client/services/chat_api_client.dart';
import 'package:bb_client/services/chat_ledger.dart';
import 'package:bb_client/services/conversation_access.dart';
import 'package:bb_client/services/group_api_client.dart';
import 'package:bb_client/services/group_service.dart';
import 'package:bb_client/ui/chat/chat_header.dart';
import 'package:bb_client/ui/chat/chat_page.dart';
import 'package:bb_client/ui/chat/chat_workspace.dart';
import 'package:bb_client/ui/chat/users_view.dart';
import 'package:bb_client/ui/widgets/profile_avatar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_chat_service.dart';
import 'support/fake_profile_gateway.dart';

const AuthUser _self = AuthUser(account: '10000001', username: 'Alice');

final String _groupAId = 'group:${'a1b2c3d4' * 4}';
final String _groupBId = 'group:${'e5f60718' * 4}';

GroupConversationItem _groupItem({
  required String id,
  required String number,
  required String name,
}) {
  return GroupConversationItem(
    conversation: ConversationRef.group(id),
    groupNumber: number,
    displayName: name,
    lastMessage: null,
    lastActivityAt: DateTime.utc(2026, 11, 28, 12),
    latestPosition: 0,
    historyThrough: 0,
    membershipRevision: 1,
    avatarUrl: '',
    avatarVersion: 'gv0',
  );
}

class _RecordedMembersCall {
  const _RecordedMembersCall({
    required this.conversationId,
    required this.limit,
    required this.includeCounts,
  });

  final String conversationId;
  final int limit;
  final bool includeCounts;
}

class _FakeGroupApiClient extends GroupApiClient {
  _FakeGroupApiClient() : super(baseUri: Uri.parse('http://127.0.0.1:1'));

  final List<_RecordedMembersCall> memberCalls = <_RecordedMembersCall>[];
  final Map<String, GroupMemberCounts?> countsByGroup =
      <String, GroupMemberCounts?>{};
  final Map<String, Object> errorsByGroup = <String, Object>{};
  final Map<String, Completer<GroupMemberPage>> nextReplyByGroup =
      <String, Completer<GroupMemberPage>>{};
  final List<Completer<GroupMemberPage>> queuedReplies =
      <Completer<GroupMemberPage>>[];

  @override
  Future<GroupMemberPage> listGroupMembers({
    required String token,
    required ConversationRef conversation,
    String afterAccount = '',
    int limit = 50,
    bool includeCounts = false,
  }) async {
    memberCalls.add(
      _RecordedMembersCall(
        conversationId: conversation.id,
        limit: limit,
        includeCounts: includeCounts,
      ),
    );
    if (queuedReplies.isNotEmpty) {
      return queuedReplies.removeAt(0).future;
    }
    final Completer<GroupMemberPage>? gate = nextReplyByGroup.remove(
      conversation.id,
    );
    if (gate != null) {
      return gate.future;
    }
    final Object? error = errorsByGroup[conversation.id];
    if (error != null) {
      throw error;
    }
    return GroupMemberPage(
      items: const <GroupMember>[],
      counts: includeCounts ? countsByGroup[conversation.id] : null,
    );
  }
}

class _FakeSharedConversationService extends SharedConversationService {
  _FakeSharedConversationService({
    required this.groupsList,
    required super.session,
    required super.access,
  }) : super(api: ChatApiClient(baseUri: Uri.parse('http://127.0.0.1:1')));

  final List<GroupConversationItem> groupsList;

  @override
  Future<SharedConversationPage> listSharedConversations({
    String afterId = '',
    int limit = 50,
    AuthIdentity? captured,
  }) async {
    return SharedConversationPage(items: groupsList, nextCursor: null);
  }

  @override
  Future<MessagePage> loadConversationHistory({
    required ConversationRef conversation,
    int? afterPosition,
    int? beforePosition,
    int limit = 100,
    AuthIdentity? captured,
  }) async {
    return const MessagePage(
      items: <ChatMessage>[],
      nextPosition: 0,
      hasMore: false,
    );
  }

  @override
  Future<Map<String, int>> incomingUnreadByGroup({
    required Iterable<GroupConversationItem> groups,
    required ChatLedger ledger,
    AuthIdentity? captured,
  }) async {
    return const <String, int>{};
  }

  @override
  Future<int> recordGroupDisplayedIncoming({
    required GroupConversationItem group,
    required ChatLedger ledger,
    required Iterable<ChatMessage> messages,
    AuthIdentity? captured,
  }) async {
    return 0;
  }
}

class _LoopbackHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)..findProxy = (_) => 'DIRECT';
  }
}

void main() {
  test('GroupMemberPage parses and serializes optional counts cleanly', () {
    final GroupMemberPage withoutCounts = GroupMemberPage.fromJson(
      <String, dynamic>{'items': <Object?>[], 'next_cursor': null},
    );
    expect(withoutCounts.counts, isNull);
    expect(withoutCounts.toJson().containsKey('counts'), isFalse);

    final GroupMemberPage withZero = GroupMemberPage.fromJson(<String, dynamic>{
      'items': <Object?>[],
      'next_cursor': null,
      'counts': <String, dynamic>{'online': 0, 'total': 12},
    });
    expect(withZero.counts, const GroupMemberCounts(online: 0, total: 12));
    expect(withZero.toJson()['counts'], <String, dynamic>{
      'online': 0,
      'total': 12,
    });

    expect(
      () => GroupMemberPage.fromJson(<String, dynamic>{
        'items': <Object?>[],
        'counts': <String, dynamic>{'online': -1, 'total': 12},
      }),
      throwsFormatException,
    );
  });

  test(
    'GroupApiClient sends include_counts over HTTP and parses counts',
    () async {
      final HttpOverrides? previous = HttpOverrides.current;
      HttpOverrides.global = _LoopbackHttpOverrides();
      addTearDown(() => HttpOverrides.global = previous);

      final List<Map<String, dynamic>> bodies = <Map<String, dynamic>>[];
      final HttpServer server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() => server.close(force: true));

      server.listen((HttpRequest req) async {
        final List<int> bytes = await req.fold<List<int>>(
          <int>[],
          (List<int> acc, List<int> chunk) => acc..addAll(chunk),
        );
        final Map<String, dynamic> body =
            jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
        bodies.add(body);
        final bool includeCounts = body['include_counts'] == true;
        req.response.statusCode = 200;
        req.response.headers.contentType = ContentType.json;
        req.response.write(
          jsonEncode(<String, dynamic>{
            'items': <Object?>[],
            'next_cursor': null,
            if (includeCounts)
              'counts': <String, dynamic>{'online': 3, 'total': 12},
          }),
        );
        await req.response.close();
      });

      final AuthSession session = AuthSession()
        ..establish(token: 'tok-http', user: _self);
      final GroupService service = GroupService(
        api: GroupApiClient(
          baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
        ),
        session: session,
        avatarCache: AvatarCache(),
      );
      final ConversationRef conv = ConversationRef.group(_groupAId);

      final GroupMemberPage defaultPage = await service.listGroupMembers(
        conversation: conv,
      );
      expect(defaultPage.counts, isNull);
      expect(bodies.last.containsKey('include_counts'), isFalse);

      final GroupMemberPage countedPage = await service.listGroupMembers(
        conversation: conv,
        limit: 1,
        includeCounts: true,
      );
      expect(countedPage.counts, const GroupMemberCounts(online: 3, total: 12));
      expect(bodies.last['include_counts'], isTrue);
      expect(bodies.last['limit'], 1);
    },
  );

  group('ChatHeader group counts widget behaviour', () {
    late FakeChatService chat;
    late FakeProfileGateway profile;
    late _FakeGroupApiClient groupApi;
    late GroupService groups;
    late ConversationAccessController access;
    late _FakeSharedConversationService shared;

    final GroupConversationItem groupA = _groupItem(
      id: _groupAId,
      number: '73051288',
      name: '夜航船',
    );
    final GroupConversationItem groupLong = _groupItem(
      id: _groupAId,
      number: '73051288',
      name: '凌晨四点的海和没说完的话',
    );
    final GroupConversationItem groupB = _groupItem(
      id: _groupBId,
      number: '88001122',
      name: '潮汐读书会',
    );
    const ChatUser bob = ChatUser(
      account: '10000002',
      username: 'bob',
      avatarUrl: '/avatars/10000002.png',
      avatarVersion: 'v1',
      presence: Presence.online,
    );

    setUp(() {
      chat = FakeChatService(self: _self, users: const <ChatUser>[bob]);
      profile = FakeProfileGateway();
      groupApi = _FakeGroupApiClient();
      access = ConversationAccessController();
      groups = GroupService(
        api: groupApi,
        session: chat.session,
        avatarCache: AvatarCache(),
        access: access,
      );
      shared = _FakeSharedConversationService(
        groupsList: <GroupConversationItem>[groupA, groupB],
        session: chat.session,
        access: access,
      );
    });

    tearDown(() {
      shared.dispose();
    });

    Widget wrap(Widget child, {bool disableAnimations = false}) {
      return MaterialApp(
        theme: buildAppTheme(),
        builder: (BuildContext context, Widget? inner) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(disableAnimations: disableAnimations),
          child: inner!,
        ),
        home: child,
      );
    }

    String badgeText(WidgetTester tester) {
      final RichText rich = tester.widget<RichText>(
        find.descendant(
          of: find.byKey(ChatPage.headerGroupCountKey),
          matching: find.byType(RichText),
        ),
      );
      return rich.text.toPlainText();
    }

    testWidgets(
      '320px phone header keeps long group name, 999/1024 badge, group number and refresh clear without overlap',
      (WidgetTester tester) async {
        groupApi.countsByGroup[groupLong.conversation.id] =
            const GroupMemberCounts(online: 999, total: 1024);
        tester.view.physicalSize = const Size(320, 720);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          wrap(
            ChatPage(
              group: groupLong,
              chat: chat,
              profile: profile,
              shared: shared,
              groups: groups,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.byKey(ChatPage.headerGroupCountKey), findsOneWidget);
        expect(badgeText(tester), '999/1024');
        expect(find.text('群号 73051288'), findsOneWidget);

        final Rect nameRect = tester.getRect(
          find.byKey(ChatPage.headerNameKey),
        );
        final Rect badgeRect = tester.getRect(
          find.byKey(ChatPage.headerGroupCountKey),
        );
        final Rect statusRect = tester.getRect(
          find.byKey(ChatPage.headerStatusKey),
        );
        final Rect refreshRect = tester.getRect(
          find.byKey(ChatPage.refreshKey),
        );

        expect(nameRect.right, lessThanOrEqualTo(badgeRect.left));
        expect(badgeRect.right, lessThanOrEqualTo(refreshRect.left));
        expect(badgeRect.right, lessThanOrEqualTo(320));
        expect(refreshRect.right, lessThanOrEqualTo(320));
        expect(statusRect.top, greaterThanOrEqualTo(nameRect.bottom));
        expect(statusRect.right, lessThanOrEqualTo(refreshRect.left));

        // Badge is non-interactive (no clickable affordance added).
        expect(
          find.descendant(
            of: find.byKey(ChatPage.headerGroupCountKey),
            matching: find.byType(InkWell),
          ),
          findsNothing,
        );
        final int callsBefore = groupApi.memberCalls.length;
        await tester.tap(find.byKey(ChatPage.headerGroupCountKey));
        await tester.pump();
        expect(groupApi.memberCalls.length, callsBefore);
      },
    );

    testWidgets(
      'unknown initial counts stay —/— instead of 0, distinct from real 0/12',
      (WidgetTester tester) async {
        // Older server / failed initial read returns no counts.
        groupApi.countsByGroup[groupA.conversation.id] = null;
        await tester.pumpWidget(
          wrap(
            ChatPage(
              group: groupA,
              chat: chat,
              profile: profile,
              shared: shared,
              groups: groups,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(badgeText(tester), '—/—');
        expect(
          find.descendant(
            of: find.byKey(ChatPage.headerGroupCountKey),
            matching: find.byType(CustomPaint),
          ),
          findsOneWidget,
        );
        expect(
          tester.getSemantics(find.byKey(ChatPage.headerGroupCountKey)).label,
          '在线人数暂时未知',
        );

        // Now server returns real zero online out of 12 total.
        groupApi.countsByGroup[groupA.conversation.id] =
            const GroupMemberCounts(online: 0, total: 12);
        await tester.tap(find.byKey(ChatPage.refreshKey));
        await tester.pumpAndSettle();

        expect(badgeText(tester), '0/12');
        final DecoratedBox box = tester.widget<DecoratedBox>(
          find.descendant(
            of: find.byKey(ChatPage.headerGroupCountKey),
            matching: find.byType(DecoratedBox),
          ),
        );
        final BoxDecoration decoration = box.decoration as BoxDecoration;
        expect(decoration.color, GroupCountBadge.zeroBackground);
        expect(
          tester.getSemantics(find.byKey(ChatPage.headerGroupCountKey)).label,
          '当前无人在线，共 12 人',
        );
      },
    );

    testWidgets(
      'manual refresh enters loading state and failure preserves last confirmed counts',
      (WidgetTester tester) async {
        groupApi.countsByGroup[groupA.conversation.id] =
            const GroupMemberCounts(online: 3, total: 12);
        await tester.pumpWidget(
          wrap(
            ChatPage(
              group: groupA,
              chat: chat,
              profile: profile,
              shared: shared,
              groups: groups,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(badgeText(tester), '3/12');

        // Hold manual refresh to inspect loading state (dimmed badge + spin).
        final Completer<GroupMemberPage> refreshGate =
            Completer<GroupMemberPage>();
        groupApi.nextReplyByGroup[groupA.conversation.id] = refreshGate;
        await tester.tap(find.byKey(ChatPage.refreshKey));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 120));

        final AnimatedOpacity badgeOpacity = tester.widget<AnimatedOpacity>(
          find.descendant(
            of: find.byKey(ChatPage.headerGroupCountKey),
            matching: find.byType(AnimatedOpacity),
          ),
        );
        expect(badgeOpacity.opacity, 0.45);
        expect(
          find.descendant(
            of: find.byKey(ChatPage.refreshKey),
            matching: find.byType(RotationTransition),
          ),
          findsOneWidget,
        );

        // Fail this refresh: previous 3/12 must be preserved, never 0 or —/—.
        refreshGate.completeError(
          const AuthFailure(status: 500, code: 'internal', message: 'boom'),
        );
        await tester.pumpAndSettle();
        expect(badgeText(tester), '3/12');

        // Subsequent successful refresh updates to 4/12.
        groupApi.countsByGroup[groupA.conversation.id] =
            const GroupMemberCounts(online: 4, total: 12);
        await tester.tap(find.byKey(ChatPage.refreshKey));
        await tester.pumpAndSettle();
        expect(badgeText(tester), '4/12');
      },
    );

    testWidgets(
      'reduced motion replaces refresh spin with dimmed icon while loading',
      (WidgetTester tester) async {
        groupApi.countsByGroup[groupA.conversation.id] =
            const GroupMemberCounts(online: 3, total: 12);
        await tester.pumpWidget(
          wrap(
            ChatPage(
              group: groupA,
              chat: chat,
              profile: profile,
              shared: shared,
              groups: groups,
            ),
            disableAnimations: true,
          ),
        );
        await tester.pumpAndSettle();

        final Completer<GroupMemberPage> gate = Completer<GroupMemberPage>();
        groupApi.nextReplyByGroup[groupA.conversation.id] = gate;
        await tester.tap(find.byKey(ChatPage.refreshKey));
        await tester.pump();

        expect(
          find.descendant(
            of: find.byKey(ChatPage.refreshKey),
            matching: find.byType(RotationTransition),
          ),
          findsNothing,
        );
        final Opacity dimmedIcon = tester.widget<Opacity>(
          find.descendant(
            of: find.byKey(ChatPage.refreshKey),
            matching: find.byType(Opacity),
          ),
        );
        expect(dimmedIcon.opacity, 0.5);

        gate.complete(
          const GroupMemberPage(
            items: <GroupMember>[],
            counts: GroupMemberCounts(online: 5, total: 12),
          ),
        );
        await tester.pumpAndSettle();
        expect(badgeText(tester), '5/12');
      },
    );

    testWidgets(
      'polling updates counts without group messages on online/offline and membership changes',
      (WidgetTester tester) async {
        groupApi.countsByGroup[groupA.conversation.id] =
            const GroupMemberCounts(online: 2, total: 2);
        await tester.pumpWidget(
          wrap(
            ChatPage(
              group: groupA,
              chat: chat,
              profile: profile,
              shared: shared,
              groups: groups,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(badgeText(tester), '2/2');

        // Member goes offline without any group system message.
        groupApi.countsByGroup[groupA.conversation.id] =
            const GroupMemberCounts(online: 1, total: 2);
        await tester.pump(const Duration(seconds: 3));
        await tester.pumpAndSettle();
        expect(badgeText(tester), '1/2');

        // Last member goes offline -> real 0/2.
        groupApi.countsByGroup[groupA.conversation.id] =
            const GroupMemberCounts(online: 0, total: 2);
        await tester.pump(const Duration(seconds: 3));
        await tester.pumpAndSettle();
        expect(badgeText(tester), '0/2');

        // Membership changes (new member joins online) without group messages.
        groupApi.countsByGroup[groupA.conversation.id] =
            const GroupMemberCounts(online: 2, total: 3);
        await tester.pump(const Duration(seconds: 3));
        await tester.pumpAndSettle();
        expect(badgeText(tester), '2/3');
        expect(
          groupApi.memberCalls.every(
            (_RecordedMembersCall call) =>
                call.includeCounts && call.limit == 1,
          ),
          isTrue,
        );
      },
    );

    testWidgets(
      'switching groups clears previous group count and drops late responses from previous group',
      (WidgetTester tester) async {
        groupApi.countsByGroup[groupA.conversation.id] =
            const GroupMemberCounts(online: 8, total: 10);
        GroupConversationItem activeGroup = groupA;

        late StateSetter setHostState;
        await tester.pumpWidget(
          wrap(
            StatefulBuilder(
              builder: (BuildContext context, StateSetter setState) {
                setHostState = setState;
                return ChatPage(
                  group: activeGroup,
                  chat: chat,
                  profile: profile,
                  shared: shared,
                  groups: groups,
                );
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(badgeText(tester), '8/10');

        // Start a refresh on group A, hold it, then switch to group B whose
        // initial load is also held.
        final Completer<GroupMemberPage> staleAGate =
            Completer<GroupMemberPage>();
        groupApi.nextReplyByGroup[groupA.conversation.id] = staleAGate;
        await tester.tap(find.byKey(ChatPage.refreshKey));
        await tester.pump();

        final Completer<GroupMemberPage> groupBGate =
            Completer<GroupMemberPage>();
        groupApi.nextReplyByGroup[groupB.conversation.id] = groupBGate;
        setHostState(() => activeGroup = groupB);
        await tester.pump();

        // Must immediately show unknown —/—, never carry over group A's 8/10.
        expect(badgeText(tester), '—/—');

        // Late response for group A arrives with 9/10 -> must be ignored.
        staleAGate.complete(
          const GroupMemberPage(
            items: <GroupMember>[],
            counts: GroupMemberCounts(online: 9, total: 10),
          ),
        );
        await tester.pump();
        expect(badgeText(tester), '—/—');

        // Group B completes with 1/4.
        groupBGate.complete(
          const GroupMemberPage(
            items: <GroupMember>[],
            counts: GroupMemberCounts(online: 1, total: 4),
          ),
        );
        await tester.pumpAndSettle();
        expect(badgeText(tester), '1/4');
      },
    );

    testWidgets(
      'out-of-order response in the same group cannot overwrite a newer refresh',
      (WidgetTester tester) async {
        groupApi.countsByGroup[groupA.conversation.id] =
            const GroupMemberCounts(online: 3, total: 12);
        await tester.pumpWidget(
          wrap(
            ChatPage(
              group: groupA,
              chat: chat,
              profile: profile,
              shared: shared,
              groups: groups,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(badgeText(tester), '3/12');

        final Completer<GroupMemberPage> olderGate =
            Completer<GroupMemberPage>();
        final Completer<GroupMemberPage> newerGate =
            Completer<GroupMemberPage>();
        groupApi.queuedReplies.addAll(<Completer<GroupMemberPage>>[
          olderGate,
          newerGate,
        ]);

        // First poll starts olderGate.
        await tester.pump(const Duration(seconds: 3));
        await tester.pump();

        // User triggers manual refresh while olderGate is still pending.
        await tester.tap(find.byKey(ChatPage.refreshKey));
        await tester.pump();

        newerGate.complete(
          const GroupMemberPage(
            items: <GroupMember>[],
            counts: GroupMemberCounts(online: 6, total: 12),
          ),
        );
        await tester.pumpAndSettle();
        expect(badgeText(tester), '6/12');

        olderGate.complete(
          const GroupMemberPage(
            items: <GroupMember>[],
            counts: GroupMemberCounts(online: 1, total: 12),
          ),
        );
        await tester.pumpAndSettle();
        expect(badgeText(tester), '6/12');
      },
    );

    testWidgets(
      'desktop split workspace shares ChatHeader without back button and isolates switched groups',
      (WidgetTester tester) async {
        groupApi.countsByGroup[groupA.conversation.id] =
            const GroupMemberCounts(online: 3, total: 12);
        groupApi.countsByGroup[groupB.conversation.id] =
            const GroupMemberCounts(online: 7, total: 20);

        tester.view.physicalSize = const Size(1280, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          wrap(
            Scaffold(
              body: ChatWorkspace(
                chat: chat,
                profile: profile,
                shared: shared,
                groups: groups,
                listHeader: const SizedBox(height: 48),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Tap group A in the left conversation pane.
        await tester.tap(
          find.byKey(UsersListView.groupRowKey(groupA.conversation.id)),
        );
        await tester.pumpAndSettle();

        final Finder chatPane = find.byKey(ChatWorkspace.chatPaneKey);
        final Finder desktopHeader = find.descendant(
          of: chatPane,
          matching: find.byType(ChatHeader),
        );
        expect(desktopHeader, findsOneWidget);
        expect(
          find.descendant(of: desktopHeader, matching: find.byType(BackButton)),
          findsNothing,
        );
        final Rect paneRect = tester.getRect(chatPane);
        final Rect avatarRect = tester.getRect(
          find.descendant(
            of: desktopHeader,
            matching: find.byType(ProfileAvatar),
          ),
        );
        expect(avatarRect.left - paneRect.left, 16);
        expect(
          find.descendant(
            of: desktopHeader,
            matching: find.text('3/12', findRichText: true),
          ),
          findsOneWidget,
        );

        // Switch to group B while refreshing group A does not leak.
        await tester.tap(
          find.byKey(UsersListView.groupRowKey(groupB.conversation.id)),
        );
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: chatPane,
            matching: find.text('7/20', findRichText: true),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'direct 1:1 chat keeps original presence header without badge',
      (WidgetTester tester) async {
        await tester.pumpWidget(
          wrap(ChatPage(peer: bob, chat: chat, profile: profile)),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(ChatPage.headerNameKey), findsOneWidget);
        expect(find.text('bob'), findsOneWidget);
        expect(find.text('在线'), findsOneWidget);
        expect(find.byKey(ChatPage.headerGroupCountKey), findsNothing);
        expect(groupApi.memberCalls, isEmpty);
      },
    );
  });
}
