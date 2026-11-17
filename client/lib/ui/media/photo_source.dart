/// One page of the shared full-screen photo viewer.
///
/// Chat media and Space images differ only in where the bytes come from; the
/// zoom, the preview/original switch and the on-disk cache must behave the
/// same. This contract is that seam. `ChatPhotoSource` and `SpacePhotoSource`
/// implement it, and the viewer never asks which one it got.
library;

import 'package:flutter/foundation.dart';

/// Transfer progress; [total] is null when the transport cannot report a size.
typedef PhotoProgress = void Function(int received, int? total);

/// A bounded preview that may be a downscaled derivative of the original.
class PhotoPreview {
  const PhotoPreview({required this.bytes, required this.isDerivative});

  final Uint8List bytes;

  /// True when these bytes are a smaller derivative, so the viewer must offer
  /// the original instead of pretending this is the best available.
  final bool isDerivative;
}

/// Bytes for one image, plus the cache lookup that makes a previously viewed
/// original come back without a network round trip.
abstract class PhotoSource {
  /// Original byte size once known. Null means "not probed yet"; loading the
  /// preview may fill it in.
  int? get byteSize;

  /// Original bytes the caller already holds (an image this account just sent).
  /// A non-empty value skips both the network and the preview step.
  Uint8List? get heldOriginal;

  /// Original bytes from the on-disk cache, or null when nothing is stored.
  ///
  /// This is what keeps "viewed the original an hour ago" from degrading back
  /// to the thumbnail after the viewer is closed.
  Future<Uint8List?> readCachedOriginal();

  /// Bounded preview bytes. Implementations must not download the original
  /// here: that is what [loadOriginal] is for.
  Future<PhotoPreview> loadPreview();

  /// Original bytes, persisted to the cache by the implementation on a miss.
  Future<Uint8List> loadOriginal({PhotoProgress? onProgress});

  /// Fires when this source's bytes stop being valid: the post was deleted, or
  /// the whole cache was cleared on reconnect. Null when the source cannot be
  /// invalidated (chat media ids are immutable once sent).
  Listenable? get changes;

  /// True once [changes] reported that these bytes are no longer current. The
  /// viewer then shows a failure state instead of a picture that should have
  /// disappeared.
  bool get invalidated;
}
