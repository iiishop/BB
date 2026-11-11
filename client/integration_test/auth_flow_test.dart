import 'dart:io';

import 'package:bb_client/app.dart';
import 'package:bb_client/services/auth_api_client.dart';
import 'package:bb_client/services/auth_service.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/session_store.dart';
import 'package:bb_client/ui/auth_shell.dart';
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
