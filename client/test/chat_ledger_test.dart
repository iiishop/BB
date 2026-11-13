import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/services/chat_ledger.dart';
import 'package:bb_client/services/chat_service.dart';
import 'package:bb_client/services/media_source.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('bb-ledger-');
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test(
    'operation ledger survives a restart and keeps resolved media ids',
    () async {
      final String path = '${root.path}/ledger.json';
      final ChatLedger first = ChatLedger.atPath(path);
      await first.saveOperation(
        '10000001',
        const ChatOperationRecord(
          operationId: 'op-1',
          kind: 'message',
          targetAccount: '10000002',
          state: 'prepared',
          sourceDigest: 'digest',
          parts: <Map<String, dynamic>>[
            <String, dynamic>{'type': 'text', 'text': 'hi'},
          ],
          resolvedMediaIds: <String>['media-1', 'media-2'],
        ),
      );
      final ChatLedger second = ChatLedger.atPath(path);
      final ChatOperationRecord? record = await second.operation(
        '10000001',
        'op-1',
      );
      expect(record, isNotNull);
      expect(record!.state, 'prepared');
      expect(record.resolvedMediaIds, <String>['media-1', 'media-2']);
      expect(await second.operation('10000009', 'op-1'), isNull);
    },
  );

  test(
    'receipts are stable per binding, confirmed durably and scoped',
    () async {
      final String path = '${root.path}/ledger.json';
      final ChatLedger ledger = ChatLedger.atPath(path);
      final PresentationReceipt first = await ledger.prepareReceipt(
        account: '10000001',
        consumerSession: 's1',
        peerAccount: '10000002',
        messageId: 'm1',
        position: 1,
        contentDigest: 'digest-1',
      );
      final PresentationReceipt again = await ledger.prepareReceipt(
        account: '10000001',
        consumerSession: 's1',
        peerAccount: '10000002',
        messageId: 'm1',
        position: 1,
        contentDigest: 'digest-1',
      );
      expect(again.receiptId, first.receiptId);
      expect(again.confirmed, isFalse);

      final List<String> confirmed = await ledger.confirmReceipts(
        account: '10000001',
        receiptIds: <String>[first.receiptId],
      );
      expect(confirmed, <String>[first.receiptId]);

      final ChatLedger reloaded = ChatLedger.atPath(path);
      final PresentationReceipt? stored = await reloaded.receipt(
        '10000001',
        first.receiptId,
      );
      expect(stored!.confirmed, isTrue);
      expect(await reloaded.receipt('10000002', first.receiptId), isNull);

      final List<PresentationReceipt> peerReceipts = await reloaded
          .receiptsForPeer(
            account: '10000001',
            consumerSession: 's1',
            peerAccount: '10000002',
          );
      expect(peerReceipts, hasLength(1));
      expect(
        await reloaded.receiptsForPeer(
          account: '10000001',
          consumerSession: 's2',
          peerAccount: '10000002',
        ),
        isEmpty,
      );
    },
  );

  test('local events deduplicate by event id and retain cursors', () async {
    final ChatLedger ledger = ChatLedger.atPath('${root.path}/ledger.json');
    final LocalEvent event = LocalEvent(
      eventId: 'server:1',
      account: '10000001',
      consumerSession: 's1',
      type: LocalEventType.messageAvailable,
      peerAccount: '10000002',
      position: 1,
      messageId: 'm1',
    );
    final LocalEventEntry? first = await ledger.appendLocalEvent(
      account: '10000001',
      consumerSession: 's1',
      event: event,
    );
    final LocalEventEntry? duplicate = await ledger.appendLocalEvent(
      account: '10000001',
      consumerSession: 's1',
      event: event,
    );
    expect(first!.cursor, 1);
    expect(duplicate, isNull);
    await ledger.appendLocalEvent(
      account: '10000001',
      consumerSession: 's1',
      event: LocalEvent(
        eventId: 'server:2',
        account: '10000001',
        consumerSession: 's1',
        type: LocalEventType.messageAvailable,
        peerAccount: '10000002',
        position: 2,
        messageId: 'm2',
      ),
    );
    final LocalEventPage page = await ledger.readLocalEvents(
      account: '10000001',
      consumerSession: 's1',
      afterCursor: 0,
    );
    expect(page.items.map((LocalEventEntry e) => e.cursor), <int>[1, 2]);
    expect(page.nextCursor, 2);
    expect(page.hasMore, isFalse);
    final LocalEventPage tail = await ledger.readLocalEvents(
      account: '10000001',
      consumerSession: 's1',
      afterCursor: 1,
    );
    expect(tail.items.single.event.eventId, 'server:2');
  });

  test('consumption is per account, consumer and peer', () async {
    final ChatLedger ledger = ChatLedger.atPath('${root.path}/ledger.json');
    await ledger.setConsumedThrough(
      '10000001',
      '10000002',
      3,
      consumerId: 'c-a',
    );
    await ledger.setConsumedThrough(
      '10000001',
      '10000002',
      2,
      consumerId: 'c-a',
    );
    expect(
      await ledger.consumedThrough(
        '10000001',
        '10000002',
        consumerId: 'c-a',
      ),
      3,
    );
    expect(
      await ledger.consumedThrough(
        '10000001',
        '10000002',
        consumerId: 'c-b',
      ),
      0,
      reason: 'a second consumer never inherits another consumer watermark',
    );
    expect(
      await ledger.consumedThrough(
        '10000001',
        '10000003',
        consumerId: 'c-a',
      ),
      0,
    );
    expect(
      await ledger.consumedThrough(
        '10000009',
        '10000002',
        consumerId: 'c-a',
      ),
      0,
    );
  });

  test('media source resolves bytes/base64/path and sanitizes names', () async {
    final Uint8List png = base64Decode(_png);
    final MediaSourceResolver resolver = MediaSourceResolver();

    final ResolvedMedia fromBytes = await resolver.resolve(
      MediaSource(bytes: png, filename: '../../evil.png'),
    );
    expect(fromBytes.mimeType, 'image/png');
    expect(fromBytes.filename.contains('/'), isFalse);
    expect(fromBytes.bytes, png);

    final ResolvedMedia fromBase64 = await resolver.resolve(
      MediaSource(
        base64: 'data:image/png;base64,${base64Encode(png)}',
        filename: 'clip.png',
      ),
    );
    expect(fromBase64.bytes, png);

    final File file = File('${root.path}/note.pdf');
    await file.writeAsBytes(utf8.encode('%PDF-1.4\nprobe\n%%EOF'));
    final ResolvedMedia fromPath = await resolver.resolve(
      MediaSource(path: file.path),
    );
    expect(fromPath.filename, 'note.pdf');
    expect(fromPath.mimeType, 'application/pdf');

    expect(
      () => resolver.resolve(const MediaSource(path: 'a', base64: 'b')),
      throwsA(isA<Exception>()),
    );
  });

  test('sniffing and filename helpers reject traversal display names', () {
    expect(
      sniffMime(Uint8List.fromList(<int>[0x25, 0x50, 0x44, 0x46])),
      'application/pdf',
    );
    expect(
      sniffMime(
        Uint8List.fromList(<int>[0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70]),
      ),
      'video/mp4',
    );
    expect(sanitizeFilename('../../a/b\\.txt'), isNot(contains('/')));
    expect(sanitizeFilename(''), 'attachment');
  });

  test('generated operation ids satisfy the server pattern', () {
    final RegExp pattern = RegExp(r'^[A-Za-z0-9_-]{1,128}$');
    for (final String prefix in <String>['b', 'a', 'x']) {
      expect(pattern.hasMatch(newOperationId(prefix)), isTrue);
    }
  });
}

const String _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAFElEQVR4nGP8z8Dwn4GBgYGJAQoAHxcCAk+Uzr4AAAAASUVORK5CYII=';
