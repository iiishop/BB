import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bb_client/app.dart';
import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/profile_models.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/ui/profile/profile_artwork.dart';
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
