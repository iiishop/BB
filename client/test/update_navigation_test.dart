import 'package:bb_client/app.dart';
import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/services/auth_api_client.dart';
import 'package:bb_client/services/auth_service.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/heartbeat_controller.dart';
import 'package:bb_client/ui/home_view.dart';
import 'package:bb_client/ui/profile/profile_panel.dart';
import 'package:bb_client/ui/updates/update_scope.dart';
import 'package:bb_client/ui/updates/update_settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_auth_gateway.dart';
import 'support/fake_profile_gateway.dart';
import 'support/fake_update_controller.dart';

const AuthUser _user = AuthUser(account: '40218765', username: 'muse.tester');

class _NoNetworkAuthApi extends AuthApiClient {
  _NoNetworkAuthApi() : super(baseUri: Uri.parse('http://127.0.0.1:1'));

  @override
  Future<void> heartbeat(String token) async {}

  @override
  Future<void> logout(String token) async {}
}

void main() {
  testWidgets('Profile 面板的设置入口打开更新页，离开后回到首页', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final FakeProfileGateway profile = FakeProfileGateway();
    final FakeAuthGateway auth = FakeAuthGateway();
    final AuthSession session = AuthSession()
      ..establish(token: 'navigation-test-token', user: _user);
    final HeartbeatController heartbeat = HeartbeatController(
      auth: AuthService(api: _NoNetworkAuthApi(), session: session),
    );
    final FakeUpdateController controller = FakeUpdateController();
    addTearDown(heartbeat.dispose);

    await tester.pumpWidget(
      UpdateScope(
        controller: controller,
        child: MaterialApp(
          theme: buildAppTheme(),
          home: HomeView(
            user: _user,
            profile: profile,
            auth: auth,
            heartbeat: heartbeat,
            onSignedOut: (LogoutResult? _) {},
            onSessionExpired: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(HomeView.avatarEntryKey));
    await tester.pumpAndSettle();
    expect(find.byKey(ProfilePanel.panelKey), findsOneWidget);

    await tester.tap(find.byKey(ProfilePanel.settingsButtonKey));
    await tester.pumpAndSettle();

    // The panel closed and the update settings route replaced it.
    expect(find.byKey(ProfilePanel.panelKey), findsNothing);
    expect(find.byKey(UpdateSettingsPage.currentVersionKey), findsOneWidget);
    expect(find.text('软件更新'), findsOneWidget);
    expect(find.byKey(UpdateSettingsPage.checkButtonKey), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byKey(HomeView.avatarEntryKey), findsOneWidget);
  });
}
