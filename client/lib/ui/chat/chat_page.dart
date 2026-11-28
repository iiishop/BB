import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:video_player/video_player.dart';

import '../../app.dart';
import '../../models/auth_models.dart';
import '../../models/chat_media.dart';
import '../../models/chat_models.dart';
import '../../models/group_models.dart';
import '../../models/mention_models.dart';
import '../../services/chat_query.dart';
import '../../services/chat_service.dart';
import '../../services/conversation_access.dart';
import '../../services/group_mention_controller.dart';
import '../../services/group_service.dart';
import '../../services/media_stream_proxy.dart';
import '../../services/presence_directory.dart';
import '../../services/profile_service.dart';
import '../profile/group_profile_host.dart';
import '../profile/profile_details.dart';
import 'chat_avatars.dart';
import 'chat_composer.dart';
import 'chat_format.dart';
import 'chat_header.dart';
import 'chat_reply_helpers.dart';
import 'chat_system_entry.dart';
import 'clipboard_paste.dart';
import 'media_actions.dart';
import 'media_save.dart';
import 'media_viewer.dart';
import 'message_bubble.dart';
import 'pending_send.dart';

/// Shared direct or group chat view with ordered content, attachments, and
/// live group membership revocation handling.
class ChatPage extends StatefulWidget {
  const ChatPage({
    super.key,
    ChatUser? peer,
    this.group,
    required this.chat,
    required this.profile,
    this.shared,
    this.groups,
    this.alerts,
    this.presence,
    this.openExternalStream,
    this.onMessagesChanged,
    this.onOpenDirectChat,
    this.onGroupRevoked,
    this.onGroupsChanged,
    this.saveService,
    this.clipboard = const PlatformClipboardMediaReader(),
    this.coverExtractor = defaultVideoCoverExtractor,
    this.viewerInlineVideoSupported,
    this.embedded = false,
    this.leading,
    this.active = true,
  }) : _peer = peer,
       assert(peer != null || group != null);

  final ChatUser? _peer;

  /// Effective peer snapshot (synthesized cleanly from [group] when in group mode
  /// so callers inspecting `peer` keep compatibility).
  ChatUser get peer =>
      _peer ??
      ChatUser(
        account: group!.groupNumber,
        username: group!.displayName,
        avatarUrl: group!.avatarUrl,
        avatarVersion: group!.avatarVersion,
        presence: Presence.offline,
      );

  /// Active group conversation item when viewing a group chat.
  final GroupConversationItem? group;

  final ChatService chat;
  final SharedConversationService? shared;
  final GroupService? groups;

  /// Shared account-level unread `@` / reply alert coordinator.
  final MentionRecipientController? alerts;

  /// Navigates to a 1:1 direct chat when tapping a member in group profile.
  final Future<void> Function(ChatUser user)? onOpenDirectChat;

  /// Notified immediately when membership is revoked (leave/remove/dissolve).
  final ValueChanged<ConversationRef>? onGroupRevoked;

  /// Notified when group metadata/membership changes from profile actions.
  final VoidCallback? onGroupsChanged;

  /// Shared with the user list; null keeps the snapshot (tests and any surface
  /// that has no directory).
  final PresenceDirectory? presence;

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

  /// Embedded in the split (desktop / unfolded foldable) right pane instead of
  /// being pushed as its own route. The conversation header and the composer
  /// are the same widgets; only the back affordance is dropped.
  final bool embedded;

  /// Optional leading control for an embedded pane (the foldable toggle when
  /// the chat is full screen). It occupies the AppBar slot instead of floating
  /// over a message.
  final Widget? leading;

  /// Whether this conversation pane is the one the reader can actually see.
  ///
  /// The split surface keeps opened conversations mounted so drafts, carets
  /// and scroll positions survive a switch. A hidden page may still poll for
  /// data, but it must not report those arrivals as displayed: the account
  /// unread is only cleared when this conversation becomes active again.
  final bool active;

  static const Key listKey = Key('chat-message-list');
  static const Key errorKey = Key('chat-error');
  static const Key emptyKey = Key('chat-empty');
  static const Key refreshKey = ChatHeader.refreshKey;
  static const Key newMessagesKey = Key('chat-new-messages');
  static const Key groupTimeKey = Key('chat-group-time');
  static const Key headerNameKey = ChatHeader.headerNameKey;
  static const Key headerStatusKey = ChatHeader.headerStatusKey;
  static const Key headerProfileKey = ChatHeader.headerProfileKey;
  static const Key headerGroupCountKey = ChatHeader.headerGroupCountKey;

  /// Header metrics taken from the annotated reference: a 48 px avatar with
  /// the name over the live presence, inside a 72 px tall bar.
  static const double headerHeight = ChatHeader.headerHeight;
  static const double headerAvatarSize = ChatHeader.headerAvatarSize;
  static const Key keyboardBodyKey = Key('chat-keyboard-body');
  static const Key mediaTransitionKey = Key('chat-media-transition');
  static const Key alertJumpKey = Key('chat-alert-jump');

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _listViewportKey = GlobalKey();
  final Map<String, GlobalKey> _rowKeys = <String, GlobalKey>{};
  final List<ChatMessage> _messages = <ChatMessage>[];
  final Set<String> _busyMedia = <String>{};
  final List<MediaStreamHandle> _streamHandles = <MediaStreamHandle>[];
  final Map<String, Uint8List> _localPreviews = <String, Uint8List>{};
  final List<String> _localPreviewOrder = <String>[];
  String? _localPreviewAccount;
  final ChatComposerController _composerController = ChatComposerController();
  List<PendingSend> _pending = <PendingSend>[];
  final Map<String, String> _operationByMessage = <String, String>{};
  String? _composingReplyTargetId;
  String? _highlightedMessageId;
  MessageHighlightKind? _highlightedKind;
  Timer? _highlightTimer;
  Timer? _viewportAlertTimer;
  Timer? _quoteSuppressTimer;
  bool _jumpingToMessage = false;
  bool _suppressViewportAlerts = false;

  /// Immutable page-level keys for the media thumbnails, so the viewer route
  /// can capture the tapped tile and expand it from its real position.
  final Map<String, GlobalKey> _mediaOriginKeys = <String, GlobalKey>{};

  /// New server messages that arrived while the reader was parked in history.
  /// They are announced by the pill instead of moving the list.
  int _unseenNew = 0;

  /// Last reported keyboard inset, used to re-pin the bottom only when the
  /// keyboard opens while the reader is already at the end.
  double _lastKeyboardInset = 0;

  /// True while a keyboard opening should keep the newest message pinned even
  /// as the viewport height changes across the inset animation.
  bool _pinBottomOnKeyboard = false;

  /// Display facts staged while this pane was hidden. They are sent only when
  /// [ChatPage.active] turns true and no covering route sits above this page,
  /// so a background poll cannot consume the other conversation's unread badge.
  final Map<String, ChatMessage> _pendingDisplayed = <String, ChatMessage>{};
  ModalRoute<dynamic>? _modalRoute;
  bool _routeCurrent = true;
  int _modalCovers = 0;

  /// Identities that were not on screen at the previous build. Only these get
  /// the entrance animation; history, scroll rebuilds and refresh do not.
  final Set<String> _animateIdentities = <String>{};

  /// Pending operation ids whose one entrance already played. Scrolling an
  /// unfinished bubble out and back in must not replay it.
  final Set<String> _pendingEntered = <String>{};

  /// Operations whose committed message is already in `_messages`. A local
  /// pending row with the same operation is hidden; other self messages are
  /// never hidden and render immediately.
  final Set<String> _committedOperations = <String>{};

  /// Failed operations the server authoritatively reported as not committed.
  /// Before that (pending/uncertain/error) the row is shown as unconfirmed.
  final Set<String> _confirmedFailedOperations = <String>{};

  /// Failed operations whose verification is not terminal yet. Used only to
  /// schedule another lookup on a later poll; it never hides messages.
  final Set<String> _unresolvedOperations = <String>{};

  /// Monotonic request ticket per operation; an older lookup completion cannot
  /// mutate a newer one.
  final Map<String, int> _lookupGeneration = <String, int>{};
  final Map<String, int> _lookupInFlight = <String, int>{};

  /// Invalidates callbacks captured for a previous peer on this widget.
  int _pageEpoch = 0;

  /// Owns the shared history-fetch gate. A peer switch abandons the old ticket
  /// so its finally cannot clear a newer request's _fetching flag.
  int _historyTicket = 0;
  int? _activeHistoryTicket;
  static const int _maxLocalPreviewEntries = 8;
  static const int _maxLocalPreviewBytes = 24 * 1024 * 1024;
  bool _loading = true;
  String? _error;
  bool _revoked = false;
  int? _capturedEpoch;
  GroupProfile? _liveGroupProfile;
  GroupMemberCounts? _groupCounts;
  int _groupCountsTicket = 0;
  int _groupCountsChangeTick = 0;
  bool _groupCountsLoading = false;
  bool _groupCountsInFlight = false;
  StreamSubscription<GroupProfile>? _groupUpdatesSub;
  int _groupAvatarTicket = 0;
  Uint8List? _groupAvatarBytes;
  Timer? _pollTimer;
  late final ChatAvatarController _avatars;

  /// Highest contiguous server position whose page has been fetched.
  int _fetchedThrough = 0;

  /// True while older messages exist on the server. The list opens on the
  /// newest window and pulls one older page at a time when the reader reaches
  /// the top — the full-history loop this replaced cost one serial request per
  /// 100 messages before the first bubble could render.
  bool _hasOlder = false;
  bool _loadingOlder = false;

  /// One page per fetch. The server caps `limit` at 100.
  static const int _historyWindow = 100;

  /// Server upper bound for `before_position` (contract: le=9007199254740991).
  /// Used as the "newest page" ceiling: omitting both boundaries means "from
  /// the beginning", not "from the end".
  static const int _historyCeiling = 9007199254740991;

  /// Highest position currently rendered (may be a local send beyond the
  /// fetched window). It must never advance the fetch cursor by itself.
  int _displayedMax = 0;
  bool _fetching = false;

  /// Bumped when the user grabs the list; queued/settling programmatic scrolls
  /// from before that gesture are abandoned instead of fighting the drag.
  int _scrollEpoch = 0;

  /// Maximum reading-column width inside the full-width transcript viewport.
  /// It keeps the old 860px centred column (860 minus the list's 2x16 padding)
  /// while the scroll viewport itself stays as wide as the chat pane.
  static const double _readingColumnMaxWidth = 860 - AppSpacing.md * 2;

  bool get _isGroup => widget.group != null;

  String get _scopeId => widget.group?.conversation.id ?? widget._peer!.account;

  String get _displayName =>
      _liveGroupProfile?.name ??
      widget.group?.displayName ??
      widget._peer!.username;

  String get _groupAvatarUrl =>
      _liveGroupProfile?.avatarUrl ?? widget.group?.avatarUrl ?? '';

  String get _groupAvatarVersion =>
      _liveGroupProfile?.avatarVersion ?? widget.group?.avatarVersion ?? '';

  ConversationRef? get _conversation => widget.group?.conversation;

  ConversationRef? get _alertConversation {
    if (_isGroup) {
      return widget.group?.conversation;
    }
    final String? self = _selfAccount;
    final String peer = widget._peer?.account ?? '';
    if (self == null ||
        peer.isEmpty ||
        peer == self ||
        !isValidAccount(self) ||
        !isValidAccount(peer)) {
      return null;
    }
    return ConversationRef.direct(self, peer);
  }

  GlobalKey _rowKeyFor(String identity) =>
      _rowKeys.putIfAbsent(identity, () => GlobalKey());

  ConversationAccessController? get _access => widget.shared?.access;

  String get _consumerSession => 'ui:${widget.chat.selfAccount}:$_scopeId';

  late final MediaSaveService _saveService =
      widget.saveService ?? MediaSaveService(chat: widget.chat);

  @override
  void initState() {
    super.initState();
    // Both sides are requested once when the conversation opens. The AppBar and
    // every bubble read this same controller, so scrolling cannot add requests.
    final Iterable<String> initialAccounts = _isGroup
        ? <String>[widget.chat.selfAccount]
        : <String>[widget.chat.selfAccount, widget._peer!.account];
    _avatars = ChatAvatarController(
      profile: widget.profile,
      accounts: initialAccounts,
    )..addListener(_onAvatarsChanged);
    widget.alerts?.addListener(_onAlertsChanged);
    _scrollController.addListener(_onScrolled);
    if (!_isGroup) {
      widget.presence?.addListener(_onPresenceChanged);
      widget.presence?.watch(widget._peer!.account);
    } else {
      _attachGroupAccess();
      _subscribeGroupUpdates();
      unawaited(_loadGroupAvatar());
    }
    unawaited(_loadInitial());
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (mounted && !_fetching && !_revoked) {
        unawaited(_pollNew());
      }
    });
  }

  void _attachGroupAccess() {
    final GroupConversationItem? group = widget.group;
    final ConversationAccessController? access = _access;
    final String? self = _selfAccount;
    if (group == null || access == null || self == null) {
      return;
    }
    if (access.stateFor(self, group.conversation.id) == null) {
      access.grant(
        self,
        group.conversation.id,
        membershipRevision: group.membershipRevision,
        historyThrough: group.historyThrough,
      );
    }
    _capturedEpoch = access.epochFor(self, group.conversation.id);
    access.addListener(_onGroupAccessChanged);
    if (access.isRevoked(self, group.conversation.id)) {
      _handleAccessRevoked(popRoute: false);
    }
  }

  void _detachGroupAccess([ConversationAccessController? access]) {
    (access ?? _access)?.removeListener(_onGroupAccessChanged);
  }

  void _onGroupAccessChanged() {
    final GroupConversationItem? group = widget.group;
    final ConversationAccessController? access = _access;
    final String? self = _selfAccount;
    if (!mounted ||
        _revoked ||
        group == null ||
        access == null ||
        self == null) {
      return;
    }
    if (access.isRevoked(self, group.conversation.id) ||
        (_capturedEpoch != null &&
            access.isStale(self, group.conversation.id, _capturedEpoch!))) {
      _handleAccessRevoked(popRoute: !widget.embedded);
    }
  }

  void _handleAccessRevoked({required bool popRoute}) {
    final GroupConversationItem? group = widget.group;
    if (_revoked || group == null) {
      return;
    }
    _revoked = true;
    _groupCountsTicket += 1;
    _groupCountsLoading = false;
    _groupCountsInFlight = false;
    _pollTimer?.cancel();
    for (final MediaStreamHandle handle in List<MediaStreamHandle>.of(
      _streamHandles,
    )) {
      unawaited(_closeStream(handle));
    }
    _localPreviews.clear();
    _localPreviewOrder.clear();
    if (mounted) {
      setState(() {
        _messages.clear();
        _pending = <PendingSend>[];
        _loading = false;
        _error = '已离开或无权访问该群会话';
      });
    }
    widget.onGroupRevoked?.call(group.conversation);
    if (popRoute && mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(Navigator.of(context).maybePop());
        }
      });
    }
  }

  void _subscribeGroupUpdates() {
    unawaited(_groupUpdatesSub?.cancel());
    _groupUpdatesSub = _isGroup
        ? widget.groups?.groupUpdates.listen(_onGroupProfileUpdated)
        : null;
  }

  void _onGroupProfileUpdated(GroupProfile profile) {
    final GroupConversationItem? group = widget.group;
    if (!mounted ||
        _revoked ||
        group == null ||
        profile.conversation != group.conversation) {
      return;
    }
    final String previousUrl = _groupAvatarUrl;
    final String previousVersion = _groupAvatarVersion;
    setState(() {
      _liveGroupProfile = profile;
    });
    if (profile.name != group.displayName ||
        profile.avatarVersion != group.avatarVersion) {
      widget.onGroupsChanged?.call();
    }
    if (profile.avatarUrl != previousUrl ||
        profile.avatarVersion != previousVersion) {
      unawaited(_loadGroupAvatar());
    }
    unawaited(_refreshGroupCounts(showLoading: false));
  }

  Future<void> _loadGroupAvatar() async {
    final GroupConversationItem? group = widget.group;
    final GroupService? groups = widget.groups;
    final int ticket = ++_groupAvatarTicket;
    final String avatarUrl = _groupAvatarUrl;
    if (group == null || groups == null || avatarUrl.isEmpty) {
      if (mounted && _groupAvatarBytes != null && avatarUrl.isEmpty) {
        setState(() => _groupAvatarBytes = null);
      }
      return;
    }
    try {
      final GroupAvatarImage image = await groups.loadGroupAvatar(
        groupNumber: group.groupNumber,
        avatarUrl: avatarUrl,
        thumb: true,
      );
      if (mounted &&
          !_revoked &&
          _scopeId == group.conversation.id &&
          _groupAvatarTicket == ticket &&
          _groupAvatarUrl == avatarUrl) {
        setState(() => _groupAvatarBytes = Uint8List.fromList(image.bytes));
      }
    } catch (_) {
      // Group avatar fallback stays cleanly without errors.
    }
  }

  void _onPresenceChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _modalRoute = ModalRoute.of(context);
    final bool current = _modalRoute?.isCurrent ?? true;
    if (current != _routeCurrent) {
      _routeCurrent = current;
      if (current) {
        _flushDisplayed();
        _scheduleViewportAlertCheck();
      }
    }
  }

  @override
  void didUpdateWidget(covariant ChatPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.alerts != widget.alerts) {
      oldWidget.alerts?.removeListener(_onAlertsChanged);
      widget.alerts?.addListener(_onAlertsChanged);
    }
    final String oldScope =
        oldWidget.group?.conversation.id ?? oldWidget._peer!.account;
    final String newScope = _scopeId;
    if (oldWidget.shared?.access != widget.shared?.access) {
      _detachGroupAccess(oldWidget.shared?.access);
      if (_isGroup) {
        _attachGroupAccess();
      }
    }
    if (oldWidget.presence != widget.presence ||
        (oldScope != newScope) ||
        (oldWidget.group != null) != _isGroup) {
      final ChatUser? oldPeer = oldWidget._peer;
      if (oldPeer != null) {
        oldWidget.presence
          ?..removeListener(_onPresenceChanged)
          ..unwatch(oldPeer.account);
      }
      if (!_isGroup) {
        widget.presence
          ?..addListener(_onPresenceChanged)
          ..watch(widget._peer!.account);
      }
    }
    if (oldWidget.groups != widget.groups ||
        (oldWidget.group != null) != _isGroup) {
      _subscribeGroupUpdates();
    }
    if (oldScope != newScope) {
      // Requests captured for the previous conversation must never write into
      // this page. A real navigation creates a new state; this guard also
      // covers a parent that reuses the widget with another target.
      _pageEpoch += 1;
      _revoked = false;
      _liveGroupProfile = null;
      _groupCounts = null;
      _groupCountsTicket += 1;
      _groupCountsChangeTick = 0;
      _groupCountsLoading = false;
      _groupCountsInFlight = false;
      _groupAvatarTicket += 1;
      _groupAvatarBytes = null;
      _lookupGeneration.clear();
      _lookupInFlight.clear();
      _messages.clear();
      _pending = <PendingSend>[];
      _operationByMessage.clear();
      _committedOperations.clear();
      _confirmedFailedOperations.clear();
      _unresolvedOperations.clear();
      _pendingEntered.clear();
      _animateIdentities.clear();
      _pendingDisplayed.clear();
      _fetchedThrough = 0;
      _displayedMax = 0;
      _hasOlder = false;
      _loadingOlder = false;
      _fetching = false;
      _activeHistoryTicket = null;
      _historyTicket += 1;
      _error = null;
      _loading = true;
      _rowKeys.clear();
      _composingReplyTargetId = null;
      _highlightedMessageId = null;
      _highlightedKind = null;
      _highlightTimer?.cancel();
      _viewportAlertTimer?.cancel();
      _quoteSuppressTimer?.cancel();
      _suppressViewportAlerts = false;
      if (_isGroup) {
        _attachGroupAccess();
        unawaited(_loadGroupAvatar());
      }
      unawaited(_loadInitial());
    } else {
      final GroupConversationItem? oldGroup = oldWidget.group;
      final GroupConversationItem? newGroup = widget.group;
      if (oldGroup != null &&
          newGroup != null &&
          (oldGroup.displayName != newGroup.displayName ||
              oldGroup.avatarUrl != newGroup.avatarUrl ||
              oldGroup.avatarVersion != newGroup.avatarVersion)) {
        final String previousUrl = _groupAvatarUrl;
        final String previousVersion = _groupAvatarVersion;
        _liveGroupProfile = null;
        if (newGroup.avatarUrl != previousUrl ||
            newGroup.avatarVersion != previousVersion) {
          unawaited(_loadGroupAvatar());
        }
      }
      final bool becameActive = !oldWidget.active && widget.active;
      final bool membershipChanged =
          oldGroup != null &&
          newGroup != null &&
          oldGroup.membershipRevision != newGroup.membershipRevision;
      final bool groupsServiceChanged = oldWidget.groups != widget.groups;
      if (becameActive) {
        // The pane just became visible again: only now do the arrivals that
        // were staged while it was hidden become display facts.
        _flushDisplayed();
        _scheduleViewportAlertCheck();
      }
      if (_isGroup &&
          (becameActive || membershipChanged || groupsServiceChanged)) {
        unawaited(_refreshGroupCounts(showLoading: false));
      }
    }
  }

  @override
  void dispose() {
    widget.alerts?.removeListener(_onAlertsChanged);
    _highlightTimer?.cancel();
    _viewportAlertTimer?.cancel();
    _quoteSuppressTimer?.cancel();
    unawaited(_groupUpdatesSub?.cancel());
    _groupUpdatesSub = null;
    if (widget._peer != null) {
      widget.presence
        ?..removeListener(_onPresenceChanged)
        ..unwatch(widget._peer!.account);
    }
    _detachGroupAccess();
    _pollTimer?.cancel();
    _avatars
      ..removeListener(_onAvatarsChanged)
      ..dispose();
    for (final MediaStreamHandle handle in _streamHandles) {
      unawaited(handle.close());
    }
    _streamHandles.clear();
    _scrollController
      ..removeListener(_onScrolled)
      ..dispose();
    super.dispose();
  }

  void _onAvatarsChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  void _onAlertsChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  int _beginHistoryRequest() {
    final int ticket = ++_historyTicket;
    _activeHistoryTicket = ticket;
    _fetching = true;
    return ticket;
  }

  bool _historyRequestCurrent(int ticket, int epoch, String scope) {
    return mounted &&
        !_revoked &&
        _activeHistoryTicket == ticket &&
        _pageEpoch == epoch &&
        _scopeId == scope;
  }

  Future<MessagePage> _fetchHistory({
    int? afterPosition,
    int? beforePosition,
    int limit = _historyWindow,
  }) {
    final GroupConversationItem? group = widget.group;
    if (group != null) {
      final SharedConversationService? shared = widget.shared;
      if (shared == null) {
        return Future<MessagePage>.error(upstreamMalformed);
      }
      return shared.loadConversationHistory(
        conversation: group.conversation,
        afterPosition: afterPosition,
        beforePosition: beforePosition,
        limit: limit,
      );
    }
    return widget.chat.loadConversation(
      peerAccount: widget._peer!.account,
      afterPosition: afterPosition,
      beforePosition: beforePosition,
      limit: limit,
    );
  }

  void _endHistoryRequest(int ticket) {
    if (_activeHistoryTicket == ticket) {
      _fetching = false;
      _activeHistoryTicket = null;
    }
  }

  bool _groupCountsRequestCurrent(int ticket, int epoch, String scope) {
    return mounted &&
        !_revoked &&
        _isGroup &&
        _pageEpoch == epoch &&
        _scopeId == scope &&
        _groupCountsTicket == ticket;
  }

  Future<void> _refreshGroupCounts({required bool showLoading}) async {
    final GroupConversationItem? group = widget.group;
    final GroupService? groups = widget.groups;
    if (!_isGroup || group == null || groups == null || _revoked) {
      return;
    }
    if (!showLoading && _groupCountsInFlight) {
      return;
    }
    final int epoch = _pageEpoch;
    final String scope = _scopeId;
    final int ticket = ++_groupCountsTicket;
    _groupCountsInFlight = true;
    if (showLoading && mounted && !_groupCountsLoading) {
      setState(() => _groupCountsLoading = true);
    }
    try {
      final GroupMemberPage page = await groups.listGroupMembers(
        conversation: group.conversation,
        limit: 1,
        includeCounts: true,
      );
      if (!_groupCountsRequestCurrent(ticket, epoch, scope)) {
        return;
      }
      final GroupMemberCounts? next = page.counts;
      if (next != null) {
        final bool changed = _groupCounts != next;
        setState(() {
          _groupCounts = next;
          if (changed) {
            _groupCountsChangeTick += 1;
          }
          _groupCountsLoading = false;
        });
      } else if (_groupCountsLoading) {
        setState(() => _groupCountsLoading = false);
      }
    } catch (_) {
      // Preserve last confirmed counts (or unknown on first load) when refresh
      // fails or an older server rejects include_counts.
      if (_groupCountsRequestCurrent(ticket, epoch, scope) &&
          _groupCountsLoading) {
        setState(() => _groupCountsLoading = false);
      }
    } finally {
      if (_groupCountsTicket == ticket) {
        _groupCountsInFlight = false;
        if (mounted && _groupCountsLoading) {
          setState(() => _groupCountsLoading = false);
        }
      }
    }
  }

  void _refreshFromHeader() {
    if (_revoked) {
      return;
    }
    if (_isGroup) {
      unawaited(_refreshGroupCounts(showLoading: true));
    }
    unawaited(_loadInitial(refreshGroupCounts: false));
  }

  Future<void> _loadInitial({bool refreshGroupCounts = true}) async {
    if (_fetching || _revoked) {
      return;
    }
    if (refreshGroupCounts && _isGroup) {
      unawaited(_refreshGroupCounts(showLoading: false));
    }
    final int epoch = _pageEpoch;
    final String scope = _scopeId;
    final int ticket = _beginHistoryRequest();
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      // Newest window only. Older pages load on demand from the top of the
      // list; opening a long conversation no longer issues one serial request
      // per 100 messages before the first bubble can render.
      final MessagePage page = await _fetchHistory(
        beforePosition: _historyCeiling,
        limit: _historyWindow,
      );
      if (!_historyRequestCurrent(ticket, epoch, scope)) {
        return;
      }
      _avatars.ensureAccounts(
        page.items.map((ChatMessage m) => m.senderAccount),
      );
      _suppressViewportAlerts = true;
      setState(() {
        _mergeMessages(page.items);
        _fetchedThrough = page.items.isEmpty ? 0 : page.items.last.position;
        _hasOlder = page.hasMore;
        _loadingOlder = false;
        _loading = false;
        _animateIdentities.clear();
        _unseenNew = 0;
      });
      _stageDisplayed(page.items);
      _forgetCommittedPending();
      widget.onMessagesChanged?.call(List<ChatMessage>.unmodifiable(_messages));
      _retryUnresolvedLookups();
      _scrollToBottom(
        animate: false,
        force: true,
        onSettled: () {
          if (mounted) {
            _suppressViewportAlerts = false;
            _scheduleViewportAlertCheck();
          }
        },
      );
    } on AuthFailure catch (failure) {
      if (!_historyRequestCurrent(ticket, epoch, scope)) {
        return;
      }
      setState(() {
        _loading = false;
        _error = failure.message;
      });
    } catch (_) {
      if (!_historyRequestCurrent(ticket, epoch, scope)) {
        return;
      }
      setState(() {
        _loading = false;
        _error = '消息加载失败，请稍后重试';
      });
    } finally {
      _endHistoryRequest(ticket);
    }
  }

  /// Pulls one older page when the reader reaches the top.
  ///
  /// The viewport is anchored: prepending a page would otherwise shift the
  /// bubbles the reader is looking at, so the scroll offset is advanced by
  /// exactly the height that was added.
  Future<void> _loadOlder() async {
    if (_loadingOlder ||
        !_hasOlder ||
        _messages.isEmpty ||
        _fetching ||
        _revoked) {
      return;
    }
    final int epoch = _pageEpoch;
    final String scope = _scopeId;
    final int ticket = _beginHistoryRequest();
    final bool hadClients = _scrollController.hasClients;
    final double beforePixels = hadClients
        ? _scrollController.position.pixels
        : 0;
    final double beforeMax = hadClients
        ? _scrollController.position.maxScrollExtent
        : 0;
    setState(() => _loadingOlder = true);
    try {
      final MessagePage page = await _fetchHistory(
        beforePosition: _messages.first.position,
        limit: _historyWindow,
      );
      if (!_historyRequestCurrent(ticket, epoch, scope)) {
        return;
      }
      _avatars.ensureAccounts(
        page.items.map((ChatMessage m) => m.senderAccount),
      );
      setState(() {
        _mergeMessages(page.items);
        _hasOlder = page.hasMore;
        _loadingOlder = false;
      });
      _stageDisplayed(page.items);
      if (hadClients) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_scrollController.hasClients) {
            return;
          }
          final double added =
              _scrollController.position.maxScrollExtent - beforeMax;
          if (added > 0) {
            _scrollController.jumpTo(beforePixels + added);
          }
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _loadingOlder = false);
      }
    } finally {
      _endHistoryRequest(ticket);
    }
  }

  Future<void> _pollNew() async {
    if (_fetching || _revoked) {
      return;
    }
    if (_isGroup && widget.active) {
      unawaited(_refreshGroupCounts(showLoading: false));
    }
    final int epoch = _pageEpoch;
    final String scope = _scopeId;
    final int ticket = _beginHistoryRequest();
    try {
      final List<ChatMessage> loaded = <ChatMessage>[];
      int cursor = _fetchedThrough;
      bool hasMore = true;
      int pages = 0;
      while (hasMore && pages < 1000) {
        final MessagePage page = await _fetchHistory(
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
      if (!_historyRequestCurrent(ticket, epoch, scope)) {
        return;
      }
      _avatars.ensureAccounts(loaded.map((ChatMessage m) => m.senderAccount));
      final bool wasNearBottom = _isNearBottom;
      final Set<String> known = _messages
          .map((ChatMessage message) => message.identity)
          .toSet();
      final Set<String> arrived = <String>{
        for (final ChatMessage message in loaded)
          if (!known.contains(message.identity)) message.identity,
      };
      final int arrivedCount = loaded
          .where(
            (ChatMessage message) =>
                !known.contains(message.identity) &&
                !message.isSystem &&
                message.senderAccount != _selfAccount,
          )
          .length;
      setState(() {
        _mergeMessages(loaded);
        // Only a contiguous server read advances the fetch cursor. Local
        // sends in _onSent never touch this value.
        _fetchedThrough = cursor;
        _animateIdentities.addAll(arrived);
        if (wasNearBottom) {
          _unseenNew = 0;
        } else if (arrivedCount > 0) {
          // A reader parked in history keeps the exact reading position and
          // gets a count instead of being yanked to the newest message.
          _unseenNew += arrivedCount;
        }
      });
      _stageDisplayed(loaded);
      _forgetCommittedPending();
      widget.onMessagesChanged?.call(List<ChatMessage>.unmodifiable(_messages));
      _retryUnresolvedLookups();
      if (_isGroup &&
          loaded.any(
            (ChatMessage message) =>
                arrived.contains(message.identity) && message.isSystem,
          )) {
        unawaited(
          widget.groups
              ?.findGroup(widget.group!.groupNumber)
              .then<void>((_) {}, onError: (Object _) {}),
        );
      }
      if (arrived.isNotEmpty && wasNearBottom) {
        _scrollToBottom(
          force: true,
          onSettled: () {
            if (mounted && !_suppressViewportAlerts) {
              _scheduleViewportAlertCheck();
            }
          },
        );
      } else if (arrived.isNotEmpty) {
        _scheduleViewportAlertCheck();
      }
    } catch (_) {
      // Polling is best effort; the explicit refresh keeps the error visible.
    } finally {
      _endHistoryRequest(ticket);
    }
  }

  String? get _selfAccount {
    try {
      return widget.chat.selfAccount;
    } on AuthFailure {
      return null;
    }
  }

  void _invalidateLookup(String operationId) {
    _lookupGeneration[operationId] = (_lookupGeneration[operationId] ?? 0) + 1;
  }

  bool _matchesScope(ChatMessage message, String scope) {
    if (_isGroup) {
      return message.conversation?.id == scope;
    }
    return message.targetAccount == scope;
  }

  bool _lookupApplies(
    String operationId,
    int generation,
    String account,
    String scope,
    int pageEpoch,
  ) {
    return mounted &&
        !_revoked &&
        _pageEpoch == pageEpoch &&
        _scopeId == scope &&
        _selfAccount == account &&
        _lookupGeneration[operationId] == generation &&
        !_committedOperations.contains(operationId) &&
        _isFailedPendingLive(operationId);
  }

  /// Registers an association that is valid for this page's account and
  /// conversation. The service already enforces scope; this is the display
  /// scope fence, and it also invalidates any in-flight lookup for the same
  /// operation because the commit is now definitive.
  void _recordAssociation(ChatMessage message, String operationId) {
    final String? self = _selfAccount;
    if (self == null ||
        message.senderAccount != self ||
        !_matchesScope(message, _scopeId)) {
      return;
    }
    if (message.operationId != null && message.operationId != operationId) {
      return;
    }
    _operationByMessage[message.identity] = operationId;
    if (_committedOperations.add(operationId)) {
      _unresolvedOperations.remove(operationId);
      _confirmedFailedOperations.remove(operationId);
      _invalidateLookup(operationId);
    }
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
      if (_lookupInFlight.containsKey(operationId) ||
          _committedOperations.contains(operationId) ||
          !_isFailedPendingLive(operationId)) {
        continue;
      }
      unawaited(_resolveFailedOperation(operationId));
    }
  }

  /// A client-observed failure is not proof the server rejected the operation.
  /// Only `GET /operations/{id}` can name the committed message for this exact
  /// operation; if it can, the local failure row is replaced by that message.
  /// Every request owns a generation; a completion is only allowed to write
  /// while its generation, page, account and peer all still match.
  Future<void> _resolveFailedOperation(String operationId) async {
    if (!_isFailedPendingLive(operationId) ||
        _committedOperations.contains(operationId)) {
      return;
    }
    final String? account = _selfAccount;
    if (account == null) {
      return;
    }
    final String scope = _scopeId;
    final int pageEpoch = _pageEpoch;
    final int generation = (_lookupGeneration[operationId] ?? 0) + 1;
    _lookupGeneration[operationId] = generation;
    _lookupInFlight[operationId] = generation;
    try {
      final OperationResult? result = await widget.chat.getOperation(
        operationId,
      );
      if (!_lookupApplies(operationId, generation, account, scope, pageEpoch)) {
        return;
      }
      final ChatMessage? message = result?.message;
      if (result?.status == OperationStatus.succeeded && message != null) {
        if (message.senderAccount != account ||
            !_matchesScope(message, scope) ||
            (message.operationId != null &&
                message.operationId != operationId)) {
          return;
        }
        setState(() {
          _recordAssociation(message, operationId);
          _mergeMessages(<ChatMessage>[message]);
          _animateIdentities.remove(message.identity);
        });
        widget.onMessagesChanged?.call(
          List<ChatMessage>.unmodifiable(_messages),
        );
        _composerController.forgetCommittedOperation(operationId);
        _hideFailureSnackBarIfClear();
      } else if (result == null || result.status == OperationStatus.failed) {
        // Authoritative "not committed": keep the local failure row, now
        // labelled as a definite failure rather than an unknown state.
        setState(() {
          _unresolvedOperations.remove(operationId);
          _confirmedFailedOperations.add(operationId);
        });
      } else {
        // pending/uncertain/succeeded-without-message: still unknown, keep the
        // retry entry and retry the lookup on a later poll.
        setState(() {
          _unresolvedOperations.add(operationId);
          _confirmedFailedOperations.remove(operationId);
        });
      }
    } on AuthFailure {
      if (_lookupApplies(operationId, generation, account, scope, pageEpoch)) {
        setState(() {
          _unresolvedOperations.add(operationId);
          _confirmedFailedOperations.remove(operationId);
        });
      }
    } catch (_) {
      if (_lookupApplies(operationId, generation, account, scope, pageEpoch)) {
        setState(() {
          _unresolvedOperations.add(operationId);
          _confirmedFailedOperations.remove(operationId);
        });
      }
    } finally {
      // Only this request's ticket is cleared. A newer request for the same
      // operation keeps its own in-flight marker.
      if (_lookupInFlight[operationId] == generation) {
        _lookupInFlight.remove(operationId);
      }
    }
  }

  /// Stages messages this page has rendered as exact display facts.
  ///
  /// While the pane is hidden the batch is held; a background poll must never
  /// clear the unread badge of the conversation the reader cannot see. The
  /// batch is flushed when [ChatPage.active] turns true (or immediately when
  /// this page is the active one).
  void _stageDisplayed(Iterable<ChatMessage> messages) {
    for (final ChatMessage message in messages) {
      _pendingDisplayed[message.identity] = message;
    }
    _flushDisplayed();
  }

  bool get _canConfirmDisplayed {
    if (!mounted || !widget.active || _revoked || _modalCovers > 0) {
      return false;
    }
    return _modalRoute?.isCurrent ?? true;
  }

  Future<T> _runCoveringRoute<T>(Future<T> Function() action) async {
    _modalCovers += 1;
    try {
      return await action();
    } finally {
      if (mounted) {
        _modalCovers = math.max(0, _modalCovers - 1);
        _flushDisplayed();
        _scheduleViewportAlertCheck();
      }
    }
  }

  /// Sends staged display facts. Bookkeeping for account incoming unread only:
  /// it reuses confirmed display receipts, never the consumption ACK, and
  /// never an outbound read receipt.
  void _flushDisplayed() {
    if (!_canConfirmDisplayed || _pendingDisplayed.isEmpty) {
      return;
    }
    final List<ChatMessage> batch = List<ChatMessage>.of(
      _pendingDisplayed.values,
    );
    _pendingDisplayed.clear();
    if (_isGroup) {
      final GroupConversationItem? group = widget.group;
      final SharedConversationService? shared = widget.shared;
      if (group == null || shared == null) {
        return;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_canConfirmDisplayed) {
          for (final ChatMessage message in batch) {
            _pendingDisplayed[message.identity] = message;
          }
          return;
        }
        unawaited(
          shared
              .recordGroupDisplayedIncoming(
                group: group,
                ledger: widget.chat.ledger,
                messages: batch,
              )
              .then<void>((int confirmed) {
                if (confirmed > 0 && mounted) {
                  widget.onGroupsChanged?.call();
                }
              })
              .catchError((Object _) {
                if (mounted) {
                  for (final ChatMessage message in batch) {
                    _pendingDisplayed.putIfAbsent(
                      message.identity,
                      () => message,
                    );
                  }
                }
              }),
        );
      });
      return;
    }
    unawaited(
      widget.chat
          .recordDisplayedIncoming(
            peerAccount: widget._peer!.account,
            messages: batch,
          )
          .then<void>((int _) {})
          .catchError((Object _) {
            // Keep the facts for the next activation; the service is
            // idempotent, so retrying cannot double-count.
            if (mounted) {
              for (final ChatMessage message in batch) {
                _pendingDisplayed[message.identity] = message;
              }
            }
          }),
    );
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
    for (final ChatMessage message in _messages) {
      final String? operationId = message.operationId;
      if (operationId != null) {
        _recordAssociation(message, operationId);
      }
    }
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
      // The sender's own message always reveals the end of the list, so the
      // history announcement no longer applies.
      _unseenNew = 0;
    });
    _forgetCommittedPending();
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
        final ChatMessage message = operation.message;
        if (message.operationId != null &&
            message.operationId != operation.operationId) {
          continue;
        }
        _recordAssociation(message, operation.operationId);
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
    final List<String> retried = <String>[
      for (final PendingSend item in pending)
        if (item.state == SendFeedbackState.sending &&
            previousState[item.operationId] == SendFeedbackState.failed)
          item.operationId,
    ];
    final List<String> newlyFailed = <String>[
      for (final PendingSend item in pending)
        if (item.state == SendFeedbackState.failed &&
            previousState[item.operationId] != SendFeedbackState.failed &&
            !_committedOperations.contains(item.operationId))
          item.operationId,
    ];
    final List<String> alreadyCommitted = <String>[
      for (final PendingSend item in pending)
        if (_committedOperations.contains(item.operationId)) item.operationId,
    ];
    setState(() {
      _pending = List<PendingSend>.of(pending);
      for (final String operationId in retried) {
        _invalidateLookup(operationId);
        _unresolvedOperations.remove(operationId);
        _confirmedFailedOperations.remove(operationId);
      }
      for (final String operationId in live) {
        if (!failedLive.contains(operationId)) {
          _confirmedFailedOperations.remove(operationId);
        }
      }
      _pendingEntered.removeWhere(
        (String operationId) => !live.contains(operationId),
      );
      _unresolvedOperations.removeWhere(
        (String operationId) => !failedLive.contains(operationId),
      );
      _confirmedFailedOperations.removeWhere(
        (String operationId) => !live.contains(operationId),
      );
      _lookupGeneration.removeWhere(
        (String operationId, int _) =>
            !live.contains(operationId) &&
            !_committedOperations.contains(operationId),
      );
    });
    if (startedSend) {
      // A new explicit send reveals its bubble immediately; a failed/retrying
      // update does not move a reader who is parked in history. No long
      // animation here, so the user can grab the list without a fight.
      _scrollToBottom(animate: false, force: true);
    }
    if (alreadyCommitted.isNotEmpty) {
      for (final String operationId in alreadyCommitted.toSet()) {
        _composerController.forgetCommittedOperation(operationId);
      }
      _hideFailureSnackBarIfClear();
    }
    if (newlyFailed.isNotEmpty) {
      for (final String operationId in newlyFailed) {
        unawaited(_resolveFailedOperation(operationId));
      }
    }
  }

  void _forgetCommittedPending() {
    final Set<String> operationIds = <String>{
      for (final PendingSend item in _pending)
        if (_committedOperations.contains(item.operationId)) item.operationId,
    };
    for (final String operationId in operationIds) {
      _composerController.forgetCommittedOperation(operationId);
    }
    if (operationIds.isNotEmpty) {
      _hideFailureSnackBarIfClear();
    }
  }

  void _hideFailureSnackBarIfClear() {
    if (mounted && !_composerController.canRetry) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
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

  /// Reading the end clears the pending "new messages" announcement.
  void _onScrolled() {
    if (!_isNearBottom) {
      // Wheel / keyboard scrolling away from the end takes over from the
      // keyboard pin; a later new message must not drag the reader down.
      _pinBottomOnKeyboard = false;
    }
    if (_unseenNew > 0 && _isNearBottom) {
      setState(() => _unseenNew = 0);
    }
  }

  void _scrollToBottom({
    bool animate = true,
    bool force = false,
    VoidCallback? onSettled,
  }) {
    if (!force && !_isNearBottom) {
      onSettled?.call();
      return;
    }
    final int epoch = _scrollEpoch;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _applyBottomScroll(
        animate: animate,
        attempt: 0,
        epoch: epoch,
        onSettled: onSettled,
      );
    });
  }

  void _goToLatest() {
    setState(() => _unseenNew = 0);
    _scrollToBottom(
      animate: true,
      force: true,
      onSettled: _scheduleViewportAlertCheck,
    );
  }

  bool _onScrollNotification(ScrollNotification notification) {
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _scrollEpoch += 1;
      // The reader took over: stop following the keyboard and allow normal
      // viewport alert confirmation as the reader scrolls manually.
      _pinBottomOnKeyboard = false;
      _quoteSuppressTimer?.cancel();
      _suppressViewportAlerts = false;
    }
    // The list is chronological, so the top edge is where the past lives.
    // `_loadOlder` guards itself against repeat entry.
    if (notification is ScrollUpdateNotification &&
        notification.depth == 0 &&
        notification.metrics.pixels <= 240) {
      unawaited(_loadOlder());
    }
    if (notification.depth == 0 &&
        !_suppressViewportAlerts &&
        (notification is ScrollEndNotification ||
            notification is ScrollUpdateNotification)) {
      _scheduleViewportAlertCheck();
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
    VoidCallback? onSettled,
  }) {
    if (!mounted || !_scrollController.hasClients || epoch != _scrollEpoch) {
      onSettled?.call();
      return;
    }
    final ScrollPosition position = _scrollController.position;
    final double target = position.maxScrollExtent;
    final double remaining = target - position.pixels;
    if (remaining.abs() <= 1) {
      onSettled?.call();
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
              _applyBottomScroll(
                animate: false,
                attempt: 1,
                epoch: epoch,
                onSettled: onSettled,
              );
            } else {
              onSettled?.call();
            }
          });
      return;
    }
    // A body photo reserves 4:3 until its real ratio arrives and then settles
    // over ~160ms; a short attempt budget would stop short of the bottom and
    // leave the newest message a few pixels below the fold.
    if (attempt >= 12) {
      onSettled?.call();
      return;
    }
    _scrollController.jumpTo(target);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _applyBottomScroll(
        animate: false,
        attempt: attempt + 1,
        epoch: epoch,
        onSettled: onSettled,
      );
    });
  }

  void _enterReply(ChatMessage message) {
    if (_revoked || message.id.isEmpty) {
      return;
    }
    final String fallback = (message.senderUsername?.isNotEmpty ?? false)
        ? message.senderUsername!
        : _displayName;
    final ReplyQuote quote = replyQuoteFromMessage(
      message,
      fallbackAuthor: fallback,
    );
    _composerController.setReplyTarget(quote);
  }

  void _setMessageHighlight(String messageId, MessageHighlightKind kind) {
    _highlightTimer?.cancel();
    setState(() {
      _highlightedMessageId = messageId;
      _highlightedKind = kind;
    });
    final bool reducedMotion =
        MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    _highlightTimer = Timer(
      Duration(milliseconds: reducedMotion ? 900 : 1400),
      () {
        if (!mounted) {
          return;
        }
        setState(() {
          if (_highlightedMessageId == messageId) {
            _highlightedMessageId = null;
            _highlightedKind = null;
          }
        });
      },
    );
  }

  Future<void> _nextFrame() {
    final Completer<void> completer = Completer<void>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!completer.isCompleted) {
        completer.complete();
      }
    });
    return completer.future;
  }

  Future<bool> _scrollToMessage(
    String messageId, {
    required MessageHighlightKind highlightKind,
  }) async {
    final ChatMessage? target = _messages.cast<ChatMessage?>().firstWhere(
      (ChatMessage? m) => m?.id == messageId,
      orElse: () => null,
    );
    if (target == null) {
      return false;
    }
    final GlobalKey key = _rowKeyFor(target.identity);
    await _nextFrame();
    if (!mounted) {
      return false;
    }
    final bool reducedMotion =
        MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (key.currentContext == null && _scrollController.hasClients) {
      final List<String> order = _timelineEntryIdentities();
      final int targetIndex = order.indexOf(target.identity);
      if (targetIndex < 0) {
        return false;
      }
      final double initialEstimate = order.length <= 1
          ? 0
          : (targetIndex / (order.length - 1)) *
                _scrollController.position.maxScrollExtent;
      _scrollController.jumpTo(
        initialEstimate.clamp(0.0, _scrollController.position.maxScrollExtent),
      );
      await _nextFrame();
      for (int step = 0; step < 12; step += 1) {
        if (!mounted || !_scrollController.hasClients) {
          return false;
        }
        if (key.currentContext != null) {
          break;
        }
        int? minMounted;
        int? maxMounted;
        for (int i = 0; i < order.length; i += 1) {
          if (_rowKeys[order[i]]?.currentContext != null) {
            minMounted ??= i;
            maxMounted = i;
          }
        }
        final ScrollPosition pos = _scrollController.position;
        final double stride = math.max(120.0, pos.viewportDimension * 0.7);
        double nextOffset = pos.pixels;
        if (minMounted != null && targetIndex < minMounted) {
          nextOffset = pos.pixels - stride;
        } else if (maxMounted != null && targetIndex > maxMounted) {
          nextOffset = pos.pixels + stride;
        } else {
          break;
        }
        final double clamped = nextOffset.clamp(0.0, pos.maxScrollExtent);
        if ((clamped - pos.pixels).abs() < 1.0) {
          break;
        }
        _scrollController.jumpTo(clamped);
        await _nextFrame();
      }
    }
    final BuildContext? rowContext = key.currentContext;
    if (rowContext == null || !rowContext.mounted) {
      return false;
    }
    await Scrollable.ensureVisible(
      rowContext,
      alignment: 0.35,
      duration: reducedMotion
          ? Duration.zero
          : const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
    if (!mounted) {
      return false;
    }
    await _nextFrame();
    if (!mounted) {
      return false;
    }
    _setMessageHighlight(target.id, highlightKind);
    return _isMessageInForegroundViewport(target);
  }

  List<String> _timelineEntryIdentities() {
    return <String>[
      for (final ChatMessage m in _messages) m.identity,
      for (final PendingSend pending in _pending)
        if (!_committedOperations.contains(pending.operationId))
          pending.message.identity,
    ];
  }

  bool _isMessageInForegroundViewport(ChatMessage message) {
    final RenderBox? viewportBox =
        _listViewportKey.currentContext?.findRenderObject() as RenderBox?;
    final RenderBox? itemBox =
        _rowKeys[message.identity]?.currentContext?.findRenderObject()
            as RenderBox?;
    if (viewportBox == null ||
        itemBox == null ||
        !viewportBox.hasSize ||
        !itemBox.hasSize ||
        !viewportBox.attached ||
        !itemBox.attached) {
      return false;
    }
    final Offset topLeft = itemBox.localToGlobal(
      Offset.zero,
      ancestor: viewportBox,
    );
    final double top = topLeft.dy;
    final double bottom = top + itemBox.size.height;
    final double height = viewportBox.size.height;
    return bottom > 8 && top < height - 8;
  }

  void _scheduleViewportAlertCheck() {
    if (!mounted ||
        _suppressViewportAlerts ||
        widget.alerts == null ||
        _alertConversation == null) {
      return;
    }
    _viewportAlertTimer?.cancel();
    _viewportAlertTimer = Timer(const Duration(milliseconds: 80), () {
      if (mounted) {
        unawaited(_reportViewportVisibleAlerts());
      }
    });
  }

  Future<void> _reportViewportVisibleAlerts() async {
    final MentionRecipientController? alerts = widget.alerts;
    final ConversationRef? conversation = _alertConversation;
    if (alerts == null ||
        conversation == null ||
        !_canConfirmDisplayed ||
        _suppressViewportAlerts ||
        _loading) {
      return;
    }
    if (alerts.summaryLoadedOnce && !alerts.hasUnreadAlerts(conversation.id)) {
      return;
    }
    final List<ChatMessage> visible = <ChatMessage>[
      for (final ChatMessage message in _messages)
        if (_isMessageInForegroundViewport(message)) message,
    ];
    if (visible.isEmpty) {
      return;
    }
    try {
      await alerts.reportVisibleMessages(
        conversation: conversation,
        visibleMessages: visible,
        isForegroundActive: _canConfirmDisplayed,
      );
    } catch (_) {
      // Unacknowledged alerts stay visible and retryable on subsequent view checks.
    }
  }

  Future<List<ChatMessage>?> _fetchContextWindow(String messageId) async {
    final ConversationRef? groupConv = _conversation;
    if (groupConv != null && widget.shared != null) {
      final MessageContextRecord? record = await widget.shared!
          .loadMessageContext(conversation: groupConv, messageId: messageId);
      return record?.items;
    }
    final ContextResult? result = await widget.chat.query.getContext(
      messageId: messageId,
      beforeLimit: 25,
      afterLimit: 25,
    );
    if (result == null) {
      return null;
    }
    if (_isGroup) {
      if (result.conversation != groupConv) {
        return null;
      }
    } else if (result.peerAccount.isNotEmpty &&
        result.peerAccount != widget._peer?.account) {
      return null;
    }
    return result.items;
  }

  Future<void> _jumpToQuotedOriginal(String originalId) async {
    if (_jumpingToMessage || _revoked) {
      return;
    }
    final int epoch = _pageEpoch;
    final String scope = _scopeId;
    _jumpingToMessage = true;
    _suppressViewportAlerts = true;
    _quoteSuppressTimer?.cancel();
    try {
      final bool loaded = _messages.any((ChatMessage m) => m.id == originalId);
      if (!loaded) {
        final List<ChatMessage>? contextItems = await _fetchContextWindow(
          originalId,
        );
        if (!mounted || epoch != _pageEpoch || scope != _scopeId) {
          return;
        }
        if (contextItems == null ||
            !contextItems.any((ChatMessage m) => m.id == originalId)) {
          _showJumpError('原消息定位失败，未标记已读');
          return;
        }
        _avatars.ensureAccounts(
          contextItems.map((ChatMessage m) => m.senderAccount),
        );
        // Contract: quote context jumps inspect history without updating
        // unread or alert confirmation watermarks.
        setState(() {
          _mergeMessages(contextItems);
        });
        widget.onMessagesChanged?.call(
          List<ChatMessage>.unmodifiable(_messages),
        );
      }
      final bool landed = await _scrollToMessage(
        originalId,
        highlightKind: MessageHighlightKind.quote,
      );
      if (!mounted) {
        return;
      }
      if (!landed) {
        _showJumpError('原消息定位失败，未标记已读');
        return;
      }
      _quoteSuppressTimer = Timer(const Duration(milliseconds: 600), () {
        if (mounted) {
          _suppressViewportAlerts = false;
        }
      });
    } on AuthFailure catch (failure) {
      if (mounted) {
        _showJumpError(failure.message);
      }
    } catch (_) {
      if (mounted) {
        _showJumpError('原消息定位失败，未标记已读');
      }
    } finally {
      _jumpingToMessage = false;
      if (_quoteSuppressTimer == null ||
          !(_quoteSuppressTimer?.isActive ?? false)) {
        _suppressViewportAlerts = false;
      }
    }
  }

  Future<void> _jumpToNextAlert() async {
    final MentionRecipientController? alerts = widget.alerts;
    final ConversationRef? conversation = _alertConversation;
    if (alerts == null ||
        conversation == null ||
        _jumpingToMessage ||
        _revoked) {
      return;
    }
    final int epoch = _pageEpoch;
    final String scope = _scopeId;
    _jumpingToMessage = true;
    _suppressViewportAlerts = true;
    _quoteSuppressTimer?.cancel();
    try {
      final Set<String> loadedIds = <String>{
        for (final ChatMessage m in _messages)
          if (m.id.isNotEmpty) m.id,
      };
      final AlertJumpResolution? resolution = await alerts
          .resolveNextJumpTarget(
            conversation: conversation,
            loadedMessageIds: loadedIds,
          );
      if (!mounted || epoch != _pageEpoch || scope != _scopeId) {
        return;
      }
      if (resolution == null) {
        _showJumpError('本会话没有未读提醒了');
        return;
      }
      final MessageContextRecord? contextRecord = resolution.context;
      if (contextRecord != null) {
        _avatars.ensureAccounts(
          contextRecord.items.map((ChatMessage m) => m.senderAccount),
        );
        setState(() {
          _mergeMessages(contextRecord.items);
        });
        widget.onMessagesChanged?.call(
          List<ChatMessage>.unmodifiable(_messages),
        );
      }
      final bool landed = await _scrollToMessage(
        resolution.alert.messageId,
        highlightKind: MessageHighlightKind.alert,
      );
      if (!mounted || epoch != _pageEpoch || scope != _scopeId) {
        return;
      }
      if (!landed) {
        _showJumpError('定位失败 · 未标记已读');
        return;
      }
      _suppressViewportAlerts = false;
      await _reportViewportVisibleAlerts();
    } on AuthFailure catch (failure) {
      if (mounted) {
        _showJumpError(failure.message);
      }
    } catch (_) {
      if (mounted) {
        _showJumpError('定位失败 · 未标记已读');
      }
    } finally {
      _jumpingToMessage = false;
      _suppressViewportAlerts = false;
    }
  }

  void _showJumpError(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(message)));
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
      peerName: _displayName,
    );
  }

  /// The thumbnail token the bubble and the viewer route both use.
  ///
  /// It identifies the *occurrence* — this message, this content slot — not
  /// just the media. One image can legitimately appear in several messages
  /// (the same picture sent twice); the painted id alone would give two live
  /// `RepaintBoundary` tiles the same `GlobalKey`, and the transition would
  /// start from whichever one the framework last moved.
  String _mediaOriginToken(ChatMessage message, int? partIndex) {
    return 'media:${message.id}:${partIndex ?? 'attachment'}';
  }

  GlobalKey _mediaOriginKey(String token) => _mediaOriginKeys.putIfAbsent(
    token,
    () => GlobalKey(debugLabel: 'chat-media-origin-$token'),
  );

  Future<({Rect rect, ui.Image? image})?> _captureOrigin(String token) async {
    final BuildContext? origin = _mediaOriginKeys[token]?.currentContext;
    if (origin == null) {
      return null;
    }
    final RenderObject? renderObject = origin.findRenderObject();
    if (renderObject is! RenderBox ||
        !renderObject.attached ||
        !renderObject.hasSize ||
        renderObject.size.isEmpty) {
      return null;
    }
    final Rect rect =
        renderObject.localToGlobal(Offset.zero) & renderObject.size;
    ui.Image? image;
    if (renderObject is RenderRepaintBoundary) {
      try {
        image = await renderObject.toImage(
          pixelRatio: MediaQuery.devicePixelRatioOf(context),
        );
      } catch (_) {
        // A tile that is mid-paint or already detached still gets the
        // position-anchored fade instead of failing to open the viewer.
      }
    }
    if (!mounted) {
      return null;
    }
    // The snapshot is owned by the route's transition frames. It is not
    // disposed when the pop future completes because the final reverse frame
    // can still build it; releasing the last reference lets the engine reclaim
    // it with the route.
    return (rect: rect, image: image);
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
    final String token = _mediaOriginToken(message, partIndex);
    final ({Rect rect, ui.Image? image})? captured = await _captureOrigin(
      token,
    );
    if (!mounted) {
      return;
    }
    final Widget viewer = MediaViewer(
      items: items,
      initialIndex: index,
      chat: widget.chat,
      saveService: _saveService,
      sequenceComplete: _error == null,
      onPlayVideo: _playViewerVideo,
      onReload: _reloadMediaSequence,
      localPreviewFor: _localPreviewFor,
      inlineVideoSupported: widget.viewerInlineVideoSupported,
      conversation: _conversation,
      access: _access,
    );
    // The route keeps the captured frame alive for both directions; see
    // [_captureOrigin] for why it is not disposed here.
    await _runCoveringRoute(
      () => Navigator.of(context).push<void>(_mediaRoute(viewer, captured)),
    );
  }

  /// Opens the existing viewer by expanding the tap target from its real list
  /// rectangle. The viewer's own playback, zoom, paging and menus are
  /// untouched; only the entrance/exit is new.
  PageRoute<void> _mediaRoute(
    Widget viewer,
    ({Rect rect, ui.Image? image})? captured,
  ) {
    return PageRouteBuilder<void>(
      fullscreenDialog: true,
      transitionDuration: const Duration(milliseconds: 260),
      reverseTransitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (
        BuildContext context,
        Animation<double> animation,
        Animation<double> secondaryAnimation,
      ) => viewer,
      transitionsBuilder:
          (
            BuildContext context,
            Animation<double> animation,
            Animation<double> secondaryAnimation,
            Widget child,
          ) {
            final Animation<double> eased = animation.drive(
              CurveTween(curve: Curves.easeOutCubic),
            );
            final ui.Image? image = captured?.image;
            if (image == null) {
              return FadeTransition(opacity: eased, child: child);
            }
            final Size screen = MediaQuery.sizeOf(context);
            final Rect from = captured!.rect;
            final Rect to = Offset.zero & screen;
            return AnimatedBuilder(
              key: ChatPage.mediaTransitionKey,
              animation: eased,
              child: child,
              builder: (BuildContext context, Widget? child) {
                final double t = eased.value.clamp(0.0, 1.0);
                final Rect rect = Rect.lerp(from, to, t)!;
                // The viewer fades in behind the expanding thumbnail, so neither
                // surface is stretched while the rectangle changes size.
                final double reveal = ((t - 0.45) / 0.55).clamp(0.0, 1.0);
                return Stack(
                  children: <Widget>[
                    Positioned.fill(
                      child: Opacity(opacity: reveal, child: child!),
                    ),
                    if (t < 0.999)
                      Positioned.fromRect(
                        rect: rect,
                        child: ClipRect(
                          child: RawImage(image: image, fit: BoxFit.cover),
                        ),
                      ),
                  ],
                );
              },
            );
          },
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
      handle = _isGroup && _access != null
          ? await widget.chat.mediaStreams.open(
              attachment.mediaId,
              conversation: _conversation,
              access: _access,
            )
          : await widget.chat.openMediaStream(attachment.mediaId);
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

  /// Last confirmed presence from the shared directory, else the snapshot the
  /// row handed over when the page opened.
  Presence get _presenceOfPeer =>
      widget.presence?.valueFor(widget._peer!.account) ??
      widget._peer!.presence;

  Future<void> _openHeaderProfile() async {
    final GroupConversationItem? group = widget.group;
    if (group != null) {
      final GroupService? groups = widget.groups;
      if (groups == null) {
        return;
      }
      await _runCoveringRoute(
        () => openGroupProfileByNumber(
          context,
          groupNumber: group.groupNumber,
          initialProfile: _liveGroupProfile,
          groups: groups,
          chat: widget.chat,
          profile: widget.profile,
          onOpenDirectChat: widget.onOpenDirectChat,
          onGroupsChanged: widget.onGroupsChanged,
        ),
      );
      return;
    }
    await _runCoveringRoute(
      () => openPersonProfile(
        context,
        account: widget._peer!.account,
        gateway: widget.profile,
      ),
    );
  }

  Future<void> _openSenderProfile(String senderAccount) async {
    if (_modalCovers > 0 ||
        senderAccount.isEmpty ||
        senderAccount == _selfAccount) {
      return;
    }
    await _runCoveringRoute(
      () => openPersonProfile(
        context,
        account: senderAccount,
        gateway: widget.profile,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final double keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    final bool reducedMotion =
        MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    // Opening the keyboard while the reader is already at the end keeps the
    // newest message above the composer; opening it in history only shrinks
    // the viewport and leaves the reading position untouched.
    if (keyboardInset != _lastKeyboardInset) {
      final bool opening = keyboardInset > _lastKeyboardInset;
      _lastKeyboardInset = keyboardInset;
      // Re-pin on every metrics change while the inset animates, otherwise the
      // first frame would target the old height and the bubble would drift.
      _pinBottomOnKeyboard = opening && _isNearBottom;
      if (opening && _isNearBottom) {
        _scrollToBottom(animate: false, force: true);
      }
    }
    return Scaffold(
      backgroundColor: AppColors.chatPaper,
      // The inset is applied to the whole chat column below, not by resizing
      // only the composer: the transcript and the input rise together while
      // the AppBar stays where it is.
      resizeToAvoidBottomInset: false,
      appBar: ChatHeader(
        displayName: _displayName,
        isGroup: _isGroup,
        avatarBytes: _isGroup
            ? _groupAvatarBytes
            : _avatars.bytesFor(widget._peer!.account),
        avatarLoading: !_isGroup && _avatars.isLoading(widget._peer!.account),
        avatarSemanticLabel: _isGroup
            ? '查看群 $_displayName 的资料'
            : '查看 $_displayName 的资料',
        onAvatarTap: _openHeaderProfile,
        onRefresh: _revoked ? null : _refreshFromHeader,
        groupNumber: widget.group?.groupNumber,
        groupCounts: _groupCounts,
        groupCountsLoading: _groupCountsLoading,
        groupCountsChangeTick: _groupCountsChangeTick,
        peerPresence: _isGroup ? null : _presenceOfPeer,
        embedded: widget.embedded,
        leading: widget.leading,
      ),
      body: AnimatedPadding(
        key: ChatPage.keyboardBodyKey,
        duration: reducedMotion
            ? Duration.zero
            : const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
        padding: EdgeInsets.only(bottom: keyboardInset),
        child: Column(
          children: <Widget>[
            Expanded(
              child: Stack(
                children: <Widget>[
                  Positioned.fill(
                    child: KeyedSubtree(
                      key: _listViewportKey,
                      child: _buildBody(),
                    ),
                  ),
                  if (_buildAlertOverlay() case final Widget alertOverlay)
                    Positioned(
                      top: AppSpacing.md,
                      right: AppSpacing.md,
                      child: alertOverlay,
                    ),
                  if (_unseenNew > 0)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: AppSpacing.sm,
                      child: Center(
                        child: _NewMessagesPill(
                          count: _unseenNew,
                          onTap: _goToLatest,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            ChatComposer(
              key: ValueKey<String>('chat-composer-$_scopeId'),
              chat: widget.chat,
              peerAccount: widget._peer?.account ?? '',
              conversation: _conversation,
              shared: widget.shared,
              draftKey: _scopeId,
              enabled: !_revoked,
              clipboard: widget.clipboard,
              coverExtractor: widget.coverExtractor,
              controller: _composerController,
              onSent: _onSent,
              onSentOperations: _onSentOperations,
              onPendingChanged: _onPendingChanged,
              onReplyTargetChanged: (ReplyQuote? target) {
                if (mounted) {
                  setState(() {
                    _composingReplyTargetId = target?.messageId;
                  });
                }
              },
            ),
          ],
        ),
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
                onPressed: _refreshFromHeader,
                child: const Text('重新加载'),
              ),
            ],
          ),
        ),
      );
    }
    final bool hasVisiblePending = _pending.any(
      (PendingSend item) => !_committedOperations.contains(item.operationId),
    );
    if (_messages.isEmpty && !hasVisiblePending) {
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
              _isGroup ? '$_displayName 还没有消息' : '和 $_displayName 还没有消息',
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
          operationId:
              message.operationId ?? _operationByMessage[message.identity],
        ),
      for (final PendingSend pending in _pending)
        if (!_committedOperations.contains(pending.operationId))
          _TimelineEntry(
            message: pending.message,
            operationId: pending.operationId,
            pending: pending,
          ),
    ];
    bool sameRun(int left, int right) {
      if (entries[left].message.isSystem || entries[right].message.isSystem) {
        return false;
      }
      return continuesMessageRun(
        entries[left].message.senderAccount,
        entries[left].message.createdAt,
        entries[right].message.senderAccount,
        entries[right].message.createdAt,
      );
    }

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // The photo block is two thirds of the message area. The page measures
        // the area, so a dual pane never asks for a phone-wide picture.
        final double messageArea =
            math.min(
              constraints.maxWidth,
              _readingColumnMaxWidth + AppSpacing.md * 2,
            ) -
            AppSpacing.md * 2;
        final double mediaMaxWidth = math.max(
          120,
          math.min(messageArea * 0.66, 420),
        );
        final List<Widget> timeline = <Widget>[
          // Older pages land above the first bubble; without a row here the
          // list looks frozen at the top while the request is in flight.
          if (_loadingOlder)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
        ];
        DateTime? previous;
        for (int index = 0; index < entries.length; index += 1) {
          final _TimelineEntry entry = entries[index];
          final ChatMessage message = entry.message;
          if (message.isSystem) {
            timeline.add(
              _readingColumn(
                key: ValueKey<String>('chat-system-column-${message.identity}'),
                child: ChatSystemEntry(
                  key: ValueKey<String>('chat-system-${message.identity}'),
                  text: message.systemText ?? '',
                ),
              ),
            );
            continue;
          }
          final bool committed = entry.pending == null;
          final bool runStart = index == 0 || !sameRun(index - 1, index);
          final bool runEnd =
              index == entries.length - 1 || !sameRun(index, index + 1);
          if (committed) {
            // One centred timestamp per group, never per bubble. The first group of
            // a day also names the day, which replaces the old separator pill.
            if (runStart) {
              final bool firstOfDay = shouldShowDaySeparator(
                previous,
                message.createdAt,
              );
              final String label = firstOfDay
                  ? '${formatDaySeparator(message.createdAt)} '
                        '${formatClockTime(message.createdAt)}'
                  : formatClockTime(message.createdAt);
              timeline.add(
                _readingColumn(
                  key: ValueKey<String>('chat-time-column-${message.identity}'),
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 12, bottom: 4),
                      child: Text(
                        label,
                        // One constant key: a test can point at "the group
                        // time" without knowing the message identity.
                        key: ChatPage.groupTimeKey,
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.chatTime,
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }
            previous = message.createdAt;
          }
          final Attachment? attachment = message.attachment;
          final String bubbleKey = entry.operationId ?? message.identity;
          final bool pendingFirstFrame =
              entry.pending != null &&
              !_pendingEntered.contains(entry.operationId);
          final SendFeedbackState? displayedSendState = entry.pending?.state;
          final bool statusUnconfirmed =
              entry.pending?.state == SendFeedbackState.failed &&
              !_confirmedFailedOperations.contains(entry.operationId);
          final Widget bubble = MessageBubble(
            key: ValueKey<String>('chat-bubble-$bubbleKey'),
            message: message,
            selfAccount: widget.chat.selfAccount,
            peerUsername: (message.senderUsername?.isNotEmpty ?? false)
                ? message.senderUsername!
                : _displayName,
            chat: widget.chat,
            avatars: _avatars,
            showSenderName: _isGroup,
            busy:
                committed &&
                attachment != null &&
                _busyMedia.contains(attachment.mediaId),
            sendState: displayedSendState,
            statusUnconfirmed: statusUnconfirmed,
            onRetry: entry.pending?.state == SendFeedbackState.failed
                ? () => _composerController.retryFailed(entry.operationId!)
                : null,
            onReply: committed && !_revoked ? () => _enterReply(message) : null,
            onTapQuote: committed ? _jumpToQuotedOriginal : null,
            highlightKind: committed && _highlightedMessageId == message.id
                ? _highlightedKind
                : null,
            composingReplyTarget:
                committed && _composingReplyTargetId == message.id,
            showAvatar: runStart,
            isRunEnd: runEnd,
            originKeyFor: (ChatMessage message, int? partIndex) =>
                _mediaOriginKey(_mediaOriginToken(message, partIndex)),
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
            onAvatarTap:
                !message.isSystem &&
                    message.senderAccount.isNotEmpty &&
                    message.senderAccount != _selfAccount
                ? () => _openSenderProfile(message.senderAccount)
                : null,
            localMediaPreview: _previewFor,
            mediaMaxWidth: mediaMaxWidth,
          );
          timeline.add(
            _readingColumn(
              // The keyed wrapper (not the inner row) is the ListView child, so a
              // day separator inserted above must not recreate the message element
              // and reset its entrance/feedback state.
              key: ValueKey<String>('chat-column-$bubbleKey'),
              child: Padding(
                key: ValueKey<String>('chat-row-$bubbleKey'),
                padding: EdgeInsets.only(top: runStart ? 10 : 2),
                child: MessageEntrance(
                  key: ValueKey<String>('chat-entrance-$bubbleKey'),
                  animate: entry.pending != null
                      ? pendingFirstFrame
                      : _animateIdentities.contains(message.identity),
                  child: KeyedSubtree(
                    key: committed ? _rowKeyFor(message.identity) : null,
                    child: bubble,
                  ),
                ),
              ),
            ),
          );
        }
        final Set<String> consumedIdentities = Set<String>.of(
          _animateIdentities,
        );
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
        // The transcript scrolls as the full-width chat pane. Constraining the
        // ListView itself to the reading column made the desktop scrollbar sit at
        // the column edge and dropped wheel input over the side gutters (DEA-478);
        // the column cap now applies to each row instead.
        return NotificationListener<ScrollMetricsNotification>(
          onNotification: (ScrollMetricsNotification notification) {
            if (_pinBottomOnKeyboard) {
              _scrollToBottom(animate: false, force: true);
            }
            return false;
          },
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
        );
      },
    );
  }

  /// Keeps the chat reading column centred and capped without shrinking the
  /// scroll viewport (and therefore the scrollbar and wheel hit area).
  Widget _readingColumn({Key? key, required Widget child}) {
    return Center(
      key: key,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _readingColumnMaxWidth),
        child: child,
      ),
    );
  }

  Widget? _buildAlertOverlay() {
    final MentionRecipientController? alerts = widget.alerts;
    final ConversationRef? conversation = _alertConversation;
    if (alerts == null ||
        conversation == null ||
        _revoked ||
        !alerts.hasUnreadAlerts(conversation.id)) {
      return null;
    }
    final AlertCounts counts = alerts.countsFor(conversation.id);
    final UnreadAlert? latest = alerts.latestAlertFor(conversation.id);
    final bool showReply;
    final bool showMention;
    if (latest != null) {
      showReply = latest.reply;
      showMention = latest.mention;
    } else {
      showReply = counts.unreadReplyCount > 0;
      showMention = counts.unreadMentionCount > 0;
    }
    final String label = showReply && showMention
        ? '跳到回复 + @'
        : (showReply ? '跳到回复' : '跳到 @');
    final int total = counts.unreadMentionCount + counts.unreadReplyCount;
    return _AlertJumpPill(
      label: label,
      count: total,
      hasReply: showReply,
      onTap: _jumpToNextAlert,
    );
  }
}

/// Shared right-middle-upper button jumping newest-to-oldest across unread `@`
/// and reply alerts in this conversation.
class _AlertJumpPill extends StatelessWidget {
  const _AlertJumpPill({
    required this.label,
    required this.count,
    required this.hasReply,
    required this.onTap,
  });

  final String label;
  final int count;
  final bool hasReply;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color fg = hasReply ? AppColors.warning : AppColors.accentDeep;
    final Color bg = hasReply ? AppColors.warningSurface : AppColors.surface;
    final Color border = hasReply ? AppColors.warningBorder : AppColors.border;
    return Material(
      color: bg,
      elevation: 3,
      shape: StadiumBorder(side: BorderSide(color: border)),
      child: InkWell(
        key: ChatPage.alertJumpKey,
        onTap: onTap,
        customBorder: const StadiumBorder(),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 36),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  hasReply
                      ? Icons.reply_rounded
                      : Icons.alternate_email_rounded,
                  size: 16,
                  color: fg,
                ),
                const SizedBox(width: 5),
                Text(
                  label,
                  style: TextStyle(
                    color: fg,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (count > 0) ...<Widget>[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.accentDeep,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '$count',
                      style: const TextStyle(
                        color: AppColors.surface,
                        fontSize: 10.5,
                        height: 1.1,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Floating announcement for messages that arrived while the reader was in
/// history. It deliberately sits above the composer instead of moving the list.
class _NewMessagesPill extends StatelessWidget {
  const _NewMessagesPill({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.accentDeep,
      borderRadius: BorderRadius.circular(999),
      elevation: 3,
      child: InkWell(
        key: ChatPage.newMessagesKey,
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(
                Icons.arrow_downward_rounded,
                size: 16,
                color: AppColors.surface,
              ),
              const SizedBox(width: 4),
              Text(
                '$count 条新消息',
                style: const TextStyle(
                  color: AppColors.surface,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
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
