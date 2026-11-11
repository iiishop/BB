import 'package:bb_client/app.dart';
import 'package:bb_client/services/auth_api_client.dart';
import 'package:bb_client/services/auth_service.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/ui/auth_shell.dart';
import 'package:bb_client/ui/login_page.dart';
import 'package:bb_client/ui/register_page.dart';
import 'package:bb_client/ui/signed_in_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/support/fake_auth_backend.dart';
import 'support/pipeline_smoke_cases.dart';

/// Linux desktop end-to-end coverage of STEP-1 against a real HTTP upstream.
///
/// Run with: flutter test integration_test -d linux
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late FakeAuthBackend backend;
  late AuthSession session;
  late AuthService service;

  setUpAll(() async {
    backend = await FakeAuthBackend.start();
  });

  tearDownAll(() async {
    await backend.close();
  });

  setUp(() {
    session = AuthSession();
    service = AuthService(
      api: AuthApiClient(baseUri: backend.baseUri),
      session: session,
    );
  });

  Finder editable(Key key) =>
      find.descendant(of: find.byKey(key), matching: find.byType(EditableText));

  Future<void> pumpApp(WidgetTester tester, {Size? size}) async {
    if (size != null) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }
    await tester.pumpWidget(BbClientApp(authGateway: service));
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

    await pumpApp(tester, size: const Size(390, 844));

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

    await tester.tap(find.byKey(RegisterPage.copyAccountButtonKey));
    await tester.pump();
    expect(clipboard, <String>['87654321']);
    expect(find.text('账号已复制'), findsOneWidget);

    await tester.tap(find.byKey(RegisterPage.goToLoginButtonKey));
    await tester.pumpAndSettle();
    expect(find.text('87654321'), findsOneWidget);

    // Registration never returns a token, so the default account cannot log in;
    // use the backend's valid credentials to complete the login step.
    await tester.enterText(editable(LoginPage.accountFieldKey), '40218765');
    await tester.enterText(editable(LoginPage.passwordFieldKey), 'Secret42');
    await tester.tap(find.byKey(LoginPage.submitButtonKey));
    await tester.pumpAndSettle();

    expect(find.byKey(SignedInView.accountValueKey), findsOneWidget);
    expect(
      session.hasToken,
      isTrue,
      reason: 'token lives in the client session',
    );
    expect(find.textContaining(backend.issuedToken), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('real HTTP: wrong password shows the shared 401 message', (
    WidgetTester tester,
  ) async {
    await pumpApp(tester, size: const Size(390, 844));

    await tester.enterText(editable(LoginPage.accountFieldKey), '40218765');
    await tester.enterText(editable(LoginPage.passwordFieldKey), 'Nope1234');
    await tester.tap(find.byKey(LoginPage.submitButtonKey));
    await tester.pumpAndSettle();

    expect(find.byKey(LoginPage.errorBannerKey), findsOneWidget);
    expect(find.text('账号或密码错误'), findsOneWidget);
    expect(session.hasToken, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('wide and compact viewports switch layout without overflow', (
    WidgetTester tester,
  ) async {
    await pumpApp(tester, size: const Size(1280, 900));
    expect(find.byKey(AuthShell.brandPanelKey), findsOneWidget);

    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    await tester.pumpAndSettle();

    expect(find.byKey(AuthShell.brandPanelKey), findsNothing);
    expect(tester.takeException(), isNull);
  });
  registerPipelineSmokeIntegrationTests();
}
