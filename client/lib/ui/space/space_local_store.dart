import 'dart:convert';

/// Unsynced Space input that must survive navigation, resize and reconnects
/// but never belong to another account or server.
///
/// Scope key is `baseUri|account`; the store is process-local. It is explicitly
/// "local input only": it never pretends the server saved a draft, and a
/// published draft is removed in the same step that clears its buffer.
class SpaceLocalStore {
  SpaceLocalStore({required this.scopeKey});

  final String scopeKey;

  /// Process-wide instance so closing a compose page or switching between
  /// chat and Space keeps unresolved input. Keys are scoped, so two accounts
  /// on the same process cannot read each other's text.
  static SpaceLocalStore shared({required String scopeKey}) {
    final SpaceLocalStore? existing = _instances[scopeKey];
    if (existing != null) {
      return existing;
    }
    final SpaceLocalStore created = SpaceLocalStore(scopeKey: scopeKey);
    _instances[scopeKey] = created;
    return created;
  }

  static final Map<String, SpaceLocalStore> _instances =
      <String, SpaceLocalStore>{};

  static void resetForTest() => _instances.clear();

  final Map<String, SpaceDraftBuffer> _drafts = <String, SpaceDraftBuffer>{};
  final Map<String, SpaceCommentBuffer> _comments =
      <String, SpaceCommentBuffer>{};

  SpaceDraftBuffer? draft(String draftId) {
    final SpaceDraftBuffer? value = _drafts[_key('draft', draftId)];
    return value?.copy();
  }

  void saveDraft(String draftId, SpaceDraftBuffer buffer) {
    _drafts[_key('draft', draftId)] = buffer.copy();
  }

  void deleteDraft(String draftId) {
    _drafts.remove(_key('draft', draftId));
  }

  SpaceCommentBuffer? comment(String postId) {
    return _comments[_key('comment', postId)]?.copy();
  }

  void saveComment(String postId, SpaceCommentBuffer buffer) {
    final String key = _key('comment', postId);
    if (buffer.text.trim().isEmpty) {
      _comments.remove(key);
    } else {
      _comments[key] = buffer.copy();
    }
  }

  void deleteComment(String postId) {
    _comments.remove(_key('comment', postId));
  }

  String _key(String kind, String id) =>
      jsonEncode(<String>[scopeKey, kind, id]);
}

class SpaceDraftBuffer {
  const SpaceDraftBuffer({
    required this.text,
    required this.imageIds,
    this.serverText,
    this.serverImageIds = const <String>[],
    this.dirty = false,
    this.version,
  });

  final String text;
  final List<String> imageIds;
  final String? serverText;
  final List<String> serverImageIds;
  final bool dirty;
  final int? version;

  SpaceDraftBuffer copy() => SpaceDraftBuffer(
    text: text,
    imageIds: List<String>.of(imageIds),
    serverText: serverText,
    serverImageIds: List<String>.of(serverImageIds),
    dirty: dirty,
    version: version,
  );
}

class SpaceCommentBuffer {
  const SpaceCommentBuffer({required this.text, required this.replyToId});

  final String text;
  final String? replyToId;

  SpaceCommentBuffer copy() =>
      SpaceCommentBuffer(text: text, replyToId: replyToId);
}
