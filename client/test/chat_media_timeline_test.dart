import 'package:bb_client/config/media_policy.dart';
import 'package:bb_client/models/chat_media.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:flutter_test/flutter_test.dart';

const String _self = '10000001';
const String _peer = '10000002';

ChatMessage _message({
  required int position,
  required String sender,
  String status = 'body',
  List<MessagePart> parts = const <MessagePart>[],
  Attachment? attachment,
  DateTime? at,
}) {
  return ChatMessage(
    id: 'm$position',
    position: position,
    senderAccount: sender,
    targetAccount: sender == _self ? _peer : _self,
    createdAt: at ?? DateTime.utc(2026, 11, 14, 10, position),
    kind: status == 'body' ? ChatMessageKind.body : ChatMessageKind.attachment,
    parts: parts,
    attachment: attachment,
  );
}

void main() {
  test('viewer sequence keeps message order and block order', () {
    final List<ChatMessage> messages = <ChatMessage>[
      _message(
        position: 3,
        sender: _peer,
        status: 'attachment',
        attachment: const Attachment(
          mediaId: 'video-3',
          kind: AttachmentKind.video,
          filename: 'clip.mp4',
          mimeType: 'video/mp4',
          byteSize: 4096,
          coverMediaId: 'cover-3',
        ),
      ),
      _message(
        position: 1,
        sender: _peer,
        parts: const <MessagePart>[
          TextPart('第一段'),
          ImagePart('image-1a'),
          TextPart('中间'),
          ImagePart('image-1b'),
        ],
      ),
      _message(
        position: 4,
        sender: _peer,
        status: 'attachment',
        attachment: const Attachment(
          mediaId: 'doc-4',
          kind: AttachmentKind.document,
          filename: 'a.pdf',
          mimeType: 'application/pdf',
          byteSize: 1024,
        ),
      ),
      _message(
        position: 2,
        sender: _self,
        parts: const <MessagePart>[ImagePart('image-2')],
      ),
    ];

    final List<ChatMediaItem> items = buildConversationMedia(
      messages: messages,
      selfAccount: _self,
      selfName: '我',
      peerName: 'bob',
    );

    expect(items.map((ChatMediaItem item) => item.mediaId), <String>[
      'image-1a',
      'image-1b',
      'image-2',
      'video-3',
    ]);
    expect(items[0].partIndex, 1);
    expect(items[1].partIndex, 3);
    expect(items[2].partIndex, 0);
    expect(items[2].senderLabel, '我');
    expect(items[0].senderLabel, 'bob');
    expect(items[3].partIndex, isNull);
    expect(items[3].coverMediaId, 'cover-3');
    expect(items[3].byteSize, 4096);
    expect(items[3].kind, ChatMediaKind.video);
    expect(items.map((ChatMediaItem item) => item.key).toSet().length, 4);
  });

  test('findConversationMediaIndex resolves body image and attachment', () {
    final List<ChatMediaItem> items = buildConversationMedia(
      messages: <ChatMessage>[
        _message(
          position: 1,
          sender: _peer,
          parts: const <MessagePart>[ImagePart('a'), ImagePart('b')],
        ),
        _message(
          position: 2,
          sender: _peer,
          status: 'attachment',
          attachment: const Attachment(
            mediaId: 'video',
            kind: AttachmentKind.video,
            filename: 'v.mp4',
            mimeType: 'video/mp4',
            byteSize: 2048,
            coverMediaId: 'cover',
          ),
        ),
      ],
      selfAccount: _self,
      selfName: '我',
      peerName: 'bob',
    );

    expect(findConversationMediaIndex(items, messageId: 'm1', partIndex: 1), 1);
    expect(
      findConversationMediaIndex(items, messageId: 'm2', partIndex: null),
      2,
    );
    expect(
      findConversationMediaIndex(items, messageId: 'm1', partIndex: 5),
      -1,
    );
  });

  test('the 100 KiB threshold is inclusive and shared', () {
    expect(mediaDirectOriginalMaxBytes, 100 * 1024);
    expect(mediaNeedsExplicitOriginal(100 * 1024), isFalse);
    expect(mediaNeedsExplicitOriginal(100 * 1024 + 1), isTrue);
    expect(mediaNeedsExplicitOriginal(40 * 1024), isFalse);
    expect(mediaNeedsExplicitOriginal(3 * 1024 * 1024), isTrue);
  });
}
