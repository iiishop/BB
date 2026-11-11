import 'package:bb_client/app.dart';
import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/ui/auth_shell.dart';
import 'package:bb_client/ui/login_page.dart';
import 'package:bb_client/ui/register_page.dart';
import 'package:bb_client/ui/signed_in_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_auth_gateway.dart';

const Size _phone = Size(390, 844);
const Size _desktop = Size(1280, 900);
const Size _smallPhone = Size(320, 568);

Finder _editable(Key key) =>
    find.descendant(of: find.byKey(key), matching: find.byType(EditableText));

void main() {
  late FakeAuthGateway gateway;

  setUp(() {
    gateway = FakeAuthGateway();
  });

  Future<void> pumpApp(WidgetTester tester, {Size size = _phone}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(BbClientApp(authGateway: gateway));
    await tester.pumpAndSettle();
  }

  Future<void> openRegister(WidgetTester tester) async {
    await tester.tap(find.byKey(LoginPage.registerLinkKey));
    await tester.pumpAndSettle();
  }

  Future<void> fillLogin(
    WidgetTester tester, {
    String account = '40218765',
    String password = 'Secret42',
  }) async {
    await tester.enterText(_editable(LoginPage.accountFieldKey), account);
    await tester.enterText(_editable(LoginPage.passwordFieldKey), password);
  }

  Future<void> submitLogin(WidgetTester tester) async {
    await tester.tap(find.byKey(LoginPage.submitButtonKey));
    await tester.pumpAndSettle();
  }

  testWidgets('compact login shows one column and no brand panel', (
    WidgetTester tester,
  ) async {
    await pumpApp(tester);

    expect(find.byKey(AuthShell.formColumnKey), findsOneWidget);
    expect(find.byKey(AuthShell.brandPanelKey), findsNothing);
    expect(find.byKey(LoginPage.accountFieldKey), findsOneWidget);
    expect(find.byKey(LoginPage.passwordFieldKey), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('wide login shows the brand panel beside the form', (
    WidgetTester tester,
  ) async {
    await pumpApp(tester, size: _desktop);

    expect(find.byKey(AuthShell.brandPanelKey), findsOneWidget);
    expect(find.byKey(AuthShell.formColumnKey), findsOneWidget);
    expect(find.text('只与你信任的人\n保持联系。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('small phone viewport stays overflow-free', (
    WidgetTester tester,
  ) async {
    await pumpApp(tester, size: _smallPhone);

    expect(find.byKey(LoginPage.submitButtonKey), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('invalid account format is rejected before any request', (
    WidgetTester tester,
  ) async {
    await pumpApp(tester);
    await fillLogin(tester, account: '123', password: 'whatever');
    await submitLogin(tester);

    expect(gateway.loginCalls, isEmpty);
    expect(find.text('账号必须为 8 位数字'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('401 shows a readable error and a retry signs in', (
    WidgetTester tester,
  ) async {
    gateway.loginFailure = const AuthFailure(
      status: 401,
      code: 'invalid_credentials',
      message: '账号或密码错误',
    );
    await pumpApp(tester);
    await fillLogin(tester, password: 'Wrong42');
    await submitLogin(tester);

    expect(find.byKey(LoginPage.errorBannerKey), findsOneWidget);
    expect(find.text('账号或密码错误'), findsOneWidget);
    expect(gateway.loginCalls.length, 1);

    gateway.loginFailure = null;
    await tester.enterText(_editable(LoginPage.passwordFieldKey), 'Secret42');
    await submitLogin(tester);

    expect(gateway.loginCalls.length, 2);
    expect(find.byKey(SignedInView.accountValueKey), findsOneWidget);
    expect(find.text('12345678'), findsOneWidget);
    expect(find.text('欢迎回来，muse'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unreachable server guidance is shown for 502', (
    WidgetTester tester,
  ) async {
    gateway.loginFailure = upstreamUnavailable;
    await pumpApp(tester);
    await fillLogin(tester);
    await submitLogin(tester);

    expect(find.text('无法连接服务器，请检查服务地址或网络后重试'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('register validates the password before calling the service', (
    WidgetTester tester,
  ) async {
    await pumpApp(tester);
    await openRegister(tester);

    await tester.enterText(_editable(RegisterPage.usernameFieldKey), 'muse');
    await tester.enterText(_editable(RegisterPage.passwordFieldKey), 'weak');
    await tester.enterText(_editable(RegisterPage.confirmFieldKey), 'weak');
    await tester.tap(find.byKey(RegisterPage.submitButtonKey));
    await tester.pumpAndSettle();

    expect(gateway.registerCalls, isEmpty);
    expect(find.text('密码至少 6 位'), findsWidgets);
    expect(find.text('密码必须包含大写字母'), findsWidgets);
    expect(find.text('密码必须包含数字'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('register success shows the account, copies it and prefills '
      'login', (WidgetTester tester) async {
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

    await pumpApp(tester);
    await openRegister(tester);
    await tester.enterText(_editable(RegisterPage.usernameFieldKey), 'muse');
    await tester.enterText(
      _editable(RegisterPage.passwordFieldKey),
      'Secret42',
    );
    await tester.enterText(_editable(RegisterPage.confirmFieldKey), 'Secret42');
    await tester.tap(find.byKey(RegisterPage.submitButtonKey));
    await tester.pumpAndSettle();

    expect(gateway.registerCalls.length, 1);
    expect(gateway.registerCalls.single.password, 'Secret42');
    expect(find.byKey(RegisterPage.accountValueKey), findsOneWidget);
    expect(find.text('12345678'), findsOneWidget);

    await tester.tap(find.byKey(RegisterPage.copyAccountButtonKey));
    await tester.pump();
    expect(clipboard, <String>['12345678']);
    expect(find.text('账号已复制'), findsOneWidget);

    await tester.tap(find.byKey(RegisterPage.goToLoginButtonKey));
    await tester.pumpAndSettle();

    expect(find.byKey(LoginPage.accountFieldKey), findsOneWidget);
    expect(find.text('12345678'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('server 422 field reason replaces the inline error', (
    WidgetTester tester,
  ) async {
    gateway.registerFailure = const AuthFailure(
      status: 422,
      code: 'validation_error',
      message: '输入有误',
      fields: <AuthFieldError>[
        AuthFieldError(
          field: 'username',
          code: 'length',
          message: '用户名去除首尾空白后须为 3–24 字符',
        ),
      ],
    );
    await pumpApp(tester);
    await openRegister(tester);
    await tester.enterText(
      _editable(RegisterPage.usernameFieldKey),
      'a-valid-name',
    );
    await tester.enterText(
      _editable(RegisterPage.passwordFieldKey),
      'Secret42',
    );
    await tester.enterText(_editable(RegisterPage.confirmFieldKey), 'Secret42');
    await tester.tap(find.byKey(RegisterPage.submitButtonKey));
    await tester.pumpAndSettle();

    expect(gateway.registerCalls.length, 1);
    expect(find.text('用户名去除首尾空白后须为 3–24 字符'), findsOneWidget);
    expect(find.byKey(RegisterPage.errorBannerKey), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('signing out clears the session and returns to login', (
    WidgetTester tester,
  ) async {
    await pumpApp(tester);
    await fillLogin(tester);
    await submitLogin(tester);

    expect(find.byKey(SignedInView.signOutButtonKey), findsOneWidget);
    await tester.tap(find.byKey(SignedInView.signOutButtonKey));
    await tester.pumpAndSettle();

    expect(gateway.signedOut, isTrue);
    expect(find.byKey(LoginPage.submitButtonKey), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
