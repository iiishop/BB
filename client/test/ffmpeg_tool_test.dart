import 'package:bb_client/services/ffmpeg_tool.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'Windows package resolves ffmpeg from its own application directory',
    () {
      final String resolved = resolveFfmpegExecutable(
        isWindows: true,
        resolvedExecutable: r'C:\Users\me\BB\bb_client.exe',
        pathSeparator: r'\',
        environmentOverride: '',
        fileExists: (String path) =>
            path == r'C:\Users\me\BB\ffmpeg\ffmpeg.exe',
      );
      expect(resolved, r'C:\Users\me\BB\ffmpeg\ffmpeg.exe');
    },
  );

  test('legacy side-by-side layout is accepted', () {
    final String resolved = resolveFfmpegExecutable(
      isWindows: true,
      resolvedExecutable: r'D:\BB\bb_client.exe',
      pathSeparator: r'\',
      environmentOverride: '',
      fileExists: (String path) => path == r'D:\BB\ffmpeg.exe',
    );
    expect(resolved, r'D:\BB\ffmpeg.exe');
  });

  test('missing bundled tool falls back to PATH for developer builds', () {
    final String resolved = resolveFfmpegExecutable(
      isWindows: true,
      resolvedExecutable:
          r'D:\dev\bb\build\windows\x64\runner\Debug\bb_client.exe',
      pathSeparator: r'\',
      environmentOverride: '',
      fileExists: (String path) => false,
    );
    expect(resolved, 'ffmpeg');
  });

  test(
    'the lookup is anchored to the application, not the current directory',
    () {
      final String resolved = resolveFfmpegExecutable(
        isWindows: true,
        resolvedExecutable: r'C:\Install\BB\bb_client.exe',
        pathSeparator: r'\',
        environmentOverride: '',
        fileExists: (String path) => path == r'C:\Install\BB\ffmpeg\ffmpeg.exe',
      );
      expect(resolved, startsWith(r'C:\Install\BB\'));
    },
  );

  test('non-Windows keeps the system ffmpeg', () {
    final String resolved = resolveFfmpegExecutable(
      isWindows: false,
      environmentOverride: '',
      fileExists: (String path) => true,
    );
    expect(resolved, 'ffmpeg');
  });

  test('explicit environment override wins', () {
    final String resolved = resolveFfmpegExecutable(
      isWindows: true,
      resolvedExecutable: r'C:\Install\BB\bb_client.exe',
      pathSeparator: r'\',
      environmentOverride: r'C:\QA\ffmpeg.exe',
      fileExists: (String path) => false,
    );
    expect(resolved, r'C:\QA\ffmpeg.exe');
  });
}
