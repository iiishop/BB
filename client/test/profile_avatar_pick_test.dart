import 'dart:convert';

import 'package:bb_client/app.dart';
import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/services/avatar_source.dart';
import 'package:bb_client/ui/profile/avatar_picker.dart';
import 'package:bb_client/ui/profile/profile_panel.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/avatar_fixtures.dart';
import 'support/fake_profile_gateway.dart';
import 'support/phone_profile.dart';

/// DEA-482: platform avatar picking. The desktop path field is unchanged but
/// gains a native picker; Android replaces the typed path with the system
/// gallery. Both entries share the preview/validation, the confirm step and the
/// single upload chain; a selection alone must never change the server avatar.
///
/// The dialog's reader and decoder are seams here because dart:io reads and
/// engine image decoding only complete under real async, which `testWidgets`
/// taps do not drive. The real reader/decoder have their own tests
/// (`avatar_source_test.dart`, `avatar_picker_decode_test.dart`).
const AuthUser _user = AuthUser(account: '40218765', username: 'muse.tester');

const Key _fieldKey = Key('avatar-source-field');
const Key _applyKey = Key('avatar-source-apply');
const Key _pickFileKey = Key('avatar-pick-file');
const Key _pickGalleryKey = Key('avatar-pick-gallery');
const Key _previewKey = Key('avatar-preview');
const Key _previewErrorKey = Key('avatar-preview-error');
const Key _pickErrorKey = Key('avatar-pick-error');

const String _validPath = '/home/me/我的 头像.png';
const String _missingPath = '/home/me/已删除.png';
const String _textPath = '/home/me/not-an-image.png';
const String _truncatedPath = '/home/me/truncated.png';

Future<bool> acceptAnyImage(Uint8List bytes) async => true;

AuthFailure _sourceFailure(String code, String message) => AuthFailure(
  status: 422,
  code: 'validation_error',
  message: message,
  fields: <AuthFieldError>[
    AuthFieldError(field: 'path', code: code, message: message),
  ],
);

/// Queue of picker results: [AvatarPick] success, `null` for cancel, or an
/// exception to throw.
class FakeAvatarImagePicker implements AvatarImagePicker {
  FakeAvatarImagePicker(this._results);

  final List<Object?> _results;
  int calls = 0;

  @override
  Future<AvatarPick?> pickImage() async {
    calls += 1;
    if (_results.isEmpty) {
      return null;
    }
    final Object? next = _results.removeAt(0);
    if (next is Exception) {
      throw next;
    }
    return next as AvatarPick?;
  }
}

/// Absolute-path reader backed by an in-memory map.
class FakeAvatarSourceReader implements AvatarSourceReader {
  final Map<String, Object> _paths = <String, Object>{};

  void serve(String path, Uint8List bytes) => _paths[path] = bytes;

  void fail(String path, AuthFailure failure) => _paths[path] = failure;

  @override
  Future<Uint8List> readPath(
    String path, {
    int maxBytes = maxAvatarBytes,
  }) async {
    final Object? result = _paths[path];
    if (result == null) {
      throw _sourceFailure('unreadable', '无法读取该本机路径');
    }
    if (result is AuthFailure) {
      throw result;
    }
    return result as Uint8List;
  }

  @override
  Future<Uint8List> readBase64(
    String payload, {
    int maxBytes = maxAvatarBytes,
  }) async => throw UnimplementedError();

  @override
  Future<Uint8List> readUrl(
    String url, {
    int maxBytes = maxAvatarBytes,
  }) async => throw UnimplementedError();
}

void main() {
  late FakeProfileGateway gateway;
  late FakeAvatarSourceReader reader;

  setUp(() {
    gateway = FakeProfileGateway();
    reader = FakeAvatarSourceReader()
      ..serve(_validPath, peerReplacedAvatar)
      ..serve(_truncatedPath, peerReplacedAvatar.sublist(0, 20))
      ..fail(_textPath, _sourceFailure('format', '仅支持 PNG、JPEG 或 WebP 图片'));
  });

  Future<void> openAvatarDialog(
    WidgetTester tester, {
    required AvatarImagePicker picker,
    AvatarDecodeCheck decodeCheck = acceptAnyImage,
    Size size = const Size(1280, 900),
  }) async {
    tester.view.physicalSize = size;
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
                  avatarPicker: picker,
                  avatarDecodeCheck: decodeCheck,
                  avatarSourceReader: reader,
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
    await openProfileEditSheet(tester);
    await tester.tap(find.text('更换头像').first);
    await tester.pumpAndSettle();
  }

  Finder previewImage() => find.descendant(
    of: find.byKey(_previewKey),
    matching: find.byType(Image),
  );

  Future<void> settlePreview(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
  }

  String fieldText(WidgetTester tester) =>
      tester.widget<TextField>(find.byKey(_fieldKey)).controller!.text;

  group('desktop path entry', () {
    testWidgets(
      'picking a file fills the path, previews it and needs confirm',
      (WidgetTester tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.linux;
        final FakeAvatarImagePicker picker = FakeAvatarImagePicker(<Object?>[
          AvatarPick(name: '我的 头像.png', path: _validPath),
        ]);
        try {
          await openAvatarDialog(tester, picker: picker);
          await tester.tap(find.byKey(_pickFileKey));
          await tester.pumpAndSettle();

          expect(picker.calls, 1);
          expect(fieldText(tester), _validPath);
          expect(previewImage(), findsOneWidget);
          // Selecting is not confirming: nothing reached the server yet.
          expect(gateway.avatarSources, isEmpty);
          expect(gateway.profile.avatarVersion, 'v1');

          await tester.tap(find.byKey(_applyKey));
          await tester.pumpAndSettle();

          expect(gateway.avatarSources.single, 'path:$_validPath');
          expect(find.text('头像已更新'), findsOneWidget);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );

    testWidgets('a typed absolute path still previews and updates', (
      WidgetTester tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        await openAvatarDialog(
          tester,
          picker: FakeAvatarImagePicker(<Object?>[]),
        );
        await tester.enterText(find.byKey(_fieldKey), _validPath);
        await settlePreview(tester);

        expect(previewImage(), findsOneWidget);
        expect(gateway.avatarSources, isEmpty);

        await tester.tap(find.byKey(_applyKey));
        await tester.pumpAndSettle();
        expect(gateway.avatarSources.single, 'path:$_validPath');
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('a missing path reports unreadable and never uploads', (
      WidgetTester tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        await openAvatarDialog(
          tester,
          picker: FakeAvatarImagePicker(<Object?>[]),
        );
        await tester.enterText(find.byKey(_fieldKey), _missingPath);
        await settlePreview(tester);

        expect(
          tester.widget<Text>(find.byKey(_previewErrorKey)).data,
          '无法读取该本机路径',
        );
        await tester.tap(find.byKey(_applyKey));
        await tester.pumpAndSettle();
        expect(gateway.avatarSources, isEmpty);
        expect(find.byKey(_applyKey), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('a non-image file is rejected by content, not by extension', (
      WidgetTester tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        await openAvatarDialog(
          tester,
          picker: FakeAvatarImagePicker(<Object?>[]),
        );
        await tester.enterText(find.byKey(_fieldKey), _textPath);
        await settlePreview(tester);

        expect(
          tester.widget<Text>(find.byKey(_previewErrorKey)).data,
          '仅支持 PNG、JPEG 或 WebP 图片',
        );
        await tester.tap(find.byKey(_applyKey));
        await tester.pumpAndSettle();
        expect(gateway.avatarSources, isEmpty);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('a truncated png with a valid signature cannot be decoded', (
      WidgetTester tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        await openAvatarDialog(
          tester,
          picker: FakeAvatarImagePicker(<Object?>[]),
          decodeCheck: (Uint8List bytes) async => false,
        );
        await tester.enterText(find.byKey(_fieldKey), _truncatedPath);
        await settlePreview(tester);

        expect(
          tester.widget<Text>(find.byKey(_previewErrorKey)).data,
          '这个文件无法解码为图片，请换一张',
        );
        await tester.tap(find.byKey(_applyKey));
        await tester.pumpAndSettle();
        expect(gateway.avatarSources, isEmpty);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('cancelling the picker keeps the typed path and preview', (
      WidgetTester tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      final FakeAvatarImagePicker picker = FakeAvatarImagePicker(<Object?>[
        null,
      ]);
      try {
        await openAvatarDialog(tester, picker: picker);
        await tester.enterText(find.byKey(_fieldKey), _validPath);
        await settlePreview(tester);
        expect(previewImage(), findsOneWidget);

        await tester.tap(find.byKey(_pickFileKey));
        await tester.pumpAndSettle();

        expect(fieldText(tester), _validPath);
        expect(previewImage(), findsOneWidget);
        expect(gateway.avatarSources, isEmpty);
        expect(find.byKey(_previewErrorKey), findsNothing);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('closing the dialog after a pick does not touch the avatar', (
      WidgetTester tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      final FakeAvatarImagePicker picker = FakeAvatarImagePicker(<Object?>[
        AvatarPick(name: 'x.png', path: _validPath),
      ]);
      try {
        await openAvatarDialog(tester, picker: picker);
        await tester.tap(find.byKey(_pickFileKey));
        await tester.pumpAndSettle();
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();

        expect(gateway.avatarSources, isEmpty);
        expect(gateway.profile.avatarVersion, 'v1');
        expect(find.byKey(_applyKey), findsNothing);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('a long path does not stretch the dialog', (
      WidgetTester tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        await openAvatarDialog(
          tester,
          picker: FakeAvatarImagePicker(<Object?>[]),
        );
        // Real Linux entry: a ~90-character Chinese path made the dialog grow
        // past the window before the content width was capped.
        final String longPath = '/home/me/${'很长的目录名/' * 8}头像 样图.png';
        await tester.enterText(find.byKey(_fieldKey), longPath);
        await settlePreview(tester);

        // The path field is the widest content row: it must stay bounded
        // instead of growing with the typed text.
        expect(
          tester.getSize(find.byKey(_fieldKey)).width,
          lessThanOrEqualTo(360),
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('a failed upload is reported as a failure, not success', (
      WidgetTester tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      gateway.avatarUpdateFailure = const AuthFailure(
        status: 500,
        code: 'storage_io_error',
        message: '头像保存失败，请稍后重试',
      );
      final FakeAvatarImagePicker picker = FakeAvatarImagePicker(<Object?>[
        AvatarPick(name: 'x.png', path: _validPath),
      ]);
      try {
        await openAvatarDialog(tester, picker: picker);
        await tester.tap(find.byKey(_pickFileKey));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(_applyKey));
        await tester.pumpAndSettle();

        // The upload was attempted exactly once and the server rejected it.
        expect(gateway.avatarSources.single, 'path:$_validPath');
        expect(find.text('头像已更新'), findsNothing);
        expect(find.text('头像保存失败，请稍后重试'), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  group('android gallery entry', () {
    testWidgets('picking from the gallery previews and uploads the bytes', (
      WidgetTester tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final FakeAvatarImagePicker picker = FakeAvatarImagePicker(<Object?>[
        AvatarPick(name: '相册图.png', bytes: peerReplacedAvatar),
      ]);
      try {
        await openAvatarDialog(
          tester,
          picker: picker,
          size: const Size(390, 844),
        );
        await tester.tap(find.byKey(_pickGalleryKey));
        await tester.pumpAndSettle();

        expect(previewImage(), findsOneWidget);
        expect(find.text('已选择：相册图.png'), findsOneWidget);
        expect(gateway.avatarSources, isEmpty);

        await tester.tap(find.byKey(_applyKey));
        await tester.pumpAndSettle();

        // No filesystem path is assumed for the platform content URI.
        expect(
          gateway.avatarSources.single,
          'bytes:${peerReplacedAvatar.length}',
        );
        expect(find.text('头像已更新'), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('cancelling the gallery keeps the current avatar', (
      WidgetTester tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final FakeAvatarImagePicker picker = FakeAvatarImagePicker(<Object?>[
        null,
      ]);
      try {
        await openAvatarDialog(
          tester,
          picker: picker,
          size: const Size(390, 844),
        );
        await tester.tap(find.byKey(_pickGalleryKey));
        await tester.pumpAndSettle();

        expect(previewImage(), findsNothing);
        expect(find.byKey(_pickErrorKey), findsNothing);
        expect(gateway.avatarSources, isEmpty);
        expect(gateway.profile.avatarVersion, 'v1');
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('a picker failure is friendly and retryable', (
      WidgetTester tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final FakeAvatarImagePicker picker = FakeAvatarImagePicker(<Object?>[
        PlatformException(code: 'picker_failed', message: 'native stack trace'),
        AvatarPick(name: 'retry.png', bytes: peerReplacedAvatar),
      ]);
      try {
        await openAvatarDialog(
          tester,
          picker: picker,
          size: const Size(390, 844),
        );
        await tester.tap(find.byKey(_pickGalleryKey));
        await tester.pumpAndSettle();

        expect(
          tester.widget<Text>(find.byKey(_pickErrorKey)).data,
          '无法打开系统相册，请稍后重试',
        );
        expect(find.textContaining('native stack trace'), findsNothing);
        expect(tester.takeException(), isNull);

        await tester.tap(find.byKey(_pickGalleryKey));
        await tester.pumpAndSettle();
        expect(previewImage(), findsOneWidget);
        expect(find.byKey(_pickErrorKey), findsNothing);

        await tester.tap(find.byKey(_applyKey));
        await tester.pumpAndSettle();
        expect(gateway.avatarSources.single, startsWith('bytes:'));
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('applying with no gallery selection asks before uploading', (
      WidgetTester tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        await openAvatarDialog(
          tester,
          picker: FakeAvatarImagePicker(<Object?>[]),
          size: const Size(390, 844),
        );
        await tester.tap(find.byKey(_applyKey));
        await tester.pumpAndSettle();

        expect(
          tester.widget<Text>(find.byKey(_pickErrorKey)).data,
          '请先从相册选择图片',
        );
        expect(gateway.avatarSources, isEmpty);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('non-image gallery bytes are rejected before upload', (
      WidgetTester tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final FakeAvatarImagePicker picker = FakeAvatarImagePicker(<Object?>[
        AvatarPick(
          name: 'fake.png',
          bytes: Uint8List.fromList(utf8.encode('not an image')),
        ),
      ]);
      try {
        await openAvatarDialog(
          tester,
          picker: picker,
          size: const Size(390, 844),
        );
        await tester.tap(find.byKey(_pickGalleryKey));
        await tester.pumpAndSettle();

        expect(
          tester.widget<Text>(find.byKey(_previewErrorKey)).data,
          '仅支持 PNG、JPEG 或 WebP 图片',
        );
        await tester.tap(find.byKey(_applyKey));
        await tester.pumpAndSettle();
        expect(gateway.avatarSources, isEmpty);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}
