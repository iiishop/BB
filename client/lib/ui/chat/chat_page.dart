import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../app.dart';
import '../../models/auth_models.dart';
import '../../models/chat_media.dart';
import '../../models/chat_models.dart';
import '../../services/chat_service.dart';
import '../../services/media_stream_proxy.dart';
import '../../services/profile_service.dart';
import '../widgets/profile_avatar.dart';
import 'chat_avatars.dart';
import 'chat_composer.dart';
import 'chat_format.dart';
import 'media_actions.dart';
import 'media_save.dart';
import 'media_viewer.dart';
import 'message_bubble.dart';
import 'pending_send.dart';

/// One-to-one chat with ordered text/image content and independent attachments.
class ChatPage extends StatefulWidget {
  const ChatPage({
    super.key,
    required this.peer,
    required this.chat,
    required this.profile,
    this.openExternalStream,
    this.onMessagesChanged,
    this.saveService,
    this.clipboard = const PlatformClipboardMediaReader(),
    this.coverExtractor = defaultVideoCoverExtractor,
    this.viewerInlineVideoSupported,
  });

  final ChatUser peer;
  final ChatService chat;

  /// Avatar source shared with the Profile surfaces; the chat page never draws
  /// its own initials.
  final ProfileGateway profile;

  /// Injected by tests; production builds the platform save service lazily.
  final MediaSaveService? saveService;

  /// Clipboard/images seam for tests that exercise the real composer.
  final ClipboardMediaReader clipboard;

  /// Product default is the real ffmpeg/platform extractor; the seam lets
  /// widget tests exercise the partial-success window with a synthetic cover.
  final VideoCoverExtractorFn coverExtractor;

  /// Test seam: force the viewer's external-player path on unsupported hosts.
  final bool? viewerInlineVideoSupported;

  /// Test seam for the desktop streaming hand-off. Production uses the
  /// platform opener on the authenticated loopback stream URL.
  final Future<void> Function(Uri uri)? openExternalStream;

  /// Test/inspection seam: emitted after every ordered merge.
  final void Function(List<ChatMessage> messages)? onMessagesChanged;

  static const Key listKey = Key('chat-message-list');
  static const Key errorKey = Key('chat-error');
  static const Key emptyKey = Key('chat-empty');
  static const Key refreshKey = Key('chat-refresh');

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final ScrollController _scrollController = ScrollController();
  final List<ChatMessage> _messages = <ChatMessage>[];
  final Set<String> _busyMedia = <String>{};
  final List<MediaStreamHandle> _streamHandles = <MediaStreamHandle>[];
  final Map<String, Uint8List> _localPreviews = <String, Uint8List>{};
  final List<String> _localPreviewOrder = <String>[];
  String? _localPreviewAccount;
  final ChatComposerController _composerController = ChatComposerController();
  List<PendingSend> _pending = <PendingSend>[];
  final Map<String, String> _operationByMessage = <String, String>{};

  /// Identities that were not on screen at the previous build. Only these get
  /// the entrance animation; history, scroll rebuilds and refresh do not.
  final Set<String> _animateIdentities = <String>{};

  /// Pending operation ids whose one entrance already played. Scrolling an
  /// unfinished bubble out and back in must not replay it.
  final Set<String> _pendingEntered = <String>{};

  /// Self-authored messages read while a send is in flight. They are held
  /// back until the operation settles: content and time cannot prove which
  /// operation a message belongs to, so only the operation record may do it.
  final Map<String, ChatMessage> _heldSelfMessages = <String, ChatMessage>{};

  /// Failed operations currently being verified against `GET /operations`.
  final Set<String> _resolvingOperations = <String>{};

  /// Failed operations the server confirmed as committed. Their local failure
  /// row is hidden because the committed message is the truth.
  final Set<String> _resolvedOperations = <String>{};

  /// Failed operations whose verification could not be completed (transport
  /// or server error). Their send result is unknown, so self messages stay
  /// held and the failure/retry row remains; a later poll retries the lookup.
  final Set<String> _unresolvedOperations = <String>{};
  static const int _maxLocalPreviewEntries = 8;
  static const int _maxLocalPreviewBytes = 24 * 1024 * 1024;
  bool _loading = true;
  String? _error;
  Timer? _pollTimer;
  late final ChatAvatarController _avatars;

  /// Highest contiguous server position whose page has been fetched.
  int _fetchedThrough = 0;

  /// Highest position currently rendered (may be a local send beyond the
  /// fetched window). It must never advance the fetch cursor by itself.
  int _displayedMax = 0;
  bool _fetching = false;

  /// Bumped when the user grabs the list; queued/settling programmatic scrolls
  /// from before that gesture are abandoned instead of fighting the drag.
  int _scrollEpoch = 0;

  String get _consumerSession =>
      'ui:${widget.chat.selfAccount}:${widget.peer.account}';

  late final MediaSaveService _saveService =
      widget.saveService ?? MediaSaveService(chat: widget.chat);

  @override
  void initState() {
    super.initState();
    // Both sides are requested once when the conversation opens. The AppBar and
    // every bubble read this same controller, so scrolling cannot add requests.
    _avatars = ChatAvatarController(
      profile: widget.profile,
      accounts: <String>[widget.chat.selfAccount, widget.peer.account],
    )..addListener(_onAvatarsChanged);
    unawaited(_loadInitial());
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (mounted && !_fetching) {
        unawaited(_pollNew());
      }
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _avatars
      ..removeListener(_onAvatarsChanged)
      ..dispose();
    for (final MediaStreamHandle handle in _streamHandles) {
      unawaited(handle.close());
    }
    _streamHandles.clear();
    _scrollController.dispose();
    super.dispose();
  }

  void _onAvatarsChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _loadInitial() async {
    if (_fetching) {
      return;
    }
    _fetching = true;
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final List<ChatMessage> loaded = <ChatMessage>[];
      int cursor = 0;
      bool hasMore = true;
      int pages = 0;
      // Fetch the complete contiguous history rather than a fixed page cap.
      // A page that makes no progress terminates the loop instead of hiding a
      // gap behind has_more=true.
      while (hasMore && pages < 1000) {
        final MessagePage page = await widget.chat.loadConversation(
          peerAccount: widget.peer.account,
          afterPosition: cursor,
          limit: 100,
        );
        loaded.addAll(page.items);
        final int next = page.nextPosition > cursor
            ? page.nextPosition
            : cursor;
        final bool progressed = page.items.isNotEmpty || next > cursor;
        cursor = next;
        hasMore = page.hasMore && progressed;
        pages += 1;
        if (!progressed) {
          break;
        }
      }
      if (!mounted) {
        return;
      }
      final Set<String> known = _messages
          .map((ChatMessage message) => message.identity)
          .toSet();
      final ({List<ChatMessage> visible, Map<String, ChatMessage> held}) split =
          _splitSelfMessages(loaded, known);
      setState(() {
        _mergeMessages(split.visible);
        _heldSelfMessages.addAll(split.held);
        _fetchedThrough = cursor;
        _loading = false;
        _animateIdentities.clear();
      });
      widget.onMessagesChanged?.call(List<ChatMessage>.unmodifiable(_messages));
      _retryUnresolvedLookups();
      _scrollToBottom(animate: false, force: true);
    } on AuthFailure catch (failure) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _error = failure.message;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _error = '消息加载失败，请稍后重试';
      });
    } finally {
      _fetching = false;
    }
  }

  Future<void> _pollNew() async {
    if (_fetching) {
      return;
    }
    _fetching = true;
    try {
      final List<ChatMessage> loaded = <ChatMessage>[];
      int cursor = _fetchedThrough;
      bool hasMore = true;
      int pages = 0;
      while (hasMore && pages < 1000) {
        final MessagePage page = await widget.chat.loadConversation(
          peerAccount: widget.peer.account,
          afterPosition: cursor,
          limit: 100,
        );
        loaded.addAll(page.items);
        final int next = page.nextPosition > cursor
            ? page.nextPosition
            : cursor;
        final bool progressed = page.items.isNotEmpty || next > cursor;
        cursor = next;
        hasMore = page.hasMore && progressed;
        pages += 1;
        if (!progressed) {
          break;
        }
      }
      if (!mounted) {
        return;
      }
      final bool wasNearBottom = _isNearBottom;
      final Set<String> known = _messages
          .map((ChatMessage message) => message.identity)
          .toSet();
      final ({List<ChatMessage> visible, Map<String, ChatMessage> held}) split =
          _splitSelfMessages(loaded, known);
      final Set<String> arrived = <String>{
        for (final ChatMessage message in split.visible) message.identity,
      };
      setState(() {
        _mergeMessages(split.visible);
        _heldSelfMessages.addAll(split.held);
        // Only a contiguous server read advances the fetch cursor. Local
        // sends in _onSent never touch this value.
        _fetchedThrough = cursor;
        _animateIdentities.addAll(arrived);
      });
      widget.onMessagesChanged?.call(List<ChatMessage>.unmodifiable(_messages));
      _retryUnresolvedLookups();
      if (arrived.isNotEmpty && wasNearBottom) {
        _scrollToBottom(force: true);
      }
    } catch (_) {
      // Polling is best effort; the explicit refresh keeps the error visible.
    } finally {
      _fetching = false;
    }
  }

  String? get _selfAccount {
    try {
      return widget.chat.selfAccount;
    } on AuthFailure {
      return null;
    }
  }

  bool get _hasSendingPending => _pending.any(
    (PendingSend item) => item.state == SendFeedbackState.sending,
  );

  /// A failed send whose authoritative operation lookup is still running is
  /// not settled yet either: the committed message must stay held until that
  /// lookup either binds it or proves it is a different operation.
  bool get _shouldHoldSelfMessages =>
      _hasSendingPending ||
      _resolvingOperations.isNotEmpty ||
      _unresolvedOperations.isNotEmpty;

  /// While a send is in flight, self-authored messages read from history are
  /// held instead of rendered. A local pending row plus the same accepted
  /// message would otherwise show one server fact twice, and comparing text
  /// or timestamps cannot prove operation ownership.
  ({List<ChatMessage> visible, Map<String, ChatMessage> held})
  _splitSelfMessages(Iterable<ChatMessage> incoming, Set<String> known) {
    final List<ChatMessage> visible = <ChatMessage>[];
    final Map<String, ChatMessage> held = <String, ChatMessage>{};
    final String? self = _selfAccount;
    final bool hold = _shouldHoldSelfMessages;
    for (final ChatMessage message in incoming) {
      if (known.contains(message.identity) ||
          _heldSelfMessages.containsKey(message.identity)) {
        continue;
      }
      if (hold && self != null && message.senderAccount == self) {
        held[message.identity] = message;
      } else {
        visible.add(message);
      }
    }
    return (visible: visible, held: held);
  }

  /// Renders held self messages once no send is in flight. Identities already
  /// committed by the send response are skipped, so the same server message
  /// never appears twice.
  void _flushHeldSelfMessages() {
    if (!mounted || _heldSelfMessages.isEmpty) {
      return;
    }
    final Set<String> known = _messages
        .map((ChatMessage message) => message.identity)
        .toSet();
    final List<ChatMessage> visible = <ChatMessage>[
      for (final ChatMessage message in _heldSelfMessages.values)
        if (known.add(message.identity)) message,
    ];
    _heldSelfMessages.clear();
    if (visible.isEmpty) {
      return;
    }
    setState(() {
      _mergeMessages(visible);
      _animateIdentities.addAll(
        visible.map((ChatMessage message) => message.identity),
      );
    });
    widget.onMessagesChanged?.call(List<ChatMessage>.unmodifiable(_messages));
  }

  bool _isFailedPendingLive(String operationId) {
    return _pending.any(
      (PendingSend item) =>
          item.operationId == operationId &&
          item.state == SendFeedbackState.failed,
    );
  }

  void _retryUnresolvedLookups() {
    if (_unresolvedOperations.isEmpty) {
      return;
    }
    for (final String operationId in Set<String>.of(_unresolvedOperations)) {
      if (!_resolvingOperations.contains(operationId) &&
          !_resolvedOperations.contains(operationId)) {
        unawaited(_resolveFailedOperation(operationId));
      }
    }
  }

  /// A client-observed failure is not proof the server rejected the operation.
  /// Only `GET /operations/{id}` can name the committed message for this exact
  /// operation; if it can, the local failure row is replaced by that message.
  Future<void> _resolveFailedOperation(String operationId) async {
    if (_resolvedOperations.contains(operationId) ||
        !_resolvingOperations.add(operationId)) {
      return;
    }
    try {
      final OperationResult? result = await widget.chat.getOperation(
        operationId,
      );
      if (!mounted) {
        return;
      }
      // A lookup from an earlier unresolved phase is stale once the operation
      // has been retried or removed. It must not recreate unknown state or
      // downgrade a definitive commit that already settled.
      if (!_isFailedPendingLive(operationId)) {
        return;
      }
      final ChatMessage? message = result?.message;
      if (result?.status == OperationStatus.succeeded && message != null) {
        setState(() {
          _resolvedOperations.add(operationId);
          _unresolvedOperations.remove(operationId);
          _operationByMessage[message.identity] = operationId;
          _heldSelfMessages.remove(message.identity);
          _mergeMessages(<ChatMessage>[message]);
          _animateIdentities.remove(message.identity);
        });
        widget.onMessagesChanged?.call(
          List<ChatMessage>.unmodifiable(_messages),
        );
        _composerController.forgetCommittedOperation(operationId);
      } else if (result == null || result.status == OperationStatus.failed) {
        // Only a terminal not-found/failed answer means the operation did not
        // commit; any held self message then belongs to another operation.
        setState(() {
          _unresolvedOperations.remove(operationId);
        });
      } else {
        // pending/uncertain (including a temporary remote 404 behind a local
        // uncertain record) is not proof of absence. Keep the message held
        // and retry the operation lookup on later polls.
        if (_isFailedPendingLive(operationId)) {
          setState(() {
            _unresolvedOperations.add(operationId);
          });
        }
      }
    } on AuthFailure {
      // Unknown is not failed: hold accepted self messages and keep retry.
      // A late error for an operation that already settled is ignored.
      if (mounted && _isFailedPendingLive(operationId)) {
        setState(() {
          _unresolvedOperations.add(operationId);
        });
      }
    } catch (_) {
      if (mounted && _isFailedPendingLive(operationId)) {
        setState(() {
          _unresolvedOperations.add(operationId);
        });
      }
    } finally {
      _resolvingOperations.remove(operationId);
      if (!_shouldHoldSelfMessages) {
        _flushHeldSelfMessages();
      }
    }
  }

  /// Merge by stable message identity and keep the displayed order. Existing
  /// local sends are preserved when an in-flight history page arrives.
  void _mergeMessages(Iterable<ChatMessage> incoming) {
    final Map<String, ChatMessage> byIdentity = <String, ChatMessage>{
      for (final ChatMessage message in _messages) message.identity: message,
    };
    for (final ChatMessage message in incoming) {
      byIdentity.putIfAbsent(message.identity, () => message);
    }
    _messages
      ..clear()
      ..addAll(byIdentity.values)
      ..sort(
        (ChatMessage a, ChatMessage b) => a.position.compareTo(b.position),
      );
    _displayedMax = _messages.isEmpty ? 0 : _messages.last.position;
  }

  void _onSent(
    List<ChatMessage> messages,
    Map<String, Uint8List> localPreviews,
  ) {
    _rememberLocalPreviews(localPreviews);
    final Set<String> known = _messages
        .map((ChatMessage message) => message.identity)
        .toSet();
    final List<ChatMessage> added = <ChatMessage>[
      for (final ChatMessage message in messages)
        if (known.add(message.identity)) message,
    ];
    if (added.isEmpty) {
      return;
    }
    final int before = _displayedMax;
    setState(() {
      _mergeMessages(added);
      // The committed bubble keeps the pending element (same operation id) and
      // continues its single entrance. Adding the identities also covers a
      // send that settled before its first frame was painted.
      _animateIdentities.addAll(
        added.map((ChatMessage message) => message.identity),
      );
    });
    widget.onMessagesChanged?.call(List<ChatMessage>.unmodifiable(_messages));
    if (_displayedMax > before) {
      // A settle is not a new user action: follow only when already near the
      // end, so a reader who scrolled up meanwhile is not pulled down.
      _scrollToBottom();
    }
  }

  void _onSentOperations(List<SentOperation> operations) {
    if (!mounted) {
      return;
    }
    setState(() {
      for (final SentOperation operation in operations) {
        _operationByMessage[operation.message.identity] = operation.operationId;
      }
    });
  }

  void _onPendingChanged(List<PendingSend> pending) {
    if (!mounted) {
      return;
    }
    final Map<String, SendFeedbackState> previousState =
        <String, SendFeedbackState>{
          for (final PendingSend item in _pending) item.operationId: item.state,
        };
    final Set<String> live = <String>{
      for (final PendingSend item in pending) item.operationId,
    };
    final Set<String> failedLive = <String>{
      for (final PendingSend item in pending)
        if (item.state == SendFeedbackState.failed) item.operationId,
    };
    final bool startedSend = pending.any(
      (PendingSend item) =>
          item.state == SendFeedbackState.sending &&
          !previousState.containsKey(item.operationId),
    );
    final List<String> newlyFailed = <String>[
      for (final PendingSend item in pending)
        if (item.state == SendFeedbackState.failed &&
            previousState[item.operationId] != SendFeedbackState.failed &&
            !_resolvedOperations.contains(item.operationId))
          item.operationId,
    ];
    setState(() {
      _pending = List<PendingSend>.of(pending);
      _pendingEntered.removeWhere(
        (String operationId) => !live.contains(operationId),
      );
      _resolvedOperations.removeWhere(
        (String operationId) => !live.contains(operationId),
      );
      _unresolvedOperations.removeWhere(
        (String operationId) => !failedLive.contains(operationId),
      );
    });
    if (startedSend) {
      // A new explicit send reveals its bubble immediately; a failed/retrying
      // update does not move a reader who is parked in history. No long
      // animation here, so the user can grab the list without a fight.
      _scrollToBottom(animate: false, force: true);
    }
    if (newlyFailed.isNotEmpty) {
      for (final String operationId in newlyFailed) {
        unawaited(_resolveFailedOperation(operationId));
      }
    } else if (!_shouldHoldSelfMessages) {
      _flushHeldSelfMessages();
    }
  }

  Uint8List? _previewFor(String mediaId) {
    for (final PendingSend pending in _pending) {
      final Uint8List? bytes = pending.imageBytes[mediaId];
      if (bytes != null) {
        return bytes;
      }
    }
    return _localPreviewFor(mediaId);
  }

  /// True when the viewport is close enough to the end that new content may
  /// follow it. A reader parked in history is never pulled down.
  bool get _isNearBottom {
    if (!_scrollController.hasClients) {
      return true;
    }
    final ScrollPosition position = _scrollController.position;
    return position.maxScrollExtent - position.pixels <= 96;
  }

  void _scrollToBottom({bool animate = true, bool force = false}) {
    if (!force && !_isNearBottom) {
      return;
    }
    final int epoch = _scrollEpoch;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _applyBottomScroll(animate: animate, attempt: 0, epoch: epoch);
    });
  }

  bool _onScrollNotification(ScrollNotification notification) {
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _scrollEpoch += 1;
    }
    return false;
  }

  /// The list is lazy, so its reported max extent can grow while scrolling
  /// toward the end. Animate once, then correct any remaining distance with
  /// cheap jumps so a send really lands on its own bubble.
  void _applyBottomScroll({
    required bool animate,
    required int attempt,
    required int epoch,
  }) {
    if (!mounted || !_scrollController.hasClients || epoch != _scrollEpoch) {
      return;
    }
    final ScrollPosition position = _scrollController.position;
    final double target = position.maxScrollExtent;
    final double remaining = target - position.pixels;
    if (remaining.abs() <= 1) {
      return;
    }
    if (animate && attempt == 0) {
      _scrollController
          .animateTo(
            target,
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOutCubic,
          )
          .whenComplete(() {
            if (mounted &&
                _scrollController.hasClients &&
                epoch == _scrollEpoch) {
              _applyBottomScroll(animate: false, attempt: 1, epoch: epoch);
            }
          });
      return;
    }
    if (attempt >= 3) {
      return;
    }
    _scrollController.jumpTo(target);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _applyBottomScroll(animate: false, attempt: attempt + 1, epoch: epoch);
    });
  }

  Future<void> _saveAs(Attachment attachment) async {
    try {
      final String? path = await MediaActions.pickSaveLocation(
        attachment.filename,
      );
      if (path == null) {
        return;
      }
      _setBusy(attachment.mediaId, true);
      final String saved = await widget.chat.saveAs(
        mediaId: attachment.mediaId,
        targetPath: path,
      );
      _snack('已保存到 $saved');
    } on AuthFailure catch (failure) {
      _snack(failure.message);
    } catch (_) {
      _snack('保存失败');
    } finally {
      _setBusy(attachment.mediaId, false);
    }
  }

  Future<void> _download(Attachment attachment) async {
    if (_busyMedia.contains(attachment.mediaId)) {
      return;
    }
    _setBusy(attachment.mediaId, true);
    try {
      final String operationId =
          'ui-dl-${attachment.mediaId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '')}';
      final DownloadTask started = await widget.chat.downloads.start(
        operationId: operationId,
        consumerSession: _consumerSession,
        mediaId: attachment.mediaId,
      );
      final DownloadTask done = await _waitForDownload(started);
      if (done.status == DownloadStatus.succeeded) {
        _snack('已下载到 ${done.actualPath}');
      } else {
        _snack('下载失败（${done.errorCode ?? '未知原因'}）');
      }
    } on AuthFailure catch (failure) {
      _snack(failure.message);
    } catch (_) {
      _snack('下载失败');
    } finally {
      _setBusy(attachment.mediaId, false);
    }
  }

  /// Local bytes are bound to the account that sent them. A different login
  /// cannot reuse them, and the short LRU keeps a burst of large sends bounded.
  void _rememberLocalPreviews(Map<String, Uint8List> previews) {
    if (previews.isEmpty) {
      return;
    }
    final String account;
    try {
      account = widget.chat.selfAccount;
    } on AuthFailure {
      return;
    }
    if (_localPreviewAccount != account) {
      _localPreviews.clear();
      _localPreviewOrder.clear();
      _localPreviewAccount = account;
    }
    previews.forEach((String mediaId, Uint8List bytes) {
      _localPreviews[mediaId] = bytes;
      _localPreviewOrder
        ..remove(mediaId)
        ..add(mediaId);
    });
    int totalBytes = _localPreviews.values.fold<int>(
      0,
      (int sum, Uint8List bytes) => sum + bytes.length,
    );
    while (_localPreviewOrder.length > _maxLocalPreviewEntries ||
        (totalBytes > _maxLocalPreviewBytes && _localPreviewOrder.isNotEmpty)) {
      final String evicted = _localPreviewOrder.removeAt(0);
      final Uint8List? bytes = _localPreviews.remove(evicted);
      if (bytes != null) {
        totalBytes -= bytes.length;
      }
    }
  }

  Uint8List? _localPreviewFor(String mediaId) {
    final String? account = _localPreviewAccount;
    if (account == null) {
      return null;
    }
    try {
      if (widget.chat.selfAccount != account) {
        return null;
      }
    } on AuthFailure {
      return null;
    }
    return _localPreviews[mediaId];
  }

  List<ChatMediaItem> _buildMediaItems() {
    return buildConversationMedia(
      messages: _messages,
      selfAccount: widget.chat.selfAccount,
      selfName: '我',
      peerName: widget.peer.username,
    );
  }

  Future<void> _openMedia(ChatMessage message, int? partIndex) async {
    final List<ChatMediaItem> items = _buildMediaItems();
    final int index = findConversationMediaIndex(
      items,
      messageId: message.id,
      partIndex: partIndex,
    );
    if (index < 0 || !mounted) {
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (BuildContext context) => MediaViewer(
          items: items,
          initialIndex: index,
          chat: widget.chat,
          saveService: _saveService,
          sequenceComplete: _error == null,
          onPlayVideo: _playViewerVideo,
          onReload: _reloadMediaSequence,
          localPreviewFor: _localPreviewFor,
          inlineVideoSupported: widget.viewerInlineVideoSupported,
        ),
      ),
    );
  }

  Future<void> _playViewerVideo(ChatMediaItem item) async {
    final Attachment? attachment = item.message.attachment;
    if (attachment == null) {
      return;
    }
    await _play(attachment);
  }

  Future<({List<ChatMediaItem> items, bool complete})>
  _reloadMediaSequence() async {
    await _loadInitial();
    return (items: _buildMediaItems(), complete: _error == null);
  }

  Future<DownloadTask> _waitForDownload(DownloadTask initial) async {
    DownloadTask task = initial;
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 120));
    while (!task.status.terminal && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final DownloadTask? next = await widget.chat.downloads.get(
        taskId: task.taskId,
        consumerSession: _consumerSession,
      );
      if (next == null) {
        break;
      }
      task = next;
    }
    return task;
  }

  Future<void> _play(Attachment attachment) async {
    if (_busyMedia.contains(attachment.mediaId)) {
      return;
    }
    _setBusy(attachment.mediaId, true);
    MediaStreamHandle? handle;
    try {
      // Opening the stream is the click action. Nothing is requested for the
      // original video before this method runs.
      handle = await widget.chat.openMediaStream(attachment.mediaId);
      _streamHandles.add(handle);
      if (!mounted) {
        return;
      }
      if (attachment.kind == AttachmentKind.video &&
          (Platform.isAndroid || Platform.isIOS)) {
        await showDialog<void>(
          context: context,
          builder: (BuildContext context) => _VideoDialog(
            uri: handle!.uri,
            mediaId: attachment.mediaId,
            onClose: () => _closeStream(handle!),
          ),
        );
      } else {
        await (widget.openExternalStream ?? MediaActions.openUrl)(handle.uri);
        if (!mounted) {
          return;
        }
        final bool? stop = await showDialog<bool>(
          context: context,
          builder: (BuildContext context) => _StreamingDialog(
            kind: attachment.kind,
            filename: attachment.filename,
          ),
        );
        if (stop ?? true) {
          await _closeStream(handle);
        }
      }
    } on AuthFailure catch (failure) {
      _snack(failure.message);
      if (handle != null) {
        await _closeStream(handle);
      }
    } catch (_) {
      _snack('无法打开在线播放流');
      if (handle != null) {
        await _closeStream(handle);
      }
    } finally {
      _setBusy(attachment.mediaId, false);
    }
  }

  Future<void> _closeStream(MediaStreamHandle handle) async {
    _streamHandles.remove(handle);
    await handle.close();
  }

  void _setBusy(String mediaId, bool value) {
    if (!mounted) {
      return;
    }
    setState(() {
      if (value) {
        _busyMedia.add(mediaId);
      } else {
        _busyMedia.remove(mediaId);
      }
    });
  }

  void _snack(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: AppColors.paper,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        surfaceTintColor: AppColors.surface,
        elevation: 0,
        scrolledUnderElevation: 1,
        titleSpacing: 0,
        title: Row(
          children: <Widget>[
            ProfileAvatar(
              bytes: _avatars.bytesFor(widget.peer.account),
              size: 36,
              showBorder: false,
              loading: _avatars.isLoading(widget.peer.account),
              semanticLabel: '${widget.peer.username} 的头像',
            ),
            const SizedBox(width: AppSpacing.sm),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  widget.peer.username,
                  style: text.titleMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  '${widget.peer.account} · '
                  '${widget.peer.presence == Presence.online ? '在线' : '离线'}',
                  style: text.bodySmall?.copyWith(fontSize: 11),
                ),
              ],
            ),
          ],
        ),
        actions: <Widget>[
          IconButton(
            key: ChatPage.refreshKey,
            tooltip: '刷新消息',
            onPressed: _loadInitial,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          Expanded(child: _buildBody()),
          ChatComposer(
            chat: widget.chat,
            peerAccount: widget.peer.account,
            clipboard: widget.clipboard,
            coverExtractor: widget.coverExtractor,
            controller: _composerController,
            onSent: _onSent,
            onSentOperations: _onSentOperations,
            onPendingChanged: _onPendingChanged,
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading && _messages.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _messages.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(
                Icons.chat_bubble_outline_rounded,
                size: 36,
                color: AppColors.inkMuted,
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                _error!,
                key: ChatPage.errorKey,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.inkMuted),
              ),
              const SizedBox(height: AppSpacing.md),
              OutlinedButton(
                onPressed: _loadInitial,
                child: const Text('重新加载'),
              ),
            ],
          ),
        ),
      );
    }
    if (_messages.isEmpty && _pending.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(
              Icons.waving_hand_outlined,
              size: 34,
              color: AppColors.inkMuted,
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              '和 ${widget.peer.username} 还没有消息',
              key: ChatPage.emptyKey,
              style: const TextStyle(color: AppColors.inkMuted),
            ),
          ],
        ),
      );
    }
    final List<_TimelineEntry> entries = <_TimelineEntry>[
      for (final ChatMessage message in _messages)
        _TimelineEntry(
          message: message,
          operationId: _operationByMessage[message.identity],
        ),
      for (final PendingSend pending in _pending)
        if (!_resolvedOperations.contains(pending.operationId))
          _TimelineEntry(
            message: pending.message,
            operationId: pending.operationId,
            pending: pending,
          ),
    ];
    final Map<String, SendFeedbackState> pendingState =
        <String, SendFeedbackState>{
          for (final PendingSend item in _pending) item.operationId: item.state,
        };
    bool sameRun(int left, int right) {
      return continuesMessageRun(
        entries[left].message.senderAccount,
        entries[left].message.createdAt,
        entries[right].message.senderAccount,
        entries[right].message.createdAt,
      );
    }

    final List<Widget> timeline = <Widget>[];
    DateTime? previous;
    for (int index = 0; index < entries.length; index += 1) {
      final _TimelineEntry entry = entries[index];
      final ChatMessage message = entry.message;
      final bool committed = entry.pending == null;
      if (committed) {
        final DateTime local = message.createdAt.toLocal();
        if (shouldShowDaySeparator(previous, message.createdAt)) {
          timeline.add(
            _DaySeparator(
              key: ValueKey<String>(
                'chat-day-${local.year}-${local.month}-${local.day}',
              ),
              label: formatDaySeparator(message.createdAt),
            ),
          );
        } else if (shouldShowGapLabel(previous, message.createdAt)) {
          timeline.add(
            KeyedSubtree(
              key: ValueKey<String>('chat-gap-${message.identity}'),
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                  child: Text(
                    formatClockTime(message.createdAt),
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppColors.inkMuted,
                    ),
                  ),
                ),
              ),
            ),
          );
        }
        previous = message.createdAt;
      }
      final bool runStart = index == 0 || !sameRun(index - 1, index);
      final bool runEnd =
          index == entries.length - 1 || !sameRun(index, index + 1);
      final Attachment? attachment = message.attachment;
      final String bubbleKey = entry.operationId ?? message.identity;
      final bool pendingFirstFrame =
          entry.pending != null && !_pendingEntered.contains(entry.operationId);
      final SendFeedbackState? displayedSendState = entry.pending != null
          ? entry.pending!.state
          : entry.operationId != null &&
                pendingState[entry.operationId] == SendFeedbackState.sending
          ? SendFeedbackState.sending
          : null;
      final Widget bubble = MessageBubble(
        key: ValueKey<String>('chat-bubble-$bubbleKey'),
        message: message,
        selfAccount: widget.chat.selfAccount,
        peerUsername: widget.peer.username,
        chat: widget.chat,
        avatars: _avatars,
        busy:
            committed &&
            attachment != null &&
            _busyMedia.contains(attachment.mediaId),
        sendState: displayedSendState,
        onRetry: entry.pending?.state == SendFeedbackState.failed
            ? () => _composerController.retryFailed(entry.operationId!)
            : null,
        showAvatar: runEnd,
        isRunEnd: runEnd,
        onSaveAs: committed && attachment != null
            ? () => _saveAs(attachment)
            : null,
        onDownload: committed && attachment != null
            ? () => _download(attachment)
            : null,
        onPlay:
            committed &&
                attachment != null &&
                attachment.kind != AttachmentKind.other
            ? () => _play(attachment)
            : null,
        onOpenMedia: committed ? _openMedia : null,
        localMediaPreview: _previewFor,
      );
      timeline.add(
        Padding(
          key: ValueKey<String>('chat-row-$bubbleKey'),
          padding: EdgeInsets.only(top: runStart ? 10 : 2),
          child: MessageEntrance(
            key: ValueKey<String>('chat-entrance-$bubbleKey'),
            animate: entry.pending != null
                ? pendingFirstFrame
                : _animateIdentities.contains(message.identity),
            child: bubble,
          ),
        ),
      );
    }
    final Set<String> consumedIdentities = Set<String>.of(_animateIdentities);
    final Set<String> consumedPending = <String>{
      for (final _TimelineEntry entry in entries)
        if (entry.pending != null &&
            !_pendingEntered.contains(entry.operationId))
          entry.operationId!,
    };
    if (consumedIdentities.isNotEmpty || consumedPending.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _animateIdentities.removeAll(consumedIdentities);
        _pendingEntered.addAll(consumedPending);
      });
    }
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 860),
        child: NotificationListener<ScrollNotification>(
          onNotification: _onScrollNotification,
          child: ListView(
            key: ChatPage.listKey,
            controller: _scrollController,
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.md,
              AppSpacing.md,
              AppSpacing.lg,
            ),
            children: timeline,
          ),
        ),
      ),
    );
  }
}

/// One row in the visible timeline: a committed message or a local pending one.
class _TimelineEntry {
  const _TimelineEntry({required this.message, this.operationId, this.pending});

  final ChatMessage message;
  final String? operationId;
  final PendingSend? pending;
}

class _DaySeparator extends StatelessWidget {
  const _DaySeparator({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          decoration: BoxDecoration(
            color: AppColors.border.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            label,
            style: const TextStyle(fontSize: 11, color: AppColors.inkMuted),
          ),
        ),
      ),
    );
  }
}

class _VideoDialog extends StatefulWidget {
  const _VideoDialog({
    required this.uri,
    required this.mediaId,
    required this.onClose,
  });

  final Uri uri;
  final String mediaId;
  final Future<void> Function() onClose;

  @override
  State<_VideoDialog> createState() => _VideoDialogState();
}

class _VideoDialogState extends State<_VideoDialog> {
  VideoPlayerController? _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    final VideoPlayerController controller = VideoPlayerController.networkUrl(
      widget.uri,
    );
    _controller = controller;
    try {
      await controller.initialize();
      if (!mounted) {
        return;
      }
      await controller.play();
      setState(() {
        _error = null;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = '在线播放初始化失败，请重试';
      });
    }
  }

  Future<void> _retry() async {
    await _controller?.dispose();
    _controller = null;
    setState(() {
      _error = null;
    });
    await _initialize();
  }

  Future<void> _cancel() async {
    await widget.onClose();
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    unawaited(widget.onClose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final VideoPlayerController? controller = _controller;
    return Dialog(
      child: AspectRatio(
        aspectRatio: controller != null && controller.value.isInitialized
            ? controller.value.aspectRatio
            : 16 / 9,
        child: Stack(
          children: <Widget>[
            Positioned.fill(
              child: _error != null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(AppSpacing.lg),
                        child: Text(
                          _error!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: AppColors.inkMuted),
                        ),
                      ),
                    )
                  : controller != null && controller.value.isInitialized
                  ? GestureDetector(
                      onTap: () {
                        if (controller.value.isPlaying) {
                          controller.pause();
                        } else {
                          controller.play();
                        }
                        setState(() {});
                      },
                      child: Stack(
                        alignment: Alignment.center,
                        children: <Widget>[
                          VideoPlayer(controller),
                          if (!controller.value.isPlaying)
                            const Icon(
                              Icons.play_circle_fill,
                              size: 56,
                              color: Colors.white70,
                            ),
                        ],
                      ),
                    )
                  : const Center(child: CircularProgressIndicator()),
            ),
            Positioned(
              top: 4,
              right: 4,
              child: IconButton(
                tooltip: '取消',
                onPressed: _cancel,
                icon: const Icon(Icons.close_rounded),
              ),
            ),
            if (_error != null)
              Positioned(
                bottom: 8,
                left: 8,
                child: TextButton(onPressed: _retry, child: const Text('重试')),
              ),
          ],
        ),
      ),
    );
  }
}

class _StreamingDialog extends StatelessWidget {
  const _StreamingDialog({required this.kind, required this.filename});

  final AttachmentKind kind;
  final String filename;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('在线播放'),
      content: Text(
        kind == AttachmentKind.video
            ? '正在通过本机回环流播放 $filename。视频原始文件不会被预先下载。'
            : '正在使用系统播放器打开 $filename 的在线流。',
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('继续播放'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('停止'),
        ),
      ],
    );
  }
}
