import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bb_client/app.dart';
import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/services/auth_api_client.dart';
import 'package:bb_client/services/auth_service.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/avatar_cache.dart';
import 'package:bb_client/services/group_api_client.dart';
import 'package:bb_client/services/group_service.dart';
import 'package:bb_client/services/heartbeat_controller.dart';
import 'package:bb_client/services/http_transport.dart';
import 'package:bb_client/ui/home_view.dart';
import 'package:bb_client/ui/notifications/notification_center.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_auth_gateway.dart';
import 'support/fake_chat_service.dart';
import 'support/fake_profile_gateway.dart';

List<NotificationEntry> _buildSampleEntries({
  VoidCallback? onDetails,
  VoidCallback? onMarkRead,
  void Function(String id, String action)? onAction,
}) {
  return <NotificationEntry>[
    NotificationEntry(
      id: 'invite-run',
      type: 'group_invitation',
      title: '入群邀请',
      body: '林小满 邀请你加入「周末跑团」',
      timeLabel: '3 分钟前',
      read: false,
      statusLabel: '待处理',
      actions: <NotificationEntryAction>[
        NotificationEntryAction(
          id: 'accept',
          label: '接受',
          onPressed: () => onAction?.call('invite-run', 'accept'),
        ),
        NotificationEntryAction(
          id: 'reject',
          label: '拒绝',
          onPressed: () => onAction?.call('invite-run', 'reject'),
        ),
      ],
      onOpenDetails: onDetails,
      onMarkRead: onMarkRead,
    ),
    NotificationEntry(
      id: 'apply-design',
      type: 'group_application',
      title: '入群申请',
      body: '陈以宁 申请加入「设计交流群」',
      timeLabel: '26 分钟前',
      read: true,
      statusLabel: '待处理',
      actions: <NotificationEntryAction>[
        NotificationEntryAction(
          id: 'approve',
          label: '同意',
          onPressed: () => onAction?.call('apply-design', 'approve'),
        ),
        NotificationEntryAction(
          id: 'reject',
          label: '拒绝',
          onPressed: () => onAction?.call('apply-design', 'reject'),
        ),
      ],
      onOpenDetails: onDetails,
    ),
    NotificationEntry(
      id: 'result-book',
      type: 'group_join_result',
      title: '入群结果',
      body: '群主同意了你的「旧书交换」入群申请',
      timeLabel: '1 小时前',
      read: false,
      statusLabel: '仅告知',
      onOpenDetails: onDetails,
      onMarkRead: onMarkRead,
    ),
    NotificationEntry(
      id: 'left-run',
      type: 'group_member_left',
      title: '成员退出',
      body: '苏晚 退出了「周末跑团」',
      timeLabel: '昨天 21:40',
      read: true,
      statusLabel: '仅告知',
      onOpenDetails: onDetails,
    ),
    NotificationEntry(
      id: 'removed-canteen',
      type: 'group_member_removed',
      title: '移出群聊',
      body: '林小满 将你移出了「深夜食堂」',
      timeLabel: '昨天 09:12',
      read: false,
      statusLabel: '仅告知',
      onOpenDetails: onDetails,
      onMarkRead: onMarkRead,
    ),
    NotificationEntry(
      id: 'invite-film',
      type: 'group_invitation',
      title: '入群邀请',
      body: '周野 邀请你加入「胶片摄影社」\n处理结果：已接受',
      timeLabel: '11月26日',
      read: true,
      statusLabel: '已处理',
      onOpenDetails: onDetails,
    ),
    NotificationEntry(
      id: 'dissolved-books',
      type: 'group_dissolved',
      title: '群已解散',
      body: '沈迟 解散了「城市漫步与旧书交换」',
      timeLabel: '11月25日',
      read: true,
      statusLabel: '仅告知',
      onOpenDetails: onDetails,
    ),
  ];
}

class _AllowLoopbackHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)..idleTimeout = Duration.zero;
}

class _FakeNoticeLoopbackServer {
  late HttpServer _server;
  Uri get baseUri => Uri.parse('http://127.0.0.1:${_server.port}');

  final List<String> executed = <String>[];
  final List<Map<String, dynamic>> notices = <Map<String, dynamic>>[
    <String, dynamic>{
      'id': 'n-invite',
      'type': 'group_invitation',
      'title': '入群邀请',
      'text': '林小满 邀请你加入「周末跑团」',
      'created_at': '2026-11-28T10:11:00Z',
      'read': false,
      'state': 'pending',
      'actions': <Map<String, dynamic>>[
        <String, dynamic>{'id': 'accept', 'label': '接受', 'available': true},
        <String, dynamic>{'id': 'reject', 'label': '拒绝', 'available': true},
      ],
      'link': <String, dynamic>{'type': 'group', 'id': '10000010'},
    },
    <String, dynamic>{
      'id': 'n-apply',
      'type': 'group_application',
      'title': '入群申请',
      'text': '陈以宁 申请加入「设计交流群」',
      'created_at': '2026-11-28T09:48:00Z',
      'read': true,
      'state': 'pending',
      'actions': <Map<String, dynamic>>[
        <String, dynamic>{'id': 'approve', 'label': '同意', 'available': true},
        <String, dynamic>{'id': 'reject', 'label': '拒绝', 'available': true},
      ],
      'link': <String, dynamic>{'type': 'group', 'id': '10000011'},
    },
    <String, dynamic>{
      'id': 'n-result',
      'type': 'group_join_result',
      'title': '入群结果',
      'text': '群主同意了你的「旧书交换」入群申请',
      'created_at': '2026-11-28T09:14:00Z',
      'read': false,
      'state': 'informational',
      'actions': const <Map<String, dynamic>>[],
      'link': <String, dynamic>{'type': 'group', 'id': '10000012'},
    },
    <String, dynamic>{
      'id': 'n-left',
      'type': 'group_member_left',
      'title': '成员退出',
      'text': '苏晚 退出了「周末跑团」',
      'created_at': '2026-11-27T21:40:00Z',
      'read': true,
      'state': 'informational',
      'actions': const <Map<String, dynamic>>[],
      'link': <String, dynamic>{'type': 'group', 'id': '10000010'},
    },
    <String, dynamic>{
      'id': 'n-removed',
      'type': 'group_member_removed',
      'title': '移出群聊',
      'text': '林小满 将你移出了「深夜食堂」',
      'created_at': '2026-11-27T09:12:00Z',
      'read': false,
      'state': 'informational',
      'actions': const <Map<String, dynamic>>[],
      'link': <String, dynamic>{'type': 'group', 'id': '10000013'},
    },
    <String, dynamic>{
      'id': 'n-dissolved',
      'type': 'group_dissolved',
      'title': '群已解散',
      'text': '沈迟 解散了「城市漫步与旧书交换」',
      'created_at': '2026-11-25T12:00:00Z',
      'read': true,
      'state': 'informational',
      'actions': const <Map<String, dynamic>>[],
      'link': <String, dynamic>{'type': 'group', 'id': '10000014'},
    },
  ];

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.idleTimeout = null;
    unawaited(_serve());
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _serve() async {
    await for (final HttpRequest request in _server) {
      final String body = await utf8.decodeStream(request);
      final Map<String, dynamic>? jsonBody = body.isEmpty
          ? null
          : jsonDecode(body) as Map<String, dynamic>;
      final String path = request.uri.path;
      if (path == '/chat/notices/list') {
        final String filter = (jsonBody?['filter'] as String?) ?? 'all';
        final String? cursor = jsonBody?['cursor'] as String?;
        final int limit = (jsonBody?['limit'] as int?) ?? 50;
        final List<Map<String, dynamic>> filtered = filter == 'pending'
            ? notices
                  .where((Map<String, dynamic> n) => n['state'] == 'pending')
                  .toList()
            : notices;
        int start = 0;
        if (cursor != null) {
          final int idx = filtered.indexWhere(
            (Map<String, dynamic> n) => n['id'] == cursor,
          );
          if (idx >= 0) {
            start = idx + 1;
          }
        }
        final List<Map<String, dynamic>> pageItems = filtered
            .skip(start)
            .take(limit)
            .toList();
        final String? nextCursor = start + pageItems.length < filtered.length
            ? pageItems.last['id'] as String
            : null;
        await _writeJson(request, 200, <String, dynamic>{
          'items': pageItems,
          'next_cursor': nextCursor,
          'unread_count': notices
              .where((Map<String, dynamic> n) => n['read'] == false)
              .length,
          'pending_count': notices
              .where((Map<String, dynamic> n) => n['state'] == 'pending')
              .length,
        });
        continue;
      }
      if (path == '/chat/notices/mark_read') {
        final String id = jsonBody!['notification_id'] as String;
        final Map<String, dynamic> item = notices.firstWhere(
          (Map<String, dynamic> n) => n['id'] == id,
        );
        item['read'] = true;
        await _writeJson(request, 200, item);
        continue;
      }
      if (path == '/chat/notices/execute_action') {
        final String id = jsonBody!['notification_id'] as String;
        final String actionId = jsonBody['action_id'] as String;
        executed.add('$id:$actionId');
        final Map<String, dynamic> item = notices.firstWhere(
          (Map<String, dynamic> n) => n['id'] == id,
        );
        item['state'] = 'processed';
        item['actions'] = <Map<String, dynamic>>[];
        final String verb = switch (actionId) {
          'accept' => '接受',
          'approve' => '同意',
          'reject' => '拒绝',
          _ => actionId,
        };
        item['text'] = '${item['text']}\n处理结果：已$verb';
        await _writeJson(request, 200, item);
        continue;
      }
      if (path == '/groups/find') {
        final String groupNumber = jsonBody!['group_number'] as String;
        await _writeJson(request, 200, <String, dynamic>{
          'conversation': <String, dynamic>{
            'type': 'group',
            'id': 'grp-$groupNumber',
          },
          'group_number': groupNumber,
          'name': '周末跑团',
          'description': '群资料测试',
          'avatar_url': '',
          'avatar_version': '',
          'status': groupNumber == '10000014' ? 'dissolved' : 'active',
          'role': null,
          'can_invite': false,
        });
        continue;
      }
      if (path == '/chat/conversations') {
        await _writeJson(request, 200, <String, dynamic>{
          'items': const <dynamic>[],
          'next_cursor': null,
        });
        continue;
      }
      await _writeJson(request, 404, <String, dynamic>{'error': 'not_found'});
    }
  }

  Future<void> _writeJson(
    HttpRequest request,
    int status,
    Object payload,
  ) async {
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(payload));
    await request.response.close();
  }
}

void main() {
  Future<void> pumpNotificationCenter(
    WidgetTester tester,
    Widget child, {
    required Size size,
    double textScale = 1.0,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        builder: (BuildContext context, Widget? content) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
            disableAnimations: true,
          ),
          child: content!,
        ),
        home: child,
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('1440x900 desktop split layout matches A v5 design', (
    WidgetTester tester,
  ) async {
    final List<NotificationEntry> entries = _buildSampleEntries(
      onDetails: () {},
      onMarkRead: () {},
    );
    await pumpNotificationCenter(
      tester,
      NotificationCenter(entries: entries),
      size: const Size(1440, 900),
    );

    expect(find.text('需要你处理'), findsOneWidget);
    expect(find.text('通知记录'), findsOneWidget);

    final Rect pendingCardRect = tester.getRect(
      find.byKey(NotificationCenter.entryKey('invite-run')),
    );
    final Rect historyRowRect = tester.getRect(
      find.byKey(NotificationCenter.entryKey('result-book')),
    );
    // Left pending column sits strictly to the left of right history column.
    expect(pendingCardRect.right, lessThan(historyRowRect.left));

    // Desktop keeps inline text links and hides mobile "更多" trigger.
    expect(find.text('查看资料'), findsNWidgets(7));
    expect(find.text('标为已读'), findsNWidgets(3));
    expect(find.text('更多'), findsNothing);

    // No single-side color stripe on pending card.
    final Container cardContainer = tester.widget<Container>(
      find.byKey(NotificationCenter.entryKey('invite-run')),
    );
    final BoxDecoration decoration = cardContainer.decoration! as BoxDecoration;
    final Border border = decoration.border! as Border;
    expect(border.isUniform, isTrue);

    expect(tester.takeException(), isNull);
  });

  testWidgets(
    '390x844 mobile compact card, equal-width actions, sheet, and heights',
    (WidgetTester tester) async {
      int detailsCalls = 0;
      int markReadCalls = 0;
      final List<NotificationEntry> entries = _buildSampleEntries(
        onDetails: () => detailsCalls += 1,
        onMarkRead: () => markReadCalls += 1,
      );
      await pumpNotificationCenter(
        tester,
        NotificationCenter(entries: entries),
        size: const Size(390, 844),
      );

      final Rect cardRect = tester.getRect(
        find.byKey(NotificationCenter.entryKey('invite-run')),
      );
      final Rect rowRect = tester.getRect(
        find.byKey(NotificationCenter.entryKey('result-book')),
      );
      expect(cardRect.height, lessThanOrEqualTo(190));
      expect(rowRect.height, lessThanOrEqualTo(130));

      final Rect acceptRect = tester.getRect(
        find.byKey(NotificationCenter.actionKey('invite-run', 'accept')),
      );
      final Rect rejectRect = tester.getRect(
        find.byKey(NotificationCenter.actionKey('invite-run', 'reject')),
      );
      final Rect moreRect = tester.getRect(
        find.byKey(NotificationCenter.moreKey('invite-run')),
      );

      // Equal width and aligned on the same action row, touch target >= 44px.
      expect((acceptRect.width - rejectRect.width).abs(), lessThanOrEqualTo(1));
      expect(acceptRect.top, moreOrLessEquals(rejectRect.top, epsilon: 1));
      expect(acceptRect.height, greaterThanOrEqualTo(44));
      expect(rejectRect.height, greaterThanOrEqualTo(44));
      expect(moreRect.height, greaterThanOrEqualTo(44));
      expect(moreRect.top, moreOrLessEquals(acceptRect.top, epsilon: 1));
      expect(moreRect.right, lessThanOrEqualTo(390));

      // Inline links are hidden on mobile.
      expect(find.text('查看资料'), findsNothing);
      expect(find.text('标为已读'), findsNothing);

      // Open bottom sheet via "更多".
      await tester.tap(find.byKey(NotificationCenter.moreKey('invite-run')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(NotificationCenter.sheetActionKey('invite-run', 'details')),
        findsOneWidget,
      );
      expect(
        find.byKey(
          NotificationCenter.sheetActionKey('invite-run', 'mark-read'),
        ),
        findsOneWidget,
      );
      expect(find.text('取消'), findsOneWidget);

      await tester.tap(
        find.byKey(
          NotificationCenter.sheetActionKey('invite-run', 'mark-read'),
        ),
      );
      await tester.pumpAndSettle();
      expect(markReadCalls, 1);

      // Open sheet from history row and tap "查看资料".
      await tester.ensureVisible(
        find.byKey(NotificationCenter.moreKey('result-book')),
      );
      await tester.tap(find.byKey(NotificationCenter.moreKey('result-book')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(NotificationCenter.sheetActionKey('result-book', 'details')),
      );
      await tester.pumpAndSettle();
      expect(detailsCalls, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('320px narrow mobile keeps primary actions and 更多 on one row', (
    WidgetTester tester,
  ) async {
    final List<NotificationEntry> entries = _buildSampleEntries(
      onDetails: () {},
      onMarkRead: () {},
    );
    await pumpNotificationCenter(
      tester,
      NotificationCenter(entries: entries),
      size: const Size(320, 568),
    );

    final Rect acceptRect = tester.getRect(
      find.byKey(NotificationCenter.actionKey('invite-run', 'accept')),
    );
    final Rect rejectRect = tester.getRect(
      find.byKey(NotificationCenter.actionKey('invite-run', 'reject')),
    );
    final Rect moreRect = tester.getRect(
      find.byKey(NotificationCenter.moreKey('invite-run')),
    );

    expect(acceptRect.top, moreOrLessEquals(rejectRect.top, epsilon: 1));
    expect(moreRect.top, moreOrLessEquals(acceptRect.top, epsilon: 1));
    expect(acceptRect.right, lessThan(rejectRect.left));
    expect(rejectRect.right, lessThan(moreRect.left));
    expect(moreRect.right, lessThanOrEqualTo(320));
    expect(tester.takeException(), isNull);
  });

  for (final double width in <double>[
    320,
    390,
    560,
    720,
    721,
    960,
    961,
    1440,
  ]) {
    testWidgets('responsive layout has zero overflow at width $width', (
      WidgetTester tester,
    ) async {
      final List<NotificationEntry> entries = _buildSampleEntries(
        onDetails: () {},
        onMarkRead: () {},
      );
      await pumpNotificationCenter(
        tester,
        NotificationCenter(entries: entries),
        size: Size(width, 900),
      );
      if (width <= 720) {
        expect(
          find.byKey(NotificationCenter.moreKey('invite-run')),
          findsOneWidget,
        );
      } else {
        expect(
          find.byKey(NotificationCenter.moreKey('invite-run')),
          findsNothing,
        );
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('empty, cleared, pending-empty, error, and status states render', (
    WidgetTester tester,
  ) async {
    // 1. Completely empty list shows title only (no extra reset/demo buttons).
    await pumpNotificationCenter(
      tester,
      const NotificationCenter(entries: <NotificationEntry>[]),
      size: const Size(390, 844),
    );
    expect(find.text('暂无通知'), findsAtLeastNWidgets(1));
    expect(find.text('重新加载'), findsNothing);
    expect(find.text('查看全部通知'), findsNothing);

    // 2. Error state shows retry button.
    int retries = 0;
    await pumpNotificationCenter(
      tester,
      NotificationCenter(error: '网络异常', onRetry: () => retries += 1),
      size: const Size(390, 844),
    );
    expect(find.text('网络异常'), findsOneWidget);
    await tester.tap(find.text('重新加载'));
    await tester.pump();
    expect(retries, 1);

    // 3. History-only entries: left cleared box in All, pending-empty switch back.
    final List<NotificationEntry> historyOnly = _buildSampleEntries()
        .where((NotificationEntry e) => !e.pending)
        .toList();
    await pumpNotificationCenter(
      tester,
      NotificationCenter(entries: historyOnly),
      size: const Size(1440, 900),
    );
    expect(find.text('待处理已清空'), findsAtLeastNWidgets(1));
    expect(find.text('已处理'), findsOneWidget);
    expect(find.text('仅告知'), findsAtLeastNWidgets(1));

    await tester.tap(find.byKey(NotificationCenter.pendingKey));
    await tester.pumpAndSettle();
    expect(find.text('没有待处理的通知'), findsOneWidget);
    await tester.tap(find.text('查看全部通知'));
    await tester.pumpAndSettle();
    expect(find.text('需要你处理'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'real HomeView entrypoint hosts NotificationCenterHost across desktop and mobile',
    (WidgetTester tester) async {
      final HttpOverrides? previousOverrides = HttpOverrides.current;
      HttpOverrides.global = _AllowLoopbackHttpOverrides();
      addTearDown(() {
        HttpOverrides.global = previousOverrides;
      });
      final _FakeNoticeLoopbackServer server = _FakeNoticeLoopbackServer();
      await tester.runAsync(server.start);
      addTearDown(() async {
        await server.close();
      });

      final Directory tempDir = Directory.systemTemp.createTempSync(
        'bb-notice-v5-',
      );
      addTearDown(() {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      });

      const AuthUser selfUser = AuthUser(account: '10000001', username: '我');
      final AuthSession session = AuthSession()
        ..establish(token: 'test-token', user: selfUser);
      final HttpTransport transport = HttpTransport(
        factory: () => HttpClient(),
      );
      final GroupService groups = GroupService(
        api: GroupApiClient(baseUri: server.baseUri, transport: transport),
        session: session,
        avatarCache: AvatarCache(directory: tempDir),
      );
      final FakeChatService chat = FakeChatService(
        self: selfUser,
        users: const <ChatUser>[],
      );
      final FakeProfileGateway profile = FakeProfileGateway();
      final HeartbeatController heartbeat = HeartbeatController(
        auth: AuthService(
          api: AuthApiClient(baseUri: server.baseUri),
          session: session,
        ),
      );
      addTearDown(heartbeat.dispose);

      Widget buildHome() => HomeView(
        user: selfUser,
        profile: profile,
        auth: FakeAuthGateway(),
        heartbeat: heartbeat,
        chat: chat,
        groups: groups,
        onSignedOut: (_) {},
        onSessionExpired: () {},
      );

      Future<void> settleHttp() async {
        for (int i = 0; i < 15; i += 1) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 25)),
          );
          await tester.pump(const Duration(milliseconds: 25));
        }
      }

      await pumpNotificationCenter(
        tester,
        buildHome(),
        size: const Size(1440, 900),
      );
      await settleHttp();

      await tester.tap(find.byKey(HomeView.navNotificationsKey));
      await settleHttp();

      // Verify read-but-pending is in 待处理 and unread count is rendered.
      expect(find.textContaining('2 条需要你处理'), findsOneWidget);
      expect(find.textContaining('3 条未读'), findsOneWidget);
      expect(
        find.byKey(NotificationCenter.entryKey('n-invite')),
        findsOneWidget,
      );
      expect(
        find.byKey(NotificationCenter.entryKey('n-apply')),
        findsOneWidget,
      );

      // Mark invitation read -> remains pending (2 pending, 2 unread).
      await tester.tap(find.text('标为已读').first);
      await settleHttp();
      expect(find.textContaining('2 条需要你处理'), findsOneWidget);
      expect(find.textContaining('2 条未读'), findsOneWidget);

      // Accept invitation and reject application -> clears pending section.
      await tester.tap(
        find.byKey(NotificationCenter.actionKey('n-invite', 'accept')),
      );
      await settleHttp();
      expect(server.executed, contains('n-invite:accept'));
      expect(find.textContaining('1 条需要你处理'), findsOneWidget);

      await tester.tap(
        find.byKey(NotificationCenter.actionKey('n-apply', 'reject')),
      );
      await settleHttp();
      expect(server.executed, contains('n-apply:reject'));
      expect(find.textContaining('待处理已清空'), findsAtLeastNWidgets(1));

      // Verify mobile resize to 390x844 works cleanly without overflow.
      tester.view.physicalSize = const Size(390, 844);
      await tester.pumpAndSettle();
      expect(
        find.byKey(NotificationCenter.moreKey('n-result')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 35));
    },
  );

  testWidgets(
    'paged older pending invitation does not show cleared message on page 1',
    (WidgetTester tester) async {
      final List<NotificationEntry> history = List<NotificationEntry>.generate(
        100,
        (int i) => NotificationEntry(
          id: 'history-$i',
          type: 'group_join_result',
          title: '入群结果',
          body: '入群申请已通过',
          timeLabel: '昨天',
          read: true,
          statusLabel: '仅告知',
        ),
      );
      await pumpNotificationCenter(
        tester,
        NotificationCenter(
          entries: history,
          hasMore: true,
          pendingOnly: false,
          pendingCount: 1,
          unreadCount: 1,
          onLoadMore: () {},
        ),
        size: const Size(1440, 900),
      );

      expect(find.textContaining('1 条需要你处理'), findsOneWidget);
      expect(find.text('待处理已清空'), findsNothing);
      expect(find.text('还有 1 条待处理'), findsOneWidget);

      // Narrow 320px width also renders without horizontal overflow.
      await pumpNotificationCenter(
        tester,
        NotificationCenter(
          entries: history,
          hasMore: true,
          pendingOnly: false,
          pendingCount: 1,
          unreadCount: 1,
          onLoadMore: () {},
        ),
        size: const Size(320, 568),
      );
      expect(find.text('待处理已清空'), findsNothing);
      expect(find.text('还有 1 条待处理'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'HomeView paginated 101st pending notice avoids false cleared and opens via 查看待处理',
    (WidgetTester tester) async {
      final HttpOverrides? previousOverrides = HttpOverrides.current;
      HttpOverrides.global = _AllowLoopbackHttpOverrides();
      addTearDown(() {
        HttpOverrides.global = previousOverrides;
      });
      final _FakeNoticeLoopbackServer server = _FakeNoticeLoopbackServer();
      server.notices
        ..clear()
        ..addAll(<Map<String, dynamic>>[
          for (int i = 0; i < 100; i += 1)
            <String, dynamic>{
              'id': 'hist-$i',
              'type': 'group_join_result',
              'title': '入群结果',
              'text': '入群申请已通过',
              'created_at': '2026-11-28T09:00:00Z',
              'read': true,
              'state': 'informational',
              'actions': const <Map<String, dynamic>>[],
              'link': null,
            },
          <String, dynamic>{
            'id': 'invite-101',
            'type': 'group_invitation',
            'title': '入群邀请',
            'text': '林小满 邀请你加入「周末跑团」',
            'created_at': '2026-11-27T09:00:00Z',
            'read': false,
            'state': 'pending',
            'actions': <Map<String, dynamic>>[
              <String, dynamic>{
                'id': 'accept',
                'label': '接受',
                'available': true,
              },
              <String, dynamic>{
                'id': 'reject',
                'label': '拒绝',
                'available': true,
              },
            ],
            'link': null,
          },
        ]);
      await tester.runAsync(server.start);
      addTearDown(() async {
        await server.close();
      });

      final Directory tempDir = Directory.systemTemp.createTempSync(
        'bb-notice-paged-',
      );
      addTearDown(() {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      });

      const AuthUser selfUser = AuthUser(account: '10000001', username: '我');
      final AuthSession session = AuthSession()
        ..establish(token: 'test-token', user: selfUser);
      final HttpTransport transport = HttpTransport(
        factory: () => HttpClient(),
      );
      final GroupService groups = GroupService(
        api: GroupApiClient(baseUri: server.baseUri, transport: transport),
        session: session,
        avatarCache: AvatarCache(directory: tempDir),
      );
      final FakeChatService chat = FakeChatService(
        self: selfUser,
        users: const <ChatUser>[],
      );
      final FakeProfileGateway profile = FakeProfileGateway();
      final HeartbeatController heartbeat = HeartbeatController(
        auth: AuthService(
          api: AuthApiClient(baseUri: server.baseUri),
          session: session,
        ),
      );
      addTearDown(heartbeat.dispose);

      Future<void> settleHttp() async {
        for (int i = 0; i < 15; i += 1) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 25)),
          );
          await tester.pump(const Duration(milliseconds: 25));
        }
      }

      await pumpNotificationCenter(
        tester,
        HomeView(
          user: selfUser,
          profile: profile,
          auth: FakeAuthGateway(),
          heartbeat: heartbeat,
          chat: chat,
          groups: groups,
          onSignedOut: (_) {},
          onSessionExpired: () {},
        ),
        size: const Size(1440, 900),
      );
      await settleHttp();

      await tester.tap(find.byKey(HomeView.navNotificationsKey));
      await settleHttp();

      expect(find.textContaining('1 条需要你处理'), findsOneWidget);
      expect(find.text('待处理已清空'), findsNothing);
      expect(find.text('还有 1 条待处理'), findsOneWidget);

      await tester.tap(find.text('查看待处理'));
      await settleHttp();

      expect(
        find.byKey(NotificationCenter.entryKey('invite-101')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(NotificationCenter.actionKey('invite-101', 'accept')),
      );
      await settleHttp();
      expect(server.executed, contains('invite-101:accept'));
      expect(find.text('没有待处理的通知'), findsOneWidget);

      await tester.tap(find.byKey(NotificationCenter.allKey));
      await settleHttp();
      expect(find.text('待处理已清空'), findsAtLeastNWidgets(1));
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 35));
    },
  );
}
