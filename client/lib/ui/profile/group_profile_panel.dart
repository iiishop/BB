import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app.dart';
import '../../models/chat_models.dart';
import '../../models/group_models.dart';
import '../../services/profile_service.dart';
import '../chat/chat_format.dart';
import '../chat/user_identity_row.dart';
import 'profile_details.dart';
import 'profile_panel.dart';

/// UI visibility only. The service still authorizes every read and mutation.
enum GroupProfileRole { visitor, member, owner }

/// Group profile panel implementing DEA-516 Plan A v4 ("成员优先").
class GroupProfilePanel extends StatefulWidget {
  const GroupProfilePanel({
    super.key,
    required this.number,
    required this.name,
    required this.description,
    required this.role,
    this.avatar,
    this.dissolved = false,
    this.canInvite = false,
    this.allowMemberInvites = false,
    this.members = const <GroupMember>[],
    this.memberCounts,
    this.membersLoading = false,
    this.membersError,
    this.profileGateway,
    this.onApply,
    this.onInvite,
    this.onEdit,
    this.onMembers,
    this.onLeave,
    this.onDisband,
    this.onAllowMemberInvitesChanged,
    this.onCopyNumber,
    this.onRetryMembers,
  });

  final String number;
  final String name;
  final String description;
  final Uint8List? avatar;
  final GroupProfileRole role;
  final bool dissolved;
  final bool canInvite;
  final bool allowMemberInvites;
  final List<GroupMember> members;
  final GroupMemberCounts? memberCounts;
  final bool membersLoading;
  final String? membersError;
  final ProfileGateway? profileGateway;
  final VoidCallback? onApply;
  final VoidCallback? onInvite;
  final VoidCallback? onEdit;
  final VoidCallback? onMembers;
  final VoidCallback? onLeave;
  final VoidCallback? onDisband;
  final ValueChanged<bool>? onAllowMemberInvitesChanged;
  final VoidCallback? onCopyNumber;
  final VoidCallback? onRetryMembers;

  static const Key closeButtonKey = ProfileDetails.closeButtonKey;
  static const Key haloKey = Key('group-profile-halo');
  static const Key copyNumberKey = Key('group-profile-copy-number');
  static const Key rolePillKey = Key('group-profile-role-pill');
  static const Key membersCardKey = Key('group-profile-members-card');
  static const Key inviteButtonKey = Key('group-profile-invite-button');
  static const Key inviteLockedNoteKey = Key('group-profile-invite-locked');
  static const Key introToggleKey = Key('group-profile-intro-toggle');
  static const Key editButtonKey = Key('group-profile-edit-button');
  static const Key allowInvitesSwitchKey = Key(
    'group-profile-allow-invites-switch',
  );
  static const Key disbandButtonKey = Key('group-profile-disband-button');
  static const Key leaveButtonKey = Key('group-profile-leave-button');
  static const Key dissolvedBannerKey = Key('group-profile-dissolved-banner');

  @override
  State<GroupProfilePanel> createState() => _GroupProfilePanelState();
}

class _GroupProfilePanelState extends State<GroupProfilePanel>
    with SingleTickerProviderStateMixin {
  static const Cubic _easeOutExpo = Cubic(0.16, 1, 0.3, 1);
  static const Cubic _facepileCurve = Cubic(0.2, 0.9, 0.3, 1);

  late final AnimationController _entrance = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  bool _entranceStarted = false;
  bool _descriptionExpanded = false;
  bool _copied = false;
  Timer? _copyResetTimer;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bool reducedMotion = MediaQuery.disableAnimationsOf(context);
    if (!_entranceStarted) {
      _entranceStarted = true;
      if (reducedMotion) {
        _entrance.value = 1.0;
      } else {
        unawaited(_entrance.forward(from: 0));
      }
    } else if (reducedMotion && _entrance.value < 1.0) {
      _entrance.value = 1.0;
    }
  }

  @override
  void didUpdateWidget(covariant GroupProfilePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.number != widget.number) {
      _descriptionExpanded = false;
      _copied = false;
      _copyResetTimer?.cancel();
    } else if (oldWidget.description != widget.description) {
      _descriptionExpanded = false;
    }
  }

  @override
  void dispose() {
    _copyResetTimer?.cancel();
    _entrance.dispose();
    super.dispose();
  }

  double _interval(double begin, double end, {Curve curve = _easeOutExpo}) {
    final double raw = ((_entrance.value - begin) / (end - begin)).clamp(
      0.0,
      1.0,
    );
    return curve.transform(raw);
  }

  Widget _fadeRise({
    required double begin,
    required double end,
    required double dy,
    required bool reducedMotion,
    double minScale = 1.0,
    Curve curve = _easeOutExpo,
    required Widget child,
  }) {
    if (reducedMotion) {
      return child;
    }
    final double t = _interval(begin, end, curve: curve);
    Widget result = Opacity(
      opacity: t,
      child: Transform.translate(offset: Offset(0, (1 - t) * dy), child: child),
    );
    if (minScale < 1.0) {
      result = Transform.scale(
        scale: minScale + (1 - minScale) * t,
        child: result,
      );
    }
    return result;
  }

  void _copyNumber() {
    unawaited(Clipboard.setData(ClipboardData(text: widget.number)));
    widget.onCopyNumber?.call();
    setState(() => _copied = true);
    _copyResetTimer?.cancel();
    _copyResetTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) {
        setState(() => _copied = false);
      }
    });
    final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(
      context,
    );
    if (messenger != null) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('群号已复制')));
    }
  }

  int? get _totalMemberCount {
    if (widget.memberCounts != null) {
      return widget.memberCounts!.total;
    }
    if (widget.members.isNotEmpty) {
      return widget.members.length;
    }
    return null;
  }

  int? get _onlineMemberCount {
    if (widget.memberCounts != null) {
      return widget.memberCounts!.online;
    }
    if (widget.members.isNotEmpty) {
      return widget.members
          .where((GroupMember m) => m.presence == Presence.online)
          .length;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final ProfilePanelMode mode = resolveProfilePanelMode(context);
    final bool reducedMotion = MediaQuery.disableAnimationsOf(context);
    final double horizontalPadding = MediaQuery.sizeOf(context).width < 420
        ? 22
        : 24;

    return Material(
      color: AppColors.paper,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _GroupPanelTopBar(
            title: '群资料',
            mode: mode,
            onBack: () => Navigator.of(context).pop(),
          ),
          Expanded(
            child: AnimatedBuilder(
              animation: _entrance,
              builder: (BuildContext context, Widget? _) {
                final double haloOuterT = reducedMotion
                    ? 1.0
                    : _interval(0.0, 1.0);
                final double haloInnerT = reducedMotion
                    ? 1.0
                    : _interval(80 / 900, 880 / 900);

                return ListView(
                  padding: EdgeInsets.fromLTRB(
                    horizontalPadding,
                    6,
                    horizontalPadding,
                    28,
                  ),
                  children: <Widget>[
                    _fadeRise(
                      begin: 0.0,
                      end: 520 / 900,
                      dy: 12,
                      reducedMotion: reducedMotion,
                      child: _IdentityHeader(
                        name: widget.name,
                        number: widget.number,
                        avatar: widget.avatar,
                        role: widget.role,
                        dissolved: widget.dissolved,
                        totalMembers: widget.dissolved
                            ? null
                            : _totalMemberCount,
                        copied: _copied,
                        reducedMotion: reducedMotion,
                        haloOuterT: haloOuterT,
                        haloInnerT: haloInnerT,
                        onCopyNumber: _copyNumber,
                      ),
                    ),
                    if (widget.dissolved)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: _fadeRise(
                          begin: 50 / 900,
                          end: 470 / 900,
                          dy: 12,
                          reducedMotion: reducedMotion,
                          child: const _DissolvedBanner(),
                        ),
                      ),
                    if (!widget.dissolved &&
                        widget.role == GroupProfileRole.visitor)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: _fadeRise(
                          begin: 60 / 900,
                          end: 560 / 900,
                          dy: 14,
                          minScale: 0.985,
                          reducedMotion: reducedMotion,
                          child: FilledButton(
                            onPressed: widget.onApply,
                            child: const Text('申请加入'),
                          ),
                        ),
                      ),
                    if (!widget.dissolved &&
                        widget.role != GroupProfileRole.visitor)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: _fadeRise(
                          begin: 60 / 900,
                          end: 560 / 900,
                          dy: 14,
                          minScale: 0.985,
                          reducedMotion: reducedMotion,
                          child: _MemberSummaryCard(
                            members: widget.members,
                            totalCount: _totalMemberCount,
                            onlineCount: _onlineMemberCount,
                            loading: widget.membersLoading,
                            error: widget.membersError,
                            canInvite:
                                widget.role == GroupProfileRole.owner ||
                                widget.canInvite,
                            profileGateway: widget.profileGateway,
                            reducedMotion: reducedMotion,
                            entranceValue: _entrance.value,
                            facepileCurve: _facepileCurve,
                            onOpenMembers: widget.onMembers,
                            onInvite: widget.onInvite,
                            onRetry: widget.onRetryMembers,
                          ),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.only(top: 24),
                      child: _fadeRise(
                        begin: 120 / 900,
                        end: 600 / 900,
                        dy: 12,
                        reducedMotion: reducedMotion,
                        child: _GroupIntroSection(
                          description: widget.description,
                          expanded: _descriptionExpanded,
                          reducedMotion: reducedMotion,
                          onToggle: () => setState(
                            () => _descriptionExpanded = !_descriptionExpanded,
                          ),
                        ),
                      ),
                    ),
                    if (!widget.dissolved &&
                        widget.role == GroupProfileRole.owner)
                      Padding(
                        padding: const EdgeInsets.only(top: 26),
                        child: _fadeRise(
                          begin: 160 / 900,
                          end: 640 / 900,
                          dy: 12,
                          reducedMotion: reducedMotion,
                          child: _OwnerManageSection(
                            allowMemberInvites: widget.allowMemberInvites,
                            reducedMotion: reducedMotion,
                            onEdit: widget.onEdit,
                            onAllowMemberInvitesChanged:
                                widget.onAllowMemberInvitesChanged,
                            onDisband: widget.onDisband,
                          ),
                        ),
                      ),
                    if (!widget.dissolved &&
                        widget.role == GroupProfileRole.member)
                      Padding(
                        padding: const EdgeInsets.only(top: 28, bottom: 6),
                        child: _fadeRise(
                          begin: 160 / 900,
                          end: 640 / 900,
                          dy: 12,
                          reducedMotion: reducedMotion,
                          child: _LeaveGroupButton(
                            reducedMotion: reducedMotion,
                            onPressed: widget.onLeave,
                          ),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.only(top: 16, bottom: 4),
                      child: _fadeRise(
                        begin: 200 / 900,
                        end: 620 / 900,
                        dy: 12,
                        reducedMotion: reducedMotion,
                        child: _RoleFootnote(
                          role: widget.role,
                          dissolved: widget.dissolved,
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _GroupPanelTopBar extends StatelessWidget {
  const _GroupPanelTopBar({
    required this.title,
    required this.mode,
    required this.onBack,
  });

  final String title;
  final ProfilePanelMode mode;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 56,
      color: AppColors.paper,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          Align(
            alignment: Alignment.centerLeft,
            child: ActionIconTheme(
              data: ActionIconThemeData(
                closeButtonIconBuilder: (BuildContext context) => Icon(
                  mode == ProfilePanelMode.desktop
                      ? Icons.close_rounded
                      : Icons.arrow_back_rounded,
                  size: 21,
                  color: AppColors.ink,
                ),
              ),
              child: CloseButton(
                key: GroupProfilePanel.closeButtonKey,
                onPressed: onBack,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 52),
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 16.5,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.1,
                color: AppColors.ink,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _IdentityHeader extends StatelessWidget {
  const _IdentityHeader({
    required this.name,
    required this.number,
    required this.avatar,
    required this.role,
    required this.dissolved,
    required this.totalMembers,
    required this.copied,
    required this.reducedMotion,
    required this.haloOuterT,
    required this.haloInnerT,
    required this.onCopyNumber,
  });

  final String name;
  final String number;
  final Uint8List? avatar;
  final GroupProfileRole role;
  final bool dissolved;
  final int? totalMembers;
  final bool copied;
  final bool reducedMotion;
  final double haloOuterT;
  final double haloInnerT;
  final VoidCallback onCopyNumber;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 18),
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Positioned(
            left: -26,
            top: -22,
            width: 330,
            height: 132,
            child: IgnorePointer(
              child: Opacity(
                key: GroupProfilePanel.haloKey,
                opacity: haloOuterT,
                child: Transform.scale(
                  scale: 0.9 + 0.1 * haloOuterT,
                  child: const DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.all(
                        Radius.elliptical(165, 66),
                      ),
                      gradient: RadialGradient(
                        center: Alignment(-0.66, -0.12),
                        radius: 0.86,
                        colors: <Color>[
                          Color(0xFAE6F0EE),
                          Color(0x8FE6F0EE),
                          Color(0x00E6F0EE),
                        ],
                        stops: <double>[0.0, 0.46, 0.76],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: -11,
            top: -11,
            width: 78,
            height: 78,
            child: IgnorePointer(
              child: Opacity(
                opacity: haloInnerT,
                child: Transform.scale(
                  scale: 0.9 + 0.1 * haloInnerT,
                  child: const DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: <Color>[
                          Color(0x4D0E6F68),
                          Color(0x1F0E6F68),
                          Color(0x000E6F68),
                        ],
                        stops: <double>[0.0, 0.44, 0.72],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              GroupAvatarBadge(
                bytes: avatar,
                size: 56,
                semanticLabel: '$name群头像',
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 22,
                        height: 1.25,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.3,
                        color: AppColors.ink,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 7,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: <Widget>[
                        _CopyNumberButton(
                          number: number,
                          copied: copied,
                          reducedMotion: reducedMotion,
                          onTap: onCopyNumber,
                        ),
                        if (totalMembers != null) ...<Widget>[
                          const _DotSeparator(),
                          Text(
                            '$totalMembers 位成员',
                            style: const TextStyle(
                              fontSize: 12.5,
                              height: 1.5,
                              color: AppColors.inkMuted,
                            ),
                          ),
                        ],
                        _RolePill(role: role, dissolved: dissolved),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Group circular avatar: shows fetched group image bytes when available,
/// otherwise renders the deep-teal crescent-and-waves emblem from DEA-516.
class GroupAvatarBadge extends StatelessWidget {
  const GroupAvatarBadge({
    super.key,
    required this.bytes,
    this.size = 56,
    this.semanticLabel,
  });

  final Uint8List? bytes;
  final double size;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final Uint8List? raw = bytes;
    final Widget inner = (raw != null && raw.isNotEmpty)
        ? Image.memory(
            raw,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            filterQuality: FilterQuality.medium,
            errorBuilder: (_, _, _) => const _GroupEmblemArt(),
          )
        : const _GroupEmblemArt();

    final Widget avatar = Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Color(0x3D073B37),
            blurRadius: 24,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: ClipOval(
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            inner,
            IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0x24F7F5F1), width: 1),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    if (semanticLabel == null) {
      return avatar;
    }
    return Semantics(image: true, label: semanticLabel, child: avatar);
  }
}

class _GroupEmblemArt extends StatelessWidget {
  const _GroupEmblemArt();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment(-0.7, -0.9),
          end: Alignment(0.8, 0.9),
          colors: <Color>[
            Color(0xFF127A71),
            AppColors.accent,
            AppColors.accentNight,
          ],
          stops: <double>[0.0, 0.46, 1.0],
        ),
      ),
      child: const CustomPaint(painter: _GroupEmblemPainter()),
    );
  }
}

class _GroupEmblemPainter extends CustomPainter {
  const _GroupEmblemPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final double scale = size.shortestSide / 96.0;
    canvas.save();
    canvas.scale(scale);

    canvas.drawCircle(
      const Offset(48, 48),
      33,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = AppColors.paper.withValues(alpha: 0.22),
    );

    final Path moonOuter = Path()
      ..addOval(Rect.fromCircle(center: const Offset(48, 46), radius: 22));
    final Path moonCut = Path()
      ..addOval(Rect.fromCircle(center: const Offset(59, 38), radius: 21));
    final Path crescent = Path.combine(
      PathOperation.difference,
      moonOuter,
      moonCut,
    );
    canvas.drawPath(
      crescent,
      Paint()..color = AppColors.paper.withValues(alpha: 0.92),
    );

    canvas.drawCircle(
      const Offset(67, 31),
      2.2,
      Paint()..color = AppColors.paper.withValues(alpha: 0.9),
    );
    canvas.drawCircle(
      const Offset(73, 40),
      1.3,
      Paint()..color = AppColors.paper.withValues(alpha: 0.66),
    );

    final Path wave = Path()
      ..moveTo(22, 66)
      ..quadraticBezierTo(34, 60, 46, 66)
      ..quadraticBezierTo(58, 72, 70, 66);
    canvas.drawPath(
      wave,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 1.4
        ..color = AppColors.paper.withValues(alpha: 0.28),
    );

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _GroupEmblemPainter oldDelegate) => false;
}

class _CopyNumberButton extends StatefulWidget {
  const _CopyNumberButton({
    required this.number,
    required this.copied,
    required this.reducedMotion,
    required this.onTap,
  });

  final String number;
  final bool copied;
  final bool reducedMotion;
  final VoidCallback onTap;

  @override
  State<_CopyNumberButton> createState() => _CopyNumberButtonState();
}

class _CopyNumberButtonState extends State<_CopyNumberButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final bool active = widget.copied || _hovered;
    final Duration duration = widget.reducedMotion
        ? Duration.zero
        : const Duration(milliseconds: 150);

    return Semantics(
      button: true,
      label: '复制群号 ${widget.number}',
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            key: GroupProfilePanel.copyNumberKey,
            onTap: widget.onTap,
            borderRadius: BorderRadius.circular(9),
            child: AnimatedContainer(
              duration: duration,
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: active ? AppColors.accentSoft : Colors.transparent,
                borderRadius: BorderRadius.circular(9),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Flexible(
                    child: Text(
                      '群号 ${widget.number}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.4,
                        color: active
                            ? AppColors.accentDeep
                            : AppColors.inkMuted,
                        fontFeatures: const <FontFeature>[
                          FontFeature.tabularFigures(),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  AnimatedSwitcher(
                    duration: widget.reducedMotion
                        ? Duration.zero
                        : const Duration(milliseconds: 160),
                    transitionBuilder: (Widget child, Animation<double> anim) {
                      if (widget.reducedMotion) {
                        return child;
                      }
                      return FadeTransition(
                        opacity: anim,
                        child: ScaleTransition(
                          scale: Tween<double>(
                            begin: 0.72,
                            end: 1.0,
                          ).animate(anim),
                          child: child,
                        ),
                      );
                    },
                    child: Icon(
                      widget.copied ? Icons.check_rounded : Icons.copy_rounded,
                      key: ValueKey<bool>(widget.copied),
                      size: 13,
                      color: active ? AppColors.accentDeep : AppColors.inkMuted,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DotSeparator extends StatelessWidget {
  const _DotSeparator();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      width: 3,
      height: 3,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Color(0xFFBDB6A9),
        ),
      ),
    );
  }
}

class _RolePill extends StatelessWidget {
  const _RolePill({required this.role, required this.dissolved});

  final GroupProfileRole role;
  final bool dissolved;

  @override
  Widget build(BuildContext context) {
    final String label = dissolved
        ? '已解散'
        : switch (role) {
            GroupProfileRole.owner => '群主',
            GroupProfileRole.member => '成员',
            GroupProfileRole.visitor => '未入群',
          };
    final bool muted = dissolved || role == GroupProfileRole.visitor;
    return Container(
      key: GroupProfilePanel.rolePillKey,
      constraints: const BoxConstraints(minHeight: 20),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: muted ? const Color(0xFFEFEAE0) : AppColors.accentSoft,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
          color: muted ? const Color(0xFF6E675C) : AppColors.accentDeep,
        ),
      ),
    );
  }
}

class _DissolvedBanner extends StatelessWidget {
  const _DissolvedBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      key: GroupProfilePanel.dissolvedBannerKey,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFEFEAE0),
        borderRadius: BorderRadius.circular(14),
      ),
      child: const Row(
        children: <Widget>[
          Icon(Icons.info_outline_rounded, size: 16, color: Color(0xFF8B8375)),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              '该群已解散',
              style: TextStyle(
                fontSize: 13,
                height: 1.5,
                color: Color(0xFF6E675C),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MemberSummaryCard extends StatelessWidget {
  const _MemberSummaryCard({
    required this.members,
    required this.totalCount,
    required this.onlineCount,
    required this.loading,
    required this.error,
    required this.canInvite,
    required this.profileGateway,
    required this.reducedMotion,
    required this.entranceValue,
    required this.facepileCurve,
    required this.onOpenMembers,
    required this.onInvite,
    required this.onRetry,
  });

  final List<GroupMember> members;
  final int? totalCount;
  final int? onlineCount;
  final bool loading;
  final String? error;
  final bool canInvite;
  final ProfileGateway? profileGateway;
  final bool reducedMotion;
  final double entranceValue;
  final Curve facepileCurve;
  final VoidCallback? onOpenMembers;
  final VoidCallback? onInvite;
  final VoidCallback? onRetry;

  String _presenceLine() {
    if (error != null && members.isEmpty && onlineCount == null) {
      return '成员状态加载失败';
    }
    if (onlineCount == null && loading) {
      return '正在同步成员在线状态…';
    }
    final int online = onlineCount ?? 0;
    if (online == 0) {
      return members.isEmpty && onlineCount == null ? '查看全部群成员' : '暂时没有人在线';
    }
    final List<GroupMember> onlineMembers = members
        .where((GroupMember m) => m.presence == Presence.online)
        .toList(growable: false);
    final List<GroupMember> namedPool = onlineMembers
        .where((GroupMember m) => m.role != GroupRole.owner)
        .toList(growable: false);
    final List<String> names =
        (namedPool.isNotEmpty ? namedPool : onlineMembers)
            .take(3)
            .map((GroupMember m) => m.username)
            .toList(growable: false);
    if (names.isEmpty) {
      return '$online 人在线';
    }
    final int shownAndOwner =
        names.length +
        (onlineMembers.any((GroupMember m) => m.role == GroupRole.owner) &&
                namedPool.isNotEmpty
            ? 1
            : 0);
    final String suffix = online > shownAndOwner ? ' 等' : '';
    return '$online 人在线 · ${names.join('、')}$suffix';
  }

  @override
  Widget build(BuildContext context) {
    final int? total = totalCount;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x11161D1E),
            blurRadius: 28,
            offset: Offset(0, 12),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _InteractiveRowSurface(
            key: GroupProfilePanel.membersCardKey,
            semanticLabel: total != null ? '查看全部群成员，共 $total 人' : '查看全部群成员',
            reducedMotion: reducedMotion,
            onTap: onOpenMembers,
            hoverColor: const Color(0xFFFBFAF7),
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(AppRadius.card),
            ),
            builder: (BuildContext context, bool hovered) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 15, 16, 13),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: Wrap(
                            spacing: 6,
                            runSpacing: 2,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: <Widget>[
                              const Text(
                                '群成员',
                                style: TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 1.4,
                                  height: 1.4,
                                  color: AppColors.inkMuted,
                                ),
                              ),
                              if (total != null)
                                Text(
                                  '$total 人',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFF66716E),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            const Text(
                              '全部',
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                                color: AppColors.accentDeep,
                              ),
                            ),
                            const SizedBox(width: 2),
                            _SlidingChevron(
                              hovered: hovered,
                              reducedMotion: reducedMotion,
                              color: AppColors.accentDeep,
                              size: 16,
                            ),
                          ],
                        ),
                      ],
                    ),
                    if (members.isNotEmpty || loading) ...<Widget>[
                      const SizedBox(height: 14),
                      _MemberFacepile(
                        members: members,
                        totalCount: total ?? members.length,
                        loading: loading,
                        profileGateway: profileGateway,
                        reducedMotion: reducedMotion,
                        entranceValue: entranceValue,
                        facepileCurve: facepileCurve,
                      ),
                      const SizedBox(height: 9),
                    ] else
                      const SizedBox(height: 10),
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            _presenceLine(),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12,
                              height: 1.5,
                              color: AppColors.inkMuted,
                            ),
                          ),
                        ),
                        if (error != null && members.isEmpty && onRetry != null)
                          TextButton(
                            onPressed: onRetry,
                            style: TextButton.styleFrom(
                              minimumSize: const Size(0, 32),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                            ),
                            child: const Text(
                              '重试',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
          const Divider(height: 1, thickness: 1, color: Color(0xFFF0ECE5)),
          if (canInvite)
            _InteractiveRowSurface(
              key: GroupProfilePanel.inviteButtonKey,
              reducedMotion: reducedMotion,
              onTap: onInvite,
              hoverColor: const Color(0xFFF6FBF9),
              builder: (BuildContext context, bool hovered) {
                return ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 50),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: <Widget>[
                        Container(
                          width: 22,
                          height: 22,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: AppColors.accentSoft,
                          ),
                          child: const Icon(
                            Icons.add_rounded,
                            size: 14,
                            color: AppColors.accentDeep,
                          ),
                        ),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Text(
                            '邀请用户',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: AppColors.accentDeep,
                            ),
                          ),
                        ),
                        _SlidingChevron(
                          hovered: hovered,
                          reducedMotion: reducedMotion,
                          color: const Color(0xFF7E8783),
                          size: 16,
                        ),
                      ],
                    ),
                  ),
                );
              },
            )
          else
            ConstrainedBox(
              key: GroupProfilePanel.inviteLockedNoteKey,
              constraints: const BoxConstraints(minHeight: 50),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: <Widget>[
                    Icon(
                      Icons.lock_outline_rounded,
                      size: 13,
                      color: Color(0xFF7D8784),
                    ),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '群主已关闭成员邀请',
                        style: TextStyle(
                          fontSize: 12,
                          color: Color(0xFF7D8784),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _MemberFacepile extends StatelessWidget {
  const _MemberFacepile({
    required this.members,
    required this.totalCount,
    required this.loading,
    required this.profileGateway,
    required this.reducedMotion,
    required this.entranceValue,
    required this.facepileCurve,
  });

  final List<GroupMember> members;
  final int totalCount;
  final bool loading;
  final ProfileGateway? profileGateway;
  final bool reducedMotion;
  final double entranceValue;
  final Curve facepileCurve;

  double _avatarAnim(int index) {
    if (reducedMotion) {
      return 1.0;
    }
    final double begin = (120 + index * 40) / 900;
    final double end = (begin + 380 / 900).clamp(begin + 0.01, 1.0);
    final double raw = ((entranceValue - begin) / (end - begin)).clamp(
      0.0,
      1.0,
    );
    return facepileCurve.transform(raw);
  }

  @override
  Widget build(BuildContext context) {
    if (members.isEmpty && loading) {
      return SizedBox(
        height: 40,
        width: 40 + 2 * 29.0,
        child: Stack(
          children: <Widget>[
            for (int i = 0; i < 3; i += 1)
              Positioned(
                left: i * 29.0,
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFFEDE9E1),
                    border: Border.all(color: AppColors.surface, width: 2),
                  ),
                ),
              ),
          ],
        ),
      );
    }

    final List<GroupMember> shown = members.take(5).toList(growable: false);
    final int extra = math.max(0, totalCount - shown.length);
    final int itemCount = shown.length + (extra > 0 ? 1 : 0);
    if (itemCount == 0) {
      return const SizedBox.shrink();
    }

    return SizedBox(
      height: 40,
      width: 40 + (itemCount - 1) * 30.0,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          for (int i = 0; i < shown.length; i += 1)
            Positioned(
              left: i * 30.0,
              child: _animatedSlot(
                index: i,
                child: _FacepileMemberAvatar(
                  member: shown[i],
                  profileGateway: profileGateway,
                ),
              ),
            ),
          if (extra > 0)
            Positioned(
              left: shown.length * 30.0,
              child: _animatedSlot(
                index: shown.length,
                child: Container(
                  width: 40,
                  height: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.accentSoft,
                    border: Border.all(color: AppColors.surface, width: 2),
                    boxShadow: const <BoxShadow>[
                      BoxShadow(
                        color: Color(0x1A161D1E),
                        blurRadius: 4,
                        offset: Offset(0, 1),
                      ),
                    ],
                  ),
                  child: Text(
                    '+$extra',
                    style: const TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.2,
                      color: AppColors.accentDeep,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _animatedSlot({required int index, required Widget child}) {
    if (reducedMotion) {
      return child;
    }
    final double t = _avatarAnim(index);
    return Opacity(
      opacity: t,
      child: Transform.scale(scale: 0.78 + 0.22 * t, child: child),
    );
  }
}

class _FacepileMemberAvatar extends StatelessWidget {
  const _FacepileMemberAvatar({
    required this.member,
    required this.profileGateway,
  });

  final GroupMember member;
  final ProfileGateway? profileGateway;

  static const List<({Color bg, Color fg})> _palette = <({Color bg, Color fg})>[
    (bg: Color(0xFFE9DFCF), fg: Color(0xFF6D5637)),
    (bg: Color(0xFFDCE8E2), fg: Color(0xFF2E5C4B)),
    (bg: Color(0xFFE6E1EC), fg: Color(0xFF554A66)),
    (bg: Color(0xFFEFE0D7), fg: Color(0xFF7A4C34)),
    (bg: Color(0xFFDDE4EE), fg: Color(0xFF3C526E)),
    (bg: Color(0xFFE7E8D8), fg: Color(0xFF5A5C32)),
    (bg: Color(0xFFEDDFE4), fg: Color(0xFF6E4453)),
    (bg: Color(0xFFDCEDE9), fg: Color(0xFF2E5E58)),
  ];

  @override
  Widget build(BuildContext context) {
    final bool online = member.presence == Presence.online;
    final ({Color bg, Color fg}) tint =
        _palette[member.account.hashCode.abs() % _palette.length];
    final ChatUser user = ChatUser(
      account: member.account,
      username: member.username,
      avatarUrl: member.avatarUrl,
      avatarVersion: member.avatarVersion,
      presence: member.presence,
    );

    final Widget circle = profileGateway != null
        ? UserIdentityAvatar(
            user: user,
            profile: profileGateway!,
            online: false,
            size: 36,
          )
        : Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(shape: BoxShape.circle, color: tint.bg),
            child: Text(
              initialsOf(member.username),
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
                color: tint.fg,
              ),
            ),
          );

    return SizedBox(
      width: 40,
      height: 40,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Container(
            width: 40,
            height: 40,
            padding: const EdgeInsets.all(2),
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.surface,
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: Color(0x1A161D1E),
                  blurRadius: 4,
                  offset: Offset(0, 1),
                ),
              ],
            ),
            child: ClipOval(child: circle),
          ),
          if (online)
            Positioned(
              right: 8,
              bottom: -1,
              child: Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: AppColors.success,
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.surface, width: 2),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _GroupIntroSection extends StatelessWidget {
  const _GroupIntroSection({
    required this.description,
    required this.expanded,
    required this.reducedMotion,
    required this.onToggle,
  });

  final String description;
  final bool expanded;
  final bool reducedMotion;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final String trimmed = description.trim();
    const TextStyle bodyStyle = TextStyle(
      fontSize: 15.5,
      height: 1.72,
      color: AppColors.ink,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Text(
          '群介绍',
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.4,
            height: 1.4,
            color: AppColors.inkMuted,
          ),
        ),
        const SizedBox(height: 7),
        if (trimmed.isEmpty)
          const Text(
            '暂无介绍',
            style: TextStyle(
              fontSize: 14.5,
              height: 1.6,
              color: Color(0xFF66716E),
              fontStyle: FontStyle.italic,
            ),
          )
        else
          LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final TextDirection direction = Directionality.of(context);
              final TextScaler scaler = MediaQuery.textScalerOf(context);
              final TextPainter collapsedPainter = TextPainter(
                text: TextSpan(text: trimmed, style: bodyStyle),
                maxLines: 3,
                textDirection: direction,
                textScaler: scaler,
              )..layout(maxWidth: constraints.maxWidth);
              final bool overflows = collapsedPainter.didExceedMaxLines;
              final TextPainter expandedPainter = TextPainter(
                text: TextSpan(text: trimmed, style: bodyStyle),
                textDirection: direction,
                textScaler: scaler,
              )..layout(maxWidth: constraints.maxWidth);

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  _CollapsibleIntroBody(
                    text: trimmed,
                    style: bodyStyle,
                    overflows: overflows,
                    expanded: expanded,
                    reducedMotion: reducedMotion,
                    collapsedHeight: collapsedPainter.height,
                    expandedHeight: expandedPainter.height,
                  ),
                  if (overflows)
                    Semantics(
                      button: true,
                      toggled: expanded,
                      child: InkWell(
                        key: GroupProfilePanel.introToggleKey,
                        onTap: onToggle,
                        borderRadius: BorderRadius.circular(8),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Text(
                                expanded ? '收起' : '展开',
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.accentDeep,
                                ),
                              ),
                              const SizedBox(width: 4),
                              AnimatedRotation(
                                turns: expanded ? 0.5 : 0.0,
                                duration: reducedMotion
                                    ? Duration.zero
                                    : const Duration(milliseconds: 240),
                                curve: const Cubic(0.22, 0.8, 0.24, 1),
                                child: const Icon(
                                  Icons.keyboard_arrow_down_rounded,
                                  size: 16,
                                  color: AppColors.accentDeep,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
      ],
    );
  }
}

class _CollapsibleIntroBody extends StatefulWidget {
  const _CollapsibleIntroBody({
    required this.text,
    required this.style,
    required this.overflows,
    required this.expanded,
    required this.reducedMotion,
    required this.collapsedHeight,
    required this.expandedHeight,
  });

  final String text;
  final TextStyle style;
  final bool overflows;
  final bool expanded;
  final bool reducedMotion;
  final double collapsedHeight;
  final double expandedHeight;

  @override
  State<_CollapsibleIntroBody> createState() => _CollapsibleIntroBodyState();
}

class _CollapsibleIntroBodyState extends State<_CollapsibleIntroBody>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
    value: widget.expanded ? 1.0 : 0.0,
  );
  late final Animation<double> _curved = CurvedAnimation(
    parent: _controller,
    curve: const Cubic(0.22, 0.8, 0.24, 1),
  );

  @override
  void didUpdateWidget(covariant _CollapsibleIntroBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.expanded != widget.expanded ||
        oldWidget.reducedMotion != widget.reducedMotion) {
      if (widget.reducedMotion) {
        _controller.value = widget.expanded ? 1.0 : 0.0;
      } else if (widget.expanded) {
        unawaited(_controller.forward());
      } else {
        unawaited(_controller.reverse());
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.overflows) {
      return SelectableText(widget.text, style: widget.style);
    }
    return AnimatedBuilder(
      animation: _controller,
      builder: (BuildContext context, Widget? _) {
        final double t = _curved.value;
        if (t <= 0.0) {
          return SelectableText(widget.text, style: widget.style, maxLines: 3);
        }
        if (t >= 1.0) {
          return SelectableText(widget.text, style: widget.style);
        }
        final double height = lerpDouble(
          widget.collapsedHeight,
          widget.expandedHeight,
          t,
        )!;
        return ClipRect(
          child: SizedBox(
            height: height,
            width: double.infinity,
            child: OverflowBox(
              alignment: Alignment.topLeft,
              minHeight: 0,
              maxHeight: double.infinity,
              child: SelectableText(widget.text, style: widget.style),
            ),
          ),
        );
      },
    );
  }
}

class _OwnerManageSection extends StatelessWidget {
  const _OwnerManageSection({
    required this.allowMemberInvites,
    required this.reducedMotion,
    required this.onEdit,
    required this.onAllowMemberInvitesChanged,
    required this.onDisband,
  });

  final bool allowMemberInvites;
  final bool reducedMotion;
  final VoidCallback? onEdit;
  final ValueChanged<bool>? onAllowMemberInvitesChanged;
  final VoidCallback? onDisband;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const Text(
          '群主管理',
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.4,
            height: 1.4,
            color: AppColors.inkMuted,
          ),
        ),
        const SizedBox(height: 9),
        Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(AppRadius.card),
            boxShadow: const <BoxShadow>[
              BoxShadow(
                color: Color(0x11161D1E),
                blurRadius: 28,
                offset: Offset(0, 12),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: <Widget>[
              _ManageActionRow(
                key: GroupProfilePanel.editButtonKey,
                icon: Icons.edit_outlined,
                label: '编辑群资料',
                subtitle: '群名称、群介绍与头像入口',
                reducedMotion: reducedMotion,
                showChevron: true,
                onTap: onEdit,
              ),
              const Divider(height: 1, thickness: 1, color: Color(0xFFF0ECE5)),
              _ManageSwitchRow(
                key: GroupProfilePanel.allowInvitesSwitchKey,
                icon: Icons.group_add_outlined,
                label: '允许所有成员邀请',
                subtitle: '关闭后，只有群主可以邀请用户',
                value: allowMemberInvites,
                reducedMotion: reducedMotion,
                onChanged: onAllowMemberInvitesChanged,
              ),
              const Divider(height: 1, thickness: 1, color: Color(0xFFF0ECE5)),
              _ManageActionRow(
                key: GroupProfilePanel.disbandButtonKey,
                icon: Icons.delete_outline_rounded,
                label: '解散群聊',
                subtitle: '所有成员将无法再收发消息',
                destructive: true,
                reducedMotion: reducedMotion,
                showChevron: false,
                onTap: onDisband,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ManageActionRow extends StatelessWidget {
  const _ManageActionRow({
    super.key,
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.reducedMotion,
    required this.showChevron,
    this.destructive = false,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final String subtitle;
  final bool reducedMotion;
  final bool showChevron;
  final bool destructive;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return _InteractiveRowSurface(
      reducedMotion: reducedMotion,
      onTap: onTap,
      hoverColor: destructive
          ? AppColors.dangerSurface.withValues(alpha: 0.45)
          : const Color(0xFFFBFAF7),
      builder: (BuildContext context, bool hovered) {
        return ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 58),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: <Widget>[
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: destructive
                        ? AppColors.dangerSurface
                        : const Color(0xFFF4F1EA),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    icon,
                    size: 16,
                    color: destructive
                        ? AppColors.danger
                        : const Color(0xFF6C7673),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        label,
                        style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w500,
                          height: 1.35,
                          color: destructive ? AppColors.danger : AppColors.ink,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: const TextStyle(
                          fontSize: 11.5,
                          height: 1.45,
                          color: Color(0xFF66716E),
                        ),
                      ),
                    ],
                  ),
                ),
                if (showChevron) ...<Widget>[
                  const SizedBox(width: 8),
                  _SlidingChevron(
                    hovered: hovered,
                    reducedMotion: reducedMotion,
                    color: const Color(0xFF7E8783),
                    size: 16,
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ManageSwitchRow extends StatelessWidget {
  const _ManageSwitchRow({
    super.key,
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.value,
    required this.reducedMotion,
    required this.onChanged,
  });

  final IconData icon;
  final String label;
  final String subtitle;
  final bool value;
  final bool reducedMotion;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      toggled: value,
      label: label,
      enabled: onChanged != null,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onChanged == null ? null : () => onChanged!(!value),
          hoverColor: const Color(0xFFFBFAF7),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 58),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: <Widget>[
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: const Color(0xFFF4F1EA),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(icon, size: 16, color: const Color(0xFF6C7673)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          label,
                          style: const TextStyle(
                            fontSize: 14.5,
                            fontWeight: FontWeight.w500,
                            height: 1.35,
                            color: AppColors.ink,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          style: const TextStyle(
                            fontSize: 11.5,
                            height: 1.45,
                            color: Color(0xFF66716E),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  _SpringPillSwitch(
                    value: value,
                    enabled: onChanged != null,
                    reducedMotion: reducedMotion,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SpringPillSwitch extends StatelessWidget {
  const _SpringPillSwitch({
    required this.value,
    required this.enabled,
    required this.reducedMotion,
  });

  final bool value;
  final bool enabled;
  final bool reducedMotion;

  @override
  Widget build(BuildContext context) {
    final Duration duration = reducedMotion
        ? Duration.zero
        : const Duration(milliseconds: 220);
    return Opacity(
      opacity: enabled ? 1.0 : 0.55,
      child: AnimatedContainer(
        duration: duration,
        curve: Curves.easeOut,
        width: 46,
        height: 28,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: value ? AppColors.accent : const Color(0xFFD8D4CC),
          borderRadius: BorderRadius.circular(999),
          border: value ? null : Border.all(color: const Color(0xFF9A9488)),
        ),
        child: AnimatedAlign(
          duration: duration,
          curve: reducedMotion
              ? Curves.linear
              : const Cubic(0.34, 1.45, 0.64, 1),
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 22,
            height: 22,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.surface,
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: Color(0x3D161D1E),
                  blurRadius: 3,
                  offset: Offset(0, 1),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LeaveGroupButton extends StatelessWidget {
  const _LeaveGroupButton({required this.reducedMotion, this.onPressed});

  final bool reducedMotion;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return _InteractiveRowSurface(
      key: GroupProfilePanel.leaveButtonKey,
      reducedMotion: reducedMotion,
      onTap: onPressed,
      hoverColor: AppColors.dangerSurface,
      borderRadius: BorderRadius.circular(AppRadius.button),
      builder: (BuildContext context, bool _) {
        return ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Icon(Icons.logout_rounded, size: 16, color: AppColors.danger),
                SizedBox(width: 7),
                Flexible(
                  child: Text(
                    '退出群聊',
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                      color: AppColors.danger,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _RoleFootnote extends StatelessWidget {
  const _RoleFootnote({required this.role, required this.dissolved});

  final GroupProfileRole role;
  final bool dissolved;

  @override
  Widget build(BuildContext context) {
    final String text = dissolved
        ? '该群已解散，资料仅可查看。'
        : switch (role) {
            GroupProfileRole.owner => '你是群主，可管理群资料、邀请权限与成员。',
            GroupProfileRole.member => '群资料由群主维护，仅可查看。',
            GroupProfileRole.visitor => '加入群聊后可查看成员并发言。',
          };
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Padding(
          padding: EdgeInsets.only(top: 1),
          child: Icon(
            Icons.lock_outline_rounded,
            size: 14,
            color: Color(0xFF66716E),
          ),
        ),
        const SizedBox(width: 7),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              fontSize: 11.5,
              height: 1.55,
              color: Color(0xFF66716E),
            ),
          ),
        ),
      ],
    );
  }
}

class _SlidingChevron extends StatelessWidget {
  const _SlidingChevron({
    required this.hovered,
    required this.reducedMotion,
    required this.color,
    required this.size,
  });

  final bool hovered;
  final bool reducedMotion;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return AnimatedSlide(
      offset: hovered && !reducedMotion ? const Offset(0.14, 0) : Offset.zero,
      duration: reducedMotion
          ? Duration.zero
          : const Duration(milliseconds: 160),
      curve: Curves.easeOut,
      child: Icon(Icons.chevron_right_rounded, size: size, color: color),
    );
  }
}

class _InteractiveRowSurface extends StatefulWidget {
  const _InteractiveRowSurface({
    super.key,
    required this.reducedMotion,
    required this.hoverColor,
    required this.builder,
    this.onTap,
    this.borderRadius,
    this.semanticLabel,
  });

  final bool reducedMotion;
  final Color hoverColor;
  final Widget Function(BuildContext context, bool hovered) builder;
  final VoidCallback? onTap;
  final BorderRadius? borderRadius;
  final String? semanticLabel;

  @override
  State<_InteractiveRowSurface> createState() => _InteractiveRowSurfaceState();
}

class _InteractiveRowSurfaceState extends State<_InteractiveRowSurface> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final bool active = widget.onTap != null;
    Widget content = MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Listener(
        onPointerDown: active ? (_) => setState(() => _pressed = true) : null,
        onPointerUp: active ? (_) => setState(() => _pressed = false) : null,
        onPointerCancel: active
            ? (_) => setState(() => _pressed = false)
            : null,
        child: AnimatedScale(
          scale: _pressed && active && !widget.reducedMotion ? 0.992 : 1.0,
          duration: widget.reducedMotion
              ? Duration.zero
              : const Duration(milliseconds: 120),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: widget.onTap,
              hoverColor: widget.hoverColor,
              borderRadius: widget.borderRadius,
              child: widget.builder(context, _hovered && active),
            ),
          ),
        ),
      ),
    );
    if (widget.semanticLabel != null) {
      content = Semantics(
        button: active,
        label: widget.semanticLabel,
        child: content,
      );
    }
    return content;
  }
}

/// Shared creation/edit fields. Avatar selection and submission are host-owned;
/// no UI-generated group number or default-avatar bytes enter the service.
class GroupDetailsForm extends StatefulWidget {
  const GroupDetailsForm({
    super.key,
    required this.onSubmit,
    this.initialName = '',
    this.initialDescription = '',
    this.busy = false,
    this.error,
  });
  final void Function(String name, String? description) onSubmit;
  final String initialName;
  final String initialDescription;
  final bool busy;
  final String? error;

  @override
  State<GroupDetailsForm> createState() => _GroupDetailsFormState();
}

class _GroupDetailsFormState extends State<GroupDetailsForm> {
  final GlobalKey<FormState> _form = GlobalKey<FormState>();
  late final TextEditingController _name = TextEditingController(
    text: widget.initialName,
  );
  late final TextEditingController _description = TextEditingController(
    text: widget.initialDescription,
  );

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Form(
    key: _form,
    child: ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: <Widget>[
        TextFormField(
          controller: _name,
          enabled: !widget.busy,
          decoration: const InputDecoration(labelText: '群名称（必填）'),
          validator: (value) =>
              value == null || value.trim().isEmpty ? '请输入群名称' : null,
        ),
        const SizedBox(height: AppSpacing.md),
        TextFormField(
          controller: _description,
          enabled: !widget.busy,
          decoration: const InputDecoration(labelText: '简介（选填）'),
          minLines: 3,
          maxLines: 6,
        ),
        const SizedBox(height: AppSpacing.lg),
        if (widget.error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.md),
            child: Text(
              widget.error!,
              style: const TextStyle(color: AppColors.danger),
            ),
          ),
        FilledButton(
          onPressed: widget.busy
              ? null
              : () {
                  if (_form.currentState!.validate()) {
                    widget.onSubmit(
                      _name.text.trim(),
                      _description.text.trim().isEmpty
                          ? null
                          : _description.text.trim(),
                    );
                  }
                },
          child: Text(widget.busy ? '正在保存…' : '保存群资料'),
        ),
      ],
    ),
  );
}
