import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../app.dart';
import '../../models/auth_models.dart';
import '../../models/profile_models.dart';
import '../../services/profile_service.dart';
import '../widgets/profile_avatar.dart';
import 'profile_artwork.dart';
import 'profile_panel.dart';

/// Content shared by group details and fallback details surfaces.
class ProfileDetails extends StatelessWidget {
  const ProfileDetails({
    super.key,
    required this.title,
    required this.name,
    required this.numberLabel,
    required this.number,
    required this.description,
    this.avatar,
    this.children = const <Widget>[],
  });

  final String title;
  final String name;
  final String numberLabel;
  final String number;
  final String description;
  final Uint8List? avatar;
  final List<Widget> children;

  static const Key closeButtonKey = Key('profile-details-close');

  @override
  Widget build(BuildContext context) {
    final List<Widget> bodyItems = <Widget>[
      Align(
        alignment: Alignment.centerLeft,
        child: ProfileAvatar(
          bytes: avatar,
          size: 80,
          semanticLabel: '$title头像',
        ),
      ),
      const SizedBox(height: AppSpacing.lg),
      Text(name, style: Theme.of(context).textTheme.headlineMedium),
      const SizedBox(height: AppSpacing.sm),
      SelectableText(
        '$numberLabel $number',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      const SizedBox(height: AppSpacing.lg),
      Text(description.isEmpty ? '暂无介绍' : description),
      for (final Widget child in children) ...<Widget>[
        const SizedBox(height: AppSpacing.md),
        child,
      ],
    ];

    return Material(
      color: AppColors.paper,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          AppBar(
            title: Text(title),
            leading: CloseButton(
              key: closeButtonKey,
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(AppSpacing.lg),
              children: bodyItems,
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> openPersonProfile(
  BuildContext context, {
  required String account,
  required ProfileGateway gateway,
}) => openProfileSurface<void>(
  context,
  label: '个人资料',
  underStatusBar: true,
  slideFromLeftOnMobile: true,
  dialogTransitionDuration: const Duration(milliseconds: 240),
  dialogReverseTransitionDuration: const Duration(milliseconds: 200),
  dialogBarrierColor:
      resolveProfilePanelMode(context) == ProfilePanelMode.desktop
      ? const Color(0x3D161D1E)
      : Colors.transparent,
  desktopPreferredSize: const Size(440, 620),
  builder: (_) => PersonProfilePanel(account: account, gateway: gateway),
);

/// Read-only peer profile implementing DEA-514 v3 Layout A ("浮起名片");
/// never exposes edit controls and preserves cover rules and switch isolation.
class PersonProfilePanel extends StatefulWidget {
  const PersonProfilePanel({
    super.key,
    required this.account,
    required this.gateway,
  });

  final String account;
  final ProfileGateway gateway;

  static const Key plateKey = Key('person-profile-plate');
  static const Key readonlyPillKey = Key('person-profile-readonly-pill');
  static const Key readonlyNoteKey = Key('person-profile-readonly-note');
  static const Key nicknameKey = Key('person-profile-nickname');
  static const Key accountKey = Key('person-profile-account');
  static const Key signatureKey = Key('person-profile-signature');

  @override
  State<PersonProfilePanel> createState() => _PersonProfilePanelState();
}

class _PersonProfilePanelState extends State<PersonProfilePanel>
    with SingleTickerProviderStateMixin {
  static const Cubic _easeOutExpo = Cubic(0.16, 1, 0.3, 1);

  int _profileGeneration = 0;
  int _coverGeneration = 0;
  Profile? _profile;
  Uint8List? _avatar;
  CoverImage? _cover;
  bool _loading = true;
  bool _coverLoading = false;
  Object? _error;

  late final AnimationController _entrance = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    unawaited(_load(notifyStart: false));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context) &&
        !_loading &&
        _error == null &&
        _entrance.value < 1.0) {
      _entrance.value = 1.0;
    }
  }

  @override
  void didUpdateWidget(covariant PersonProfilePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.account != widget.account ||
        oldWidget.gateway != widget.gateway) {
      _profileGeneration += 1;
      _coverGeneration += 1;
      _profile = null;
      _avatar = null;
      _cover = null;
      _loading = true;
      _coverLoading = false;
      _error = null;
      _entrance.reset();
      unawaited(_load(notifyStart: false));
    }
  }

  @override
  void dispose() {
    _entrance.dispose();
    super.dispose();
  }

  Future<void> _load({required bool notifyStart}) async {
    final String targetAccount = widget.account;
    final ProfileGateway gateway = widget.gateway;
    final int generation = ++_profileGeneration;
    if (notifyStart && mounted) {
      setState(() {
        _loading = true;
        _coverLoading = false;
        _error = null;
      });
    }
    try {
      final Profile profile = await gateway.loadProfile(account: targetAccount);
      if (!mounted ||
          generation != _profileGeneration ||
          targetAccount != widget.account ||
          gateway != widget.gateway) {
        return;
      }
      if (profile.account != targetAccount) {
        throw const FormatException('profile account mismatch');
      }
      final AvatarImage avatar = await gateway.loadAvatar(
        account: targetAccount,
      );
      if (!mounted ||
          generation != _profileGeneration ||
          targetAccount != widget.account ||
          gateway != widget.gateway) {
        return;
      }
      if (avatar.account != targetAccount) {
        throw const FormatException('avatar account mismatch');
      }
      setState(() {
        _profile = profile;
        _avatar = avatar.bytes;
        _loading = false;
        _coverLoading = true;
        _error = null;
      });
      if (MediaQuery.disableAnimationsOf(context)) {
        _entrance.value = 1.0;
      } else {
        unawaited(_entrance.forward(from: 0));
      }
      unawaited(_loadCover(targetAccount: targetAccount, gateway: gateway));
    } catch (error) {
      if (!mounted ||
          generation != _profileGeneration ||
          targetAccount != widget.account ||
          gateway != widget.gateway) {
        return;
      }
      setState(() {
        _loading = false;
        _error = error;
      });
    }
  }

  Future<void> _loadCover({
    required String targetAccount,
    required ProfileGateway gateway,
  }) async {
    final int generation = ++_coverGeneration;
    if (mounted &&
        targetAccount == widget.account &&
        gateway == widget.gateway &&
        !_coverLoading) {
      setState(() => _coverLoading = true);
    }
    try {
      final CoverImage cover = await gateway.loadCover(account: targetAccount);
      if (!mounted ||
          generation != _coverGeneration ||
          targetAccount != widget.account ||
          gateway != widget.gateway) {
        return;
      }
      if (cover.account != targetAccount) {
        setState(() => _coverLoading = false);
        return;
      }
      setState(() {
        _cover = cover;
        _coverLoading = false;
      });
    } catch (_) {
      if (!mounted ||
          generation != _coverGeneration ||
          targetAccount != widget.account ||
          gateway != widget.gateway) {
        return;
      }
      // Cover reads are supplementary: a read failure keeps the packaged
      // default sea-wave cover so the peer profile stays usable.
      setState(() => _coverLoading = false);
    }
  }

  double _interval(double begin, double end, {Curve curve = Curves.easeOut}) {
    final double raw = ((_entrance.value - begin) / (end - begin)).clamp(
      0.0,
      1.0,
    );
    return curve.transform(raw);
  }

  Widget _fadeSlide({
    required double begin,
    required double end,
    required double dy,
    Curve curve = Curves.easeOut,
    required Widget child,
  }) {
    final double t = _interval(begin, end, curve: curve);
    return Opacity(
      opacity: t,
      child: Transform.translate(offset: Offset(0, (1 - t) * dy), child: child),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ProfilePanelMode mode = resolveProfilePanelMode(context);
    final Profile? profile = _profile;
    if (!_loading &&
        _error == null &&
        profile != null &&
        profile.account == widget.account) {
      final CoverImage? cover =
          (_cover != null && _cover!.account == widget.account) ? _cover : null;
      final bool reducedMotion = MediaQuery.disableAnimationsOf(context);
      final bool isMobile = mode == ProfilePanelMode.mobile;
      final EdgeInsets insets = MediaQuery.paddingOf(context);

      return Material(
        color: AppColors.paper,
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final double maxCoverCap = math.max(
              168.0,
              constraints.maxHeight * 0.55,
            );
            final double coverHeight = isMobile
                ? (constraints.maxHeight * 0.38).clamp(240.0, 320.0)
                : (constraints.maxHeight * 0.38).clamp(180.0, 230.0);
            final double effectiveCoverHeight = math.min(
              coverHeight,
              maxCoverCap,
            );
            final double avatarSize = isMobile
                ? (constraints.maxWidth < 340 ? 64.0 : 72.0)
                : 68.0;
            final double plateOverlap = math.min(
              isMobile ? 52.0 : 44.0,
              effectiveCoverHeight * 0.25,
            );
            final double nameFontSize = isMobile ? 24.0 : 22.0;
            final String signature = profile.signature ?? '';
            final bool hasSignature = signature.isNotEmpty;

            return AnimatedBuilder(
              animation: _entrance,
              builder: (BuildContext context, Widget? _) {
                final double coverT = reducedMotion
                    ? 1.0
                    : _interval(0.0, 1.0, curve: _easeOutExpo);
                final double barT = reducedMotion
                    ? 1.0
                    : _interval(60 / 900, 440 / 900, curve: _easeOutExpo);
                final double pillT = reducedMotion
                    ? 1.0
                    : _interval(340 / 900, 640 / 900);
                final double plateT = reducedMotion
                    ? 1.0
                    : _interval(120 / 900, 680 / 900, curve: _easeOutExpo);
                final double avatarT = reducedMotion
                    ? 1.0
                    : _interval(170 / 900, 690 / 900, curve: _easeOutExpo);
                final double noteT = reducedMotion
                    ? 1.0
                    : _interval(620 / 900, 1.0);

                final Widget coverLayer = ClipRect(
                  child: Opacity(
                    opacity: 0.45 + 0.55 * coverT,
                    child: Transform.scale(
                      scale: 1.08 - 0.08 * coverT,
                      child: ProfileSeaCover(
                        height: effectiveCoverHeight,
                        imageBytes: cover?.bytes,
                        imageMimeType: cover?.mimeType,
                        loading: _coverLoading,
                        fadeDuration: reducedMotion
                            ? Duration.zero
                            : const Duration(milliseconds: 280),
                        topScrimHeightFactor: 0.64,
                        topScrimMaxAlpha: 0.64,
                        bottomScrimHeightFactor: 0.32,
                        bottomScrimMaxAlpha: 0.30,
                      ),
                    ),
                  ),
                );

                final Widget overlayBar = Opacity(
                  opacity: barT,
                  child: Transform.translate(
                    offset: Offset(0, (1 - barT) * -8),
                    child: SizedBox(
                      height: 50,
                      child: Row(
                        children: <Widget>[
                          _GlassCloseButton(
                            mode: mode,
                            reducedMotion: reducedMotion,
                            onPressed: () => Navigator.of(context).pop(),
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              '个人资料',
                              style: TextStyle(
                                fontSize: isMobile ? 16.5 : 16.0,
                                fontWeight: FontWeight.w600,
                                color: AppColors.surface,
                                letterSpacing: 0.1,
                                shadows: const <Shadow>[
                                  Shadow(
                                    color: Color(0x4D000000),
                                    blurRadius: 3,
                                    offset: Offset(0, 1),
                                  ),
                                ],
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Opacity(
                            opacity: pillT,
                            child: Transform.scale(
                              scale: 0.88 + 0.12 * pillT,
                              child: Container(
                                key: PersonProfilePanel.readonlyPillKey,
                                height: 26,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0x570B1020),
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: <Widget>[
                                    Icon(
                                      Icons.lock_outline_rounded,
                                      size: 11,
                                      color: AppColors.surface,
                                    ),
                                    SizedBox(width: 5),
                                    Text(
                                      '仅可查看',
                                      style: TextStyle(
                                        color: AppColors.surface,
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.w600,
                                        letterSpacing: 0.3,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );

                final Widget plate = Opacity(
                  opacity: plateT,
                  child: Transform.translate(
                    offset: Offset(0, (1 - plateT) * 24),
                    child: Transform.scale(
                      scale: 0.96 + 0.04 * plateT,
                      child: Container(
                        key: PersonProfilePanel.plateKey,
                        margin: const EdgeInsets.symmetric(horizontal: 24),
                        padding: const EdgeInsets.fromLTRB(12, 12, 16, 12),
                        decoration: BoxDecoration(
                          color: AppColors.surface,
                          borderRadius: BorderRadius.circular(22),
                          boxShadow: const <BoxShadow>[
                            BoxShadow(
                              color: Color(0x26161D1E),
                              blurRadius: 30,
                              offset: Offset(0, 14),
                            ),
                          ],
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: <Widget>[
                            Opacity(
                              opacity: avatarT,
                              child: Transform.scale(
                                scale: 0.82 + 0.18 * avatarT,
                                child: DecoratedBox(
                                  decoration: const BoxDecoration(
                                    shape: BoxShape.circle,
                                    boxShadow: <BoxShadow>[
                                      BoxShadow(
                                        color: Color(0x33161D1E),
                                        blurRadius: 16,
                                        offset: Offset(0, 7),
                                      ),
                                    ],
                                  ),
                                  child: ScallopedAvatar(
                                    key: ValueKey<String>(
                                      'person-avatar-${profile.account}',
                                    ),
                                    bytes: _avatar,
                                    size: avatarSize,
                                    playRing: !reducedMotion,
                                    semanticLabel: '${profile.username} 的头像',
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: <Widget>[
                                  _fadeSlide(
                                    begin: reducedMotion ? 0 : 240 / 900,
                                    end: reducedMotion ? 1 : 640 / 900,
                                    dy: reducedMotion ? 0 : 10,
                                    child: Text(
                                      profile.username,
                                      key: PersonProfilePanel.nicknameKey,
                                      style: TextStyle(
                                        fontSize: nameFontSize,
                                        height: 1.2,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: -0.35,
                                        color: AppColors.ink,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  _fadeSlide(
                                    begin: reducedMotion ? 0 : 300 / 900,
                                    end: reducedMotion ? 1 : 700 / 900,
                                    dy: reducedMotion ? 0 : 10,
                                    child: SelectableText.rich(
                                      TextSpan(
                                        text: 'BB号 ',
                                        style: const TextStyle(
                                          fontSize: 12.5,
                                          height: 1.5,
                                          color: AppColors.inkMuted,
                                        ),
                                        children: <InlineSpan>[
                                          TextSpan(
                                            text: profile.account,
                                            style: const TextStyle(
                                              letterSpacing: 1.15,
                                              fontFeatures: <FontFeature>[
                                                FontFeature.tabularFigures(),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                      key: PersonProfilePanel.accountKey,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );

                final Widget signatureBlock = Padding(
                  padding: const EdgeInsets.fromLTRB(24, 26, 24, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      _fadeSlide(
                        begin: reducedMotion ? 0 : 420 / 900,
                        end: reducedMotion ? 1 : 800 / 900,
                        dy: reducedMotion ? 0 : 10,
                        child: const Text(
                          '签名',
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.4,
                            height: 1.4,
                            color: AppColors.inkMuted,
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      _fadeSlide(
                        begin: reducedMotion ? 0 : 470 / 900,
                        end: reducedMotion ? 1 : 890 / 900,
                        dy: reducedMotion ? 0 : 10,
                        child: hasSignature
                            ? SelectableText(
                                signature,
                                key: PersonProfilePanel.signatureKey,
                                style: const TextStyle(
                                  fontSize: 16.5,
                                  height: 1.7,
                                  color: AppColors.ink,
                                ),
                              )
                            : const Text(
                                '还没有签名',
                                key: PersonProfilePanel.signatureKey,
                                style: TextStyle(
                                  fontSize: 16.5,
                                  height: 1.7,
                                  color: AppColors.inkMuted,
                                  fontStyle: FontStyle.italic,
                                ),
                              ),
                      ),
                    ],
                  ),
                );

                final Widget footnote = Opacity(
                  opacity: noteT,
                  child: Padding(
                    key: PersonProfilePanel.readonlyNoteKey,
                    padding: EdgeInsets.fromLTRB(
                      24,
                      30,
                      24,
                      (isMobile ? 40.0 : 32.0) + insets.bottom,
                    ),
                    child: const Row(
                      children: <Widget>[
                        Icon(
                          Icons.lock_outline_rounded,
                          size: 13,
                          color: AppColors.inkMuted,
                        ),
                        SizedBox(width: 7),
                        Expanded(
                          child: Text(
                            '资料由对方维护，仅可查看',
                            style: TextStyle(
                              fontSize: 11.5,
                              height: 1.5,
                              color: AppColors.inkMuted,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );

                return SingleChildScrollView(
                  child: Stack(
                    children: <Widget>[
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        height: effectiveCoverHeight,
                        child: coverLayer,
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          SizedBox(height: effectiveCoverHeight - plateOverlap),
                          plate,
                          signatureBlock,
                          footnote,
                        ],
                      ),
                      Positioned(
                        top: isMobile ? insets.top + 8 : 10,
                        left: 4,
                        right: isMobile ? 20 : 14,
                        child: overlayBar,
                      ),
                    ],
                  ),
                );
              },
            );
          },
        ),
      );
    }
    return Material(
      color: AppColors.paper,
      child: Column(
        children: <Widget>[
          AppBar(
            title: const Text('个人资料'),
            leading: _themedCloseButton(
              mode: mode,
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
          Expanded(
            child: _error != null
                ? Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(AppSpacing.lg),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Text(
                            _error is AuthFailure
                                ? (_error! as AuthFailure).message
                                : '资料加载失败，请重试',
                          ),
                          TextButton(
                            onPressed: () =>
                                unawaited(_load(notifyStart: true)),
                            child: const Text('重试'),
                          ),
                        ],
                      ),
                    ),
                  )
                : const Center(child: CircularProgressIndicator()),
          ),
        ],
      ),
    );
  }
}

/// Builds an actual [CloseButton] so route tests matching `byType(CloseButton)`
/// continue to work while mobile shows `←` and desktop shows `✕`.
Widget _themedCloseButton({
  Key? key,
  required ProfilePanelMode mode,
  Color? color,
  required VoidCallback onPressed,
}) => ActionIconTheme(
  data: ActionIconThemeData(
    closeButtonIconBuilder: (BuildContext context) => Icon(
      mode == ProfilePanelMode.desktop
          ? Icons.close_rounded
          : Icons.arrow_back_rounded,
      size: 20,
    ),
  ),
  child: CloseButton(key: key, color: color, onPressed: onPressed),
);

class _GlassCloseButton extends StatefulWidget {
  const _GlassCloseButton({
    required this.mode,
    required this.reducedMotion,
    required this.onPressed,
  });

  final ProfilePanelMode mode;
  final bool reducedMotion;
  final VoidCallback onPressed;

  @override
  State<_GlassCloseButton> createState() => _GlassCloseButtonState();
}

class _GlassCloseButtonState extends State<_GlassCloseButton> {
  bool _pressed = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final bool isDesktop = widget.mode == ProfilePanelMode.desktop;
    final Color baseColor = isDesktop
        ? const Color(0x4D101A2A)
        : const Color(0x42101A2A);
    final Color fill = _hovered ? const Color(0x6B101A2A) : baseColor;
    final Duration duration = widget.reducedMotion
        ? Duration.zero
        : const Duration(milliseconds: 120);

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Listener(
        onPointerDown: (_) => setState(() => _pressed = true),
        onPointerUp: (_) => setState(() => _pressed = false),
        onPointerCancel: (_) => setState(() => _pressed = false),
        child: AnimatedScale(
          scale: _pressed && !widget.reducedMotion ? 0.94 : 1.0,
          duration: duration,
          curve: Curves.easeOut,
          child: AnimatedContainer(
            duration: duration,
            width: 44,
            height: 44,
            decoration: BoxDecoration(color: fill, shape: BoxShape.circle),
            child: _themedCloseButton(
              key: ProfileDetails.closeButtonKey,
              mode: widget.mode,
              color: AppColors.surface,
              onPressed: widget.onPressed,
            ),
          ),
        ),
      ),
    );
  }
}
