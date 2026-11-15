// TEMPORARY Windows-native diagnostic for DEA-480. Deleted before delivery.
//
// It runs the production Windows clipboard reader on a real Windows runner and
// prints the raw process bytes/exit code, so the failure that the user sees as
// "missing extension byte" can be attributed to a concrete probe error.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/ui/chat/clipboard_paste.dart';
import 'package:bb_client/ui/chat/media_actions.dart';
import 'package:flutter_test/flutter_test.dart';

String _encodePowerShell(String script) {
  final List<int> bytes = <int>[];
  for (final int unit in script.codeUnits) {
    bytes.add(unit & 0xFF);
    bytes.add((unit >> 8) & 0xFF);
  }
  return base64Encode(bytes);
}

String _hex(Object? raw) {
  if (raw is! List<int>) {
    return '<${raw.runtimeType}>';
  }
  return raw.map((int b) => b.toRadixString(16).padLeft(2, '0')).join();
}

String _safe(Object? Function() fn) {
  try {
    return '${fn()}';
  } catch (error) {
    return 'THREW $error';
  }
}

Future<ProcessResult> _ps(String command) {
  return Process.run(
    'powershell.exe',
    <String>[
      '-NoProfile',
      '-NonInteractive',
      '-STA',
      '-Command',
      command,
    ],
    stdoutEncoding: null,
    stderrEncoding: null,
  );
}

void _dumpProcess(String label, ProcessResult result) {
  final List<int> out = (result.stdout as List<int>?) ?? const <int>[];
  final List<int> err = (result.stderr as List<int>?) ?? const <int>[];
  print('DIAG[$label] exit=${result.exitCode}');
  print('DIAG[$label] stdout_hex=${_hex(out)}');
  print('DIAG[$label] stderr_hex=${_hex(err)}');
  print(
    'DIAG[$label] stdout_lenient=${_safe(() => utf8.decode(out, allowMalformed: true))}',
  );
  print(
    'DIAG[$label] stderr_lenient=${_safe(() => utf8.decode(err, allowMalformed: true))}',
  );
  print(
    'DIAG[$label] stderr_strict=${_safe(() => utf8.decode(err))}',
  );
}

Future<void> _probe(String label, String outputPath) async {
  final String script = buildWindowsClipboardScript(outputPath);
  final ProcessResult result = await Process.run(
    'powershell.exe',
    <String>[
      '-NoProfile',
      '-NonInteractive',
      '-STA',
      '-WindowStyle',
      'Hidden',
      '-EncodedCommand',
      _encodePowerShell(script),
    ],
    stdoutEncoding: null,
    stderrEncoding: null,
  );
  _dumpProcess(label, result);
  final File listing = File(outputPath);
  print('DIAG[$label] listing_exists=${listing.existsSync()}');
  if (listing.existsSync()) {
    final Uint8List bytes = await listing.readAsBytes();
    print('DIAG[$label] listing_hex=${_hex(bytes)}');
    print(
      'DIAG[$label] listing_strict=${_safe(() => utf8.decode(bytes))}',
    );
  }
  try {
    final ClipboardPaste paste =
        await const WindowsClipboardMediaReader().read();
    print(
      'DIAG[$label] reader files=${paste.files.map((PickedMedia m) => m.filename).toList()} '
      'problems=${paste.problems}',
    );
  } catch (error, stack) {
    print('DIAG[$label] reader_THREW $error');
    print('DIAG[$label] reader_stack $stack');
  }
}

void main() {
  test('windows clipboard native diagnostic', () async {
    print('DIAG os=${Platform.operatingSystem} version=${Platform.operatingSystemVersion}');
    if (!Platform.isWindows) {
      print('DIAG NOT_WINDOWS');
      return;
    }

    final ProcessResult env = await _ps(
      r'$PSVersionTable.PSVersion.ToString(); '
      r'(Get-Culture).Name; '
      r'(Get-WinSystemLocale).Name; '
      r'[Console]::OutputEncoding.WebName; '
      r'$env:PROCESSOR_ARCHITECTURE',
    );
    _dumpProcess('env', env);

    final Directory temp =
        await Directory.systemTemp.createTemp('bb-clipboard-diag-');
    addTearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    });
    final String sep = Platform.pathSeparator;
    final String outputPath = '${temp.path}${sep}clipboard.txt';

    // 1. Clear the clipboard.
    _dumpProcess('clear', await _ps(
      'Add-Type -AssemblyName System.Windows.Forms; '
      '[System.Windows.Forms.Clipboard]::Clear()',
    ));
    await _probe('empty', outputPath);

    // 2. Plain text.
    _dumpProcess('text_set', await _ps(
      "Add-Type -AssemblyName System.Windows.Forms; "
      "[System.Windows.Forms.Clipboard]::SetText('hello')",
    ));
    await _probe('text', outputPath);

    // 3. One ASCII file through a real CF_HDROP file drop list.
    final File ascii = File('${temp.path}${sep}report.pdf');
    await ascii.writeAsBytes(utf8.encode('%PDF-1.4 dea480'));
    _dumpProcess('ascii_set', await _ps(
      'Set-Clipboard -Path '
      "'${ascii.path.replaceAll("'", "''")}'",
    ));
    await _probe('ascii_file', outputPath);

    // 4. Chinese and space in the file name.
    final File cjk = File('${temp.path}${sep}报告 一.pdf');
    await cjk.writeAsBytes(utf8.encode('%PDF-1.4 dea480 cjk'));
    _dumpProcess('cjk_set', await _ps(
      'Set-Clipboard -Path '
      "'${cjk.path.replaceAll("'", "''")}'",
    ));
    await _probe('cjk_file', outputPath);

    // 5. A directory.
    final Directory folder = Directory('${temp.path}${sep}文件夹 一');
    await folder.create();
    _dumpProcess('folder_set', await _ps(
      'Set-Clipboard -Path '
      "'${folder.path.replaceAll("'", "''")}'",
    ));
    await _probe('folder', outputPath);

    // 6. Raw pixels: a real image is placed on the clipboard as CF_DIB.
    final File image = File('${temp.path}${sep}shot.png');
    await image.writeAsBytes(base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAFElEQVR4nGP8z8Dwn4GBgYGJAQoAHxcCAk+Uzr4AAAAASUVORK5CYII=',
    ));
    _dumpProcess('image_set', await _ps(
      'Add-Type -AssemblyName System.Windows.Forms; '
      'Add-Type -AssemblyName System.Drawing; '
      "\$img = [System.Drawing.Image]::FromFile('${image.path.replaceAll("'", "''")}'); "
      '[System.Windows.Forms.Clipboard]::SetImage(\$img); '
      r'$img.Dispose()',
    ));
    await _probe('image', outputPath);
  }, timeout: const Timeout(Duration(minutes: 8)));
}
