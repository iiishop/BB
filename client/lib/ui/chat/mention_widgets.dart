import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app.dart';
import '../../models/chat_models.dart';
import '../../models/group_models.dart';
import '../../models/mention_models.dart';
import '../../services/group_mention_controller.dart';
import '../../services/profile_service.dart';
import 'user_identity_row.dart';

const Color _mentionBannerBorder = Color(0xFFC7DEDA);
const Color _mixedBannerDivider = Color(0xFFDDD4C4);
const Color _matchHighlightFill = Color(0xFFCDE4DE);

/// L1 single-line unread alert banner for conversation list rows.
///
/// Renders at most one horizontal line (`有人 @ 你 N · 有人回复你 M`,
/// `有人 @ 你 · N`, or `有人回复你 · M`) and scales down on ultra-narrow widths
/// so it never wraps onto two lines.
class ConversationAlertNote extends StatelessWidget {
  const ConversationAlertNote({
    super.key,
    required this.conversationId,
    required this.counts,
    this.compact = false,
  });

  final String conversationId;
  final AlertCounts counts;
  final bool compact;

  static Key bannerKey(String conversationId) =>
      Key('conversation-alert-note-$conversationId');
  static Key mixedKey(String conversationId) =>
      Key('conversation-alert-mixed-$conversationId');
  static Key mentionKey(String conversationId) =>
      Key('conversation-alert-mention-$conversationId');
  static Key replyKey(String conversationId) =>
      Key('conversation-alert-reply-$conversationId');

  @override
  Widget build(BuildContext context) {
    final int mentions = counts.unreadMentionCount;
    final int replies = counts.unreadReplyCount;
    if (mentions <= 0 && replies <= 0) {
      return const SizedBox.shrink();
    }
    final bool both = mentions > 0 && replies > 0;
    final double fontSize = compact ? 10.0 : 10.5;
    final double iconSize = compact ? 13.0 : 15.0;

    final String semanticsText = both
        ? '有人 @ 你 $mentions 条，回复你 $replies 条'
        : mentions > 0
        ? '有人 @ 你 $mentions 条'
        : '有人回复你 $replies 条';

    final Widget pill;
    if (both) {
      pill = Container(
        key: mixedKey(conversationId),
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 6 : 7,
          vertical: compact ? 1.5 : 2,
        ),
        decoration: BoxDecoration(
          color: AppColors.surface.withValues(alpha: 0.94),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: _mentionBannerBorder),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _AlertCircleGlyph(
              glyph: '@',
              size: iconSize,
              background: AppColors.accentDeep,
            ),
            const SizedBox(width: 4),
            _AlertTextPair(
              prefix: '有人 @ 你 ',
              count: mentions,
              color: AppColors.accentDeep,
              fontSize: fontSize,
            ),
            const SizedBox(width: 5),
            Container(width: 1, height: 10, color: _mixedBannerDivider),
            const SizedBox(width: 5),
            _AlertCircleGlyph(
              icon: Icons.reply_rounded,
              size: iconSize,
              background: AppColors.warning,
            ),
            const SizedBox(width: 4),
            _AlertTextPair(
              prefix: '回复你 ',
              count: replies,
              color: AppColors.warning,
              fontSize: fontSize,
            ),
          ],
        ),
      );
    } else if (mentions > 0) {
      pill = Container(
        key: mentionKey(conversationId),
        padding: EdgeInsets.fromLTRB(compact ? 2 : 3, 2, compact ? 6 : 7, 2),
        decoration: BoxDecoration(
          color: AppColors.surface.withValues(alpha: 0.94),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: _mentionBannerBorder),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _AlertCircleGlyph(
              glyph: '@',
              size: iconSize,
              background: AppColors.accentDeep,
            ),
            const SizedBox(width: 4),
            _AlertTextPair(
              prefix: '有人 @ 你 · ',
              count: mentions,
              color: AppColors.accentDeep,
              fontSize: fontSize,
            ),
          ],
        ),
      );
    } else {
      pill = Container(
        key: replyKey(conversationId),
        padding: EdgeInsets.fromLTRB(compact ? 2 : 3, 2, compact ? 6 : 7, 2),
        decoration: BoxDecoration(
          color: AppColors.warningSurface,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: AppColors.warningBorder),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _AlertCircleGlyph(
              icon: Icons.reply_rounded,
              size: iconSize,
              background: AppColors.warning,
            ),
            const SizedBox(width: 4),
            _AlertTextPair(
              prefix: '有人回复你 · ',
              count: replies,
              color: AppColors.warning,
              fontSize: fontSize,
            ),
          ],
        ),
      );
    }

    return Semantics(
      key: bannerKey(conversationId),
      container: true,
      label: semanticsText,
      child: Align(
        alignment: Alignment.centerLeft,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: pill,
        ),
      ),
    );
  }
}

class _AlertCircleGlyph extends StatelessWidget {
  const _AlertCircleGlyph({
    this.glyph,
    this.icon,
    required this.size,
    required this.background,
  });

  final String? glyph;
  final IconData? icon;
  final double size;
  final Color background;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: background, shape: BoxShape.circle),
      child: icon != null
          ? Icon(icon, size: size * 0.8, color: AppColors.surface)
          : Text(
              glyph!,
              style: TextStyle(
                color: AppColors.surface,
                fontSize: size * 0.65,
                fontWeight: FontWeight.w800,
                height: 1,
              ),
            ),
    );
  }
}

class _AlertTextPair extends StatelessWidget {
  const _AlertTextPair({
    required this.prefix,
    required this.count,
    required this.color,
    required this.fontSize,
  });

  final String prefix;
  final int count;
  final Color color;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(
        text: prefix,
        style: TextStyle(
          color: color,
          fontSize: fontSize,
          fontWeight: FontWeight.w700,
          height: 1.3,
        ),
        children: <InlineSpan>[
          TextSpan(
            text: '$count',
            style: const TextStyle(fontWeight: FontWeight.w900),
          ),
        ],
      ),
      maxLines: 1,
      softWrap: false,
    );
  }
}

/// Shared right-upper-middle jump button for unread `@` mentions and replies.
class FloatingAlertJumpButton extends StatelessWidget {
  const FloatingAlertJumpButton({
    super.key,
    required this.latestAlert,
    required this.unreadMessageCount,
    required this.compact,
    required this.loading,
    required this.onTap,
  });

  final UnreadAlert latestAlert;
  final int unreadMessageCount;
  final bool compact;
  final bool loading;
  final VoidCallback onTap;

  static const Key buttonKey = Key('chat-alert-jump-button');
  static const Key countKey = Key('chat-alert-jump-count');

  static String typeLabelFor(UnreadAlert alert) {
    if (alert.mention && alert.reply) {
      return '回复 + @';
    }
    if (alert.reply) {
      return '回复';
    }
    return '@';
  }

  static String desktopLabelFor(UnreadAlert alert) {
    if (alert.mention && alert.reply) {
      return '跳到回复 + @';
    }
    if (alert.reply) {
      return '跳到回复';
    }
    return '跳到 @';
  }

  @override
  Widget build(BuildContext context) {
    final int count = math.max(1, unreadMessageCount);
    final String semantics =
        '跳到最新未读提醒：${typeLabelFor(latestAlert)}，剩余 $count 条';
    if (compact) {
      return Semantics(
        button: true,
        label: semantics,
        child: Tooltip(
          message: '跳到最新未读提醒：${typeLabelFor(latestAlert)}',
          child: Stack(
            clipBehavior: Clip.none,
            children: <Widget>[
              Material(
                key: buttonKey,
                color: AppColors.surface.withValues(alpha: 0.96),
                shape: const CircleBorder(
                  side: BorderSide(color: _mentionBannerBorder),
                ),
                elevation: 4,
                shadowColor: AppColors.accentNight.withValues(alpha: 0.22),
                child: InkWell(
                  onTap: loading ? null : onTap,
                  customBorder: const CircleBorder(),
                  child: SizedBox(
                    width: 44,
                    height: 44,
                    child: Center(
                      child: loading
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: AppColors.accentDeep,
                              ),
                            )
                          : Row(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                if (latestAlert.reply)
                                  const Icon(
                                    Icons.reply_rounded,
                                    size: 16,
                                    color: AppColors.accentDeep,
                                  ),
                                if (latestAlert.mention)
                                  const Text(
                                    '@',
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w800,
                                      color: AppColors.accentDeep,
                                      height: 1,
                                    ),
                                  ),
                              ],
                            ),
                    ),
                  ),
                ),
              ),
              Positioned(
                top: -4,
                right: -4,
                child: IgnorePointer(
                  child: Container(
                    key: countKey,
                    constraints: const BoxConstraints(
                      minWidth: 18,
                      minHeight: 18,
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: AppColors.accentDeep,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: AppColors.chatPaper, width: 2),
                    ),
                    child: Text(
                      '$count',
                      style: const TextStyle(
                        color: AppColors.surface,
                        fontSize: 9.5,
                        fontWeight: FontWeight.w800,
                        height: 1,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Semantics(
      button: true,
      label: semantics,
      child: Tooltip(
        message: '跳到最新未读提醒：${typeLabelFor(latestAlert)}',
        child: Material(
          key: buttonKey,
          color: AppColors.surface.withValues(alpha: 0.96),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(999),
            side: const BorderSide(color: _mentionBannerBorder),
          ),
          elevation: 5,
          shadowColor: AppColors.accentNight.withValues(alpha: 0.20),
          child: InkWell(
            onTap: loading ? null : onTap,
            borderRadius: BorderRadius.circular(999),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 38),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(6, 5, 11, 5),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Container(
                      width: 25,
                      height: 25,
                      alignment: Alignment.center,
                      decoration: const BoxDecoration(
                        color: AppColors.accentSoft,
                        shape: BoxShape.circle,
                      ),
                      child: loading
                          ? const SizedBox(
                              width: 13,
                              height: 13,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: AppColors.accentDeep,
                              ),
                            )
                          : const Icon(
                              Icons.arrow_upward_rounded,
                              size: 15,
                              color: AppColors.accentDeep,
                            ),
                    ),
                    const SizedBox(width: 7),
                    Text(
                      desktopLabelFor(latestAlert),
                      maxLines: 1,
                      softWrap: false,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: AppColors.accentDeep,
                      ),
                    ),
                    const SizedBox(width: 7),
                    Container(
                      key: countKey,
                      constraints: const BoxConstraints(
                        minWidth: 19,
                        minHeight: 19,
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 5),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: AppColors.accentDeep,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        '$count',
                        style: const TextStyle(
                          color: AppColors.surface,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w800,
                          height: 1,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Desktop Option A inline member picker floated immediately above the composer.
class MentionMemberPickerOverlay extends StatefulWidget {
  const MentionMemberPickerOverlay({
    super.key,
    required this.candidates,
    required this.totalGroupMemberCount,
    required this.otherMemberCount,
    required this.query,
    required this.highlightedIndex,
    required this.onSelect,
    this.profile,
  });

  final List<GroupMember> candidates;
  final int totalGroupMemberCount;
  final int otherMemberCount;
  final String query;
  final int highlightedIndex;
  final ValueChanged<GroupMember> onSelect;
  final ProfileGateway? profile;

  static const Key panelKey = Key('mention-desktop-picker');
  static const Key listKey = Key('mention-desktop-picker-list');
  static const Key emptyKey = Key('mention-desktop-picker-empty');
  static Key rowKey(String account) => Key('mention-candidate-$account');

  @override
  State<MentionMemberPickerOverlay> createState() =>
      _MentionMemberPickerOverlayState();
}

class _MentionMemberPickerOverlayState
    extends State<MentionMemberPickerOverlay> {
  final ScrollController _scroll = ScrollController();

  @override
  void didUpdateWidget(covariant MentionMemberPickerOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.highlightedIndex != widget.highlightedIndex &&
        widget.candidates.isNotEmpty) {
      final int clamped = widget.highlightedIndex.clamp(
        0,
        widget.candidates.length - 1,
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients) {
          return;
        }
        const double itemExtent = 56;
        final double itemTop = clamped * itemExtent;
        final double itemBottom = itemTop + itemExtent;
        final double offset = _scroll.offset;
        final double viewport = _scroll.position.viewportDimension;
        if (itemTop < offset) {
          _scroll.jumpTo(itemTop);
        } else if (itemBottom > offset + viewport) {
          _scroll.jumpTo(itemBottom - viewport);
        }
      });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final String trimmed = widget.query.trim();
    final String subtitle = trimmed.isNotEmpty
        ? '匹配「$trimmed」'
        : '当前群 ${widget.otherMemberCount} 位其他成员';
    return Semantics(
      container: true,
      label: '选择群成员',
      child: Material(
        key: MentionMemberPickerOverlay.panelKey,
        color: AppColors.surface,
        elevation: 10,
        shadowColor: AppColors.accentNight.withValues(alpha: 0.22),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: AppColors.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 372),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(13, 11, 13, 9),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          const Text(
                            '群成员',
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w800,
                              color: AppColors.ink,
                            ),
                          ),
                          const SizedBox(height: 1),
                          Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 10.5,
                              color: AppColors.inkMuted,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Text(
                      '${widget.candidates.length} / ${widget.totalGroupMemberCount}',
                      style: const TextStyle(
                        fontSize: 10.5,
                        color: AppColors.inkMuted,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              if (widget.candidates.isEmpty)
                const _MentionPickerEmpty(
                  key: MentionMemberPickerOverlay.emptyKey,
                )
              else
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 294),
                  child: ListView.builder(
                    key: MentionMemberPickerOverlay.listKey,
                    controller: _scroll,
                    shrinkWrap: true,
                    padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
                    itemCount: widget.candidates.length,
                    itemBuilder: (BuildContext context, int index) {
                      final GroupMember member = widget.candidates[index];
                      return _MentionCandidateTile(
                        key: MentionMemberPickerOverlay.rowKey(member.account),
                        member: member,
                        query: widget.query,
                        active: index == widget.highlightedIndex,
                        showEnterHint: true,
                        profile: widget.profile,
                        onTap: () => widget.onSelect(member),
                      );
                    },
                  ),
                ),
              Container(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
                decoration: const BoxDecoration(
                  color: Color(0xFFFCFAF6),
                  border: Border(top: BorderSide(color: Color(0xFFF0EBE3))),
                ),
                child: Row(
                  children: const <Widget>[
                    Text(
                      '↑↓ 选择 · Enter 插入 · Esc 收起',
                      style: TextStyle(fontSize: 10, color: AppColors.inkMuted),
                    ),
                    Spacer(),
                    Text(
                      '不会发送',
                      style: TextStyle(
                        fontSize: 10,
                        color: AppColors.accent,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Mobile half-sheet member picker opened on `@` on phone-sized viewports.
Future<GroupMember?> showMentionMemberSheet({
  required BuildContext context,
  required GroupMentionComposerController mentionController,
  required int Function() totalGroupMemberCount,
  required String initialQuery,
  ProfileGateway? profile,
}) {
  return showModalBottomSheet<GroupMember>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (BuildContext sheetContext) {
      return _MentionMemberSheet(
        mentionController: mentionController,
        totalGroupMemberCount: totalGroupMemberCount,
        initialQuery: initialQuery,
        profile: profile,
      );
    },
  );
}

class _MentionMemberSheet extends StatefulWidget {
  const _MentionMemberSheet({
    required this.mentionController,
    required this.totalGroupMemberCount,
    required this.initialQuery,
    this.profile,
  });

  final GroupMentionComposerController mentionController;
  final int Function() totalGroupMemberCount;
  final String initialQuery;
  final ProfileGateway? profile;

  @override
  State<_MentionMemberSheet> createState() => _MentionMemberSheetState();
}

class _MentionMemberSheetState extends State<_MentionMemberSheet> {
  static const Key sheetKey = Key('mention-mobile-sheet');
  static const Key searchKey = Key('mention-mobile-sheet-search');
  static const Key listKey = Key('mention-mobile-sheet-list');
  static const Key emptyKey = Key('mention-mobile-sheet-empty');
  static const Key closeKey = Key('mention-mobile-sheet-close');

  late final TextEditingController _searchController = TextEditingController(
    text: widget.initialQuery,
  );
  late List<GroupMember> _filtered =
      GroupMentionComposerController.filterMembers(
        widget.mentionController.members,
        widget.initialQuery,
      );

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_recomputeFilter);
    widget.mentionController.addListener(_recomputeFilter);
  }

  void _recomputeFilter() {
    if (!mounted) {
      return;
    }
    setState(() {
      _filtered = GroupMentionComposerController.filterMembers(
        widget.mentionController.members,
        _searchController.text,
      );
    });
  }

  @override
  void dispose() {
    _searchController.removeListener(_recomputeFilter);
    widget.mentionController.removeListener(_recomputeFilter);
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final MediaQueryData media = MediaQuery.of(context);
    final int totalCount = widget.totalGroupMemberCount();
    final double targetHeight = math.max(
      340.0,
      math.min(media.size.height * 0.58, media.size.height - 80),
    );
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
        child: SizedBox(
          key: sheetKey,
          height: targetHeight,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Center(
                child: Container(
                  width: 38,
                  height: 4,
                  margin: const EdgeInsets.only(top: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFDCD6CA),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 12, 4),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          const Text(
                            '选择群成员',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                              color: AppColors.ink,
                            ),
                          ),
                          Text(
                            '当前群 · $totalCount 人',
                            style: const TextStyle(
                              fontSize: 10.5,
                              color: AppColors.inkMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      key: closeKey,
                      tooltip: '关闭',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close_rounded, size: 20),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 6, 14, 4),
                child: TextField(
                  key: searchKey,
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText: '搜索群成员（昵称或 BB 号）',
                    prefixIcon: const Icon(Icons.search_rounded, size: 18),
                    isDense: true,
                    filled: true,
                    fillColor: const Color(0xFFFBFAF7),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(11),
                      borderSide: const BorderSide(color: AppColors.border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(11),
                      borderSide: const BorderSide(color: AppColors.border),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: Text(
                  '匹配 ${_filtered.length} 人 · 当前群 $totalCount 人',
                  style: const TextStyle(
                    fontSize: 10.5,
                    color: AppColors.inkMuted,
                  ),
                ),
              ),
              Expanded(
                child: _filtered.isEmpty
                    ? const _MentionPickerEmpty(key: emptyKey)
                    : ListView.builder(
                        key: listKey,
                        padding: const EdgeInsets.fromLTRB(8, 2, 8, 6),
                        itemCount: _filtered.length,
                        itemBuilder: (BuildContext context, int index) {
                          final GroupMember member = _filtered[index];
                          return _MentionCandidateTile(
                            key: Key(
                              'mention-sheet-candidate-${member.account}',
                            ),
                            member: member,
                            query: _searchController.text,
                            active: false,
                            showEnterHint: false,
                            profile: widget.profile,
                            onTap: () => Navigator.of(context).pop(member),
                          );
                        },
                      ),
              ),
              Container(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
                decoration: const BoxDecoration(
                  border: Border(top: BorderSide(color: Color(0xFFF0EBE3))),
                ),
                child: const Text(
                  '点选成员返回输入框 · 草稿不会丢',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 10, color: AppColors.inkMuted),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MentionCandidateTile extends StatelessWidget {
  const _MentionCandidateTile({
    super.key,
    required this.member,
    required this.query,
    required this.active,
    required this.showEnterHint,
    required this.onTap,
    this.profile,
  });

  final GroupMember member;
  final String query;
  final bool active;
  final bool showEnterHint;
  final VoidCallback onTap;
  final ProfileGateway? profile;

  @override
  Widget build(BuildContext context) {
    final bool online = member.presence == Presence.online;
    final ChatUser user = ChatUser(
      account: member.account,
      username: member.username,
      avatarUrl: member.avatarUrl,
      avatarVersion: member.avatarVersion,
      presence: member.presence,
    );
    final Widget avatar = profile != null
        ? UserIdentityAvatar(
            user: user,
            profile: profile!,
            online: online,
            size: 40,
          )
        : Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              color: AppColors.accentDeep,
              shape: BoxShape.circle,
            ),
            child: Text(
              member.username.isEmpty ? '?' : member.username.substring(0, 1),
              style: const TextStyle(
                color: AppColors.surface,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          );

    return Material(
      color: active ? AppColors.accentSoft : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          constraints: const BoxConstraints(minHeight: 56),
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
          child: Row(
            children: <Widget>[
              if (active)
                Container(
                  width: 3,
                  height: 26,
                  margin: const EdgeInsets.only(right: 6),
                  decoration: BoxDecoration(
                    color: AppColors.accent,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              avatar,
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    _HighlightedUsername(
                      username: member.username,
                      query: query,
                    ),
                    const SizedBox(height: 1),
                    Text(
                      'BB号 ${member.account} · ${online ? '在线' : '离线'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 10.5,
                        color: AppColors.inkMuted,
                      ),
                    ),
                  ],
                ),
              ),
              if (active && showEnterHint)
                Container(
                  width: 22,
                  height: 22,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: AppColors.surface.withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: _mentionBannerBorder),
                  ),
                  child: const Icon(
                    Icons.keyboard_return_rounded,
                    size: 13,
                    color: AppColors.accentDeep,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HighlightedUsername extends StatelessWidget {
  const _HighlightedUsername({required this.username, required this.query});

  final String username;
  final String query;

  @override
  Widget build(BuildContext context) {
    final String needle = query.trim().toLowerCase();
    const TextStyle baseStyle = TextStyle(
      fontSize: 13.5,
      fontWeight: FontWeight.w700,
      color: AppColors.ink,
    );
    if (needle.isEmpty) {
      return Text(
        username,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: baseStyle,
      );
    }
    final String lower = username.toLowerCase();
    final int exactStart = lower.indexOf(needle);
    final Set<int> hitRunes = <int>{};
    if (exactStart >= 0) {
      final int prefixRunes = lower.substring(0, exactStart).runes.length;
      final int needleRunes = needle.runes.length;
      for (int i = 0; i < needleRunes; i += 1) {
        hitRunes.add(prefixRunes + i);
      }
    } else {
      final List<int> hRunes = lower.runes.toList(growable: false);
      final List<int> nRunes = needle.runes.toList(growable: false);
      int ni = 0;
      for (int hi = 0; hi < hRunes.length && ni < nRunes.length; hi += 1) {
        if (hRunes[hi] == nRunes[ni]) {
          hitRunes.add(hi);
          ni += 1;
        }
      }
      if (ni != nRunes.length) {
        hitRunes.clear();
      }
    }
    if (hitRunes.isEmpty) {
      return Text(
        username,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: baseStyle,
      );
    }
    final List<int> origRunes = username.runes.toList(growable: false);
    final List<InlineSpan> spans = <InlineSpan>[];
    for (int i = 0; i < origRunes.length; i += 1) {
      final String ch = String.fromCharCode(origRunes[i]);
      spans.add(
        TextSpan(
          text: ch,
          style: hitRunes.contains(i)
              ? baseStyle.copyWith(
                  backgroundColor: _matchHighlightFill,
                  color: AppColors.accentNight,
                  fontWeight: FontWeight.w800,
                )
              : baseStyle,
        ),
      );
    }
    return Text.rich(
      TextSpan(children: spans),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

class _MentionPickerEmpty extends StatelessWidget {
  const _MentionPickerEmpty({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 22, 14, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              color: Color(0xFFF1EDE6),
              shape: BoxShape.circle,
            ),
            child: const Text(
              '@',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: Color(0xFF8B8577),
              ),
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            '没有匹配的群成员',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: AppColors.inkMuted,
            ),
          ),
          const SizedBox(height: 2),
          const Text(
            '只检索当前群成员；不会提醒群外用户。',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 10.5, color: AppColors.inkMuted),
          ),
        ],
      ),
    );
  }
}
