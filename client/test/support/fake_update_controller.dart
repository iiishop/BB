import 'package:bb_client/updates/update_contract.dart';

/// Deterministic [UpdateController] for UI tests.
///
/// It records which actions the surface requested; it never performs I/O and no
/// release selection happens here (that is Forge's contract test area).
class FakeUpdateController extends UpdateController {
  FakeUpdateController({
    UpdateSnapshot snapshot = const UpdateSnapshot(),
    InstallSafetyGate? safetyGate,
  }) : safetyGate = safetyGate ?? InstallSafetyGate.instance {
    _snapshot = snapshot;
  }

  UpdateSnapshot _snapshot = const UpdateSnapshot();
  int checkOnceCalls = 0;
  int checkCalls = 0;
  int downloadCalls = 0;
  int installCalls = 0;
  int cancelCalls = 0;

  @override
  final InstallSafetyGate safetyGate;

  @override
  UpdateSnapshot get snapshot => _snapshot;

  void emit(UpdateSnapshot snapshot) {
    _snapshot = snapshot;
    notifyListeners();
  }

  @override
  Future<void> checkOnce() async {
    checkOnceCalls += 1;
  }

  @override
  Future<void> check() async {
    checkCalls += 1;
  }

  @override
  Future<void> download() async {
    downloadCalls += 1;
  }

  @override
  Future<void> install() async {
    installCalls += 1;
  }

  @override
  void cancel() {
    cancelCalls += 1;
  }
}

UpdateRelease fakeRelease({String version = '0.1.0+3', String body = ''}) {
  return UpdateRelease(
    id: 1,
    tag: 'v$version',
    version: version,
    body: body,
    htmlUrl: Uri.parse('https://github.com/iiishop/BB/releases/tag/v$version'),
    asset: UpdateAsset(
      id: 11,
      name: 'bb-$version-android-arm64-v8a.apk',
      url: Uri.parse(
        'https://github.com/iiishop/BB/releases/download/v$version/'
        'bb-$version-android-arm64-v8a.apk',
      ),
      size: 1024,
    ),
    checksums: UpdateAsset(
      id: 12,
      name: 'SHA256SUMS',
      url: Uri.parse(
        'https://github.com/iiishop/BB/releases/download/v$version/SHA256SUMS',
      ),
      size: 256,
    ),
  );
}
