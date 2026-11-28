import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bb_client/app.dart';
import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/profile_models.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/ui/profile/profile_artwork.dart';
import 'package:bb_client/ui/profile/profile_details.dart';
import 'package:bb_client/ui/profile/profile_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_profile_gateway.dart';

const AuthUser _user = AuthUser(account: '40218765', username: 'muse.tester');

/// DEA-492 QA counterexample (response reordering).
///
/// An opened Profile starts its first cover GET; the user then replaces the
/// cover before that GET returns. When the delayed response finally lands it
/// must not restore the old image over the newer upload: the page already said
/// "封面已更新" and shows the new bytes.
void main() {
  final Uint8List oldCover = File('assets/profile/default-cover.png')
      .readAsBytesSync();
  final Uint8List newCover = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
  );

  CoverImage cover(Uint8List bytes) => CoverImage(
    account: '40218765',
    bytes: bytes,
    version: 'sha256-${'a' * 64}',
    mimeType: 'image/png',
    isDefault: false,
  );

  Future<void> pumpHost(
    WidgetTester tester,
    DelayedFirstCoverGateway gateway,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => Center(
              child: ElevatedButton(
                onPressed: () => openProfilePanel(
                  context,
                  gateway: gateway,
                  user: _user,
                  avatarDecodeCheck: (Uint8List _) async => true,
                  onLogout: () async =>
                      const LogoutResult(serverNotified: true),
                ),
                child: const Text('open-profile'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open-profile'));
    await tester.pumpAndSettle();
    expect(find.byType(ProfilePanel), findsOneWidget);
  }

  Finder coverImage() => find.descendant(
    of: find.byKey(ProfileSeaCover.coverKey),
    matching: find.byType(Image),
  );

  MemoryImage shownCover(WidgetTester tester) =>
      tester.widget<Image>(coverImage().first).image as MemoryImage;

  testWidgets(
    'a delayed first cover response cannot restore the old image after upload',
    (WidgetTester tester) async {
      final DelayedFirstCoverGateway gateway = DelayedFirstCoverGateway(
        initial: cover(oldCover),
      );
      await pumpHost(tester, gateway);

      await tester.tap(find.byKey(ProfilePanel.editProfileKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ProfilePanel.changeCoverKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Base64'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('avatar-source-field')),
        'data:image/png;base64,${base64Encode(newCover)}',
      );
      await tester.tap(find.byKey(const Key('avatar-source-apply')));
      await tester.pumpAndSettle();

      expect(gateway.coverSources.single, startsWith('base64:'));
      expect(find.textContaining('封面已更新'), findsOneWidget);
      expect(shownCover(tester).bytes, newCover);

      // Release the first, pre-upload response now that the new image is on
      // screen. It must be discarded, not painted over the newer upload.
      gateway.releaseFirstLoad();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpAndSettle();
      expect(
        shownCover(tester).bytes,
        newCover,
        reason: 'late first response must not restore the old cover',
      );
      expect(find.textContaining('封面已更新'), findsOneWidget);
    },
  );

  testWidgets(
    'switching peer while previous cover response is delayed does not leak old cover',
    (WidgetTester tester) async {
      const String accountA = '40218765';
      const String accountB = '40218766';
      final _PeerRaceGateway gateway = _PeerRaceGateway(
        heldCoverAccount: accountA,
        heldProfileAccount: null,
      );
      gateway.profiles[accountA] = const Profile(
        account: accountA,
        username: '重名同学',
        signature: 'A',
        avatarUrl: '/avatars/$accountA.png',
        avatarVersion: 'va',
      );
      gateway.profiles[accountB] = const Profile(
        account: accountB,
        username: '重名同学',
        signature: 'B',
        avatarUrl: '/avatars/$accountB.png',
        avatarVersion: 'vb',
      );
      gateway.covers[accountA] = CoverImage(
        account: accountA,
        bytes: oldCover,
        version: 'sha256-${'a' * 64}',
        mimeType: 'image/png',
        isDefault: false,
      );
      gateway.covers[accountB] = CoverImage(
        account: accountB,
        bytes: newCover,
        version: 'sha256-${'b' * 64}',
        mimeType: 'image/png',
        isDefault: false,
      );

      final ValueNotifier<String> account = ValueNotifier<String>(accountA);
      addTearDown(account.dispose);

      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(
            body: ValueListenableBuilder<String>(
              valueListenable: account,
              builder: (BuildContext context, String value, Widget? _) =>
                  PersonProfilePanel(account: value, gateway: gateway),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('BB号 $accountA'), findsOneWidget);
      // Cover A is still in flight, so default sea wave stays on screen.
      expect(find.byKey(ProfileSeaCover.defaultCoverKey), findsOneWidget);

      // Switch to B (same display name, different account & custom cover).
      account.value = accountB;
      await tester.pumpAndSettle();
      expect(find.text('BB号 $accountB'), findsOneWidget);
      expect(shownCover(tester).bytes, newCover);

      // Release delayed cover A; it must be discarded and never overwrite B.
      gateway.releaseHeldCover();
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.text('BB号 $accountB'), findsOneWidget);
      expect(shownCover(tester).bytes, newCover);
    },
  );

  testWidgets(
    'switching peer while previous profile response is delayed keeps new peer',
    (WidgetTester tester) async {
      const String accountA = '40218765';
      const String accountB = '40218766';
      final _PeerRaceGateway gateway = _PeerRaceGateway(
        heldCoverAccount: null,
        heldProfileAccount: accountA,
      );
      gateway.profiles[accountA] = const Profile(
        account: accountA,
        username: '重名同学',
        signature: 'old peer',
        avatarUrl: '/avatars/$accountA.png',
        avatarVersion: 'va',
      );
      gateway.profiles[accountB] = const Profile(
        account: accountB,
        username: '重名同学',
        signature: 'new peer',
        avatarUrl: '/avatars/$accountB.png',
        avatarVersion: 'vb',
      );
      gateway.covers[accountA] = CoverImage(
        account: accountA,
        bytes: oldCover,
        version: 'sha256-${'a' * 64}',
        mimeType: 'image/png',
        isDefault: false,
      );

      final ValueNotifier<String> account = ValueNotifier<String>(accountA);
      addTearDown(account.dispose);

      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(
            body: ValueListenableBuilder<String>(
              valueListenable: account,
              builder: (BuildContext context, String value, Widget? _) =>
                  PersonProfilePanel(account: value, gateway: gateway),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      account.value = accountB;
      await tester.pumpAndSettle();
      expect(find.text('BB号 $accountB'), findsOneWidget);
      expect(find.text('new peer'), findsOneWidget);
      // Account B has no custom cover -> default sea wave.
      expect(find.byKey(ProfileSeaCover.defaultCoverKey), findsOneWidget);

      gateway.releaseHeldProfile();
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.text('BB号 $accountB'), findsOneWidget);
      expect(find.text('new peer'), findsOneWidget);
      expect(find.text('old peer'), findsNothing);
      expect(find.byKey(ProfileSeaCover.defaultCoverKey), findsOneWidget);
    },
  );

  testWidgets(
    'rapidly switching A -> B -> C while animations are running keeps C and drops delayed A/B responses',
    (WidgetTester tester) async {
      const String accountA = '40218765';
      const String accountB = '40218766';
      const String accountC = '40218767';
      final _MultiPeerRaceGateway gateway = _MultiPeerRaceGateway(
        heldProfileAccounts: <String>{accountA, accountB},
        heldCoverAccounts: <String>{accountA, accountB},
      );
      gateway.profiles[accountA] = const Profile(
        account: accountA,
        username: '林晓',
        signature: '一号签名',
        avatarUrl: '/avatars/$accountA.png',
        avatarVersion: 'va',
      );
      gateway.profiles[accountB] = const Profile(
        account: accountB,
        username: '林晓',
        signature: '二号签名',
        avatarUrl: '/avatars/$accountB.png',
        avatarVersion: 'vb',
      );
      gateway.profiles[accountC] = const Profile(
        account: accountC,
        username: '林晓',
        signature: '三号签名',
        avatarUrl: '/avatars/$accountC.png',
        avatarVersion: 'vc',
      );
      gateway.covers[accountA] = CoverImage(
        account: accountA,
        bytes: oldCover,
        version: 'sha256-${'a' * 64}',
        mimeType: 'image/png',
        isDefault: false,
      );
      gateway.covers[accountC] = CoverImage(
        account: accountC,
        bytes: newCover,
        version: 'sha256-${'c' * 64}',
        mimeType: 'image/png',
        isDefault: false,
      );

      final ValueNotifier<String> account = ValueNotifier<String>(accountA);
      addTearDown(account.dispose);

      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          builder: (BuildContext context, Widget? child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: false),
            child: child!,
          ),
          home: Scaffold(
            body: ValueListenableBuilder<String>(
              valueListenable: account,
              builder: (BuildContext context, String value, Widget? _) =>
                  PersonProfilePanel(account: value, gateway: gateway),
            ),
          ),
        ),
      );

      // Rapidly switch A -> B -> C mid-flight before A or B resolves.
      await tester.pump(const Duration(milliseconds: 40));
      account.value = accountB;
      await tester.pump(const Duration(milliseconds: 40));
      account.value = accountC;
      await tester.pumpAndSettle();

      expect(find.text('BB号 $accountC'), findsOneWidget);
      expect(find.text('三号签名'), findsOneWidget);
      expect(shownCover(tester).bytes, newCover);

      // Release delayed A and B responses; neither may overwrite C.
      gateway.releaseAll();
      await tester.pumpAndSettle();
      expect(find.text('BB号 $accountC'), findsOneWidget);
      expect(find.text('三号签名'), findsOneWidget);
      expect(find.text('一号签名'), findsNothing);
      expect(find.text('二号签名'), findsNothing);
      expect(shownCover(tester).bytes, newCover);
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
    },
  );
}

class _MultiPeerRaceGateway extends FakeProfileGateway {
  _MultiPeerRaceGateway({
    required this.heldProfileAccounts,
    required this.heldCoverAccounts,
  });

  final Set<String> heldProfileAccounts;
  final Set<String> heldCoverAccounts;
  final Completer<void> _release = Completer<void>();

  void releaseAll() {
    if (!_release.isCompleted) {
      _release.complete();
    }
  }

  @override
  Future<Profile> loadProfile({String? account, AuthIdentity? captured}) async {
    final Profile result = await super.loadProfile(
      account: account,
      captured: captured,
    );
    if (account != null && heldProfileAccounts.contains(account)) {
      await _release.future;
    }
    return result;
  }

  @override
  Future<CoverImage> loadCover({
    String? account,
    AuthIdentity? captured,
  }) async {
    final CoverImage result = await super.loadCover(
      account: account,
      captured: captured,
    );
    if (account != null && heldCoverAccounts.contains(account)) {
      await _release.future;
    }
    return result;
  }
}

class _PeerRaceGateway extends FakeProfileGateway {
  _PeerRaceGateway({
    required this.heldCoverAccount,
    required this.heldProfileAccount,
  });

  final String? heldCoverAccount;
  final String? heldProfileAccount;
  final Completer<void> _coverRelease = Completer<void>();
  final Completer<void> _profileRelease = Completer<void>();

  void releaseHeldCover() {
    if (!_coverRelease.isCompleted) {
      _coverRelease.complete();
    }
  }

  void releaseHeldProfile() {
    if (!_profileRelease.isCompleted) {
      _profileRelease.complete();
    }
  }

  @override
  Future<Profile> loadProfile({String? account, AuthIdentity? captured}) async {
    final Profile result = await super.loadProfile(
      account: account,
      captured: captured,
    );
    if (account != null && account == heldProfileAccount) {
      await _profileRelease.future;
    }
    return result;
  }

  @override
  Future<CoverImage> loadCover({
    String? account,
    AuthIdentity? captured,
  }) async {
    final CoverImage result = await super.loadCover(
      account: account,
      captured: captured,
    );
    if (account != null && account == heldCoverAccount) {
      await _coverRelease.future;
    }
    return result;
  }
}

/// Gateway double whose first [loadCover] snapshots the current cover, then
/// waits until the test releases it — modelling a slow GET started before the
/// upload.
class DelayedFirstCoverGateway extends FakeProfileGateway {
  DelayedFirstCoverGateway({required this.initial});

  final CoverImage initial;
  final Completer<void> _release = Completer<void>();
  int _loads = 0;

  void releaseFirstLoad() {
    if (!_release.isCompleted) {
      _release.complete();
    }
  }

  @override
  Future<CoverImage> loadCover({
    String? account,
    AuthIdentity? captured,
  }) async {
    _loads += 1;
    final bool first = _loads == 1;
    // Snapshot before waiting: the delayed response must carry the values the
    // server had when the GET started, like the reported slow first read.
    final CoverImage snapshot = first
        ? initial
        : await super.loadCover(account: account, captured: captured);
    if (first) {
      await _release.future;
    }
    return snapshot;
  }
}
