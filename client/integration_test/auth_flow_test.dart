import 'dart:convert';
import 'dart:io';

import 'package:bb_client/app.dart';
import 'package:bb_client/services/auth_api_client.dart';
import 'package:bb_client/services/auth_service.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/avatar_cache.dart';
import 'package:bb_client/services/heartbeat_controller.dart';
import 'package:bb_client/services/profile_api_client.dart';
import 'package:bb_client/services/profile_service.dart';
import 'package:bb_client/services/session_store.dart';
import 'package:bb_client/ui/auth_shell.dart';
import 'package:bb_client/ui/home_view.dart';
import 'package:bb_client/ui/profile/profile_panel.dart';
import 'package:bb_client/ui/login_page.dart';
import 'package:bb_client/ui/register_page.dart';
import 'package:bb_client/ui/signed_in_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/support/fake_auth_backend.dart';

/// Linux desktop end-to-end coverage of STEP-1 against a real HTTP upstream.
///
/// Run with: `flutter test integration_test -d linux`.
///
/// The Linux device can only launch one app per `flutter test` invocation, so
/// every desktop integration case lives in this single `*_test.dart` file.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late FakeAuthBackend backend;
  late Uri backendBaseUri;
  late Directory directory;
  late SessionStore store;

  setUpAll(() async {
    backend = await FakeAuthBackend.start();
    backendBaseUri = backend.baseUri;
  });

  tearDownAll(() async {
    await backend.close();
  });

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('bb-integration-');
    store = SessionStore.atPath('${directory.path}/session.json');
  });

  tearDown(() async {
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });

  AuthService newService() {
    return AuthService(
      api: AuthApiClient(baseUri: backendBaseUri),
      session: AuthSession(),
      store: SessionStore.atPath(store.file.path),
    );
  }

  Finder editable(Key key) =>
      find.descendant(of: find.byKey(key), matching: find.byType(EditableText));

  Future<void> pumpApp(
    WidgetTester tester,
    AuthGateway gateway, {
    Size size = const Size(390, 844),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(BbClientApp(authGateway: gateway));
    await tester.pumpAndSettle();
  }

  testWidgets('real HTTP: register → account → copy → login → signed in', (
    WidgetTester tester,
  ) async {
    final List<String> clipboard = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (
          MethodCall call,
        ) async {
          if (call.method == 'Clipboard.setData') {
            final Map<dynamic, dynamic> arguments =
                call.arguments as Map<dynamic, dynamic>;
            clipboard.add(arguments['text'] as String);
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    final AuthService service = newService();
    await pumpApp(tester, service);

    await tester.tap(find.byKey(LoginPage.registerLinkKey));
    await tester.pumpAndSettle();
    await tester.enterText(editable(RegisterPage.usernameFieldKey), '桌面用户');
    await tester.enterText(editable(RegisterPage.passwordFieldKey), 'Secret42');
    await tester.enterText(editable(RegisterPage.confirmFieldKey), 'Secret42');
    await tester.tap(find.byKey(RegisterPage.submitButtonKey));
    await tester.pumpAndSettle();

    expect(find.byKey(RegisterPage.accountValueKey), findsOneWidget);
    expect(find.text('87654321'), findsOneWidget);
    expect(backend.requests.last['password'], 'Secret42');
    expect(await store.read(), isNull, reason: 'register does not sign in');

    await tester.tap(find.byKey(RegisterPage.copyAccountButtonKey));
    await tester.pump();
    expect(clipboard, <String>['87654321']);
    expect(find.text('账号已复制'), findsOneWidget);

    await tester.tap(find.byKey(RegisterPage.goToLoginButtonKey));
    await tester.pumpAndSettle();
    expect(find.text('87654321'), findsOneWidget);

    await tester.enterText(editable(LoginPage.accountFieldKey), '40218765');
    await tester.enterText(editable(LoginPage.passwordFieldKey), 'Secret42');
    await tester.tap(find.byKey(LoginPage.submitButtonKey));
    await tester.pumpAndSettle();

    expect(find.byKey(SignedInView.accountValueKey), findsOneWidget);
    expect(service.session.hasToken, isTrue);
    expect(find.textContaining(backend.issuedToken), findsNothing);

    final PersistedSession? stored = await store.read();
    expect(stored?.account, '40218765');
    expect(stored?.token, backend.issuedToken);
    expect(
      (await store.file.readAsString()).contains('Secret42'),
      isFalse,
      reason: 'never persist the password',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('real HTTP: wrong password shows the shared 401 message', (
    WidgetTester tester,
  ) async {
    final AuthService service = newService();
    await pumpApp(tester, service);

    await tester.enterText(editable(LoginPage.accountFieldKey), '40218765');
    await tester.enterText(editable(LoginPage.passwordFieldKey), 'Nope1234');
    await tester.tap(find.byKey(LoginPage.submitButtonKey));
    await tester.pumpAndSettle();

    expect(find.byKey(LoginPage.errorBannerKey), findsOneWidget);
    expect(find.text('账号或密码错误'), findsOneWidget);
    expect(service.session.hasToken, isFalse);
    expect(await store.read(), isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('restart: a persisted credential restores the session', (
    WidgetTester tester,
  ) async {
    await newService().login(account: '40218765', password: 'Secret42');
    expect(await store.read(), isNotNull);

    // New process model: fresh session object, same credential file.
    final AuthService restarted = newService();
    await pumpApp(tester, restarted);

    expect(find.byKey(SignedInView.accountValueKey), findsOneWidget);
    expect(find.text('40218765'), findsOneWidget);
    expect(find.byKey(LoginPage.submitButtonKey), findsNothing);
    expect(restarted.session.hasToken, isTrue);
    expect(backend.log.last.path, '/auth/session');
    expect(backend.log.last.authorization, 'Bearer ${backend.issuedToken}');
    expect(find.textContaining(backend.issuedToken), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'restart: an expired credential is cleared and returns to login',
    (WidgetTester tester) async {
      await store.write(
        const PersistedSession(
          account: '40218765',
          username: 'muse.tester',
          token: 'expired-token',
        ),
      );

      final AuthService restarted = newService();
      await pumpApp(tester, restarted);

      expect(find.byKey(LoginPage.noticeKey), findsOneWidget);
      expect(find.text('登录已失效，请重新登录'), findsOneWidget);
      expect(find.byKey(SignedInView.accountValueKey), findsNothing);
      expect(await store.read(), isNull, reason: 'invalid credential removed');
      expect(restarted.session.hasToken, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('wide and compact viewports switch layout without overflow', (
    WidgetTester tester,
  ) async {
    await pumpApp(tester, newService(), size: const Size(1280, 900));
    expect(find.byKey(AuthShell.brandPanelKey), findsOneWidget);

    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    await tester.pumpAndSettle();

    expect(find.byKey(AuthShell.brandPanelKey), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('a storage failure after a real server login is not success', (
    WidgetTester tester,
  ) async {
    final AuthService failing = AuthService(
      api: AuthApiClient(baseUri: backendBaseUri),
      session: AuthSession(),
      store: SessionStore.atPath(
        '${directory.path}/failing.json',
        replace: (File temporary, File target) async {
          throw FileSystemException('injected replace failure', temporary.path);
        },
      ),
    );
    await pumpApp(tester, failing);

    await tester.enterText(editable(LoginPage.accountFieldKey), '40218765');
    await tester.enterText(editable(LoginPage.passwordFieldKey), 'Secret42');
    await tester.tap(find.byKey(LoginPage.submitButtonKey));
    await tester.pumpAndSettle();

    expect(backend.log.any((record) => record.path == '/auth/login'), isTrue);
    expect(find.text('会话存储不可用'), findsOneWidget);
    expect(find.byKey(SignedInView.accountValueKey), findsNothing);
    expect(failing.session.hasToken, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'real HTTP + Linux render: Profile edit, avatar upload and logout',
    (WidgetTester tester) async {
      final AuthService service = newService();
      await service.login(account: '40218765', password: 'Secret42');
      final ProfileService profile = ProfileService(
        api: ProfileApiClient(baseUri: backendBaseUri),
        auth: service,
        cache: AvatarCache(),
      );
      final HeartbeatController heartbeat = HeartbeatController(auth: service);
      addTearDown(heartbeat.dispose);

      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        BbClientApp(
          authGateway: service,
          profile: profile,
          heartbeat: heartbeat,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(HomeView), findsOneWidget);
      expect(find.byKey(HomeView.greetingKey), findsOneWidget);
      expect(find.textContaining(backend.issuedToken), findsNothing);

      await tester.tap(find.byKey(HomeView.avatarEntryKey));
      await tester.pumpAndSettle();
      expect(find.byType(ProfilePanel), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(ProfilePanel.accountValueKey)).data,
        '40218765',
      );

      await tester.tap(find.byKey(ProfilePanel.editNicknameKey));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('profile-edit-field')),
        '桌面昵称',
      );
      await tester.tap(find.byKey(const Key('profile-edit-save')));
      await tester.pumpAndSettle();
      expect(backend.username, '桌面昵称');
      expect(find.text('桌面昵称'), findsWidgets);

      await tester.tap(find.text('更换头像').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Base64'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('avatar-source-field')),
        'data:image/png;base64,'
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
      );
      await tester.tap(find.byKey(const Key('avatar-source-apply')));
      await tester.pumpAndSettle();
      expect(backend.avatarUploaded, isTrue);
      expect(find.text('头像已更新'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(ProfilePanel.logoutButtonKey));
      await tester.pumpAndSettle();
      expect(find.byKey(LoginPage.submitButtonKey), findsOneWidget);
      expect(backend.tokenValid, isFalse, reason: 'server session deleted');
      expect(service.session.hasToken, isFalse);
      expect(await store.read(), isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'real HTTP + Linux: STEP-2 Profile edits, live reflow, avatar path and logout',
    (WidgetTester tester) async {
      final AuthService service = newService();
      await service.login(account: '40218765', password: 'Secret42');
      final ProfileService profile = ProfileService(
        api: ProfileApiClient(baseUri: backendBaseUri),
        auth: service,
        cache: AvatarCache(),
      );
      final HeartbeatController heartbeat = HeartbeatController(auth: service);
      addTearDown(heartbeat.dispose);

      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        BbClientApp(
          authGateway: service,
          profile: profile,
          heartbeat: heartbeat,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(HomeView.avatarEntryKey));
      await tester.pumpAndSettle();
      expect(
        tester.widget<ProfilePanel>(find.byType(ProfilePanel)).mode,
        ProfilePanelMode.desktop,
      );

      // QA-465-03 on the real Linux renderer: shrink while the panel is open.
      tester.view.physicalSize = const Size(390, 844);
      await tester.pumpAndSettle();
      expect(
        tester.widget<ProfilePanel>(find.byType(ProfilePanel)).mode,
        ProfilePanelMode.mobile,
      );
      expect(
        tester.getSize(find.byKey(ProfilePanel.panelKey)).width,
        closeTo(390, 0.1),
      );

      await tester.tap(find.byKey(ProfilePanel.editSignatureKey));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('profile-edit-field')),
        '集成签名',
      );
      await tester.tap(find.byKey(const Key('profile-edit-save')));
      await tester.pumpAndSettle();
      expect(backend.signature, '集成签名');
      expect(find.text('集成签名'), findsWidgets);

      await tester.tap(find.byKey(ProfilePanel.editNicknameKey));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('profile-edit-field')),
        '集成昵称',
      );
      await tester.tap(find.byKey(const Key('profile-edit-save')));
      await tester.pumpAndSettle();
      expect(backend.username, '集成昵称');

      final String versionBefore = backend.avatarVersion;
      final File avatarFile = File('${directory.path}/linux-avatar.png');
      await avatarFile.writeAsBytes(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
        ),
      );
      await tester.tap(find.text('更换头像').first);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('avatar-source-field')),
        avatarFile.path,
      );
      await tester.tap(find.byKey(const Key('avatar-source-apply')));
      await tester.pumpAndSettle();
      expect(backend.avatarVersion, isNot(versionBefore));
      expect(find.text('头像已更新'), findsOneWidget);

      backend.knownAccounts.add('87654321');
      await tester.tap(find.byKey(ProfilePanel.otherProfileKey));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('account-lookup-field')),
        '87654321',
      );
      await tester.tap(find.byKey(const Key('account-lookup-submit')));
      await tester.pumpAndSettle();
      expect(find.text('87654321'), findsWidgets);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(ProfilePanel.logoutButtonKey));
      await tester.pumpAndSettle();
      expect(find.byKey(LoginPage.submitButtonKey), findsOneWidget);
      expect(backend.tokenValid, isFalse);
      expect(service.session.hasToken, isFalse);
      expect(await store.read(), isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'real HTTP + Linux: heartbeat failures keep the session and banner',
    (WidgetTester tester) async {
      final AuthService service = newService();
      await service.login(account: '40218765', password: 'Secret42');
      final ProfileService profile = ProfileService(
        api: ProfileApiClient(baseUri: backendBaseUri),
        auth: service,
        cache: AvatarCache(),
      );
      final HeartbeatController heartbeat = HeartbeatController(auth: service);
      addTearDown(heartbeat.dispose);
      addTearDown(() => backend.heartbeatStatus = 200);

      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        BbClientApp(
          authGateway: service,
          profile: profile,
          heartbeat: heartbeat,
        ),
      );
      await tester.pumpAndSettle();

      backend.heartbeatStatus = 503;
      for (int i = 0; i < 3; i++) {
        await heartbeat.beatNow();
      }
      await tester.pumpAndSettle();
      expect(find.byKey(HomeView.reconnectingBannerKey), findsOneWidget);
      expect(find.text('连接已断开，正在重连'), findsOneWidget);
      expect(service.session.hasToken, isTrue);
      expect(await store.read(), isNotNull);

      backend.heartbeatStatus = 200;
      await heartbeat.beatNow();
      await tester.pumpAndSettle();
      expect(find.byKey(HomeView.reconnectingBannerKey), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('real HTTP + Linux: resized Profile panel exits to the left', (
    WidgetTester tester,
  ) async {
    final AuthService service = newService();
    await service.login(account: '40218765', password: 'Secret42');
    final ProfileService profile = ProfileService(
      api: ProfileApiClient(baseUri: backendBaseUri),
      auth: service,
      cache: AvatarCache(),
    );
    final HeartbeatController heartbeat = HeartbeatController(auth: service);
    addTearDown(heartbeat.dispose);

    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      BbClientApp(authGateway: service, profile: profile, heartbeat: heartbeat),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(HomeView.avatarEntryKey));
    await tester.pumpAndSettle();
    expect(
      tester.widget<ProfilePanel>(find.byType(ProfilePanel)).mode,
      ProfilePanelMode.desktop,
    );

    tester.view.physicalSize = const Size(390, 844);
    await tester.pumpAndSettle();
    expect(
      tester.widget<ProfilePanel>(find.byType(ProfilePanel)).mode,
      ProfilePanelMode.mobile,
    );
    final double before = tester
        .getTopLeft(find.byKey(ProfilePanel.panelKey))
        .dx;
    Navigator.of(tester.element(find.byType(ProfilePanel))).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final double during = tester
        .getTopLeft(find.byKey(ProfilePanel.panelKey))
        .dx;
    expect(
      during,
      lessThan(before - 1),
      reason: 'resized mobile panel must slide left, not fade in place',
    );
    await tester.pumpAndSettle();
    expect(find.byType(ProfilePanel), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('restart: an unreachable server keeps the credential and warns', (
    WidgetTester tester,
  ) async {
    await newService().login(account: '40218765', password: 'Secret42');
    await backend.close();

    final AuthService restarted = newService();
    await pumpApp(tester, restarted);

    expect(find.byKey(LoginPage.noticeKey), findsOneWidget);
    expect(find.text('暂时无法验证登录状态，请检查网络后重试'), findsOneWidget);
    expect(find.byKey(SignedInView.accountValueKey), findsNothing);
    final PersistedSession? kept = await store.read();
    expect(kept?.token, backend.issuedToken, reason: 'credential kept');
    expect(restarted.session.hasToken, isFalse);
    expect(tester.takeException(), isNull);
  });
}
