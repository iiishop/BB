import 'package:bb_client/app.dart';
import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/profile_models.dart';
import 'package:bb_client/services/auth_api_client.dart';
import 'package:bb_client/services/auth_service.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/heartbeat_controller.dart';
import 'package:bb_client/ui/home_view.dart';
import 'package:bb_client/ui/profile/profile_artwork.dart';
import 'package:bb_client/ui/profile/profile_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_auth_gateway.dart';
import 'support/fake_profile_gateway.dart';
import 'support/phone_profile.dart';

const AuthUser _user = AuthUser(account: '40218765', username: 'muse.tester');

/// DEA-492 phone Profile page: cover layout, avatar flight, ring sweep and the
/// retained entry points.
void main() {
  late FakeProfileGateway gateway;
  late ProfilePanelResult? lastResult;

  setUp(() {
    gateway = FakeProfileGateway();
    lastResult = null;
  });

  Widget host({double textScale = 1, bool disableAnimations = false}) {
    return MaterialApp(
      theme: buildAppTheme(),
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
          disableAnimations: disableAnimations,
        ),
        child: child!,
      ),
      home: Scaffold(
        body: Builder(
          builder: (BuildContext context) => Center(
            child: ElevatedButton(
              onPressed: () async {
                lastResult = await openProfilePanel(
                  context,
                  gateway: gateway,
                  user: _user,
                  onLogout: () async {
                    await gateway.logout();
                    return const LogoutResult(serverNotified: true);
                  },
                );
              },
              child: const Text('open-profile'),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> pumpPhone(
    WidgetTester tester, {
    Size size = const Size(390, 844),
    double textScale = 1,
    bool disableAnimations = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      host(textScale: textScale, disableAnimations: disableAnimations),
    );
    await tester.tap(find.text('open-profile'));
    await tester.pumpAndSettle();
    expect(find.byType(ProfilePanel), findsOneWidget);
    expect(
      tester.widget<ProfilePanel>(find.byType(ProfilePanel)).mode,
      ProfilePanelMode.mobile,
    );
  }

  testWidgets('the sea cover takes about a quarter of a portrait phone', (
    WidgetTester tester,
  ) async {
    await pumpPhone(tester);

    final Rect cover = tester.getRect(find.byKey(ProfileSeaCover.coverKey));
    expect(cover.top, 0);
    expect(cover.width, closeTo(390, 0.1));
    expect(cover.height, closeTo(844 * 0.25, 0.5));
    expect(
      cover.height / 844,
      closeTo(0.25, 0.02),
      reason: 'the issue fixes the cover at roughly a quarter of the screen',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('avatar straddles the cover seam and the name sits beside it', (
    WidgetTester tester,
  ) async {
    await pumpPhone(tester);

    final Rect cover = tester.getRect(find.byKey(ProfileSeaCover.coverKey));
    final Rect photo = tester.getRect(find.byKey(ScallopedAvatar.photoKey));
    expect(
      photo.top,
      lessThan(cover.bottom),
      reason: 'the avatar must start inside the cover',
    );
    expect(
      photo.bottom,
      greaterThan(cover.bottom),
      reason: 'the avatar must reach into the plain body',
    );

    final Rect nickname = tester.getRect(
      find.byKey(ProfilePanel.nicknameValueKey),
    );
    final Rect account = tester.getRect(
      find.byKey(ProfilePanel.accountValueKey),
    );
    expect(nickname.top, greaterThanOrEqualTo(cover.bottom));
    expect(
      nickname.left,
      greaterThan(photo.right - 2),
      reason: 'name belongs in the plain area beside the avatar',
    );
    expect(account.left, greaterThan(photo.right - 2));
    expect(find.text('muse.tester'), findsOneWidget);
    expect(find.text('40218765'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('signature has its own line below the avatar', (
    WidgetTester tester,
  ) async {
    await pumpPhone(tester);

    final Rect photo = tester.getRect(find.byKey(ScallopedAvatar.photoKey));
    final Rect signature = tester.getRect(
      find.byKey(ProfilePanel.signatureValueKey),
    );
    expect(signature.top, greaterThan(photo.bottom));
    expect(find.text('签名'), findsOneWidget);
    expect(find.text('把日子过成自己的节奏。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('long nickname and signature wrap above the action buttons', (
    WidgetTester tester,
  ) async {
    gateway.profile = const Profile(
      account: '40218765',
      username: '一二三四五六七八九十一二三四五六七八九十',
      signature: '这一行签名写得很长很长，用来确认它会换行显示，并且不会盖住下面的编辑资料按钮和个人主页按钮。',
      avatarUrl: '/avatars/40218765.png',
      avatarVersion: 'v1',
    );
    await pumpPhone(tester, size: const Size(360, 800), textScale: 2);

    expect(tester.takeException(), isNull);
    final Rect signature = tester.getRect(
      find.byKey(ProfilePanel.signatureValueKey),
    );
    final Rect editButton = tester.getRect(
      find.byKey(ProfilePanel.editProfileKey),
    );
    final Rect homeButton = tester.getRect(
      find.byKey(ProfilePanel.homeButtonKey),
    );
    expect(
      editButton.top,
      greaterThan(signature.bottom),
      reason: 'wrapped text must push the buttons down, never overlap them',
    );
    expect(homeButton.top, greaterThan(signature.bottom));
    expect(find.text('一二三四五六七八九十一二三四五六七八九十'), findsOneWidget);
  });

  testWidgets(
    'default avatar, nothing-written state and the two main actions',
    (WidgetTester tester) async {
      gateway.profile = const Profile(
        account: '40218765',
        username: 'muse.tester',
        signature: null,
        avatarUrl: '/avatars/40218765.png',
        avatarVersion: 'identicon-v1',
      );
      await pumpPhone(tester);

      expect(find.text('还没有签名'), findsOneWidget);
      expect(find.byKey(ScallopedAvatar.photoKey), findsOneWidget);
      expect(find.text('编辑资料'), findsOneWidget);
      expect(find.text('个人主页'), findsOneWidget);

      await tester.tap(find.byKey(ProfilePanel.homeButtonKey));
      await tester.pumpAndSettle();
      expect(lastResult?.openHomeAccount, '40218765');
    },
  );

  testWidgets('edit sheet keeps avatar, nickname and signature reachable', (
    WidgetTester tester,
  ) async {
    await pumpPhone(tester);
    await openProfileEditSheet(tester);

    expect(find.text('更换头像'), findsOneWidget);
    expect(find.byKey(ProfilePanel.removeAvatarKey), findsOneWidget);
    expect(find.byKey(ProfilePanel.editNicknameKey), findsOneWidget);
    expect(find.byKey(ProfilePanel.editSignatureKey), findsOneWidget);

    await tester.tap(find.byKey(ProfilePanel.editNicknameKey));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('profile-edit-field')),
      '  新昵称  ',
    );
    await tester.tap(find.byKey(const Key('profile-edit-save')));
    await tester.pumpAndSettle();

    expect(gateway.patches.single.username, '新昵称');
    expect(
      tester.widget<Text>(find.byKey(ProfilePanel.nicknameValueKey)).data,
      '新昵称',
      reason: 'saving must update the cover page behind the sheet',
    );
  });

  testWidgets('avatar removal stays reachable from the edit sheet', (
    WidgetTester tester,
  ) async {
    await pumpPhone(tester);
    await openProfileEditSheet(tester);

    await tester.tap(find.byKey(ProfilePanel.removeAvatarKey));
    await tester.pumpAndSettle();

    expect(gateway.profile.avatarVersion, 'v-identicon');
    expect(find.text('已恢复默认头像'), findsOneWidget);
  });

  testWidgets('settings, other accounts and logout remain reachable', (
    WidgetTester tester,
  ) async {
    await pumpPhone(tester);

    await tester.tap(find.byKey(ProfilePanel.settingsButtonKey));
    await tester.pumpAndSettle();
    expect(lastResult?.openSettings, isTrue);

    await pumpPhone(tester);
    await tester.tap(find.byKey(ProfilePanel.otherProfileKey));
    await tester.pumpAndSettle();
    expect(find.text('查看其他账号'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(ProfilePanel.logoutButtonKey));
    await tester.pumpAndSettle();
    expect(gateway.logoutCalls, 1);
    expect(find.byType(ProfilePanel), findsNothing);
    expect(lastResult?.signedOut, isTrue);
  });

  testWidgets('only the outline turns and it comes to rest', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(host());

    await tester.tap(find.text('open-profile'));
    await tester.pump();
    // Route fade/hero clock: the sweep waits for the landing.
    await tester.pump(const Duration(milliseconds: 360));
    final RotationTransition ring = tester.widget<RotationTransition>(
      find.byKey(ScallopedAvatar.ringRotationKey),
    );
    final double start = ring.turns.value;
    expect(start, lessThan(0));
    expect(
      find.ancestor(
        of: find.byKey(ScallopedAvatar.photoKey),
        matching: find.byKey(ScallopedAvatar.ringRotationKey),
      ),
      findsNothing,
      reason: 'the photo must never rotate with the rim',
    );

    await tester.pump(const Duration(milliseconds: 150));
    final double mid = ring.turns.value;
    expect(mid, greaterThan(start), reason: 'the rim sweeps toward rest');
    expect(mid, lessThan(0));

    await tester.pumpAndSettle();
    expect(ring.turns.value, 0);
    expect(
      tester.binding.transientCallbackCount,
      0,
      reason: 'the sweep is one-shot; nothing may keep animating',
    );
  });

  testWidgets('reduced motion renders the resting outline immediately', (
    WidgetTester tester,
  ) async {
    await pumpPhone(tester, disableAnimations: true);
    final RotationTransition ring = tester.widget<RotationTransition>(
      find.byKey(ScallopedAvatar.ringRotationKey),
    );
    expect(ring.turns.value, 0);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('the avatar flies from the messages entry and returns', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final HeartbeatController heartbeat = HeartbeatController(
      auth: AuthService(
        api: AuthApiClient(baseUri: Uri.parse('http://127.0.0.1:1')),
        session: AuthSession()..establish(token: 'test-token', user: _user),
      ),
    );
    addTearDown(heartbeat.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: HomeView(
          user: _user,
          profile: gateway,
          auth: FakeAuthGateway(),
          heartbeat: heartbeat,
          onSignedOut: (LogoutResult? _) {},
          onSessionExpired: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Rect entryRect = tester.getRect(find.byKey(HomeView.avatarEntryKey));
    await tester.tap(find.byKey(HomeView.avatarEntryKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(
      find.byKey(ProfilePanel.avatarFlightKey),
      findsOneWidget,
      reason: 'the avatar must be in flight between the two pages',
    );
    final Rect flight = tester.getRect(
      find.byKey(ProfilePanel.avatarFlightKey),
    );
    expect(flight.center.dy, lessThan(entryRect.center.dy));

    await tester.pumpAndSettle();
    expect(find.byKey(ProfilePanel.avatarFlightKey), findsNothing);
    final Rect landed = tester.getRect(find.byKey(ScallopedAvatar.photoKey));
    expect(landed.center.dy, lessThan(entryRect.center.dy));
    expect(landed.height, greaterThan(entryRect.height));

    await tester.tap(find.byKey(ProfilePanel.closeButtonKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(
      find.byKey(ProfilePanel.avatarFlightKey),
      findsOneWidget,
      reason: 'the avatar must travel back to its entry',
    );
    await tester.pumpAndSettle();
    expect(find.byType(ProfilePanel), findsNothing);
    final Rect restored = tester.getRect(find.byKey(HomeView.avatarEntryKey));
    expect(restored.center, entryRect.center);
    expect(restored.size, entryRect.size);
  });

  testWidgets('a quick enter and exit never blocks the page', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final HeartbeatController heartbeat = HeartbeatController(
      auth: AuthService(
        api: AuthApiClient(baseUri: Uri.parse('http://127.0.0.1:1')),
        session: AuthSession()..establish(token: 'test-token', user: _user),
      ),
    );
    addTearDown(heartbeat.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: HomeView(
          user: _user,
          profile: gateway,
          auth: FakeAuthGateway(),
          heartbeat: heartbeat,
          onSignedOut: (LogoutResult? _) {},
          onSessionExpired: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(HomeView.avatarEntryKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    await tester.tap(find.byKey(ProfilePanel.closeButtonKey));
    await tester.pumpAndSettle();

    expect(find.byType(ProfilePanel), findsNothing);
    expect(find.byKey(HomeView.avatarEntryKey), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
