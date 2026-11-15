import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bb_client/updates/release_client.dart';
import 'package:bb_client/updates/release_policy.dart';
import 'package:bb_client/updates/release_update_controller.dart';
import 'package:bb_client/updates/update_contract.dart';

const info = UpdatePlatformInfo(
  os: 'windows',
  architecture: 'x64',
  version: '1.9.0',
  buildNumber: 2,
);
final payload = utf8.encode('isolated package bytes');
String sums({bool wrong = false}) =>
    '${wrong ? '0' * 64 : sha256.convert(payload)}  bb-1.10.0-windows-x64.zip\n';
Map<String, dynamic> release({
  String version = '1.10.0',
  bool draft = false,
  bool pre = false,
}) {
  Map<String, dynamic> asset(String name, int size, int id) => {
    'id': id,
    'name': name,
    'size': size,
    'state': 'uploaded',
    'browser_download_url':
        'https://github.com/iiishop/BB/releases/download/v$version/$name',
  };
  return {
    'id': 123,
    'tag_name': 'v$version',
    'draft': draft,
    'prerelease': pre,
    'body': '# Original\n<script>never execute</script>\n[link](https://example.org)',
    'html_url': 'https://github.com/iiishop/BB/releases/tag/v$version',
    'assets': [
      asset('bb-$version-windows-x64.zip', payload.length, 7),
      asset('SHA256SUMS', sums().length, 8),
    ],
  };
}

class Installer implements UpdateInstaller {
  int installs = 0;
  @override
  Future<UpdatePlatformInfo> platformInfo() async => info;
  @override
  Future<UpdateInstallResult> install(VerifiedUpdate update) async {
    installs++;
    return UpdateInstallResult.installerOpened;
  }
}

// Only reroutes sockets to a real loopback HTTP server. Production URL and
// redirect validation still execute unchanged before every request.
class LoopbackClient implements HttpClient {
  LoopbackClient(this.port);
  final int port;
  final HttpClient inner = HttpClient();
  @override
  set autoUncompress(bool value) {
    inner.autoUncompress = value;
  }

  @override
  set connectionTimeout(Duration? value) {
    inner.connectionTimeout = value;
  }

  @override
  Future<HttpClientRequest> getUrl(Uri uri) =>
      inner.getUrl(uri.replace(scheme: 'http', host: '127.0.0.1', port: port));
  @override
  void close({bool force = false}) => inner.close(force: force);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('SemVer numeric, pre-release, build metadata and invalid forms', () {
    for (final pair in [
      ('1.9.0', '1.10.0'),
      ('1.0.0-rc.9', '1.0.0-rc.10'),
      ('1.0.0-alpha', '1.0.0'),
      ('0.0.1', '0.2.0'),
    ]) {
      expect(
        ReleaseVersion.parse(pair.$1).compareTo(ReleaseVersion.parse(pair.$2)),
        lessThan(0),
      );
    }
    expect(
      ReleaseVersion.parse('1.0.0+2')
          .compareTo(ReleaseVersion.parse('1.0.0+3')),
      0,
    );
    for (final invalid in [
      '01.0.0',
      '1.0',
      '1.0.0-01',
      '1.0.0-a..b',
      '1.0.0+',
    ]) {
      expect(() => ReleaseVersion.parse(invalid), throwsFormatException);
    }
  });
  test('highest stable version ignores order, draft, prerelease and older', () {
    final selected = selectRelease([
      release(version: '1.8.0'),
      release(),
      release(version: '2.0.0', draft: true),
      release(version: '2.0.0-rc.1'),
      release(version: '3.0.0', pre: true),
    ], info)!;
    expect(selected.version, '1.10.0');
    expect(selected.body, release()['body']);
    expect(
      selectRelease([
        release(version: '1.9.0'),
        release(version: '1.0.0'),
      ], info),
      isNull,
    );
    expect(
      selectRelease(
        [release(version: '0.0.1')],
        const UpdatePlatformInfo(
          os: 'windows',
          architecture: 'x64',
          version: '0.2.0',
          buildNumber: 1,
        ),
      ),
      isNull,
    );
  });
  test(
    'asset ambiguity, wrong architecture and foreign source fail closed',
    () {
      final row = release();
      final assets = row['assets'] as List;
      assets.add(Map<String, dynamic>.from(assets.first as Map));
      expect(() => selectRelease([row], info), throwsStateError);
      expect(
        () => selectRelease(
          [release()],
          const UpdatePlatformInfo(
            os: 'windows',
            architecture: 'arm64',
            version: '1.0.0',
            buildNumber: 1,
          ),
        ),
        throwsStateError,
      );
      final foreign = release();
      (foreign['assets'] as List).first['browser_download_url'] =
          'https://evil.example/package.zip';
      expect(() => selectRelease([foreign], info), throwsStateError);
      final missing = release();
      (missing['assets'] as List).removeLast();
      expect(() => selectRelease([missing], info), throwsStateError);
    },
  );
  test('checksums require unique exact filename and valid digest', () {
    expect(
      checksumFor(sums(), 'bb-1.10.0-windows-x64.zip'),
      sha256.convert(payload).toString(),
    );
    expect(
      () => checksumFor(sums() + sums(), 'bb-1.10.0-windows-x64.zip'),
      throwsFormatException,
    );
    expect(() => checksumFor(sums(), 'another.zip'), throwsFormatException);
    expect(() => checksumFor('bad checksum', 'a.zip'), throwsFormatException);
  });
  test(
    'gate blocks drafts and complete in-flight operation; admission is atomic',
    () async {
      final gate = InstallSafetyGate();
      final owner = Object();
      gate.setBlocker(owner, 'unsaved draft');
      expect(gate.acquire, throwsStateError);
      gate.setBlocker(owner, null);
      final pending = Completer<void>();
      final work = gate.protect(() => pending.future);
      expect(gate.acquire, throwsStateError);
      pending.complete();
      await work;
      gate.acquire();
      await expectLater(gate.protect(() async {}), throwsStateError);
      gate.release();
      await gate.protect(() async {});
    },
  );

  group('real HTTP transport + controller', () {
    late HttpServer server;
    late Directory temp;
    late ReleaseUpdateController controller;
    late Installer installer;
    int checks = 0;
    int status = 200;
    bool wrongHash = false;
    bool truncated = false;
    bool foreignRedirect = false;
    bool hold = false;
    late Completer<void> downloadStarted;
    late Completer<void> finish;
    setUp(() async {
      checks = 0;
      status = 200;
      wrongHash = false;
      truncated = false;
      foreignRedirect = false;
      hold = false;
      downloadStarted = Completer<void>();
      finish = Completer<void>();
      temp = await Directory.systemTemp.createTemp('bb-update-test-');
      server = await HttpServer.bind('127.0.0.1', 0);
      server.listen((request) async {
        try {
          if (request.uri.path == '/repos/iiishop/BB/releases') {
            checks++;
            request.response.statusCode = status;
            request.response.write(jsonEncode([release()]));
          } else if (request.uri.path.endsWith('/assets/8')) {
            request.response.write(sums(wrong: wrongHash));
          } else if (foreignRedirect) {
            request.response.statusCode = 302;
            request.response.headers.set(
              'location',
              'https://evil.example/package.zip',
            );
          } else {
            if (!downloadStarted.isCompleted) downloadStarted.complete();
            request.response.add(truncated ? payload.sublist(0, 3) : payload);
            if (hold) {
              await request.response.flush();
              await finish.future;
            }
          }
          await request.response.close();
        } catch (_) {
          /* A cancelled socket is expected in the cancellation test. */
        }
      });
      final port = server.port;
      installer = Installer();
      controller = ReleaseUpdateController(
        installer: installer,
        cacheDirectory: temp,
        safetyGate: InstallSafetyGate(),
        clientFactory: () => ReleaseClient(http: LoopbackClient(port)),
      );
    });
    tearDown(() async {
      if (!finish.isCompleted) finish.complete();
      controller.dispose();
      await server.close(force: true);
      await temp.delete(recursive: true);
    });
    test(
      'one startup check, exact original body, manual retry after rate limit',
      () async {
        status = 429;
        await Future.wait([controller.checkOnce(), controller.checkOnce()]);
        expect(checks, 1);
        expect(controller.snapshot.phase, UpdatePhase.failed);
        status = 200;
        await controller.check();
        expect(checks, 2);
        expect(controller.snapshot.phase, UpdatePhase.available);
        expect(controller.snapshot.release!.body, release()['body']);
        expect(await temp.list().isEmpty, isTrue); // Check never downloads.
      },
    );
    test('download verifies, draft blocks install, explicit retry invokes installer', () async {
      await controller.check();
      await controller.download();
      expect(controller.snapshot.phase, UpdatePhase.ready);
      controller.safetyGate.setBlocker('draft', 'Finish draft');
      await controller.install();
      expect(installer.installs, 0);
      controller.safetyGate.setBlocker('draft', null);
      await controller.install();
      expect(installer.installs, 1);
      expect(controller.snapshot.phase, UpdatePhase.installerOpened);
      expect(controller.safetyGate.installing, isFalse);
    });
    test(
      'wrong hash, truncated body and foreign redirect never reach installer',
      () async {
        await controller.check();
        wrongHash = true;
        await controller.download();
        expect(controller.snapshot.phase, UpdatePhase.failed);
        expect(await temp.list().isEmpty, isTrue);
        wrongHash = false;
        truncated = true;
        await controller.download();
        expect(controller.snapshot.phase, UpdatePhase.failed);
        truncated = false;
        foreignRedirect = true;
        await controller.download();
        expect(controller.snapshot.phase, UpdatePhase.failed);
        await controller.install();
        expect(installer.installs, 0);
        foreignRedirect = false;
        await controller.download();
        expect(controller.snapshot.phase, UpdatePhase.ready);
      },
    );
    test(
      'cancel and immediate retry cannot race old staging cleanup',
      () async {
        await controller.check();
        hold = true;
        final download = controller.download();
        await downloadStarted.future;
        controller.cancel();
        await controller.download(); // Still busy; must be ignored.
        finish.complete();
        await download;
        expect(controller.snapshot.phase, UpdatePhase.cancelled);
        expect(await temp.list().isEmpty, isTrue);
        hold = false;
        await controller.download();
        expect(controller.snapshot.phase, UpdatePhase.ready);
      },
    );
    test(
      'tampering after verification is rejected at installation boundary',
      () async {
        await controller.check();
        await controller.download();
        final file = await temp
            .list(recursive: true)
            .where((e) => e is File)
            .cast<File>()
            .first;
        await file.writeAsString('tampered');
        await controller.install();
        expect(installer.installs, 0);
        expect(controller.snapshot.phase, UpdatePhase.failed);
      },
    );
    test(
      'offline check is visible and does not throw out of startup',
      () async {
        await server.close(force: true);
        await controller.checkOnce();
        expect(controller.snapshot.phase, UpdatePhase.failed);
        expect(controller.snapshot.message, contains('网络'));
      },
    );
  });
}
