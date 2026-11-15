@TestOn('windows')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bb_client/ui/chat/clipboard_paste.dart';
import 'package:bb_client/ui/chat/media_actions.dart';
import 'package:flutter_test/flutter_test.dart';

// Native Windows clipboard chain for DEA-480.
//
// These tests use the real Windows clipboard and the real PowerShell probe; no
// fake is inserted at the native boundary. They cover the user path (Explorer
// copy -> Ctrl+V reader -> ordered draft entries) and the DEA-480 failure:
// Windows PowerShell 5.1 writes a localized CLIXML progress record to stderr
// even when the probe succeeds, so strict UTF-8 decoding of stderr replaced the
// result with `FormatException: Missing extension byte`.
final Uint8List _png = Uint8List.fromList(<int>[
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x02,
  0x00,
  0x00,
  0x00,
  0x02,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x72,
  0xB6,
  0x0D,
  0x24,
  0x00,
  0x00,
  0x00,
  0x14,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9C,
  0x63,
  0xFC,
  0xCF,
  0xC0,
  0xF0,
  0x9F,
  0x81,
  0x81,
  0x81,
  0x81,
  0x89,
  0x01,
  0x0A,
  0x00,
  0x1F,
  0x17,
  0x02,
  0x02,
  0x4F,
  0x94,
  0xCE,
  0xBE,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
]);

Future<ProcessResult> _powershell(String command) async {
  final ProcessResult result = await Process.run(
    'powershell.exe',
    <String>['-NoProfile', '-NonInteractive', '-STA', '-Command', command],
    stdoutEncoding: null,
    stderrEncoding: null,
  );
  expect(
    result.exitCode,
    0,
    reason:
        'clipboard seeding failed: '
        '${utf8.decode((result.stderr as List<int>?) ?? const <int>[], allowMalformed: true)}',
  );
  return result;
}

String _quote(String path) => "'${path.replaceAll("'", "''")}'";

String _encodePowerShell(String script) {
  final List<int> bytes = <int>[];
  for (final int unit in script.codeUnits) {
    bytes.add(unit & 0xFF);
    bytes.add((unit >> 8) & 0xFF);
  }
  return base64Encode(bytes);
}

void main() {
  late Directory root;

  setUpAll(() {
    expect(Platform.isWindows, isTrue);
  });

  setUp(() async {
    root = await Directory.systemTemp.createTemp('bb-dea480-native-');
    await _powershell(
      'Add-Type -AssemblyName System.Windows.Forms; '
      '[System.Windows.Forms.Clipboard]::Clear()',
    );
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test('real Explorer file list becomes ordered draft entries', () async {
    final File ascii = File('${root.path}\\report.pdf');
    await ascii.writeAsBytes(utf8.encode('%PDF-1.4 dea480'));
    final File cjk = File('${root.path}\\报告 一.png');
    await cjk.writeAsBytes(_png);
    await _powershell(
      'Set-Clipboard -Path ${_quote(ascii.path)},${_quote(cjk.path)}',
    );

    final ClipboardPaste paste = await const WindowsClipboardMediaReader()
        .read();

    expect(paste.problems, isEmpty);
    expect(paste.files.map((PickedMedia media) => media.filename), <String>[
      'report.pdf',
      '报告 一.png',
    ]);
    expect(paste.files[0].mimeType, 'application/pdf');
    expect(paste.files[0].bytes, utf8.encode('%PDF-1.4 dea480'));
    expect(paste.files[1].mimeType, 'image/png');
    expect(paste.files[1].bytes, _png);
  });

  test(
    'a copied folder is reported as unsupported, not a decode error',
    () async {
      final Directory folder = Directory('${root.path}\\文件夹 一');
      await folder.create();
      await _powershell('Set-Clipboard -Path ${_quote(folder.path)}');

      final ClipboardPaste paste = await const WindowsClipboardMediaReader()
          .read();

      expect(paste.files, isEmpty);
      expect(paste.problems.single, contains('已跳过文件夹'));
    },
  );

  test('plain text and an empty clipboard stay a text paste', () async {
    await _powershell(
      'Add-Type -AssemblyName System.Windows.Forms; '
      "[System.Windows.Forms.Clipboard]::SetText('hello')",
    );
    ClipboardPaste paste = await const WindowsClipboardMediaReader().read();
    expect(paste.files, isEmpty);
    expect(paste.problems, isEmpty);

    await _powershell(
      'Add-Type -AssemblyName System.Windows.Forms; '
      '[System.Windows.Forms.Clipboard]::Clear()',
    );
    paste = await const WindowsClipboardMediaReader().read();
    expect(paste.files, isEmpty);
    expect(paste.problems, isEmpty);
  });

  test('raw clipboard pixels become a PNG attachment', () async {
    final File image = File('${root.path}\\pixels.png');
    await image.writeAsBytes(_png);
    await _powershell(
      'Add-Type -AssemblyName System.Windows.Forms; '
      'Add-Type -AssemblyName System.Drawing; '
      "\$img = [System.Drawing.Image]::FromFile(${_quote(image.path)}); "
      '[System.Windows.Forms.Clipboard]::SetImage(\$img); '
      r'$img.Dispose()',
    );

    final ClipboardPaste paste = await const WindowsClipboardMediaReader()
        .read();

    expect(paste.problems, isEmpty);
    expect(paste.files, hasLength(1));
    expect(paste.files.single.mimeType, 'image/png');
    expect(paste.files.single.filename, endsWith('.png'));
    // CF_DIB is converted to a fresh PNG by the probe, so compare the PNG
    // signature instead of the source file's exact encoding.
    expect(paste.files.single.bytes.take(8), <int>[
      0x89,
      0x50,
      0x4E,
      0x47,
      0x0D,
      0x0A,
      0x1A,
      0x0A,
    ]);
    expect(paste.files.single.bytes.length, greaterThan(8));
  });

  test(
    'the old strict UTF-8 stderr decode throws the user-visible error, while '
    'the probe now ignores localized CLIXML on a successful run',
    () async {
      // Microsoft's own Set-Clipboard/Add-Type path makes Windows PowerShell
      // serialize a progress record to stderr as CLIXML. On a zh-CN Windows the
      // record text is encoded in the console code page (936); this script
      // reproduces those bytes deterministically on any Windows locale.
      const String script = r'''
$stream = [Console]::OpenStandardError()
$bytes = [byte[]](0xC4, 0xE3)
$stream.Write($bytes, 0, $bytes.Length)
$stream.Flush()
exit 0
''';
      final String encoded = _encodePowerShell(script);
      final List<String> arguments = <String>[
        '-NoProfile',
        '-NonInteractive',
        '-STA',
        '-WindowStyle',
        'Hidden',
        '-EncodedCommand',
        encoded,
      ];

      // The old probe invocation: strict UTF-8 decoding of both streams.
      await expectLater(
        Process.run(
          'powershell.exe',
          arguments,
          stdoutEncoding: utf8,
          stderrEncoding: utf8,
        ),
        throwsA(
          isA<FormatException>().having(
            (FormatException error) => error.message,
            'message',
            'Missing extension byte',
          ),
        ),
      );

      final WindowsClipboardProbeOutcome outcome =
          await runWindowsClipboardProbe(script);
      expect(outcome.ok, isTrue);
      expect(outcome.detail, isEmpty);
    },
  );
}
