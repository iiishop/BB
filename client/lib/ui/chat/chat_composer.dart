import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../app.dart';
import '../../models/auth_models.dart';
import '../../models/chat_models.dart';
import '../../models/group_models.dart';
import '../../models/mention_models.dart';
import '../../services/chat_service.dart';
import '../../services/group_mention_controller.dart';
import '../../services/group_service.dart';
import '../../services/install_safety_gate.dart';
import '../../services/media_source.dart';
import '../../services/profile_service.dart';
import 'chat_format.dart';
import 'clipboard_paste.dart';
import 'media_actions.dart';
import 'chat_drafts.dart';
import 'mention_widgets.dart';
import 'pending_send.dart';

/// Lets the chat page retry one failed item from its bubble.
///
/// The composer still owns the operation plan so a retry reuses the exact same
/// operation id and cannot double-send.
class ChatComposerController {
  _ChatComposerState? _state;

  void _attach(_ChatComposerState state) {
    _state = state;
  }

  void _detach(_ChatComposerState state) {
    if (identical(_state, state)) {
      _state = null;
    }
  }

  bool get canRetry => _state?._failed.isNotEmpty ?? false;

  Future<void> retryFailed(String operationId) async {
    final _ChatComposerState? state = _state;
    if (state == null || !state.mounted) {
      return;
    }
    await state._retryOne(operationId);
  }

  /// The server operation was verified as committed; the local failure entry
  /// and its retry affordance must disappear.
  void forgetCommittedOperation(String operationId) {
    _state?._forgetCommittedOperation(operationId);
  }
}

/// Ordered composer: text and images keep their insertion order; videos,
/// PDFs and other files are independent attachment messages.
class ChatComposer extends StatefulWidget {
  const ChatComposer({
    super.key,
    required this.chat,
    required this.peerAccount,
    required this.onSent,
    this.onSentOperations,
    this.onPendingChanged,
    this.controller,
    this.enabled = true,
    this.clipboard = const PlatformClipboardMediaReader(),
    this.coverExtractor = defaultVideoCoverExtractor,
    this.conversation,
    this.shared,
    this.groups,
    this.profile,
    this.draftKey,
  });

  final ChatService chat;
  final String peerAccount;
  final ConversationRef? conversation;
  final SharedConversationService? shared;
  final GroupService? groups;
  final ProfileGateway? profile;
  final String? draftKey;

  /// Successful messages plus the local bytes already held for body images,
  /// keyed by the committed media id.
  final void Function(
    List<ChatMessage> messages,
    Map<String, Uint8List> localPreviews,
  )
  onSent;

  /// Successful operations paired with the committed messages, so the chat
  /// page can keep one bubble element from "sending" to "sent".
  final void Function(List<SentOperation> operations)? onSentOperations;

  /// Snapshot of local bubbles that have not settled yet (sending or failed).
  final void Function(List<PendingSend> pending)? onPendingChanged;

  final ChatComposerController? controller;
  final bool enabled;
  final ClipboardMediaReader clipboard;

  /// Product default is the real ffmpeg/platform extractor; the seam lets
  /// widget tests observe the picked path/bytes without replacing the UI flow.
  final VideoCoverExtractorFn coverExtractor;

  static const Key inputKey = Key('chat-composer-input');
  static const Key sendKey = Key('chat-composer-send');
  static const Key imageKey = Key('chat-composer-image');
  static const Key fileKey = Key('chat-composer-file');

  /// The round "+" that collects the existing image/attachment entries.
  static const Key attachMenuKey = Key('chat-composer-attach');
  static const Key attachSheetKey = Key('chat-composer-attach-sheet');

  /// Blocks editing while an update install transaction is admitted.
  static const Key safetyGateKey = Key('chat-composer-safety-gate');

  @override
  State<ChatComposer> createState() => _ChatComposerState();
}

class _ChatComposerState extends State<ChatComposer> {
  late final _MentionTextEditingController _controller =
      _MentionTextEditingController(
        mentionsProvider: () => _mentionController,
        isGroupProvider: () => _isGroup,
      );
  final FocusNode _focus = FocusNode();
  final GroupMentionComposerController _mentionController =
      GroupMentionComposerController();
  final OverlayPortalController _pickerOverlay = OverlayPortalController();
  final LayerLink _pickerLink = LayerLink();
  final Object _mentionTapGroup = Object();
  final List<ChatDraftPart> _parts = <ChatDraftPart>[];
  final List<ChatDraftAttachment> _attachments = <ChatDraftAttachment>[];
  final List<String> _stagedMentionedAccounts = <String>[];
  List<SendOutcome> _failed = <SendOutcome>[];
  final List<PendingSend> _pending = <PendingSend>[];
  bool _pasting = false;
  bool _hadText = false;
  late final Object _draftSession;
  final Set<String> _ownedOperations = <String>{};
  TextEditingValue _lastControllerValue = TextEditingValue.empty;
  bool _applyingMentionSelection = false;
  bool _mobileSheetOpen = false;
  bool _wasPickerOpen = false;
  int _totalGroupMemberCount = 0;
  int _membersTicket = 0;
  bool _membersLoaded = false;
  StreamSubscription<GroupProfile>? _groupUpdatesSub;

  bool get _isGroup =>
      widget.conversation?.isGroup == true && widget.shared != null;

  bool get _useDesktopInlinePicker {
    if (!_isDesktop || !mounted) {
      return false;
    }
    return MediaQuery.sizeOf(context).width >= 600;
  }

  bool get _isDesktopMentionPickerOpen =>
      _isGroup && _mentionController.pickerOpen && _useDesktopInlinePicker;

  String get _draftAccount =>
      widget.draftKey ?? widget.conversation?.id ?? widget.peerAccount;

  @override
  void initState() {
    super.initState();
    _draftSession = ChatDrafts.instance.key(widget.chat);
    _focus.onKeyEvent = _onKeyEvent;
    widget.controller?._attach(this);
    _mentionController.addListener(_onMentionStateChanged);
    final ChatDraft? stored = ChatDrafts.instance.read(
      _draftSession,
      _draftAccount,
    );
    if (stored != null) {
      _controller.text = stored.text;
      _hadText = _controller.text.trim().isNotEmpty;
      _parts.addAll(stored.parts);
      _attachments.addAll(stored.attachments);
      _pending.addAll(stored.pending);
      _failed.addAll(stored.failed);
      _ownedOperations.addAll(_pending.map((p) => p.operationId));
      _mentionController.restore(
        value: _controller.value,
        spans: stored.mentionSpans,
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _emitPending();
      });
    }
    _lastControllerValue = _controller.value;
    _controller.addListener(_onControllerChanged);
    InstallSafetyGate.instance.addListener(_onSafetyGateChanged);
    _subscribeGroupMemberUpdates();
  }

  @override
  void didUpdateWidget(covariant ChatComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller?._detach(this);
      widget.controller?._attach(this);
    }
    if (oldWidget.conversation != widget.conversation ||
        oldWidget.groups != widget.groups) {
      _membersLoaded = false;
      _totalGroupMemberCount = 0;
      _mentionController.setMembers(const <GroupMember>[]);
      _subscribeGroupMemberUpdates();
      if (!_isGroup) {
        _mentionController.clear();
      }
    }
  }

  @override
  void dispose() {
    _focus.onKeyEvent = null;
    widget.controller?._detach(this);
    InstallSafetyGate.instance.removeListener(_onSafetyGateChanged);
    _mentionController.removeListener(_onMentionStateChanged);
    unawaited(_groupUpdatesSub?.cancel());
    _groupUpdatesSub = null;
    // Route teardown keeps unsaved content: the draft store keeps the text and
    // staged media and the safety gate stays blocked until it is sent or
    // explicitly cleared. Never clear here just to leave the page.
    _persistDraft();
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
    _mentionController.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _subscribeGroupMemberUpdates() {
    unawaited(_groupUpdatesSub?.cancel());
    _groupUpdatesSub = null;
    if (!_isGroup || widget.groups == null) {
      return;
    }
    _groupUpdatesSub = widget.groups!.groupUpdates.listen((
      GroupProfile profile,
    ) {
      if (mounted &&
          (_membersLoaded || _mentionController.pickerOpen) &&
          widget.conversation != null &&
          profile.conversation.id == widget.conversation!.id) {
        unawaited(_loadGroupMembers());
      }
    });
  }

  Future<void> _loadGroupMembers() async {
    final GroupService? groups = widget.groups;
    final ConversationRef? conv = widget.conversation;
    if (!_isGroup || groups == null || conv == null) {
      return;
    }
    final int ticket = ++_membersTicket;
    final String selfAccount = widget.chat.selfAccount;
    final List<GroupMember> allMembers = <GroupMember>[];
    String? afterAccount;
    int? totalCount;
    try {
      while (true) {
        final GroupMemberPage page = await groups.listGroupMembers(
          conversation: conv,
          afterAccount: afterAccount ?? '',
          limit: 100,
          includeCounts: totalCount == null,
        );
        if (!mounted ||
            ticket != _membersTicket ||
            widget.conversation?.id != conv.id) {
          return;
        }
        totalCount ??= page.counts?.total;
        allMembers.addAll(page.items);
        final String? next = page.nextCursor;
        if (next == null || next == afterAccount) {
          break;
        }
        afterAccount = next;
      }
      final List<GroupMember> others = <GroupMember>[
        for (final GroupMember m in allMembers)
          if (m.account != selfAccount) m,
      ];
      _totalGroupMemberCount = totalCount ?? allMembers.length;
      _membersLoaded = true;
      _mentionController.setMembers(others);
    } catch (_) {
      // Keep any previously loaded member list cleanly without crashing input.
    }
  }

  void _onControllerChanged() {
    final TextEditingValue current = _controller.value;
    final TextEditingValue previous = _lastControllerValue;
    _lastControllerValue = current;
    if (_isGroup && !_applyingMentionSelection && !current.composing.isValid) {
      _mentionController.handleTextValueChanged(previous, current);
    }
    _persistDraft();
  }

  void _onMentionStateChanged() {
    if (!mounted) {
      return;
    }
    final bool nowOpen = _mentionController.pickerOpen;
    final bool opened = nowOpen && !_wasPickerOpen;
    _wasPickerOpen = nowOpen;
    if (opened && _isGroup && _mentionController.members.isEmpty) {
      unawaited(_loadGroupMembers());
    }
    _syncMentionOverlayAndSheet(opened: opened);
    setState(() {});
  }

  void _syncMentionOverlayAndSheet({required bool opened}) {
    if (!mounted) {
      return;
    }
    if (!_isGroup || !_mentionController.pickerOpen) {
      if (_pickerOverlay.isShowing) {
        _pickerOverlay.hide();
      }
      return;
    }
    if (_useDesktopInlinePicker) {
      if (!_pickerOverlay.isShowing && Overlay.maybeOf(context) != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted &&
              _isGroup &&
              _mentionController.pickerOpen &&
              _useDesktopInlinePicker &&
              !_pickerOverlay.isShowing &&
              Overlay.maybeOf(context) != null) {
            _pickerOverlay.show();
          }
        });
      }
      return;
    }
    if (_pickerOverlay.isShowing) {
      _pickerOverlay.hide();
    }
    if (opened && !_mobileSheetOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            _isGroup &&
            _mentionController.pickerOpen &&
            !_useDesktopInlinePicker &&
            !_mobileSheetOpen) {
          unawaited(_openMobileMentionSheet());
        }
      });
    }
  }

  Future<void> _openMobileMentionSheet() async {
    if (_mobileSheetOpen || !mounted || !_isGroup) {
      return;
    }
    _mobileSheetOpen = true;
    try {
      final GroupMember? picked = await showMentionMemberSheet(
        context: context,
        mentionController: _mentionController,
        totalGroupMemberCount: () => _totalGroupMemberCount > 0
            ? _totalGroupMemberCount
            : _mentionController.members.length + 1,
        initialQuery: _mentionController.activeQuery?.query ?? '',
        profile: widget.profile,
      );
      if (!mounted) {
        return;
      }
      if (picked != null) {
        _selectMentionMember(picked);
      } else {
        _mentionController.dismissPicker();
        _focus.requestFocus();
      }
    } finally {
      _mobileSheetOpen = false;
    }
  }

  void _selectMentionMember(GroupMember member) {
    _applyingMentionSelection = true;
    try {
      final TextEditingValue nextValue = _mentionController.selectMember(
        member,
        _controller.value,
      );
      _controller.value = nextValue;
      _lastControllerValue = nextValue;
    } finally {
      _applyingMentionSelection = false;
    }
    _persistDraft();
    _focus.requestFocus();
  }

  void _persistDraft() {
    final bool hasText = _controller.text.trim().isNotEmpty;
    if (mounted && hasText != _hadText) {
      _hadText = hasText;
      // The send affordance follows "is there anything sendable" without a
      // separate text editing callback.
      setState(() {});
    }
    final stored = !mounted
        ? ChatDrafts.instance.read(_draftSession, _draftAccount)
        : null;
    ChatDrafts.instance.write(
      _draftSession,
      _draftAccount,
      ChatDraft(
        text: stored?.text ?? _controller.text,
        parts: stored?.parts ?? List<ChatDraftPart>.of(_parts),
        attachments:
            stored?.attachments ?? List<ChatDraftAttachment>.of(_attachments),
        mentionSpans:
            stored?.mentionSpans ??
            List<MentionSpan>.of(_mentionController.spans),
        pending: [
          if (stored != null)
            ...stored.pending.where(
              (p) => !_ownedOperations.contains(p.operationId),
            ),
          ..._pending,
        ],
        failed: [
          if (stored != null)
            ...stored.failed.where(
              (p) => !_ownedOperations.contains(p.operationId),
            ),
          ..._failed,
        ],
      ),
    );
  }

  void _change(VoidCallback action) {
    if (mounted) {
      setState(action);
    } else {
      action();
    }
  }

  void _onSafetyGateChanged() {
    if (!mounted ||
        SchedulerBinding.instance.schedulerPhase ==
            SchedulerPhase.persistentCallbacks) {
      // The gate can change while the tree is locked (route teardown persisting
      // the draft); no rebuild is needed in that phase.
      return;
    }
    _change(() {});
  }

  /// The round "+" menu: the same two entries the bar used to show.
  Future<void> _openAttachSheet() async {
    final BuildContext context = this.context;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (BuildContext sheetContext) => SafeArea(
        key: ChatComposer.attachSheetKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              key: ChatComposer.imageKey,
              leading: const Icon(Icons.image_outlined),
              title: const Text('图片'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                unawaited(_addImage());
              },
            ),
            ListTile(
              key: ChatComposer.fileKey,
              leading: const Icon(Icons.attach_file_rounded),
              title: const Text('附件'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                unawaited(_addFile());
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _addImage() =>
      InstallSafetyGate.instance.protect(_addImagePrepared);

  Future<void> _addImagePrepared() async {
    try {
      final PickedMedia? picked = await MediaActions.pick(MediaPickKind.image);
      if (picked == null || !mounted) {
        return;
      }
      _addBodyImage(picked);
    } on FormatException catch (error) {
      _snack(error.message);
    } catch (_) {
      _snack('选择图片失败');
    }
  }

  Future<void> _addFile() =>
      InstallSafetyGate.instance.protect(_addFilePrepared);

  Future<void> _addFilePrepared() async {
    try {
      final PickedMedia? picked = await MediaActions.pick(MediaPickKind.file);
      if (picked == null || !mounted) {
        return;
      }
      if (picked.mimeType.startsWith('image/')) {
        _addBodyImage(picked);
        return;
      }
      final String? problem = await _addAttachment(picked);
      if (problem != null && mounted) {
        _snack(problem);
      }
    } on FormatException catch (error) {
      _snack(error.message);
    } catch (_) {
      _snack('选择文件失败');
    }
  }

  Future<String?> _addAttachment(PickedMedia picked) async {
    AttachmentKind kind = attachmentKindForMime(picked.mimeType);
    String mimeType = picked.mimeType;
    ResolvedMedia? cover;
    if (kind == AttachmentKind.video) {
      cover = await widget.coverExtractor(
        path: picked.path,
        bytes: picked.bytes,
        filename: picked.filename,
      );
      if (cover == null) {
        // A MIME that claims video but carries no video track (audio-only
        // webm/mp4) must stay sendable as the contract's generic file, not be
        // blocked by the server's video-cover requirement.
        if (hasVideoTrackInContainer(picked.bytes) == false) {
          kind = AttachmentKind.other;
          mimeType = 'application/octet-stream';
        } else {
          return _isDesktop
              ? '无法从 ${picked.filename} 提取视频封面（未找到可用的 ffmpeg）'
              : '无法从 ${picked.filename} 提取视频封面';
        }
      }
    }
    if (!mounted) {
      return null;
    }
    _change(() {
      _attachments.add(
        ChatDraftAttachment(
          attachment: OutgoingAttachment(
            source: MediaSource(
              bytes: picked.bytes,
              filename: picked.filename,
              mimeType: mimeType,
            ),
            cover: cover == null
                ? null
                : MediaSource(
                    bytes: cover.bytes,
                    filename: cover.filename,
                    mimeType: cover.mimeType,
                  ),
          ),
          filename: picked.filename,
          size: picked.bytes.length,
          kind: kind,
          coverBytes: cover?.bytes,
        ),
      );
    });
    _persistDraft();
    return null;
  }

  void _addBodyImage(PickedMedia picked) {
    _commitCurrentText();
    _change(() {
      _parts.add(
        ChatDraftPart(
          OutgoingImage(
            MediaSource(
              bytes: picked.bytes,
              filename: picked.filename,
              mimeType: picked.mimeType,
            ),
          ),
          bytes: picked.bytes,
        ),
      );
    });
    _persistDraft();
  }

  Future<void> _pasteFromClipboard() =>
      InstallSafetyGate.instance.protect(_pasteFromClipboardPrepared);

  Future<void> _pasteFromClipboardPrepared() async {
    if (!widget.enabled || _pasting) {
      return;
    }
    _pasting = true;
    try {
      final ClipboardPaste paste = await widget.clipboard.read();
      if (!mounted) {
        return;
      }
      final List<String> problems = List<String>.of(paste.problems);
      if (paste.files.isEmpty) {
        if (problems.isEmpty) {
          await _pasteText();
        }
      } else {
        for (final PickedMedia picked in paste.files) {
          // One bad file must not drop the rest of the same paste.
          try {
            final String? problem = await _addPasted(picked);
            if (problem != null) {
              problems.add(problem);
            }
          } on FormatException catch (error) {
            problems.add(error.message);
          } catch (_) {
            problems.add('已跳过 ${picked.filename}：添加失败');
          }
        }
      }
      if (!mounted) {
        return;
      }
      _reportPasteProblems(problems);
    } on FormatException catch (error) {
      _snack(error.message);
    } catch (_) {
      _snack('读取剪贴板失败');
    } finally {
      _pasting = false;
    }
  }

  /// One pasted file: images keep their place in the ordered body; videos and
  /// every other file type go through the same attachment preparation as the
  /// file picker. The returned problem is shown to the user, never swallowed.
  Future<String?> _addPasted(PickedMedia picked) async {
    if (picked.bytes.isEmpty) {
      return '已跳过空文件：${picked.filename}';
    }
    if (picked.bytes.length > chatMaxUploadBytes) {
      return '已跳过超过 32 MiB 的文件：${picked.filename}';
    }
    if (picked.mimeType.startsWith('image/')) {
      _addBodyImage(picked);
      return null;
    }
    return _addAttachment(picked);
  }

  /// Plain text pastes through the editor, preserving the current selection.
  Future<void> _pasteText() =>
      InstallSafetyGate.instance.protect(_pasteTextPrepared);

  Future<void> _pasteTextPrepared() async {
    final ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
    final String? text = data?.text;
    if (!mounted || text == null || text.isEmpty) {
      return;
    }
    _insertAtSelection(text);
  }

  void _insertAtSelection(String text) {
    final TextEditingValue value = _controller.value;
    final TextSelection selection = value.selection;
    final int start = selection.isValid ? selection.start : value.text.length;
    final int end = selection.isValid ? selection.end : value.text.length;
    _controller.value = TextEditingValue(
      text: value.text.replaceRange(start, end, text),
      selection: TextSelection.collapsed(offset: start + text.length),
    );
  }

  void _reportPasteProblems(List<String> problems) {
    if (problems.isEmpty) {
      return;
    }
    _snack(problems.join('；'));
  }

  /// Enter sends; Ctrl+Enter inserts a newline; the IME owns Enter while a
  /// composition is active; held keys never submit twice.
  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) {
      return KeyEventResult.ignored;
    }
    final HardwareKeyboard keyboard = HardwareKeyboard.instance;
    final LogicalKeyboardKey key = event.logicalKey;
    final bool control = keyboard.isControlPressed;
    final bool alt = keyboard.isAltPressed;
    final bool meta = keyboard.isMetaPressed;
    if (event is KeyRepeatEvent) {
      if (_isDesktopMentionPickerOpen && !_controller.value.composing.isValid) {
        if (key == LogicalKeyboardKey.arrowDown) {
          _mentionController.moveHighlightDown();
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.arrowUp) {
          _mentionController.moveHighlightUp();
          return KeyEventResult.handled;
        }
      }
      final bool isSendKey =
          key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.numpadEnter;
      final bool isPasteKey = key == LogicalKeyboardKey.keyV && control;
      return isSendKey || isPasteKey
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }
    if (_isDesktopMentionPickerOpen && !_controller.value.composing.isValid) {
      if (key == LogicalKeyboardKey.arrowDown) {
        _mentionController.moveHighlightDown();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowUp) {
        _mentionController.moveHighlightUp();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.escape) {
        _mentionController.dismissPicker();
        return KeyEventResult.handled;
      }
      if ((key == LogicalKeyboardKey.enter ||
              key == LogicalKeyboardKey.numpadEnter) &&
          !control &&
          !alt &&
          !meta &&
          !keyboard.isShiftPressed) {
        final GroupMember? hit = _mentionController.highlightedCandidate;
        if (hit != null) {
          _selectMentionMember(hit);
        }
        return KeyEventResult.handled;
      }
    }
    if (key == LogicalKeyboardKey.keyV &&
        control &&
        !alt &&
        !meta &&
        !keyboard.isShiftPressed) {
      unawaited(_pasteFromClipboard());
      return KeyEventResult.handled;
    }
    if (key != LogicalKeyboardKey.enter &&
        key != LogicalKeyboardKey.numpadEnter) {
      return KeyEventResult.ignored;
    }
    if (control && !alt && !meta) {
      _insertAtSelection('\n');
      return KeyEventResult.handled;
    }
    if (alt || meta || keyboard.isShiftPressed) {
      // Shift/Alt+Enter stay with the editor for newline insertion.
      return KeyEventResult.ignored;
    }
    if (_controller.value.composing.isValid) {
      return KeyEventResult.ignored;
    }
    unawaited(_send());
    return KeyEventResult.handled;
  }

  bool get _isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  bool get _usesSendShortcut => _isDesktop;

  List<String> _collectMentionedAccounts() {
    final List<String> merged = <String>[];
    final Set<String> seen = <String>{};
    for (final String account in _stagedMentionedAccounts) {
      if (seen.add(account) && merged.length < mentionMaxRecipients) {
        merged.add(account);
      }
    }
    for (final String account in _mentionController.uniqueMentionedAccounts) {
      if (seen.add(account) && merged.length < mentionMaxRecipients) {
        merged.add(account);
      }
    }
    return List<String>.unmodifiable(merged);
  }

  void _commitCurrentText() {
    if (_isGroup) {
      for (final String account in _mentionController.uniqueMentionedAccounts) {
        if (!_stagedMentionedAccounts.contains(account) &&
            _stagedMentionedAccounts.length < mentionMaxRecipients) {
          _stagedMentionedAccounts.add(account);
        }
      }
    }
    final String text = _controller.text.trim();
    _mentionController.clear();
    if (text.isEmpty) {
      _controller.clear();
      _lastControllerValue = _controller.value;
      return;
    }
    _parts.add(ChatDraftPart(OutgoingText(text)));
    _controller.clear();
    _lastControllerValue = _controller.value;
  }

  Future<void> _send() async {
    if (!widget.enabled || InstallSafetyGate.instance.installing) {
      return;
    }
    _commitCurrentText();
    if (_parts.isEmpty && _attachments.isEmpty) {
      _stagedMentionedAccounts.clear();
      return;
    }
    final List<String> mentionedAccounts = _isGroup && _parts.isNotEmpty
        ? _collectMentionedAccounts()
        : const <String>[];
    _stagedMentionedAccounts.clear();
    final List<ChatDraftPart> parts = List<ChatDraftPart>.of(_parts);
    final List<ChatDraftAttachment> attachments = List<ChatDraftAttachment>.of(
      _attachments,
    );
    final String seed = newOperationId('x');
    final List<PendingSend> pending;
    try {
      pending = _buildPending(seed, parts, attachments);
    } on AuthFailure catch (failure) {
      _snack(failure.message);
      return;
    }
    _change(() {
      _parts.clear();
      _attachments.clear();
      _pending.addAll(pending);
    });
    _ownedOperations.addAll(pending.map((p) => p.operationId));
    // Retain retryable content in the same draft owner until confirmed.
    _persistDraft();
    _emitPending();
    final List<OutgoingPart> body = <OutgoingPart>[
      for (final ChatDraftPart part in parts) part.part,
    ];
    final List<OutgoingAttachment> outgoingAttachments = <OutgoingAttachment>[
      for (final ChatDraftAttachment item in attachments) item.attachment,
    ];
    try {
      final ComposedSendResult result = _isGroup
          ? await widget.shared!.sendGroupComposed(
              conversation: widget.conversation!,
              body: body,
              mentionedAccounts: mentionedAccounts,
              attachments: outgoingAttachments,
              operationSeed: seed,
            )
          : await widget.chat.sendComposed(
              targetAccount: widget.peerAccount,
              body: body,
              attachments: outgoingAttachments,
              operationSeed: seed,
            );
      _applyResult(result);
    } on AuthFailure catch (failure) {
      _markSeedFailed(seed, parts, attachments, failure, mentionedAccounts);
      _snack(failure.message);
    } catch (_) {
      _markSeedFailed(
        seed,
        parts,
        attachments,
        const AuthFailure(
          status: 0,
          code: 'send_failed',
          message: '发送失败，请稍后重试',
        ),
        mentionedAccounts,
      );
      _snack('发送失败，请稍后重试');
    }
  }

  void _applyResult(ComposedSendResult result) {
    final List<SendOutcome> outcomes = <SendOutcome>[
      if (result.body != null) result.body!,
      ...result.attachments,
    ];
    final Set<String> succeededIds = <String>{};
    final Set<String> failedIds = <String>{};
    final List<ChatMessage> sent = <ChatMessage>[];
    final List<SendOutcome> failed = <SendOutcome>[];
    final List<SentOperation> operations = <SentOperation>[];
    for (final SendOutcome outcome in outcomes) {
      final ChatMessage? message = outcome.message;
      if (message != null) {
        succeededIds.add(outcome.operationId);
        sent.add(message);
        operations.add(
          SentOperation(operationId: outcome.operationId, message: message),
        );
      } else {
        failedIds.add(outcome.operationId);
        failed.add(outcome);
      }
    }
    _change(() {
      _pending.removeWhere(
        (PendingSend pending) => succeededIds.contains(pending.operationId),
      );
      _markPendingFailed(failedIds);
      // Earlier failures stay retryable when a new message is sent.
      _failed.addAll(failed);
    });
    if (mounted && sent.isNotEmpty) {
      widget.onSent(sent, _bodyLocalPreviews(result.body));
      widget.onSentOperations?.call(operations);
    }
    _emitPending();
    if (failed.isNotEmpty) {
      _snack('有 ${failed.length} 项发送失败，可点按气泡重试');
    }
  }

  void _markSeedFailed(
    String seed,
    List<ChatDraftPart> parts,
    List<ChatDraftAttachment> attachments,
    AuthFailure failure, [
    List<String> mentionedAccounts = const <String>[],
  ]) {
    final List<SendOutcome> failed = <SendOutcome>[
      if (parts.isNotEmpty)
        SendOutcome(
          operationId: '$seed-b',
          failure: failure,
          part: <OutgoingPart>[
            for (final ChatDraftPart part in parts) part.part,
          ],
          mentionedAccounts: mentionedAccounts,
        ),
      for (int i = 0; i < attachments.length; i += 1)
        SendOutcome(
          operationId: '$seed-a$i',
          failure: failure,
          attachment: attachments[i].attachment,
        ),
    ];
    _change(() {
      _failed.addAll(failed);
      _markPendingFailed(<String>{
        for (final SendOutcome outcome in failed) outcome.operationId,
      });
    });
    _emitPending();
  }

  void _markPendingFailed(Set<String> operationIds) {
    for (int i = 0; i < _pending.length; i += 1) {
      if (operationIds.contains(_pending[i].operationId)) {
        _pending[i] = _pending[i].copyWith(state: SendFeedbackState.failed);
      }
    }
  }

  Future<void> _retryOne(String operationId) async {
    if (!widget.enabled || InstallSafetyGate.instance.installing) {
      return;
    }
    final int index = _failed.indexWhere(
      (SendOutcome outcome) => outcome.operationId == operationId,
    );
    if (index < 0) {
      return;
    }
    final SendOutcome outcome = _failed[index];
    _change(() {
      _failed = List<SendOutcome>.of(_failed)..removeAt(index);
      _setPendingState(operationId, SendFeedbackState.sending);
    });
    _emitPending();
    SendOutcome? retried;
    try {
      if (outcome.part != null) {
        retried = _isGroup
            ? await widget.shared!.sendGroupBodyOutcome(
                conversation: widget.conversation!,
                content: outcome.part!,
                mentionedAccounts: outcome.mentionedAccounts,
                operationId: operationId,
              )
            : await widget.chat.sendBody(
                targetAccount: widget.peerAccount,
                content: outcome.part!,
                mentionedAccounts: outcome.mentionedAccounts,
                operationId: operationId,
              );
      } else if (outcome.attachment != null) {
        retried = _isGroup
            ? await widget.shared!.sendGroupAttachmentOutcome(
                conversation: widget.conversation!,
                attachment: outcome.attachment!,
                operationId: operationId,
              )
            : await widget.chat.sendAttachment(
                targetAccount: widget.peerAccount,
                attachment: outcome.attachment!,
                operationId: operationId,
              );
      }
    } catch (error) {
      _change(() {
        _failed.add(
          error is AuthFailure
              ? SendOutcome(
                  operationId: operationId,
                  failure: error,
                  part: outcome.part,
                  attachment: outcome.attachment,
                  mentionedAccounts: outcome.mentionedAccounts,
                )
              : outcome,
        );
        _setPendingState(operationId, SendFeedbackState.failed);
      });
      _emitPending();
      _snack(error is AuthFailure ? error.message : '重试失败，请稍后再试');
      return;
    }
    if (retried == null) {
      _change(() {
        _failed.add(outcome);
        _setPendingState(operationId, SendFeedbackState.failed);
      });
      _emitPending();
      return;
    }
    final ChatMessage? message = retried.message;
    if (message == null) {
      _change(() {
        _failed.add(retried!);
        _setPendingState(operationId, SendFeedbackState.failed);
      });
      _emitPending();
      _snack('重试失败，请稍后再试');
      return;
    }
    _change(() {
      _pending.removeWhere(
        (PendingSend pending) => pending.operationId == operationId,
      );
    });
    if (mounted) {
      widget.onSent(<ChatMessage>[message], _bodyLocalPreviews(retried));
    }
    if (mounted) {
      widget.onSentOperations?.call(<SentOperation>[
        SentOperation(operationId: operationId, message: message),
      ]);
    }
    _emitPending();
  }

  Future<void> _discardFailed() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清除失败发送的本机内容？'),
        content: const Text('仅移除本机重试内容，不会撤回服务器可能已收到的消息。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('保留'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final ids = _failed.map((f) => f.operationId).toSet();
    _change(() {
      _failed.clear();
      _pending.removeWhere((p) => ids.contains(p.operationId));
    });
    _emitPending();
  }

  void _forgetCommittedOperation(String operationId) {
    final bool hadFailed = _failed.any(
      (SendOutcome outcome) => outcome.operationId == operationId,
    );
    final bool hadPending = _pending.any(
      (PendingSend item) => item.operationId == operationId,
    );
    if (!hadFailed && !hadPending) {
      return;
    }
    _change(() {
      _failed.removeWhere(
        (SendOutcome outcome) => outcome.operationId == operationId,
      );
      _pending.removeWhere(
        (PendingSend item) => item.operationId == operationId,
      );
    });
    if (hadPending) {
      _emitPending();
    }
  }

  void _setPendingState(String operationId, SendFeedbackState state) {
    for (int i = 0; i < _pending.length; i += 1) {
      if (_pending[i].operationId == operationId) {
        _pending[i] = _pending[i].copyWith(state: state);
      }
    }
  }

  void _emitPending() {
    _persistDraft();
    if (!mounted) return;
    final void Function(List<PendingSend>)? callback = widget.onPendingChanged;
    if (callback == null) {
      return;
    }
    callback(List<PendingSend>.unmodifiable(_pending));
  }

  /// Builds one local bubble per outgoing item before any request is sent.
  /// Media ids are local-only, so a pending image can render from bytes the
  /// composer already holds without pretending it was uploaded.
  List<PendingSend> _buildPending(
    String seed,
    List<ChatDraftPart> parts,
    List<ChatDraftAttachment> attachments,
  ) {
    final String self = widget.chat.selfAccount;
    final DateTime now = DateTime.now().toUtc();
    final List<PendingSend> pending = <PendingSend>[];
    final List<MessagePart> bodyParts = <MessagePart>[];
    final Map<String, Uint8List> imageBytes = <String, Uint8List>{};
    for (int index = 0; index < parts.length; index += 1) {
      final OutgoingPart part = parts[index].part;
      if (part is OutgoingText) {
        bodyParts.add(TextPart(part.text));
      } else if (part is OutgoingImage) {
        final String mediaId = 'pending:$seed:img$index';
        bodyParts.add(ImagePart(mediaId));
        final Uint8List? bytes = parts[index].bytes ?? part.source.bytes;
        if (bytes != null && bytes.isNotEmpty) {
          imageBytes[mediaId] = bytes;
        }
      }
    }
    if (bodyParts.isNotEmpty) {
      pending.add(
        PendingSend(
          operationId: '$seed-b',
          message: ChatMessage(
            id: 'pending:$seed-b',
            position: 0,
            senderAccount: self,
            targetAccount: widget.conversation?.isGroup == true
                ? ''
                : widget.peerAccount,
            conversation: widget.conversation,
            createdAt: now,
            kind: ChatMessageKind.body,
            parts: bodyParts,
          ),
          state: SendFeedbackState.sending,
          imageBytes: imageBytes,
        ),
      );
    }
    for (int index = 0; index < attachments.length; index += 1) {
      final ChatDraftAttachment draft = attachments[index];
      final Uint8List? cover = draft.coverBytes;
      final String mediaId = 'pending:$seed:att$index';
      final String? coverId = cover == null
          ? null
          : 'pending:$seed:cover$index';
      pending.add(
        PendingSend(
          operationId: '$seed-a$index',
          message: ChatMessage(
            id: 'pending:$seed-a$index',
            position: 0,
            senderAccount: self,
            targetAccount: widget.conversation?.isGroup == true
                ? ''
                : widget.peerAccount,
            conversation: widget.conversation,
            createdAt: now,
            kind: ChatMessageKind.attachment,
            attachment: Attachment(
              mediaId: mediaId,
              kind: draft.kind,
              filename: draft.filename,
              mimeType:
                  draft.attachment.source.mimeType ??
                  'application/octet-stream',
              byteSize: draft.size,
              coverMediaId: coverId,
            ),
          ),
          state: SendFeedbackState.sending,
          imageBytes: coverId == null
              ? const <String, Uint8List>{}
              : <String, Uint8List>{coverId: cover!},
        ),
      );
    }
    return pending;
  }

  /// Maps committed image blocks back to the bytes the composer still holds.
  /// Only used when both sides report the same number of images; a mismatch
  /// means the server normalized the body and guessing would bind wrong bytes.
  Map<String, Uint8List> _bodyLocalPreviews(SendOutcome? outcome) {
    final ChatMessage? message = outcome?.message;
    final List<OutgoingPart>? parts = outcome?.part;
    if (message == null || parts == null) {
      return <String, Uint8List>{};
    }
    final List<ImagePart> images = message.parts
        .whereType<ImagePart>()
        .toList();
    final List<OutgoingImage> outgoing = parts
        .whereType<OutgoingImage>()
        .toList();
    if (images.length != outgoing.length) {
      return <String, Uint8List>{};
    }
    final Map<String, Uint8List> previews = <String, Uint8List>{};
    for (int index = 0; index < images.length; index += 1) {
      final Uint8List? bytes = outgoing[index].source.bytes;
      if (bytes != null && bytes.isNotEmpty) {
        previews[images[index].mediaId] = bytes;
      }
    }
    return previews;
  }

  void _snack(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _buildDesktopPickerOverlay(BuildContext overlayContext) {
    final int totalCount = _totalGroupMemberCount > 0
        ? _totalGroupMemberCount
        : _mentionController.members.length + 1;
    return Positioned.fill(
      child: IgnorePointer(
        ignoring: false,
        child: UnconstrainedBox(
          alignment: Alignment.topLeft,
          child: CompositedTransformFollower(
            link: _pickerLink,
            showWhenUnlinked: false,
            targetAnchor: Alignment.topLeft,
            followerAnchor: Alignment.bottomLeft,
            offset: const Offset(AppSpacing.md, -8),
            child: TapRegion(
              groupId: _mentionTapGroup,
              child: MentionMemberPickerOverlay(
                candidates: _mentionController.candidates,
                totalGroupMemberCount: totalCount,
                otherMemberCount: _mentionController.members.length,
                query: _mentionController.activeQuery?.query ?? '',
                highlightedIndex: _mentionController.highlightedIndex,
                profile: widget.profile,
                onSelect: _selectMentionMember,
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // The send key is emphasised for any sendable content, including plain
    // text that still lives in the input. The staged strip, however, only
    // belongs to text/image parts and attachments; showing a duplicate text
    // chip for the field itself used to add a 64px band on every keystroke.
    final bool hasSendable =
        _controller.text.trim().isNotEmpty ||
        _parts.isNotEmpty ||
        _attachments.isNotEmpty;
    final bool hasStaged = _parts.isNotEmpty || _attachments.isNotEmpty;
    final String hint = _isGroup
        ? (_usesSendShortcut ? '输入消息… Enter 发送 · 输入 @ 点名' : '输入消息… 输入 @ 点名')
        : (_usesSendShortcut ? '输入消息… Enter 发送' : '输入消息…');
    return IgnorePointer(
      key: ChatComposer.safetyGateKey,
      ignoring: InstallSafetyGate.instance.installing,
      child: CompositedTransformTarget(
        link: _pickerLink,
        child: OverlayPortal(
          controller: _pickerOverlay,
          overlayChildBuilder: _buildDesktopPickerOverlay,
          child: TapRegion(
            groupId: _mentionTapGroup,
            onTapOutside: (_) {
              if (_isDesktopMentionPickerOpen) {
                _mentionController.dismissPicker();
              }
            },
            child: Container(
              decoration: const BoxDecoration(
                color: AppColors.surface,
                border: Border(top: BorderSide(color: AppColors.border)),
              ),
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.md,
                    AppSpacing.sm,
                    AppSpacing.sm,
                    AppSpacing.sm,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      if (hasStaged) _draftStrip(),
                      if (_failed.isNotEmpty)
                        TextButton(
                          onPressed: _discardFailed,
                          child: const Text('清除失败项'),
                        ),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: <Widget>[
                          // One round "+" collects the existing image and file
                          // entries; there is no separate paperclip in the bar.
                          _CircleButton(
                            key: ChatComposer.attachMenuKey,
                            tooltip: '添加',
                            icon: Icons.add_rounded,
                            iconColor: AppColors.accentDeep,
                            background: AppColors.accentSoft,
                            onTap: widget.enabled ? _openAttachSheet : null,
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          Expanded(
                            child: Container(
                              // Same height as the round + and send buttons on
                              // one line; it still grows with a multi-line
                              // draft.
                              constraints: const BoxConstraints(minHeight: 44),
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: AppColors.surface,
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(color: AppColors.border),
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: AppSpacing.md,
                              ),
                              child: TextField(
                                key: ChatComposer.inputKey,
                                controller: _controller,
                                focusNode: _focus,
                                enabled:
                                    widget.enabled &&
                                    !InstallSafetyGate.instance.installing,
                                minLines: 1,
                                maxLines: 5,
                                textInputAction: TextInputAction.newline,
                                // The pill is the field's own outline; the
                                // theme's focus border must not draw a second
                                // one inside it.
                                decoration: InputDecoration(
                                  hintText: hint,
                                  isDense: true,
                                  border: InputBorder.none,
                                  enabledBorder: InputBorder.none,
                                  focusedBorder: InputBorder.none,
                                  disabledBorder: InputBorder.none,
                                  contentPadding: EdgeInsets.zero,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          Tooltip(
                            message: _usesSendShortcut ? '发送（Enter）' : '发送',
                            child: _CircleButton(
                              key: ChatComposer.sendKey,
                              icon: Icons.arrow_forward_rounded,
                              iconColor: hasSendable
                                  ? AppColors.surface
                                  : AppColors.inkMuted,
                              background: hasSendable
                                  ? AppColors.accentDeep
                                  : AppColors.surface,
                              border: hasSendable
                                  ? AppColors.accentDeep
                                  : AppColors.border,
                              onTap: widget.enabled ? _send : null,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _draftStrip() {
    return SizedBox(
      height: 64,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
        children: <Widget>[
          for (int i = 0; i < _parts.length; i++) _partChip(i, _parts[i]),
          for (int i = 0; i < _attachments.length; i++)
            _attachmentChip(i, _attachments[i]),
        ],
      ),
    );
  }

  Widget _partChip(int index, ChatDraftPart part) {
    final Widget content = part.bytes == null
        ? Container(
            constraints: const BoxConstraints(maxWidth: 180),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            alignment: Alignment.centerLeft,
            child: Text(
              (part.part as OutgoingText).text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12.5),
            ),
          )
        : ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.memory(
              part.bytes!,
              width: 56,
              height: 56,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder:
                  (BuildContext context, Object error, StackTrace? stack) {
                    return const SizedBox(width: 56, height: 56);
                  },
            ),
          );
    return Padding(
      padding: const EdgeInsets.only(right: AppSpacing.sm),
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Container(
            height: 56,
            decoration: BoxDecoration(
              color: AppColors.paper,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.border),
            ),
            child: content,
          ),
          Positioned(
            right: -6,
            top: -6,
            child: InkWell(
              onTap: () {
                _change(() => _parts.removeAt(index));
                _persistDraft();
              },
              child: Container(
                width: 18,
                height: 18,
                decoration: const BoxDecoration(
                  color: AppColors.ink,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.close,
                  size: 12,
                  color: AppColors.surface,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _attachmentChip(int index, ChatDraftAttachment attachment) {
    return Padding(
      padding: const EdgeInsets.only(right: AppSpacing.sm),
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Container(
            height: 56,
            constraints: const BoxConstraints(maxWidth: 220),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: AppColors.paper,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (attachment.coverBytes != null)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Image.memory(
                      attachment.coverBytes!,
                      width: 40,
                      height: 40,
                      fit: BoxFit.cover,
                    ),
                  )
                else
                  Icon(
                    Icons.insert_drive_file_outlined,
                    color: attachmentColor(
                      attachment.kind == AttachmentKind.document
                          ? 'application/pdf'
                          : 'application/octet-stream',
                    ),
                  ),
                const SizedBox(width: 6),
                Flexible(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        attachment.filename,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        '${attachment.kind.previewLabel} · '
                        '${formatBytes(attachment.size)}',
                        style: const TextStyle(
                          fontSize: 10.5,
                          color: AppColors.inkMuted,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            right: -6,
            top: -6,
            child: InkWell(
              onTap: () {
                _change(() => _attachments.removeAt(index));
                _persistDraft();
              },
              child: Container(
                width: 18,
                height: 18,
                decoration: const BoxDecoration(
                  color: AppColors.ink,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.close,
                  size: 12,
                  color: AppColors.surface,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A round, thin-outlined icon button used by the composer bar.
class _CircleButton extends StatelessWidget {
  const _CircleButton({
    super.key,
    required this.icon,
    required this.iconColor,
    this.tooltip,
    this.background = AppColors.surface,
    this.border = AppColors.border,
    this.onTap,
  });

  final IconData icon;
  final Color iconColor;
  final String? tooltip;
  final Color background;
  final Color border;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final Widget button = SizedBox(
      width: 44,
      height: 44,
      child: Material(
        color: background,
        shape: CircleBorder(side: BorderSide(color: border)),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Icon(icon, size: 20, color: iconColor),
        ),
      ),
    );
    if (tooltip == null) {
      return button;
    }
    return Tooltip(message: tooltip!, child: button);
  }
}

class _MentionTextEditingController extends TextEditingController {
  _MentionTextEditingController({
    required this.mentionsProvider,
    required this.isGroupProvider,
  });

  final GroupMentionComposerController Function() mentionsProvider;
  final bool Function() isGroupProvider;

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    if (!isGroupProvider()) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    final List<MentionSpan> spans = mentionsProvider().spans;
    final String text = value.text;
    final bool hasComposing =
        withComposing &&
        value.composing.isValid &&
        !value.composing.isCollapsed &&
        value.composing.start >= 0 &&
        value.composing.end <= text.length;
    if (spans.isEmpty || hasComposing) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    final List<MentionSpan> validSpans = <MentionSpan>[
      for (final MentionSpan span in spans)
        if (span.start >= 0 &&
            span.end <= text.length &&
            span.start < span.end &&
            text.substring(span.start, span.end) == span.label)
          span,
    ]..sort((MentionSpan a, MentionSpan b) => a.start.compareTo(b.start));
    if (validSpans.isEmpty) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    final TextStyle tokenStyle = (style ?? const TextStyle()).copyWith(
      color: AppColors.accentDeep,
      backgroundColor: AppColors.accentSoft,
      fontWeight: FontWeight.w700,
    );
    final List<InlineSpan> children = <InlineSpan>[];
    int cursor = 0;
    for (final MentionSpan span in validSpans) {
      if (span.start < cursor) {
        continue;
      }
      if (span.start > cursor) {
        children.add(
          TextSpan(text: text.substring(cursor, span.start), style: style),
        );
      }
      children.add(
        TextSpan(text: text.substring(span.start, span.end), style: tokenStyle),
      );
      cursor = span.end;
    }
    if (cursor < text.length) {
      children.add(TextSpan(text: text.substring(cursor), style: style));
    }
    return TextSpan(style: style, children: children);
  }
}
