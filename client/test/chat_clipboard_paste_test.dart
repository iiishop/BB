import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/services/chat_service.dart';
import 'package:bb_client/services/media_source.dart';
import 'package:bb_client/ui/chat/chat_composer.dart';
import 'package:bb_client/ui/chat/clipboard_paste.dart';
import 'package:bb_client/ui/chat/media_actions.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/chat_keyboard.dart';
import 'support/fake_chat_service.dart';

const AuthUser _self = AuthUser(account: '10000001', username: 'alice');
const String _peer = '10000002';

final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAFElEQVR4nGP8z8Dwn4GBgYGJAQoAHxcCAk+Uzr4AAAAASUVORK5CYII=',
);

class _DeferredClipboard implements ClipboardMediaReader {
  final Completer<ClipboardPaste> pending = Completer<ClipboardPaste>();
  int calls = 0;

  @override
  Future<ClipboardPaste> read() {
    calls += 1;
    return pending.future;
  }

  void complete(ClipboardPaste paste) {
    if (!pending.isCompleted) {
      pending.complete(paste);
    }
  }
}

class _FakePasteClipboard implements ClipboardMediaReader {
  _FakePasteClipboard(this.paste);

  ClipboardPaste paste;
  int calls = 0;

  @override
  Future<ClipboardPaste> read() async {
    calls += 1;
    return paste;
  }
}

Future<FakeChatService> _pumpComposer(
  WidgetTester tester,
  ClipboardMediaReader clipboard, {
  Future<ResolvedMedia?> Function({
    String? path,
    required Uint8List bytes,
    required String filename,
  })?
  coverExtractor,
}) async {
  tester.view.physicalSize = const Size(900, 700);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final FakeChatService chat = FakeChatService(
    self: _self,
    users: const <ChatUser>[],
  );
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ChatComposer(
          chat: chat,
          peerAccount: _peer,
          clipboard: clipboard,
          coverExtractor: coverExtractor ?? defaultVideoCoverExtractor,
          onSent: (List<ChatMessage> _, Map<String, Uint8List> _) {},
        ),
      ),
    ),
  );
  await tester.pump();
  return chat;
}

PickedMedia _media(
  String filename,
  String mime,
  List<int> bytes, {
  String? path,
}) {
  return PickedMedia(
    bytes: Uint8List.fromList(bytes),
    filename: filename,
    mimeType: mime,
    path: path,
  );
}

void main() {
  group('Windows clipboard listing', () {
    test('parses FILE and IMAGE entries in order and ignores junk', () {
      final List<WindowsClipboardEntry> entries = parseWindowsClipboardListing(
        'FILE\tC:\\Users\\me\\a.zip\r\n'
        'IMAGE\tC:\\Temp\\clipboard.png\r\n'
        '\r\n'
        'junk line\r\n'
        'UNKNOWN\tC:\\x\r\n'
        'FILE\t\r\n',
      );
      expect(entries, hasLength(2));
      expect(entries[0].isImage, isFalse);
      expect(entries[0].path, 'C:\\Users\\me\\a.zip');
      expect(entries[1].isImage, isTrue);
      expect(entries[1].path, 'C:\\Temp\\clipboard.png');
    });

    test(
      'probe script reads the file list and image, quoting the output path',
      () {
        final String script = buildWindowsClipboardScript(
          r"C:\Users\O'Brien\Temp\clipboard.txt",
        );
        expect(script, contains('ContainsFileDropList'));
        expect(script, contains('ContainsImage'));
        expect(script, contains(r"C:\Users\O''Brien\Temp\clipboard.txt"));
        expect(script, isNot(contains(r"O'Brien\Temp\clipboard.txt';")));
      },
    );
  });

  group('WindowsClipboardMediaReader', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('bb-windows-clipboard-');
    });

    tearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });

    test(
      'collects arbitrary file types, images and reports skipped entries',
      () async {
        final File pdf = File(
          '${root.path}${Platform.pathSeparator}report.pdf',
        );
        await pdf.writeAsBytes(utf8.encode('%PDF-1.4 test'));
        final File zip = File(
          '${root.path}${Platform.pathSeparator}archive.zip',
        );
        await zip.writeAsBytes(<int>[0x50, 0x4B, 0x03, 0x04, 1, 2, 3]);
        final File audio = File(
          '${root.path}${Platform.pathSeparator}song.mp3',
        );
        await audio.writeAsBytes(<int>[0x49, 0x44, 0x33, 4, 0, 0, 0]);
        final File image = File(
          '${root.path}${Platform.pathSeparator}shot.png',
        );
        await image.writeAsBytes(_png);
        final File empty = File(
          '${root.path}${Platform.pathSeparator}empty.txt',
        );
        await empty.writeAsBytes(const <int>[]);
        final File big = File('${root.path}${Platform.pathSeparator}big.bin');
        final RandomAccessFile handle = await big.open(mode: FileMode.write);
        await handle.truncate(chatMaxUploadBytes + 1);
        await handle.close();
        final Directory folder = Directory(
          '${root.path}${Platform.pathSeparator}some-folder',
        );
        await folder.create();
        final String missing = '${root.path}${Platform.pathSeparator}gone.png';
        final String listing = <String>[
          'FILE\t${pdf.path}',
          'FILE\t${zip.path}',
          'FILE\t${audio.path}',
          'FILE\t${image.path}',
          'FILE\t${empty.path}',
          'FILE\t${big.path}',
          'FILE\t${folder.path}',
          'FILE\t$missing',
        ].join('\n');

        final WindowsClipboardMediaReader reader = WindowsClipboardMediaReader(
          runner: (String script, String outputPath) async {
            await File(outputPath).writeAsString(listing);
            return true;
          },
        );
        final ClipboardPaste paste = await reader.read();

        expect(paste.files.map((PickedMedia media) => media.filename), <String>[
          'report.pdf',
          'archive.zip',
          'song.mp3',
          'shot.png',
        ]);
        expect(paste.files.map((PickedMedia media) => media.mimeType), <String>[
          'application/pdf',
          'application/octet-stream',
          'audio/mpeg',
          'image/png',
        ]);
        expect(paste.files[0].path, pdf.path);
        expect(paste.files[1].path, zip.path);
        expect(paste.problems, hasLength(4));
        expect(paste.problems.join(' '), contains('空文件'));
        expect(paste.problems.join(' '), contains('32 MiB'));
        expect(paste.problems.join(' '), contains('文件夹'));
        expect(paste.problems.join(' '), contains('不可读'));
      },
    );

    test('a raw clipboard image becomes a PNG attachment', () async {
      final File raw = File(
        '${root.path}${Platform.pathSeparator}clipboard.png',
      );
      await raw.writeAsBytes(_png);
      final WindowsClipboardMediaReader reader = WindowsClipboardMediaReader(
        runner: (String script, String outputPath) async {
          await File(outputPath).writeAsString('IMAGE\t${raw.path}');
          return true;
        },
      );

      final ClipboardPaste paste = await reader.read();

      expect(paste.problems, isEmpty);
      expect(paste.files, hasLength(1));
      expect(paste.files.single.mimeType, 'image/png');
      expect(paste.files.single.filename, endsWith('.png'));
      expect(paste.files.single.bytes, _png);
    });

    test(
      'a failed probe is reported instead of silently pasting text',
      () async {
        const WindowsClipboardMediaReader reader = WindowsClipboardMediaReader(
          runner: _failingProbe,
        );

        final ClipboardPaste paste = await reader.read();

        expect(paste.files, isEmpty);
        expect(paste.problems.single, contains('Windows 剪贴板'));
      },
    );
  });

  group('composer Ctrl+V', () {
    testWidgets(
      'pastes many arbitrary files, keeps the body and never auto-sends',
      (WidgetTester tester) async {
        final _FakePasteClipboard clipboard = _FakePasteClipboard(
          ClipboardPaste(
            files: <PickedMedia>[
              _media('报告.pdf', 'application/pdf', utf8.encode('%PDF-1.4 x')),
              _media('archive.zip', 'application/octet-stream', <int>[
                0x50,
                0x4B,
                3,
                4,
              ]),
              _media('song.mp3', 'audio/mpeg', <int>[0x49, 0x44, 0x33, 1]),
            ],
          ),
        );
        final FakeChatService chat = await _pumpComposer(tester, clipboard);
        await tester.enterText(find.byKey(ChatComposer.inputKey), '正文');

        await pasteFromClipboard(tester);

        expect(clipboard.calls, 1);
        expect(chat.sendCalls, 0, reason: 'paste must not auto-send');
        expect(find.text('报告.pdf'), findsOneWidget);
        expect(find.text('archive.zip'), findsOneWidget);
        expect(find.text('song.mp3'), findsOneWidget);
        expect(
          tester
              .widget<TextField>(find.byKey(ChatComposer.inputKey))
              .controller!
              .text,
          '正文',
        );

        await tester.tap(find.byKey(ChatComposer.sendKey));
        await tester.pumpAndSettle();

        expect(chat.sendCalls, 1);
        expect(chat.lastSentBody.whereType<OutgoingText>().single.text, '正文');
        expect(
          chat.lastSentAttachments.map(
            (OutgoingAttachment a) => a.source.filename,
          ),
          <String>['报告.pdf', 'archive.zip', 'song.mp3'],
        );
        expect(
          chat.lastSentAttachments.map(
            (OutgoingAttachment a) => a.source.mimeType,
          ),
          <String>['application/pdf', 'application/octet-stream', 'audio/mpeg'],
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );

    testWidgets('a pasted image enters the ordered body draft', (
      WidgetTester tester,
    ) async {
      final _FakePasteClipboard clipboard = _FakePasteClipboard(
        ClipboardPaste(
          files: <PickedMedia>[_media('screenshot.png', 'image/png', _png)],
        ),
      );
      final FakeChatService chat = await _pumpComposer(tester, clipboard);
      await tester.enterText(find.byKey(ChatComposer.inputKey), '图片前');
      await tester.pump();

      await pasteFromClipboard(tester);

      expect(chat.sendCalls, 0);
      await tester.tap(find.byKey(ChatComposer.sendKey));
      await tester.pumpAndSettle();

      final List<OutgoingPart> body = chat.lastSentBody;
      expect(body.whereType<OutgoingText>().single.text, '图片前');
      expect(body.whereType<OutgoingImage>(), hasLength(1));
      expect(chat.lastSentAttachments, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });

    testWidgets('a pasted video uses the shared cover path', (
      WidgetTester tester,
    ) async {
      final _FakePasteClipboard clipboard = _FakePasteClipboard(
        ClipboardPaste(
          files: <PickedMedia>[
            _media('clip.mp4', 'video/mp4', <int>[
              0,
              0,
              0,
              0x18,
              0x66,
              0x74,
              0x79,
              0x70,
            ]),
          ],
        ),
      );
      String? coverPath;
      final FakeChatService chat = await _pumpComposer(
        tester,
        clipboard,
        coverExtractor:
            ({
              String? path,
              required Uint8List bytes,
              required String filename,
            }) async {
              coverPath = path;
              return ResolvedMedia(
                bytes: _png,
                filename: 'cover.png',
                mimeType: 'image/png',
              );
            },
      );
      await pasteFromClipboard(tester);
      expect(coverPath, isNull, reason: 'bytes-only paste has no real path');

      await tester.tap(find.byKey(ChatComposer.sendKey));
      await tester.pumpAndSettle();
      expect(chat.lastSentAttachments, hasLength(1));
      expect(chat.lastSentAttachments.single.cover, isNotNull);
      expect(chat.lastSentAttachments.single.source.mimeType, 'video/mp4');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });

    testWidgets('one failing video cover does not drop the other files', (
      WidgetTester tester,
    ) async {
      final _FakePasteClipboard clipboard = _FakePasteClipboard(
        ClipboardPaste(
          files: <PickedMedia>[
            _media('notes.pdf', 'application/pdf', utf8.encode('%PDF-1.4')),
            _media('broken.mp4', 'video/mp4', <int>[0, 0, 0, 0x18, 0x66]),
            _media('later.zip', 'application/octet-stream', <int>[0x50, 0x4B]),
          ],
        ),
      );
      final FakeChatService chat = await _pumpComposer(
        tester,
        clipboard,
        coverExtractor:
            ({
              String? path,
              required Uint8List bytes,
              required String filename,
            }) async {
              throw const FormatException('无法从该视频提取封面');
            },
      );

      await pasteFromClipboard(tester);

      expect(find.text('notes.pdf'), findsOneWidget);
      expect(find.text('broken.mp4'), findsNothing);
      expect(find.text('later.zip'), findsOneWidget);
      expect(find.textContaining('无法从该视频提取封面'), findsOneWidget);
      expect(chat.sendCalls, 0);
      await tester.tap(find.byKey(ChatComposer.sendKey));
      await tester.pumpAndSettle();
      expect(
        chat.lastSentAttachments.map(
          (OutgoingAttachment a) => a.source.filename,
        ),
        <String>['notes.pdf', 'later.zip'],
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });

    testWidgets('a video MIME without a video track still attaches', (
      WidgetTester tester,
    ) async {
      final Uint8List bytes = File('test/fixtures/media/audio-only.webm')
          .readAsBytesSync();
      final _FakePasteClipboard clipboard = _FakePasteClipboard(
        ClipboardPaste(
          files: <PickedMedia>[
            PickedMedia(
              bytes: bytes,
              filename: 'voice.webm',
              mimeType: 'video/webm',
            ),
          ],
        ),
      );
      final FakeChatService chat = await _pumpComposer(
        tester,
        clipboard,
        coverExtractor: ({
          String? path,
          required Uint8List bytes,
          required String filename,
        }) async => null,
      );

      await pasteFromClipboard(tester);

      expect(find.textContaining('提取视频封面'), findsNothing);
      expect(find.text('voice.webm'), findsOneWidget);
      await tester.tap(find.byKey(ChatComposer.sendKey));
      await tester.pumpAndSettle();
      expect(chat.lastSentAttachments, hasLength(1));
      expect(
        chat.lastSentAttachments.single.source.mimeType,
        'application/octet-stream',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });

    testWidgets('skipped clipboard entries are visible next to valid files', (
      WidgetTester tester,
    ) async {
      final _FakePasteClipboard clipboard = _FakePasteClipboard(
        ClipboardPaste(
          files: <PickedMedia>[
            _media('ok.pdf', 'application/pdf', utf8.encode('%PDF-1.4')),
          ],
          problems: <String>['已跳过文件夹：照片'],
        ),
      );
      final FakeChatService chat = await _pumpComposer(tester, clipboard);

      await pasteFromClipboard(tester);

      expect(find.text('ok.pdf'), findsOneWidget);
      expect(find.textContaining('已跳过文件夹：照片'), findsOneWidget);
      expect(chat.sendCalls, 0);
    });

    testWidgets(
      'an unreadable-file problem is shown even when nothing pasted',
      (WidgetTester tester) async {
        final _FakePasteClipboard clipboard = _FakePasteClipboard(
          const ClipboardPaste(problems: <String>['已跳过超过 32 MiB 的文件：huge.bin']),
        );
        await _pumpComposer(tester, clipboard);

        await pasteFromClipboard(tester);

        expect(
          find.textContaining('已跳过超过 32 MiB 的文件：huge.bin'),
          findsOneWidget,
        );
      },
    );

    testWidgets('text-only clipboard paste keeps normal editing behaviour', (
      WidgetTester tester,
    ) async {
      final _FakePasteClipboard clipboard = _FakePasteClipboard(
        const ClipboardPaste(),
      );
      final FakeChatService chat = await _pumpComposer(tester, clipboard);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (MethodCall call) async {
          if (call.method == 'Clipboard.getData') {
            return <String, dynamic>{'text': '粘贴的文本'};
          }
          return null;
        },
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        );
      });
      await tester.enterText(find.byKey(ChatComposer.inputKey), 'AB');
      final TextField field = tester.widget<TextField>(
        find.byKey(ChatComposer.inputKey),
      );
      field.controller!.selection = const TextSelection.collapsed(offset: 1);
      await tester.pump();

      await sendPasteShortcut(tester);

      expect(clipboard.calls, 1);
      expect(field.controller!.text, 'A粘贴的文本B');
      expect(chat.sendCalls, 0);
      expect(
        tester
            .widget<TextField>(find.byKey(ChatComposer.inputKey))
            .controller!
            .text,
        'A粘贴的文本B',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });

    testWidgets('a pasted attachment can be removed before sending', (
      WidgetTester tester,
    ) async {
      final _FakePasteClipboard clipboard = _FakePasteClipboard(
        ClipboardPaste(
          files: <PickedMedia>[
            _media('first.bin', 'application/octet-stream', <int>[1, 2, 3]),
            _media('second.pdf', 'application/pdf', utf8.encode('%PDF-1.4')),
          ],
        ),
      );
      final FakeChatService chat = await _pumpComposer(tester, clipboard);

      await pasteFromClipboard(tester);
      expect(find.text('first.bin'), findsOneWidget);
      expect(find.text('second.pdf'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.close).first);
      await tester.pumpAndSettle();
      expect(find.text('first.bin'), findsNothing);

      await tester.tap(find.byKey(ChatComposer.sendKey));
      await tester.pumpAndSettle();
      expect(chat.lastSentAttachments, hasLength(1));
      expect(chat.lastSentAttachments.single.source.filename, 'second.pdf');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  });
  group('async paste safety', () {
    testWidgets('late clipboard keeps edits and coalesces overlapping Ctrl+V', (
      WidgetTester tester,
    ) async {
      final _DeferredClipboard clipboard = _DeferredClipboard();
      final FakeChatService chat = await _pumpComposer(tester, clipboard);
      await tester.enterText(find.byKey(ChatComposer.inputKey), 'before');

      await pasteFromClipboard(tester);
      await sendPasteShortcut(tester);
      await tester.enterText(find.byKey(ChatComposer.inputKey), 'after');
      clipboard.complete(
        ClipboardPaste(files: <PickedMedia>[_binaryAttachment()]),
      );
      await tester.pumpAndSettle();

      expect(clipboard.calls, 1, reason: 'overlapping Ctrl+V coalesces');
      expect(find.text('pending.bin'), findsOneWidget);
      expect(chat.sendCalls, 0, reason: 'late paste must not auto-send');
      await tester.tap(find.byKey(ChatComposer.sendKey));
      await tester.pumpAndSettle();
      expect(chat.sentTexts, <String>['after']);
      expect(chat.lastSentAttachments, hasLength(1));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });

    testWidgets('sending during a clipboard read leaves the late file out', (
      WidgetTester tester,
    ) async {
      final _DeferredClipboard clipboard = _DeferredClipboard();
      final FakeChatService chat = await _pumpComposer(tester, clipboard);
      await tester.enterText(find.byKey(ChatComposer.inputKey), 'first');
      await pasteFromClipboard(tester);
      await tester.tap(find.byKey(ChatComposer.sendKey));
      await tester.pumpAndSettle();
      expect(chat.sendCalls, 1);

      clipboard.complete(
        ClipboardPaste(files: <PickedMedia>[_binaryAttachment()]),
      );
      await tester.pumpAndSettle();
      expect(chat.sendCalls, 1, reason: 'late file must not auto-send');
      expect(find.text('pending.bin'), findsOneWidget);

      await tester.tap(find.byKey(ChatComposer.sendKey));
      await tester.pumpAndSettle();
      expect(chat.sendCalls, 2);
      expect(chat.lastSentAttachments.single.source.filename, 'pending.bin');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });

    testWidgets('late clipboard after disposal neither sends nor throws', (
      WidgetTester tester,
    ) async {
      final _DeferredClipboard clipboard = _DeferredClipboard();
      final FakeChatService chat = await _pumpComposer(tester, clipboard);
      await pasteFromClipboard(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      clipboard.complete(
        ClipboardPaste(files: <PickedMedia>[_binaryAttachment()]),
      );
      await tester.pumpAndSettle();
      expect(chat.sendCalls, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'audio-only WebM from a clipboard file list stays a sendable attachment',
      (WidgetTester tester) async {
        final File file = File('test/fixtures/media/audio-only.webm').absolute;
        expect(file.existsSync(), isTrue);
        final Uint8List bytes = file.readAsBytesSync();
        expect(hasVideoTrackInContainer(bytes), isFalse);
        expect(sniffMime(bytes, 'audio-only.webm'), 'application/octet-stream');
        final WindowsClipboardMediaReader reader = WindowsClipboardMediaReader(
          runner: (String script, String outputPath) async {
            await File(outputPath).writeAsString('FILE\t${file.path}');
            return true;
          },
        );
        final ClipboardPaste? paste = await tester.runAsync(reader.read);
        expect(paste, isNotNull);
        expect(paste!.files, hasLength(1));
        expect(paste.files.single.bytes, bytes);

        final _DeferredClipboard clipboard = _DeferredClipboard();
        final FakeChatService chat = await _pumpComposer(tester, clipboard);
        await pasteFromClipboard(tester);
        clipboard.complete(paste);
        await tester.pumpAndSettle();

        expect(chat.sendCalls, 0, reason: 'paste must not auto-send');
        expect(find.textContaining('提取视频封面'), findsNothing);
        expect(find.text('audio-only.webm'), findsOneWidget);
        await tester.tap(find.byKey(ChatComposer.sendKey));
        await tester.pumpAndSettle();
        expect(chat.sendCalls, 1);
        expect(
          chat.lastSentAttachments.single.source.filename,
          'audio-only.webm',
        );
        expect(
          chat.lastSentAttachments.single.source.mimeType,
          'application/octet-stream',
        );
        expect(chat.lastSentAttachments.single.cover, isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );
  });
}

PickedMedia _binaryAttachment() => PickedMedia(
  bytes: Uint8List.fromList(<int>[1, 2, 3]),
  filename: 'pending.bin',
  mimeType: 'application/octet-stream',
);

Future<bool> _failingProbe(String script, String outputPath) async => false;
