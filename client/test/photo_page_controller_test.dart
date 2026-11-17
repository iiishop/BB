import 'package:bb_client/ui/media/photo_page.dart';
import 'package:bb_client/ui/media/photo_source.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// The rules the two viewers share live in [PhotoPageController], so they are
/// tested here once instead of through two widget trees.
class _FakeSource implements PhotoSource {
  _FakeSource({
    this.byteSize,
    this.previewDerivative = true,
    this.cachedOriginal,
    this.failOriginal = false,
    this.failPreview = false,
  });

  @override
  int? byteSize;

  final bool previewDerivative;
  final Uint8List? cachedOriginal;
  final bool failOriginal;
  final bool failPreview;

  final List<int> progress = <int>[];
  int originalCalls = 0;
  int previewCalls = 0;

  final ChangeNotifier _notifier = ChangeNotifier();
  bool _invalidated = false;

  void invalidate() {
    _invalidated = true;
    _notifier.notifyListeners();
  }

  @override
  Uint8List? get heldOriginal => null;

  @override
  Listenable? get changes => _notifier;

  @override
  bool get invalidated => _invalidated;

  @override
  Future<Uint8List?> readCachedOriginal() async => cachedOriginal;

  @override
  Future<PhotoPreview> loadPreview() async {
    previewCalls += 1;
    if (failPreview) {
      throw StateError('preview failed');
    }
    return PhotoPreview(
      bytes: Uint8List.fromList(<int>[1, 2, 3]),
      isDerivative: previewDerivative,
    );
  }

  @override
  Future<Uint8List> loadOriginal({PhotoProgress? onProgress}) async {
    originalCalls += 1;
    onProgress?.call(1, 4);
    progress.add(1);
    if (failOriginal) {
      throw StateError('original failed');
    }
    onProgress?.call(4, 4);
    progress.add(4);
    return Uint8List.fromList(<int>[9, 9, 9, 9]);
  }
}

void main() {
  test('a small image is shown at full quality with no original action', () async {
    final _FakeSource source = _FakeSource(
      byteSize: 40 * 1024,
      previewDerivative: false,
    );
    final PhotoPageController controller = PhotoPageController(source: source);
    await controller.start();

    expect(controller.phase, PhotoPhase.ready);
    expect(controller.isOriginal, isTrue);
    expect(controller.offersOriginal, isFalse);
    expect(source.originalCalls, 0, reason: '小图不该走显式原图通道');
  });

  test('a large image offers the original, then reports transfer progress', () async {
    final _FakeSource source = _FakeSource(byteSize: 3 * 1024 * 1024);
    final PhotoPageController controller = PhotoPageController(source: source);
    await controller.start();

    expect(controller.phase, PhotoPhase.showingPreview);
    expect(controller.offersOriginal, isTrue);
    expect(controller.originalLabel, '原图 3.0 MB');
    expect(source.originalCalls, 0);

    await controller.loadOriginal();

    expect(controller.phase, PhotoPhase.ready);
    expect(controller.isOriginal, isTrue);
    expect(source.originalCalls, 1);
    expect(source.progress, <int>[1, 4]);
  });

  test('an original already in the cache opens without a download', () async {
    final _FakeSource source = _FakeSource(
      byteSize: 3 * 1024 * 1024,
      cachedOriginal: Uint8List.fromList(<int>[7, 7]),
    );
    final PhotoPageController controller = PhotoPageController(source: source);
    await controller.start();

    expect(controller.phase, PhotoPhase.ready);
    expect(controller.isOriginal, isTrue);
    expect(controller.offersOriginal, isFalse);
    expect(
      source.originalCalls,
      0,
      reason: '看过一次的原图，重开时不该再问网络',
    );
  });

  test('a failed original fetch keeps the preview and offers a retry', () async {
    final _FakeSource source = _FakeSource(
      byteSize: 3 * 1024 * 1024,
      failOriginal: true,
    );
    final PhotoPageController controller = PhotoPageController(source: source);
    await controller.start();
    await controller.loadOriginal();

    expect(controller.phase, PhotoPhase.showingPreview);
    expect(controller.originalFailed, isTrue);
    expect(controller.bytes, isNotNull, reason: '预览不能被失败的原图拖走');
    expect(controller.originalLabel, '重试 原图 3.0 MB');
  });

  test('a failed preview falls back to the failure state', () async {
    final _FakeSource source = _FakeSource(failPreview: true);
    final PhotoPageController controller = PhotoPageController(source: source);
    await controller.start();

    expect(controller.phase, PhotoPhase.failed);
    expect(controller.bytes, isNull);
  });

  test('an invalidated source drops the picture already on screen', () async {
    final _FakeSource source = _FakeSource(byteSize: 3 * 1024 * 1024);
    final PhotoPageController controller = PhotoPageController(source: source);
    await controller.start();
    expect(controller.phase, PhotoPhase.showingPreview);

    source.invalidate();

    expect(controller.phase, PhotoPhase.failed);
    expect(controller.bytes, isNull);
  });
}
