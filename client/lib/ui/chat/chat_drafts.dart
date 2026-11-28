import 'package:flutter/foundation.dart';

import '../../models/chat_models.dart';
import '../../services/chat_service.dart';
import '../../services/group_mention_controller.dart';
import '../../services/install_safety_gate.dart';
import 'pending_send.dart';

/// One unsaved composer part: text or an image kept in insertion order.
@immutable
class ChatDraftPart {
  const ChatDraftPart(
    this.part, {
    this.bytes,
    this.mentionedAccounts = const <String>[],
  });

  final OutgoingPart part;
  final Uint8List? bytes;
  final List<String> mentionedAccounts;
}

/// One unsaved attachment (video / file) with the bytes already prepared.
@immutable
class ChatDraftAttachment {
  const ChatDraftAttachment({
    required this.attachment,
    required this.filename,
    required this.size,
    required this.kind,
    this.coverBytes,
  });

  final OutgoingAttachment attachment;
  final String filename;
  final int size;
  final AttachmentKind kind;
  final Uint8List? coverBytes;
}

/// Unsaved composer content for one conversation.
@immutable
class ChatDraft {
  const ChatDraft({
    this.text = '',
    this.parts = const <ChatDraftPart>[],
    this.attachments = const <ChatDraftAttachment>[],
    this.mentionSpans = const <MentionSpan>[],
    this.pending = const <PendingSend>[],
    this.failed = const <SendOutcome>[],
  });

  final List<PendingSend> pending;
  final List<SendOutcome> failed;
  final String text;
  final List<ChatDraftPart> parts;
  final List<ChatDraftAttachment> attachments;
  final List<MentionSpan> mentionSpans;

  bool get isEmpty =>
      text.isEmpty &&
      parts.isEmpty &&
      attachments.isEmpty &&
      mentionSpans.isEmpty &&
      pending.isEmpty &&
      failed.isEmpty;

  bool get isNotEmpty => !isEmpty;

  String describe() {
    final List<String> items = <String>[];
    if (text.trim().isNotEmpty) {
      items.add('未发送的文字');
    }
    if (parts.isNotEmpty) {
      items.add('未发送的图片');
    }
    if (pending.isNotEmpty || failed.isNotEmpty) items.add('待完成或待重试的发送');
    if (attachments.isNotEmpty) {
      items.add('未发送的附件');
    }
    return items.join('、');
  }
}

/// Process-scoped store for unsaved composer content, keyed by the running
/// [ChatService] so a draft survives route/panel teardown but never leaks into
/// another account/session instance.
///
/// Every write also updates [InstallSafetyGate]: an unsaved draft blocks update
/// installation until it is sent or explicitly cleared. Route disposal only
/// writes the current draft; it never clears it.
class ChatDrafts {
  ChatDrafts._();

  static final ChatDrafts instance = ChatDrafts._();

  final Map<(Object, String?), Map<String, _PeerDraft>> _sessions = {};

  (Object, String?) key(Object session) => session is ChatService
      ? (session, session.session.user?.account)
      : (session, null);

  bool hasSession(Object session) => _sessions.entries.any(
    (e) =>
        identical(e.key.$1, session) &&
        e.value.values.any((p) => p.draft.isNotEmpty),
  );

  ChatDraft? read(Object session, String peer) {
    final _PeerDraft? entry =
        _sessions[session is (Object, String?) ? session : key(session)]?[peer];
    return entry == null || entry.draft.isEmpty ? null : entry.draft;
  }

  void write(Object session, String peer, ChatDraft draft) {
    final Map<String, _PeerDraft> peers =
        _sessions[session is (Object, String?) ? session : key(session)] ??=
            <String, _PeerDraft>{};
    final _PeerDraft entry = peers[peer] ??= _PeerDraft();
    entry.draft = draft;
    InstallSafetyGate.instance.setBlocker(
      entry.owner,
      draft.isEmpty ? null : '聊天草稿尚未处理：${draft.describe()}。发送或清空后再安装更新。',
    );
  }

  void clear(Object session, String peer) {
    final _PeerDraft? entry =
        _sessions[session is (Object, String?) ? session : key(session)]?[peer];
    if (entry == null) {
      return;
    }
    entry.draft = const ChatDraft();
    InstallSafetyGate.instance.setBlocker(entry.owner, null);
  }

  /// Explicit discard/test cleanup only. Service or route disposal must not
  /// call this: teardown is not user consent to lose unsaved data.
  void clearSession(Object session) {
    final Map<String, _PeerDraft>? peers = _sessions.remove(
      session is (Object, String?) ? session : key(session),
    );
    if (peers == null) {
      return;
    }
    for (final _PeerDraft entry in peers.values) {
      entry.draft = const ChatDraft();
      InstallSafetyGate.instance.setBlocker(entry.owner, null);
    }
  }

  /// Clears every session's draft and gate blocker. Tests only.
  @visibleForTesting
  void resetForTest() {
    for (final Map<String, _PeerDraft> peers in _sessions.values) {
      for (final _PeerDraft entry in peers.values) {
        entry.draft = const ChatDraft();
        InstallSafetyGate.instance.setBlocker(entry.owner, null);
      }
    }
    _sessions.clear();
  }
}

class _PeerDraft {
  final _DraftOwner owner = _DraftOwner();
  ChatDraft draft = const ChatDraft();
}

class _DraftOwner {
  @override
  String toString() => 'chat-draft';
}
