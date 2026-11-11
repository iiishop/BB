import 'package:bb_client/app.dart';
import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/services/auth_api_client.dart';
import 'package:bb_client/services/auth_service.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/heartbeat_controller.dart';
import 'package:bb_client/ui/home_view.dart';
import 'package:bb_client/ui/login_page.dart';
import 'package:bb_client/ui/profile/profile_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_auth_gateway.dart';
import 'support/fake_profile_gateway.dart';

const AuthUser _user = AuthUser(account: '40218765', username: 'muse.tester');

/// Heartbeat transport double: no real network inside widget tests.
class _ScriptedAuthApi extends AuthApiClient {
  _ScriptedAuthApi() : super(baseUri: Uri.parse('http://127.0.0.1:1'));

  int heartbeatStatus = 200;
  int heartbeatCalls = 0;
  int logoutCalls = 0;

  @override
  Future<void> heartbeat(String token) async {
    heartbeatCalls += 1;
    if (heartbeatStatus == 401) {
      throw unauthenticated;
    }
    if (heartbeatStatus != 200) {
      throw const AuthFailure(
        status: 503,
        code: 'storage_unavailable',
        message: '存储暂不可用',
      );
    }
  }

  @override
  Future<void> logout(String token) async {
    logoutCalls += 1;
  }
}

void main() {
  late _ScriptedAuthApi api;
  late AuthService auth;
  late AuthSession session;

  setUp(() {
    api = _ScriptedAuthApi();
    session = AuthSession()..establish(token: 'widget-test-token', user: _user);
    auth = AuthService(api: api, session: session);
  });

  Widget home({
    required FakeProfileGateway profile,
    required FakeAuthGateway gateway,
    required HeartbeatController heartbeat,
    required VoidCallback onSignedOut,
  }) {
    return MaterialApp(
      theme: buildAppTheme(),
      home: HomeView(
        user: _user,
        profile: profile,
        auth: gateway,
        heartbeat: heartbeat,
        onSignedOut: (LogoutResult? _) => onSignedOut(),
        onSessionExpired: onSignedOut,
      ),
    );
  }

  testWidgets('three missed beats show the reconnect banner and keep login', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    api.heartbeatStatus = 503;
    final HeartbeatController heartbeat = HeartbeatController(auth: auth);
    addTearDown(heartbeat.dispose);
    final FakeProfileGateway profile = FakeProfileGateway();
    final FakeAuthGateway gateway = FakeAuthGateway();
    bool signedOut = false;

    await tester.pumpWidget(
      home(
        profile: profile,
        gateway: gateway,
        heartbeat: heartbeat,
        onSignedOut: () => signedOut = true,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(HomeView.reconnectingBannerKey), findsNothing);

    for (int i = 0; i < 3; i++) {
      await heartbeat.beatNow();
    }
    await tester.pumpAndSettle();

    expect(find.byKey(HomeView.reconnectingBannerKey), findsOneWidget);
    expect(find.text('连接已断开，正在重连'), findsOneWidget);
    expect(signedOut, isFalse, reason: 'offline must not log the user out');
    expect(find.byKey(HomeView.avatarEntryKey), findsOneWidget);
    expect(session.hasToken, isTrue, reason: 'credentials are retained');

    api.heartbeatStatus = 200;
    await heartbeat.beatNow();
    await tester.pumpAndSettle();
    expect(find.byKey(HomeView.reconnectingBannerKey), findsNothing);
  });

  testWidgets('the bottom-left avatar opens Profile in the phone layout', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final HeartbeatController heartbeat = HeartbeatController(auth: auth);
    addTearDown(heartbeat.dispose);
    await tester.pumpWidget(
      home(
        profile: FakeProfileGateway(),
        gateway: FakeAuthGateway(),
        heartbeat: heartbeat,
        onSignedOut: () {},
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(HomeView.avatarEntryKey));
    await tester.pumpAndSettle();

    final ProfilePanel panel = tester.widget<ProfilePanel>(
      find.byType(ProfilePanel),
    );
    expect(panel.mode, ProfilePanelMode.mobile);
    expect(find.byKey(ProfilePanel.accountValueKey), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(ProfilePanel.accountValueKey)).data,
      '40218765',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a 401 on profile load asks the auth flow to expire the session',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final HeartbeatController heartbeat = HeartbeatController(auth: auth);
      addTearDown(heartbeat.dispose);
      final FakeProfileGateway profile = FakeProfileGateway()
        ..failure = unauthenticated;
      bool expired = false;
      await tester.pumpWidget(
        home(
          profile: profile,
          gateway: FakeAuthGateway(),
          heartbeat: heartbeat,
          onSignedOut: () => expired = true,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(expired, isTrue);
    },
  );

  testWidgets('heartbeat 401 returns the whole app to login', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final FakeAuthGateway gateway = FakeAuthGateway()..restoreResult = _user;
    final HeartbeatController heartbeat = HeartbeatController(auth: auth);
    addTearDown(heartbeat.dispose);
    await tester.pumpWidget(
      BbClientApp(
        authGateway: gateway,
        profile: FakeProfileGateway(),
        heartbeat: heartbeat,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(HomeView), findsOneWidget);

    api.heartbeatStatus = 401;
    await heartbeat.beatNow();
    await tester.pumpAndSettle();

    expect(find.byType(LoginPage), findsOneWidget);
    expect(find.text('登录已失效，请重新登录'), findsOneWidget);
    expect(gateway.signedOut, isTrue);
  });

  testWidgets(
    'logout from the panel returns to login and stops the heartbeat',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final FakeAuthGateway gateway = FakeAuthGateway()..restoreResult = _user;
      final HeartbeatController heartbeat = HeartbeatController(auth: auth);
      addTearDown(heartbeat.dispose);
      await tester.pumpWidget(
        BbClientApp(
          authGateway: gateway,
          profile: FakeProfileGateway(),
          heartbeat: heartbeat,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(HomeView.avatarEntryKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ProfilePanel.logoutButtonKey));
      await tester.pumpAndSettle();

      expect(gateway.signedOut, isTrue);
      expect(find.byType(LoginPage), findsOneWidget);
      expect(heartbeat.phase, HeartbeatPhase.idle);
    },
  );
}
