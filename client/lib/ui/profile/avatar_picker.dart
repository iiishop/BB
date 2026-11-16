import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';

/// One image chosen through a platform picker.
///
/// Either [path] or [bytes] describes where the image comes from:
/// * desktop pickers return a real absolute [path], and the dialog writes it
///   into the path field so the field stays the single source of truth;
/// * Android's system document picker only guarantees readable bytes for the
///   returned content URI, so the adapter keeps [bytes] and never assumes a
///   filesystem path exists.
class AvatarPick {
  const AvatarPick({required this.name, this.path, this.bytes});

  /// Display name only; never used to decide whether the file is an image.
  final String name;
  final String? path;
  final Uint8List? bytes;
}

/// A failure with a message that is safe to show to the user.
class AvatarPickFailure implements Exception {
  const AvatarPickFailure(this.message);

  final String message;

  @override
  String toString() => 'AvatarPickFailure: $message';
}

/// Platform image chooser used by the avatar dialog.
abstract class AvatarImagePicker {
  /// Opens the system image chooser. Null means the user cancelled.
  Future<AvatarPick?> pickImage();
}

/// Proves candidate bytes really decode as an image.
///
/// Injectable so widget tests can accept/reject candidates deterministically:
/// the engine decoder only completes under real async, which `testWidgets`
/// taps do not drive. The default is [isDecodableAvatarImage].
typedef AvatarDecodeCheck = Future<bool> Function(Uint8List bytes);

/// Default picker backed by `file_selector`.
///
/// The type group lists PNG/JPEG/WebP so the chooser filters to decodable
/// avatar images:
/// * Android maps it to `ACTION_OPEN_DOCUMENT` with an image MIME filter
///   (system gallery/recents UI, no storage or photo permission);
/// * Linux/Windows open their native file dialogs.
class FileSelectorAvatarImagePicker implements AvatarImagePicker {
  const FileSelectorAvatarImagePicker();

  static const XTypeGroup _imageGroup = XTypeGroup(
    label: '图片',
    extensions: <String>['png', 'jpg', 'jpeg', 'webp'],
    mimeTypes: <String>['image/png', 'image/jpeg', 'image/webp'],
  );

  @override
  Future<AvatarPick?> pickImage() async {
    final XFile? file = await openFile(
      acceptedTypeGroups: const <XTypeGroup>[_imageGroup],
      confirmButtonText: '选择',
    );
    if (file == null) {
      return null;
    }
    final String name = file.name.isEmpty ? 'avatar' : file.name;
    // Android returns a content URI that file_selector copies into a cache
    // file. That path is a plugin implementation detail, so read the bytes the
    // platform actually handed back instead of depending on it.
    if (!Platform.isAndroid && file.path.isNotEmpty) {
      return AvatarPick(name: name, path: file.path);
    }
    return AvatarPick(name: name, bytes: await file.readAsBytes());
  }
}

/// True when the engine can decode [bytes] as an image.
///
/// A file extension or even the image magic bytes are not enough: a truncated
/// or corrupt `.png` must be rejected before it is previewed or uploaded.
/// Decoding is bounded to 256px so a small file with huge dimensions cannot
/// exhaust memory just to prove it is an image.
Future<bool> isDecodableAvatarImage(Uint8List bytes) async {
  if (bytes.isEmpty) {
    return false;
  }
  ui.Codec? codec;
  try {
    codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: 256,
      targetHeight: 256,
    );
    final ui.FrameInfo frame = await codec.getNextFrame();
    frame.image.dispose();
    return true;
  } catch (_) {
    return false;
  } finally {
    codec?.dispose();
  }
}
