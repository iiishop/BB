import 'dart:async';
import 'dart:typed_data';

import 'package:bb_client/app.dart';
import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/services/avatar_source.dart';
import 'package:bb_client/ui/profile/avatar_picker.dart';
import 'package:bb_client/ui/profile/profile_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'profile_avatar_pick_test.dart'
    show FakeAvatarImagePicker, FakeAvatarSourceReader;
import 'support/avatar_fixtures.dart';
import 'support/fake_profile_gateway.dart';

/// DEA-482 QA regression (P2): busy state is owned by the operation that
/// started it. Switching the avatar source invalidates pending results, but a
/// stale completion must still release the picker/reading state, otherwise the
/// dialog stays disabled until it is reopened.
///
/// Adapted from the independent review probe
/// `client/review_probes/avatar_async_probe.dart` (switchSource control +
/// failing case) and extended to the preview-read and dispose paths.
const AuthUser _user = AuthUser(account: '40218765', username: 'qa.tester');

const Key _pickFileKey = Key('avatar-pick-file');
const Key _fieldKey = Key('avatar-source-field');
const Key _applyKey = Key('avatar-source-apply');
const Key _previewKey = Key('avatar-preview');

const String _avatarPath = '/qa/avatar.png';

/// Reader whose first `readPath` stays pending until the test completes it.
class DeferredAvatarSourceReader implements AvatarSourceReader {
  final Completer<Uint8List> firstRead = Completer<Uint8List>();
  final Map<String, Uint8List> ready = <String, Uint8List>{};
  int readCalls = 0;

  @override
  Future<Uint8List> readPath(String path) {
    readCalls += 1;
    if (readCalls == 1) {
      return firstRead.future;
    }
    final Uint8List? bytes = ready[path];
    if (bytes == null) {
      throw AuthFailure(
        status: 422,
        code: 'validation_error',
        message: '无法读取该本机路径',
        fields: <AuthFieldError>[
          const AuthFieldError(
            field: 'path',
            code: 'unreadable',
            message: '无法读取该本机路径',
          ),
        ],
      );
    }
    return Future<Uint8List>.value(bytes);
  }

  @override
  Future<Uint8List> readBase64(String payload) async =>
      throw UnimplementedError();

  @override
  Future<Uint8List> readUrl(String url) async => throw UnimplementedError();
}

void main() {
  Future<void> pumpAvatarDialog(
    WidgetTester tester, {
    required FakeProfileGateway gateway,
    required AvatarImagePicker picker,
    AvatarDecodeCheck decodeCheck = _acceptAnyImage,
    AvatarSourceReader? reader,
    Size size = const Size(1280, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme().copyWith(platform: TargetPlatform.linux),
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => Center(
              child: ElevatedButton(
                onPressed: () => openProfilePanel(
                  context,
                  gateway: gateway,
                  user: _user,
                  avatarPicker: picker,
                  avatarDecodeCheck: decodeCheck,
                  avatarSourceReader: reader ?? FakeAvatarSourceReader(),
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
    await tester.tap(find.text('更换头像').first);
    await tester.pumpAndSettle();
  }

  Finder previewSpinner() => find.descendant(
    of: find.byKey(_previewKey),
    matching: find.byType(CircularProgressIndicator),
  );

  Finder previewImage() => find.descendant(
    of: find.byKey(_previewKey),
    matching: find.byType(Image),
  );

  Future<void> switchToUrlAndBack(WidgetTester tester) async {
    await tester.tap(find.text('图片链接'));
    await tester.pump();
    await tester.tap(find.text('本机路径'));
    await tester.pump();
  }

  for (final bool switchSource in <bool>[false, true]) {
    testWidgets(
      'selected image decode releases the picker (switchSource=$switchSource)',
      (WidgetTester tester) async {
        final FakeProfileGateway gateway = FakeProfileGateway();
        final FakeAvatarSourceReader reader = FakeAvatarSourceReader()
          ..serve(_avatarPath, peerReplacedAvatar);
        final Completer<bool> decoding = Completer<bool>();
        await pumpAvatarDialog(
          tester,
          gateway: gateway,
          picker: FakeAvatarImagePicker(<Object?>[
            const AvatarPick(name: 'avatar.png', path: _avatarPath),
          ]),
          reader: reader,
          decodeCheck: (Uint8List bytes) => decoding.future,
        );

        await tester.tap(find.byKey(_pickFileKey));
        await tester.pump();
        if (switchSource) {
          await switchToUrlAndBack(tester);
        }
        decoding.complete(true);
        await tester.pumpAndSettle();

        // A source switch only invalidates the result, never the busy owner.
        expect(gateway.avatarSources, isEmpty);
        final OutlinedButton button = tester.widget<OutlinedButton>(
          find.byKey(_pickFileKey),
        );
        expect(
          button.onPressed,
          isNotNull,
          reason: 'stale pick must release the picker busy state',
        );
      },
    );
  }

  testWidgets('a stale pick can be retried and only the retry applies', (
    WidgetTester tester,
  ) async {
    final FakeProfileGateway gateway = FakeProfileGateway();
    final FakeAvatarSourceReader reader = FakeAvatarSourceReader()
      ..serve(_avatarPath, peerReplacedAvatar);
    final Completer<bool> firstDecode = Completer<bool>();
    int decodeCalls = 0;
    await pumpAvatarDialog(
      tester,
      gateway: gateway,
      picker: FakeAvatarImagePicker(<Object?>[
        const AvatarPick(name: 'stale.png', path: _avatarPath),
        const AvatarPick(name: 'retry.png', path: _avatarPath),
      ]),
      reader: reader,
      decodeCheck: (Uint8List bytes) {
        decodeCalls += 1;
        return decodeCalls == 1
            ? firstDecode.future
            : Future<bool>.value(true);
      },
    );

    await tester.tap(find.byKey(_pickFileKey));
    await tester.pump();
    await switchToUrlAndBack(tester);
    firstDecode.complete(true);
    await tester.pumpAndSettle();

    // The stale result was dropped: no path/preview from it.
    expect(
      tester.widget<TextField>(find.byKey(_fieldKey)).controller!.text,
      isEmpty,
    );
    expect(previewImage(), findsNothing);

    // Retry works, previews and then uploads only on confirm.
    await tester.tap(find.byKey(_pickFileKey));
    await tester.pumpAndSettle();
    expect(previewImage(), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byKey(_fieldKey)).controller!.text,
      _avatarPath,
    );
    expect(gateway.avatarSources, isEmpty);

    await tester.tap(find.byKey(_applyKey));
    await tester.pumpAndSettle();
    expect(gateway.avatarSources.single, 'path:$_avatarPath');
  });

  testWidgets('a source switch during a preview read releases the spinner', (
    WidgetTester tester,
  ) async {
    final FakeProfileGateway gateway = FakeProfileGateway();
    final DeferredAvatarSourceReader reader = DeferredAvatarSourceReader()
      ..ready[_avatarPath] = peerReplacedAvatar;
    await pumpAvatarDialog(
      tester,
      gateway: gateway,
      picker: FakeAvatarImagePicker(<Object?>[]),
      reader: reader,
    );

    await tester.enterText(find.byKey(_fieldKey), _avatarPath);
    await tester.pump(const Duration(milliseconds: 400));
    // The read is pending; do not pumpAndSettle against the spinner.
    expect(previewSpinner(), findsOneWidget);

    await switchToUrlAndBack(tester);
    reader.firstRead.complete(peerReplacedAvatar);
    await tester.pumpAndSettle();

    // The stale preview is dropped and the spinner is released by its owner.
    expect(previewSpinner(), findsNothing);
    expect(previewImage(), findsNothing);
    expect(find.byKey(const Key('avatar-preview-error')), findsNothing);

    // The dialog is still usable: applying re-validates and submits.
    await tester.tap(find.byKey(_applyKey));
    await tester.pumpAndSettle();
    expect(gateway.avatarSources.single, 'path:$_avatarPath');
  });

  testWidgets('closing the dialog during a pending decode does not throw', (
    WidgetTester tester,
  ) async {
    final FakeProfileGateway gateway = FakeProfileGateway();
    final FakeAvatarSourceReader reader = FakeAvatarSourceReader()
      ..serve(_avatarPath, peerReplacedAvatar);
    final Completer<bool> decoding = Completer<bool>();
    await pumpAvatarDialog(
      tester,
      gateway: gateway,
      picker: FakeAvatarImagePicker(<Object?>[
        const AvatarPick(name: 'avatar.png', path: _avatarPath),
      ]),
      reader: reader,
      decodeCheck: (Uint8List bytes) => decoding.future,
    );

    await tester.tap(find.byKey(_pickFileKey));
    await tester.pump();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    decoding.complete(true);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(gateway.avatarSources, isEmpty);
  });
}

Future<bool> _acceptAnyImage(Uint8List bytes) async => true;
