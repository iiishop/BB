import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show DisplayFeature, ImageFilter;

import 'package:flutter/material.dart';

import '../../app.dart';
import '../../models/auth_models.dart';
import '../../models/profile_models.dart';
import '../../services/avatar_source.dart';
import '../../services/profile_service.dart';
import '../../validation/profile_rules.dart';
import '../display_features.dart';
import '../widgets/profile_avatar.dart';
import 'avatar_picker.dart';
import 'profile_artwork.dart';

/// Which of the three Profile presentations applies.
enum ProfilePanelMode {
  /// Narrow phone: full-screen sheet sliding in from the left.
  mobile,

  /// Unfolded foldable/tablet: left half, blurred right half.
  folded,

  /// Wide desktop: floating card without a dark backdrop.
  desktop,
}

/// Resolves the presentation exactly as the STEP-2 spec orders it:
/// a flat fold/hinge wins over the width breakpoint; only then does a narrow
/// width mean phone and a wide width mean desktop.
ProfilePanelMode resolveProfilePanelMode(BuildContext context) {
  final List<DisplayFeature> features = MediaQuery.displayFeaturesOf(context);
  final bool folded = features.any(isFlatFoldFeature);
  if (folded) {
    return ProfilePanelMode.folded;
  }
  return MediaQuery.sizeOf(context).width < 600
      ? ProfilePanelMode.mobile
      : ProfilePanelMode.desktop;
}

/// The left-half width for the folded presentation, taken from the display
/// feature's own bounds. The 600dp breakpoint is never used as a fold judgement.
double foldedPanelWidth(BuildContext context) {
  final Size size = MediaQuery.sizeOf(context);
  for (final DisplayFeature feature in MediaQuery.displayFeaturesOf(context)) {
    if (!isFlatFoldFeature(feature)) {
      continue;
    }
    final Rect bounds = feature.bounds;
    if (isVerticalFeature(feature) && bounds.left > 0) {
      return bounds.left.clamp(280.0, size.width - 1);
    }
  }
  return size.width / 2;
}

/// What happened inside a Profile panel.
class ProfilePanelResult {
  const ProfilePanelResult({
    this.changed = false,
    this.signedOut = false,
    this.logout,
    this.openSettings = false,
    this.openHomeAccount,
  });

  final bool changed;
  final bool signedOut;
  final LogoutResult? logout;

  /// The user asked for the settings surface; the host opens it after the panel
  /// closes so the update page is not stacked behind a dialog.
  final bool openSettings;

  /// The user opened a home page from this Profile. The host pushes the shared
  /// home page after the panel closes, so it is not stacked inside the dialog.
  final String? openHomeAccount;
}

/// Opens the Profile panel in the right presentation for this viewport.
///
/// A phone gets a full-screen [PageRoute] rather than a dialog because the
/// avatar has to travel from the messages-page entry to the cover, and Hero
/// flights only run between [PageRoute]s. Folded and desktop keep the dialog.
Future<ProfilePanelResult?> openProfilePanel(
  BuildContext context, {
  required ProfileGateway gateway,
  required AuthUser user,
  Profile? initialProfile,
  Uint8List? initialAvatar,
  required Future<LogoutResult> Function() onLogout,
  AvatarImagePicker? avatarPicker,
  AvatarDecodeCheck? avatarDecodeCheck,
  AvatarSourceReader? avatarSourceReader,
}) {
  // Reparent the same content State when a live resize replaces its shell.
  final GlobalKey contentKey = GlobalKey(debugLabel: 'profile-content');
  Widget frame() => _ResponsiveProfileFrame(
    contentKey: contentKey,
    gateway: gateway,
    user: user,
    initialProfile: initialProfile,
    initialAvatar: initialAvatar,
    onLogout: onLogout,
    avatarPicker: avatarPicker,
    avatarDecodeCheck: avatarDecodeCheck,
    avatarSourceReader: avatarSourceReader,
  );

  // Resolved once, at open time: the route type cannot change later without
  // dropping the panel, and a resize to desktop while open keeps this page
  // (the frame still reflows to the desktop card).
  if (resolveProfilePanelMode(context) == ProfilePanelMode.mobile) {
    return Navigator.of(context)
        .push<ProfilePanelResult>(_PhoneProfileRoute(builder: (_) => frame()));
  }
  return Navigator.of(
    context,
    rootNavigator: true,
  ).push<ProfilePanelResult>(_ProfileDialogRoute(builder: (_) => frame()));
}

/// Opens read-only people, group details and directory surfaces using the same
/// route, live posture rules and frame as the signed-in Profile.
Future<T?> openProfileSurface<T>(
  BuildContext context, {
  required String label,
  required WidgetBuilder builder,
  bool underStatusBar = false,
  bool slideFromLeftOnMobile = false,
  Duration? dialogTransitionDuration,
  Duration? dialogReverseTransitionDuration,
  Color? dialogBarrierColor,
  Size? desktopPreferredSize,
}) {
  final GlobalKey contentKey = GlobalKey(debugLabel: 'profile-surface-content');
  Widget frame(BuildContext context) => ProfilePanelFrame(
    underStatusBar: underStatusBar,
    desktopPreferredSize: desktopPreferredSize,
    child: KeyedSubtree(
      key: contentKey,
      child: Builder(builder: builder),
    ),
  );
  if (resolveProfilePanelMode(context) == ProfilePanelMode.mobile) {
    return Navigator.of(context).push<T>(
      slideFromLeftOnMobile
          ? _SlidePhoneProfileRoute<T>(builder: frame)
          : _PhoneProfileRoute<T>(builder: frame),
    );
  }
  return Navigator.of(context, rootNavigator: true).push<T>(
    _ProfileDialogRoute<T>(
      builder: frame,
      label: label,
      customTransitionDuration: dialogTransitionDuration,
      customReverseTransitionDuration: dialogReverseTransitionDuration,
      customBarrierColor: dialogBarrierColor,
    ),
  );
}

/// In flat posture the frame owns both panes, so the route retains the full view
/// instead of a dialog's default DisplayFeatureSubScreen removing its hinge.
class _ProfileDialogRoute<T> extends PopupRoute<T> {
  _ProfileDialogRoute({
    required this.builder,
    this.label = '个人资料',
    this.customTransitionDuration,
    this.customReverseTransitionDuration,
    this.customBarrierColor,
  });

  final WidgetBuilder builder;
  final String label;
  final Duration? customTransitionDuration;
  final Duration? customReverseTransitionDuration;
  final Color? customBarrierColor;

  @override
  bool get barrierDismissible => true;

  @override
  Color get barrierColor => customBarrierColor ?? Colors.transparent;

  @override
  String get barrierLabel => label;

  @override
  Duration get transitionDuration =>
      customTransitionDuration ?? const Duration(milliseconds: 300);

  @override
  Duration get reverseTransitionDuration =>
      customReverseTransitionDuration ?? transitionDuration;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final Widget content = builder(context);
    final bool folded = MediaQuery.displayFeaturesOf(context)
        .any(isFlatFoldFeature);
    return Semantics(
      scopesRoute: true,
      explicitChildNodes: true,
      child: folded ? content : DisplayFeatureSubScreen(child: content),
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => _ResponsiveProfileTransition(animation: animation, child: child);
}

/// Key for the phone page's route fade; the exit is a cross-fade while the
/// avatar Hero returns, never the old left slide.
const Key profilePhoneFadeKey = Key('profile-phone-fade');

/// Full-screen phone route for the Profile page.
///
/// The page fades in while the avatar Hero flies; both use the same 360 ms
/// clock so the photo has landed before the scalloped rim starts settling.
class _PhoneProfileRoute<T> extends PageRouteBuilder<T> {
  _PhoneProfileRoute({required WidgetBuilder builder})
    : super(
        opaque: true,
        barrierDismissible: false,
        transitionDuration: const Duration(milliseconds: 360),
        reverseTransitionDuration: const Duration(milliseconds: 300),
        pageBuilder: (
          BuildContext context,
          Animation<double> a,
          Animation<double> b,
        ) => builder(context),
        transitionsBuilder:
            (
              BuildContext context,
              Animation<double> animation,
              Animation<double> secondary,
              Widget child,
            ) => MediaQuery.disableAnimationsOf(context)
            ? child
            : FadeTransition(
                key: profilePhoneFadeKey,
                opacity: CurvedAnimation(
                  parent: animation,
                  curve: Curves.easeOutCubic,
                  reverseCurve: Curves.easeInCubic,
                ),
                child: child,
              ),
      );
}

/// Full-screen phone route sliding from the left per the DEA-514 v3 spec.
class _SlidePhoneProfileRoute<T> extends PageRouteBuilder<T> {
  _SlidePhoneProfileRoute({required WidgetBuilder builder})
    : super(
        opaque: true,
        barrierDismissible: false,
        transitionDuration: const Duration(milliseconds: 380),
        reverseTransitionDuration: const Duration(milliseconds: 300),
        pageBuilder: (
          BuildContext context,
          Animation<double> a,
          Animation<double> b,
        ) => builder(context),
        transitionsBuilder: (
          BuildContext context,
          Animation<double> animation,
          Animation<double> secondary,
          Widget child,
        ) => _SlidePhoneProfileTransition(animation: animation, child: child),
      );
}

class _SlidePhoneProfileTransition extends StatefulWidget {
  const _SlidePhoneProfileTransition({
    required this.animation,
    required this.child,
  });

  final Animation<double> animation;
  final Widget child;

  @override
  State<_SlidePhoneProfileTransition> createState() =>
      _SlidePhoneProfileTransitionState();
}

class _SlidePhoneProfileTransitionState
    extends State<_SlidePhoneProfileTransition> {
  late CurvedAnimation _curved;

  @override
  void initState() {
    super.initState();
    _curved = _makeCurved(widget.animation);
  }

  @override
  void didUpdateWidget(_SlidePhoneProfileTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation != widget.animation) {
      _curved.dispose();
      _curved = _makeCurved(widget.animation);
    }
  }

  CurvedAnimation _makeCurved(Animation<double> animation) => CurvedAnimation(
    parent: animation,
    curve: const Cubic(0.16, 1, 0.3, 1),
    reverseCurve: Curves.easeInCubic,
  );

  @override
  void dispose() {
    _curved.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) {
      return widget.child;
    }
    return SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(-1, 0),
        end: Offset.zero,
      ).animate(_curved),
      child: FadeTransition(opacity: _curved, child: widget.child),
    );
  }
}

/// Rebuilds the Profile presentation from the live MediaQuery.
///
/// The dialog's page builder runs once, so the old code kept the
/// desktop/folded mode until the panel closed. This frame depends on
/// `MediaQuery.sizeOf`/`displayFeaturesOf` and therefore reflows immediately
/// when the window is resized or a flat hinge appears/disappears/moves.
/// Route transition driven by the same live MediaQuery as the panel content.
///
/// Desktop uses fade+scale, mobile/folded slide from/to the left. The widget
/// tree is identical in every mode (`Slide -> Fade -> Scale -> child`) so a
/// mid-open reflow cannot recreate the panel state; only the animation values
/// switch. Consequently a desktop-opened panel shrunk to mobile exits left
/// instead of fading out with the cached open-time branch (QA-465-05).
class _ResponsiveProfileTransition extends StatefulWidget {
  const _ResponsiveProfileTransition({
    required this.animation,
    required this.child,
  });

  final Animation<double> animation;
  final Widget child;

  @override
  State<_ResponsiveProfileTransition> createState() =>
      _ResponsiveProfileTransitionState();
}

class _ResponsiveProfileTransitionState
    extends State<_ResponsiveProfileTransition> {
  late CurvedAnimation _curved;

  @override
  void initState() {
    super.initState();
    _curved = _makeCurved(widget.animation);
  }

  @override
  void didUpdateWidget(_ResponsiveProfileTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation != widget.animation) {
      _curved.dispose();
      _curved = _makeCurved(widget.animation);
    }
  }

  CurvedAnimation _makeCurved(Animation<double> animation) {
    return CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
  }

  @override
  void dispose() {
    _curved.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool reducedMotion = MediaQuery.disableAnimationsOf(context);
    final bool desktop =
        resolveProfilePanelMode(context) == ProfilePanelMode.desktop;
    if (reducedMotion) {
      return widget.child;
    }
    return SlideTransition(
      position: desktop
          ? const AlwaysStoppedAnimation<Offset>(Offset.zero)
          : Tween<Offset>(
              begin: const Offset(-1, 0),
              end: Offset.zero,
            ).animate(_curved),
      child: FadeTransition(
        opacity: desktop ? _curved : const AlwaysStoppedAnimation<double>(1),
        child: ScaleTransition(
          scale: desktop
              ? Tween<double>(begin: 0.96, end: 1).animate(_curved)
              : const AlwaysStoppedAnimation<double>(1),
          child: widget.child,
        ),
      ),
    );
  }
}

class _ResponsiveProfileFrame extends StatelessWidget {
  const _ResponsiveProfileFrame({
    required this.contentKey,
    required this.gateway,
    required this.user,
    required this.initialProfile,
    required this.initialAvatar,
    required this.onLogout,
    this.avatarPicker,
    this.avatarDecodeCheck,
    this.avatarSourceReader,
  });

  final GlobalKey contentKey;
  final ProfileGateway gateway;
  final AuthUser user;
  final Profile? initialProfile;
  final Uint8List? initialAvatar;
  final Future<LogoutResult> Function() onLogout;
  final AvatarImagePicker? avatarPicker;
  final AvatarDecodeCheck? avatarDecodeCheck;
  final AvatarSourceReader? avatarSourceReader;

  @override
  Widget build(BuildContext context) {
    final ProfilePanelMode mode = resolveProfilePanelMode(context);
    final Widget panel = ProfilePanel(
      key: contentKey,
      mode: mode,
      gateway: gateway,
      user: user,
      initialProfile: initialProfile,
      initialAvatar: initialAvatar,
      onLogout: onLogout,
      avatarPicker: avatarPicker,
      avatarDecodeCheck: avatarDecodeCheck,
      avatarSourceReader: avatarSourceReader,
    );
    return ProfilePanelFrame(mode: mode, underStatusBar: true, child: panel);
  }
}

/// Shared containers only; each caller owns its content, data and permissions.
class ProfilePanelFrame extends StatelessWidget {
  const ProfilePanelFrame({
    super.key,
    required this.child,
    this.mode,
    this.underStatusBar = false,
    this.desktopPreferredSize,
  });

  static const Key desktopCardKey = Key('profile-desktop-card');

  final Widget child;
  final ProfilePanelMode? mode;
  final bool underStatusBar;
  final Size? desktopPreferredSize;

  @override
  Widget build(BuildContext context) {
    final ProfilePanelMode mode = this.mode ?? resolveProfilePanelMode(context);
    if (mode == ProfilePanelMode.mobile) {
      // The phone page draws under the status bar so the sea cover reaches the
      // top edge; ProfilePanel insets only its own controls. The Scaffold is
      // the page's own: an opaque route would otherwise show its snackbars on
      // the hidden messages page underneath. The page also owns its messenger,
      // so feedback is never mirrored onto the host Scaffold when this frame is
      // shown as a dialog after a desktop-to-phone reflow.
      return ScaffoldMessenger(
        child: Scaffold(
          backgroundColor: AppColors.paper,
          body: underStatusBar ? child : SafeArea(child: child),
        ),
      );
    }
    if (mode == ProfilePanelMode.folded) {
      return _FoldedFrame(width: foldedPanelWidth(context), child: child);
    }
    return _DesktopFrame(preferredSize: desktopPreferredSize, child: child);
  }
}

class _FoldedFrame extends StatelessWidget {
  const _FoldedFrame({required this.width, required this.child});

  final double width;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: Row(
        children: <Widget>[
          SizedBox(
            width: width,
            child: Material(
              color: AppColors.paper,
              elevation: 18,
              child: SafeArea(child: child),
            ),
          ),
          Expanded(
            child: ClipRect(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                child: ColoredBox(
                  color: const Color(0x33161D1E),
                  child: Semantics(
                    label: '右侧内容已模糊',
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DesktopFrame extends StatelessWidget {
  const _DesktopFrame({required this.child, this.preferredSize});

  final Widget child;
  final Size? preferredSize;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Align(
          alignment: Alignment.center,
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final Widget card = Container(
                key: ProfilePanelFrame.desktopCardKey,
                decoration: BoxDecoration(
                  color: AppColors.paper,
                  borderRadius: BorderRadius.circular(AppRadius.panel),
                  boxShadow: const <BoxShadow>[
                    BoxShadow(
                      color: Color(0x1F161D1E),
                      blurRadius: 40,
                      spreadRadius: 2,
                      offset: Offset(0, 18),
                    ),
                  ],
                ),
                clipBehavior: Clip.antiAlias,
                child: Material(type: MaterialType.transparency, child: child),
              );
              if (preferredSize == null) {
                return ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: 440,
                    maxHeight: 700,
                  ),
                  child: card,
                );
              }
              return SizedBox(
                width: math.min(preferredSize!.width, constraints.maxWidth),
                height: math.min(preferredSize!.height, constraints.maxHeight),
                child: card,
              );
            },
          ),
        ),
      ),
    );
  }
}

/// The Profile content shared by all three presentations.
class ProfilePanel extends StatefulWidget {
  const ProfilePanel({
    super.key,
    required this.mode,
    required this.gateway,
    required this.user,
    this.initialProfile,
    this.initialAvatar,
    required this.onLogout,
    this.avatarPicker,
    this.avatarDecodeCheck,
    this.avatarSourceReader,
  });

  final ProfilePanelMode mode;
  final ProfileGateway gateway;
  final AuthUser user;
  final Profile? initialProfile;
  final Uint8List? initialAvatar;

  /// Server-side logout + local clear, supplied by the host so this panel stays
  /// independent of the auth implementation.
  final Future<LogoutResult> Function() onLogout;

  /// Platform image chooser; defaults to the native `file_selector` chooser.
  /// Tests and hosts can substitute one.
  final AvatarImagePicker? avatarPicker;

  /// Decodability check for a candidate image; defaults to the engine decoder.
  final AvatarDecodeCheck? avatarDecodeCheck;

  /// Local path reader used for the preview and candidate validation; defaults
  /// to [DefaultAvatarSourceReader].
  final AvatarSourceReader? avatarSourceReader;

  static const Key panelKey = Key('profile-panel');
  static const Key closeButtonKey = Key('profile-close');
  static const Key nicknameValueKey = Key('profile-nickname');
  static const Key accountValueKey = Key('profile-account');
  static const Key signatureValueKey = Key('profile-signature');
  static const Key editNicknameKey = Key('profile-edit-nickname');
  static const Key editSignatureKey = Key('profile-edit-signature');
  static const Key avatarButtonKey = Key('profile-avatar-button');
  static const Key removeAvatarKey = Key('profile-remove-avatar');
  static const Key logoutButtonKey = Key('profile-logout');
  static const Key settingsButtonKey = Key('profile-settings');
  static const Key otherProfileKey = Key('profile-other-account');
  static const Key homeButtonKey = Key('profile-home');
  static const Key errorKey = Key('profile-error');

  /// Phone-only entries: the edit sheet and the avatar Hero shared with the
  /// messages-page entry.
  static const Key editProfileKey = Key('profile-edit');
  static const Key editSheetKey = Key('profile-edit-sheet');
  static const Key changeCoverKey = Key('profile-change-cover');

  /// The avatar in flight; present only while the entry/cover Hero runs.
  static const Key avatarFlightKey = Key('profile-avatar-flight');
  static const String avatarHeroTag = 'profile-avatar-hero';

  /// Shuttle for the entry -> cover avatar flight.
  ///
  /// It always carries the avatar that is already decoded (the messages-page
  /// thumbnail on the way in, the cover photo on the way back) and is scaled by
  /// the Hero rect, so the flight never flashes an empty placeholder even when
  /// the full-size fetch is still in flight.
  static Widget avatarFlightShuttle(
    BuildContext flightContext,
    Animation<double> animation,
    HeroFlightDirection direction,
    BuildContext fromHeroContext,
    BuildContext toHeroContext,
  ) {
    final BuildContext source = direction == HeroFlightDirection.push
        ? fromHeroContext
        : toHeroContext;
    final Hero hero = source.widget as Hero;
    // The flight lives in the overlay, outside the page Material; without this
    // the avatar's tap layer asserts on the missing ancestor mid-flight.
    return Material(
      key: avatarFlightKey,
      type: MaterialType.transparency,
      child: FittedBox(fit: BoxFit.contain, child: hero.child),
    );
  }

  @override
  State<ProfilePanel> createState() => _ProfilePanelState();
}

class _ProfilePanelState extends State<ProfilePanel> {
  Profile? _profile;
  Uint8List? _avatar;
  CoverImage? _cover;

  /// Monotonic owner of the displayed cover. Every load/replacement bumps it;
  /// a response may only write [_cover] while it still owns the newest value.
  /// Without this, a slow first GET (started before an upload) lands after the
  /// upload and restores the old image over the "cover updated" state.
  int _coverGeneration = 0;
  bool _loading = false;
  bool _busy = false;
  String? _error;
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    _profile = widget.initialProfile;
    _avatar = widget.initialAvatar;
    unawaited(_load());
  }

  /// Always asks the server; avatar bytes are revalidated with the cached
  /// version, so opening the panel can never show a stale avatar.
  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final Profile profile = await widget.gateway.loadProfile();
      final AvatarImage image = await widget.gateway.loadAvatar();
      if (!mounted) {
        return;
      }
      setState(() {
        _profile = profile;
        _avatar = image.bytes;
        _loading = false;
      });
      // The cover is independent: a cover failure must never turn the profile
      // into an error page, and the packaged default keeps the header filled.
      unawaited(_loadCover());
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
        _error = '资料加载失败，请稍后重试';
      });
    }
  }

  Future<void> _reloadAvatar() async {
    try {
      final AvatarImage image = await widget.gateway.loadAvatar();
      if (!mounted) {
        return;
      }
      setState(() {
        _avatar = image.bytes;
        _changed = true;
      });
    } on AuthFailure catch (failure) {
      _showSnack(failure.message);
    }
  }

  /// Revalidates the displayed cover with the server.
  ///
  /// On failure the currently displayed bytes (custom or default) stay; the
  /// page never falls back to an invented image.
  Future<void> _loadCover({bool quiet = true}) async {
    final int generation = ++_coverGeneration;
    try {
      final CoverImage cover = await widget.gateway.loadCover();
      // A later upload/reload owns the display now; this response is stale even
      // if it just arrived and even though it came from the server.
      if (!mounted || generation != _coverGeneration) {
        return;
      }
      setState(() => _cover = cover);
    } on AuthFailure catch (failure) {
      if (!quiet && mounted && generation == _coverGeneration) {
        _showSnack(failure.message);
      }
    } catch (_) {
      if (!quiet && mounted && generation == _coverGeneration) {
        _showSnack('封面加载失败，请稍后重试');
      }
    }
  }

  Future<void> _changeCover() async {
    final bool galleryMode =
        Theme.of(context).platform == TargetPlatform.android;
    final _AvatarChoice? choice = await showDialog<_AvatarChoice>(
      context: context,
      builder: (BuildContext context) => _AvatarSourceDialog(
        picker: widget.avatarPicker ?? const FileSelectorAvatarImagePicker(),
        decodeCheck: widget.avatarDecodeCheck ?? isDecodableAvatarImage,
        reader: widget.avatarSourceReader ?? DefaultAvatarSourceReader(),
        galleryMode: galleryMode,
        subject: '封面',
        maxMegabytes: 8,
      ),
    );
    if (choice == null) {
      return;
    }
    setState(() => _busy = true);
    try {
      final CoverInfo info;
      switch (choice.source) {
        case 'path':
          info = await widget.gateway.updateCoverFromPath(choice.value);
        case 'url':
          info = await widget.gateway.updateCoverFromUrl(choice.value);
        case 'bytes':
          info = await widget.gateway.updateCoverFromBytes(choice.bytes!);
        default:
          info = await widget.gateway.updateCoverFromBase64(choice.value);
      }
      if (!mounted) {
        return;
      }
      // The replacement is committed server-side: invalidate any load that was
      // already in flight so its older snapshot cannot overwrite this upload.
      final int generation = ++_coverGeneration;
      // Show the server-rendered display image, never the uploaded source.
      final CoverImage cover = await widget.gateway.loadCover();
      if (!mounted) {
        return;
      }
      if (generation != _coverGeneration) {
        // A newer cover operation owns the display; keep its state untouched.
        setState(() => _busy = false);
        return;
      }
      setState(() {
        _busy = false;
        _cover = cover;
      });
      _showSnack('封面已更新（${info.coverVersion.substring(0, 12)}…）');
    } on AuthFailure catch (failure) {
      if (!mounted) {
        return;
      }
      // Keep the previously displayed cover: a failed replacement is not a
      // reason to blank the header.
      setState(() => _busy = false);
      _showSnack(_failureMessage(failure));
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() => _busy = false);
      _showSnack('封面更新失败，请稍后重试');
    }
  }

  Future<void> _editNickname() async {
    final Profile? profile = _profile;
    if (profile == null) {
      return;
    }
    final String? value = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => _TextEditDialog(
        title: '修改昵称',
        initial: profile.username,
        minCodePoints: usernameMinCodePoints,
        maxCodePoints: usernameMaxCodePoints,
        helperText: '昵称同时就是用户名，3–24 个字符',
      ),
    );
    if (value == null || value == profile.username) {
      return;
    }
    await _save(
      ProfilePatch(setUsername: true, username: value),
      successMessage: '昵称已更新',
    );
  }

  Future<void> _editSignature() async {
    final Profile? profile = _profile;
    if (profile == null) {
      return;
    }
    final String? value = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => _TextEditDialog(
        title: '修改签名',
        initial: profile.signature ?? '',
        minCodePoints: 0,
        maxCodePoints: signatureMaxCodePoints,
        allowEmpty: true,
        helperText: '最多 49 个字符，留空即清空签名',
      ),
    );
    if (value == null) {
      return;
    }
    final String? normalized = value.trim().isEmpty ? null : value;
    if (normalized == profile.signature) {
      return;
    }
    await _save(
      ProfilePatch(setSignature: true, signature: normalized),
      successMessage: '签名已更新',
    );
  }

  Future<void> _save(
    ProfilePatch patch, {
    required String successMessage,
  }) async {
    setState(() => _busy = true);
    try {
      final Profile profile = await widget.gateway.saveProfile(patch);
      if (!mounted) {
        return;
      }
      setState(() {
        _profile = profile;
        _changed = true;
        _busy = false;
      });
      _showSnack(successMessage);
    } on AuthFailure catch (failure) {
      if (!mounted) {
        return;
      }
      setState(() => _busy = false);
      _showSnack(_failureMessage(failure));
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() => _busy = false);
      _showSnack('保存失败，请稍后重试');
    }
  }

  Future<void> _changeAvatar() async {
    // Android has no typeable path: the local entry is the system gallery.
    final bool galleryMode =
        Theme.of(context).platform == TargetPlatform.android;
    final _AvatarChoice? choice = await showDialog<_AvatarChoice>(
      context: context,
      builder: (BuildContext context) => _AvatarSourceDialog(
        picker: widget.avatarPicker ?? const FileSelectorAvatarImagePicker(),
        decodeCheck: widget.avatarDecodeCheck ?? isDecodableAvatarImage,
        reader: widget.avatarSourceReader ?? DefaultAvatarSourceReader(),
        galleryMode: galleryMode,
      ),
    );
    if (choice == null) {
      return;
    }
    setState(() => _busy = true);
    try {
      final AvatarInfo info;
      switch (choice.source) {
        case 'path':
          info = await widget.gateway.updateAvatarFromPath(choice.value);
        case 'url':
          info = await widget.gateway.updateAvatarFromUrl(choice.value);
        case 'bytes':
          info = await widget.gateway.updateAvatarFromBytes(choice.bytes!);
        default:
          info = await widget.gateway.updateAvatarFromBase64(choice.value);
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _busy = false;
        _changed = true;
        if (_profile != null) {
          _profile = Profile(
            account: _profile!.account,
            username: _profile!.username,
            signature: _profile!.signature,
            avatarUrl: info.avatarUrl,
            avatarVersion: info.avatarVersion,
          );
        }
      });
      // Fetch the server's re-encoded PNG instead of showing the upload bytes.
      await _reloadAvatar();
      _showSnack('头像已更新');
    } on AuthFailure catch (failure) {
      if (!mounted) {
        return;
      }
      setState(() => _busy = false);
      _showSnack(_failureMessage(failure));
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() => _busy = false);
      _showSnack('头像更新失败，请稍后重试');
    }
  }

  Future<void> _removeAvatar() async {
    setState(() => _busy = true);
    try {
      await widget.gateway.removeAvatar();
      if (!mounted) {
        return;
      }
      setState(() {
        _busy = false;
        _changed = true;
      });
      await _reloadAvatar();
      _showSnack('已恢复默认头像');
    } on AuthFailure catch (failure) {
      if (!mounted) {
        return;
      }
      setState(() => _busy = false);
      _showSnack(_failureMessage(failure));
    }
  }

  void _openHome() {
    Navigator.of(context).pop(
      ProfilePanelResult(
        openHomeAccount: _profile?.account ?? widget.user.account,
      ),
    );
  }

  Future<void> _viewOtherAccount() async {
    final String? account = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => const _AccountLookupDialog(),
    );
    if (account == null || !mounted) {
      return;
    }
    try {
      final Profile profile = await widget.gateway.loadProfile(
        account: account,
      );
      final AvatarImage image = await widget.gateway.loadAvatar(
        account: account,
      );
      if (!mounted) {
        return;
      }
      final String? openHome = await showDialog<String>(
        context: context,
        builder: (BuildContext context) =>
            _OtherProfileDialog(profile: profile, avatar: image.bytes),
      );
      if (openHome != null && mounted) {
        Navigator.of(context)
            .pop(ProfilePanelResult(openHomeAccount: openHome));
      }
    } on AuthFailure catch (failure) {
      _showSnack(_failureMessage(failure));
    }
  }

  Future<void> _logout() async {
    setState(() => _busy = true);
    try {
      final LogoutResult result = await widget.onLogout();
      if (!mounted) {
        return;
      }
      Navigator.of(
        context,
      ).pop(ProfilePanelResult(changed: true, signedOut: true, logout: result));
    } on AuthFailure catch (failure) {
      if (!mounted) {
        return;
      }
      setState(() => _busy = false);
      _showSnack(failure.message);
    }
  }

  void _showSnack(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  String _failureMessage(AuthFailure failure) {
    if (failure.fields.isNotEmpty) {
      return failure.fields.first.message;
    }
    return failure.message;
  }

  void _close() {
    Navigator.of(context).pop(ProfilePanelResult(changed: _changed));
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) =>
          _buildContent(
            context,
            Size(constraints.maxWidth, constraints.maxHeight),
          ),
    );
  }

  /// Shared cover-led content, sized to the actual presentation container.
  Widget _buildContent(BuildContext context, Size viewport) {
    final TextTheme text = Theme.of(context).textTheme;
    final Profile? profile = _profile;
    final String nickname = profile?.username ?? widget.user.username;
    final String account = profile?.account ?? widget.user.account;
    final String? signature = profile?.signature;
    final bool hasSignature = signature != null && signature.isNotEmpty;
    final EdgeInsets insets = MediaQuery.paddingOf(context);
    final double coverHeight = profileCoverHeight(viewport);
    final double avatarSize = viewport.width < 360 ? 92 : 104;
    final double avatarLeft = AppSpacing.lg;
    final double avatarOverhang = avatarSize * 0.55;
    // Enlarged text cannot share the seam row with the photo: the name moves
    // below the avatar and the two actions stack, so nothing is squeezed or
    // clipped at 200 %.
    final bool largeText = MediaQuery.textScalerOf(context).scale(1) > 1.35;
    final bool stackActions = largeText || viewport.width < 340;

    final Widget nameBlock = Padding(
      padding: EdgeInsets.only(
        right: AppSpacing.lg,
        left: largeText ? AppSpacing.lg : 0,
        top: largeText ? avatarOverhang + AppSpacing.sm : 10,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            nickname,
            key: ProfilePanel.nicknameValueKey,
            style: text.headlineSmall?.copyWith(
              fontSize: 24,
              fontWeight: FontWeight.w700,
              height: 1.18,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: <Widget>[
              Text(
                '账号  ',
                style: text.bodySmall?.copyWith(color: AppColors.inkMuted),
              ),
              Flexible(
                child: Text(
                  account,
                  key: ProfilePanel.accountValueKey,
                  style: text.bodyMedium?.copyWith(
                    color: AppColors.inkMuted,
                    letterSpacing: 1.1,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );

    return Column(
      key: ProfilePanel.panelKey,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(
          child: SingleChildScrollView(
            padding: EdgeInsets.only(bottom: AppSpacing.xl + insets.bottom),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Stack(
                  clipBehavior: Clip.none,
                  children: <Widget>[
                    ProfileSeaCover(
                      height: coverHeight,
                      imageBytes: _cover?.bytes,
                      imageMimeType: _cover?.mimeType,
                      backBar: Padding(
                        padding: EdgeInsets.only(
                          top: insets.top + AppSpacing.sm,
                          bottom: AppSpacing.sm,
                        ),
                        child: _profileBackBar(context),
                      ),
                    ),
                    Positioned(
                      left: avatarLeft,
                      top: coverHeight - avatarOverhang,
                      child: Hero(
                        tag: ProfilePanel.avatarHeroTag,
                        flightShuttleBuilder: ProfilePanel.avatarFlightShuttle,
                        child: ScallopedAvatar(
                          bytes: _avatar,
                          size: avatarSize,
                          loading: _loading && _avatar == null,
                          onTap: _busy ? null : _changeAvatar,
                          semanticLabel: '更换头像',
                        ),
                      ),
                    ),
                  ],
                ),
                if (largeText)
                  nameBlock
                else
                  // The name column starts beside the overhanging avatar; the
                  // minimum height keeps the signature below the avatar even
                  // when the nickname is a single short line.
                  ConstrainedBox(
                    constraints: BoxConstraints(minHeight: avatarOverhang),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        SizedBox(
                          width: avatarLeft + avatarSize + AppSpacing.md,
                        ),
                        Expanded(child: nameBlock),
                      ],
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    AppSpacing.md,
                    AppSpacing.lg,
                    0,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        '签名',
                        style: text.labelMedium?.copyWith(
                          color: AppColors.inkMuted,
                          letterSpacing: 1.2,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        hasSignature ? signature : '还没有签名',
                        key: ProfilePanel.signatureValueKey,
                        style: text.bodyLarge?.copyWith(
                          height: 1.5,
                          color: hasSignature
                              ? AppColors.ink
                              : AppColors.inkMuted,
                          fontStyle: hasSignature ? null : FontStyle.italic,
                        ),
                      ),
                    ],
                  ),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.lg,
                      AppSpacing.md,
                      AppSpacing.lg,
                      0,
                    ),
                    child: Text(
                      _error!,
                      key: ProfilePanel.errorKey,
                      style: text.bodySmall?.copyWith(color: AppColors.danger),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    AppSpacing.xl,
                    AppSpacing.lg,
                    0,
                  ),
                  child: stackActions
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            _editButton(),
                            const SizedBox(height: AppSpacing.sm),
                            _homeButton(),
                          ],
                        )
                      : Row(
                          children: <Widget>[
                            Expanded(child: _editButton()),
                            const SizedBox(width: AppSpacing.md),
                            Expanded(child: _homeButton()),
                          ],
                        ),
                ),
                const SizedBox(height: AppSpacing.lg),
                _ProfileEntry(
                  key: ProfilePanel.otherProfileKey,
                  icon: Icons.people_outline_rounded,
                  label: '查看其他账号资料',
                  onTap: _busy ? null : _viewOtherAccount,
                ),
                const _ProfileDivider(),
                _ProfileEntry(
                  key: ProfilePanel.settingsButtonKey,
                  icon: Icons.settings_outlined,
                  label: '设置',
                  onTap: _busy
                      ? null
                      : () => Navigator.of(context)
                            .pop(const ProfilePanelResult(openSettings: true)),
                ),
                const _ProfileDivider(),
                _ProfileEntry(
                  key: ProfilePanel.logoutButtonKey,
                  icon: Icons.logout_rounded,
                  label: '退出登录',
                  danger: true,
                  trailing: false,
                  onTap: _busy ? null : _logout,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    AppSpacing.xs,
                    AppSpacing.lg,
                    AppSpacing.lg,
                  ),
                  child: Text('退出登录会删除服务端该会话，并清除本机凭据。', style: text.bodySmall),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _profileBackBar(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Row(
      children: <Widget>[
        DecoratedBox(
          decoration: const BoxDecoration(
            color: Color(0x3D0B1020),
            shape: BoxShape.circle,
          ),
          child: IconButton(
            key: ProfilePanel.closeButtonKey,
            onPressed: _close,
            tooltip: widget.mode == ProfilePanelMode.desktop ? '关闭' : '返回',
            color: AppColors.surface,
            icon: Icon(
              widget.mode == ProfilePanelMode.desktop
                  ? Icons.close_rounded
                  : Icons.arrow_back_rounded,
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            '个人资料',
            style: text.titleLarge?.copyWith(
              color: AppColors.surface,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (_busy || _loading)
          const Padding(
            padding: EdgeInsets.only(right: AppSpacing.md),
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppColors.surface,
              ),
            ),
          ),
      ],
    );
  }

  Widget _editButton() {
    return FilledButton.icon(
      key: ProfilePanel.editProfileKey,
      onPressed: _busy ? null : _openEditSheet,
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 48),
        backgroundColor: AppColors.accentDeep,
        foregroundColor: AppColors.surface,
        shape: const StadiumBorder(),
      ),
      icon: const Icon(Icons.edit_outlined, size: 18),
      label: const Text('编辑资料', maxLines: 1, overflow: TextOverflow.ellipsis),
    );
  }

  Widget _homeButton() {
    return FilledButton.icon(
      key: ProfilePanel.homeButtonKey,
      onPressed: _busy ? null : _openHome,
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 48),
        backgroundColor: AppColors.accentSoft,
        foregroundColor: AppColors.accentDeep,
        shape: const StadiumBorder(),
      ),
      icon: const Icon(Icons.person_outline_rounded, size: 18),
      label: const Text('个人主页', maxLines: 1, overflow: TextOverflow.ellipsis),
    );
  }

  /// One sheet for everything the reference page no longer shows inline.
  ///
  /// Every action closes the sheet and runs the existing handler, so the photo
  /// picker and text editors stay exactly the surfaces they were; nothing is
  /// duplicated and a saved value rebuilds the page behind the sheet.
  Future<void> _openEditSheet() async {
    final Profile? profile = _profile;
    final String nickname = profile?.username ?? widget.user.username;
    final String? signature = profile?.signature;
    final String signatureText = (signature == null || signature.isEmpty)
        ? '还没有签名'
        : signature;
    final _ProfileEditAction?
    action = await showModalBottomSheet<_ProfileEditAction>(
      context: context,
      showDragHandle: true,
      backgroundColor: AppColors.paper,
      isScrollControlled: true,
      builder: (BuildContext sheetContext) {
        final TextTheme text = Theme.of(sheetContext).textTheme;
        return SafeArea(
          child: SingleChildScrollView(
            child: Padding(
              key: ProfilePanel.editSheetKey,
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                0,
                AppSpacing.lg,
                AppSpacing.lg,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(
                    '编辑资料',
                    style: text.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  OverflowBar(
                    alignment: MainAxisAlignment.spaceBetween,
                    spacing: AppSpacing.md,
                    overflowSpacing: AppSpacing.sm,
                    children: <Widget>[
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          ProfileAvatar(
                            bytes: _avatar,
                            size: 48,
                            showBorder: false,
                          ),
                          const SizedBox(width: AppSpacing.md),
                          Text(
                            '头像',
                            style: text.bodyLarge?.copyWith(
                              color: AppColors.ink,
                            ),
                          ),
                        ],
                      ),
                      Wrap(
                        runSpacing: AppSpacing.xs,
                        children: <Widget>[
                          TextButton(
                            onPressed: () =>
                                Navigator.of(sheetContext)
                                    .pop(_ProfileEditAction.changeAvatar),
                            child: const Text('更换头像'),
                          ),
                          TextButton(
                            key: ProfilePanel.removeAvatarKey,
                            onPressed: () =>
                                Navigator.of(sheetContext)
                                    .pop(_ProfileEditAction.removeAvatar),
                            child: const Text('移除'),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const Divider(height: AppSpacing.lg, color: AppColors.border),
                  ListTile(
                    key: ProfilePanel.changeCoverKey,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.landscape_outlined, size: 20),
                    title: const Text('封面'),
                    subtitle: Text(
                      _cover?.isDefault ?? true
                          ? '当前为默认海浪，点按上传替换'
                          : '已使用自己的封面，点按替换',
                    ),
                    trailing: const Icon(Icons.edit_outlined, size: 18),
                    onTap: () =>
                        Navigator.of(sheetContext)
                            .pop(_ProfileEditAction.cover),
                  ),
                  const Divider(height: AppSpacing.lg, color: AppColors.border),
                  ListTile(
                    key: ProfilePanel.editNicknameKey,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.badge_outlined, size: 20),
                    title: const Text('昵称'),
                    subtitle: Text(
                      nickname,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: const Icon(Icons.edit_outlined, size: 18),
                    onTap: () =>
                        Navigator.of(sheetContext)
                            .pop(_ProfileEditAction.nickname),
                  ),
                  const Divider(height: AppSpacing.lg, color: AppColors.border),
                  ListTile(
                    key: ProfilePanel.editSignatureKey,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.notes_rounded, size: 20),
                    title: const Text('签名'),
                    subtitle: Text(
                      signatureText,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: const Icon(Icons.edit_outlined, size: 18),
                    onTap: () =>
                        Navigator.of(sheetContext)
                            .pop(_ProfileEditAction.signature),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
    if (!mounted || action == null) {
      return;
    }
    switch (action) {
      case _ProfileEditAction.changeAvatar:
        await _changeAvatar();
      case _ProfileEditAction.removeAvatar:
        await _removeAvatar();
      case _ProfileEditAction.cover:
        await _changeCover();
      case _ProfileEditAction.nickname:
        await _editNickname();
      case _ProfileEditAction.signature:
        await _editSignature();
    }
  }
}

enum _ProfileEditAction {
  changeAvatar,
  removeAvatar,
  cover,
  nickname,
  signature,
}

/// A full-width settings row in the shared Profile content.
class _ProfileEntry extends StatelessWidget {
  const _ProfileEntry({
    super.key,
    required this.icon,
    required this.label,
    this.onTap,
    this.danger = false,
    this.trailing = true,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool danger;
  final bool trailing;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final Color ink = danger ? AppColors.danger : AppColors.ink;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.md,
          AppSpacing.lg,
          AppSpacing.md,
        ),
        child: Row(
          children: <Widget>[
            Icon(
              icon,
              size: 22,
              color: danger ? AppColors.danger : AppColors.inkMuted,
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Text(label, style: text.bodyLarge?.copyWith(color: ink)),
            ),
            if (trailing)
              const Icon(
                Icons.chevron_right_rounded,
                size: 22,
                color: AppColors.inkMuted,
              ),
          ],
        ),
      ),
    );
  }
}

class _ProfileDivider extends StatelessWidget {
  const _ProfileDivider();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.only(left: 62, right: AppSpacing.lg),
      child: Divider(height: 1, thickness: 1, color: AppColors.border),
    );
  }
}

class _TextEditDialog extends StatefulWidget {
  const _TextEditDialog({
    required this.title,
    required this.initial,
    required this.minCodePoints,
    required this.maxCodePoints,
    required this.helperText,
    this.allowEmpty = false,
  });

  final String title;
  final String initial;
  final int minCodePoints;
  final int maxCodePoints;
  final String helperText;
  final bool allowEmpty;

  static const Key fieldKey = Key('profile-edit-field');
  static const Key saveKey = Key('profile-edit-save');

  @override
  State<_TextEditDialog> createState() => _TextEditDialogState();
}

class _TextEditDialogState extends State<_TextEditDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  int get _length => codePointLength(_controller.text.trim());

  bool get _valid =>
      _length >= widget.minCodePoints &&
      _length <= widget.maxCodePoints &&
      (widget.allowEmpty || _length > 0);

  void _submit() {
    if (!_valid) {
      setState(() {
        _error = _length > widget.maxCodePoints
            ? '最多 ${widget.maxCodePoints} 个字符'
            : '至少 ${widget.minCodePoints} 个字符';
      });
      return;
    }
    Navigator.of(context).pop(_controller.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return AlertDialog(
      scrollable: true,
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      title: Text(widget.title, style: text.titleMedium),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          TextField(
            key: _TextEditDialog.fieldKey,
            controller: _controller,
            autofocus: true,
            minLines: 1,
            maxLines: 4,
            onChanged: (_) => setState(() => _error = null),
            decoration: InputDecoration(
              hintText: widget.helperText,
              counterText:
                  '${codePointLength(_controller.text)}/${widget.maxCodePoints}',
              errorText: _error,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(widget.helperText, style: text.bodySmall),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: _TextEditDialog.saveKey,
          onPressed: _valid ? _submit : null,
          style: FilledButton.styleFrom(minimumSize: const Size(88, 44)),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

/// The dialog's chosen avatar source.
///
/// `bytes` is set only for platform-picked image data that has no usable
/// filesystem path (Android returns a content URI). Every other source keeps the
/// existing path/url/base64 contract.
typedef _AvatarChoice = ({String source, String value, Uint8List? bytes});

enum _AvatarSourceKind { path, url, base64 }

class _AvatarSourceDialog extends StatefulWidget {
  const _AvatarSourceDialog({
    required this.picker,
    required this.decodeCheck,
    required this.reader,
    required this.galleryMode,
    this.subject = '头像',
    this.maxMegabytes = 5,
  });

  final AvatarImagePicker picker;
  final AvatarDecodeCheck decodeCheck;
  final AvatarSourceReader reader;

  /// Android has no typeable path: the local entry is the system gallery.
  final bool galleryMode;

  /// What is being replaced; the picker wording and limits change with it.
  final String subject;

  /// Server source limit for the subject: 5 MB avatar, 8 MB cover.
  final int maxMegabytes;

  static const Key fieldKey = Key('avatar-source-field');
  static const Key applyKey = Key('avatar-source-apply');
  static const Key pickFileKey = Key('avatar-pick-file');
  static const Key pickGalleryKey = Key('avatar-pick-gallery');
  static const Key previewKey = Key('avatar-preview');
  static const Key previewErrorKey = Key('avatar-preview-error');
  static const Key errorKey = Key('avatar-pick-error');

  @override
  State<_AvatarSourceDialog> createState() => _AvatarSourceDialogState();
}

class _AvatarSourceDialogState extends State<_AvatarSourceDialog> {
  /// Wait for typing to settle before reading the file for the preview.
  static const Duration _debounceDelay = Duration(milliseconds: 350);

  final TextEditingController _controller = TextEditingController();

  _AvatarSourceKind _kind = _AvatarSourceKind.path;
  String? _error;
  String? _previewError;
  Uint8List? _previewBytes;
  String? _previewedPath;
  Uint8List? _galleryBytes;
  String? _galleryName;
  Timer? _debounceTimer;

  /// In-flight preview/validation reads. The preview spinner shows while this
  /// is non-zero, and every read releases exactly one unit in `finally` — even
  /// when a source switch or a newer edit made its result stale. Busy state is
  /// owned by the operation that started it, never by the invalidation path
  /// (DEA-482 QA: a stale pick left the picker disabled forever).
  int _pendingReads = 0;

  /// In-flight platform picks plus their validation, counted for the same
  /// ownership reason as [_pendingReads].
  int _pendingPicks = 0;

  bool get _reading => _pendingReads > 0;

  bool get _picking => _pendingPicks > 0;

  /// The candidate the dialog currently represents. Every user action that
  /// changes it — typing (immediately, not after the debounce), switching the
  /// source kind, or starting a new pick — bumps this generation. Async work
  /// captures the generation it started for and may only land while that
  /// generation is still current, so a late pick decode can never overwrite a
  /// newer typed path and a stale read can never replace the preview.
  ///
  /// Busy state is separate: see [_pendingReads]/[_pendingPicks].
  int _generation = 0;

  bool get _isPathKind => _kind == _AvatarSourceKind.path;

  String get _pathLabel => widget.galleryMode ? '本机图片' : '本机路径';

  int get _maxBytes => widget.maxMegabytes * 1024 * 1024;

  String get _hint {
    final String subject = widget.subject;
    final int limit = widget.maxMegabytes;
    switch (_kind) {
      case _AvatarSourceKind.path:
        return widget.galleryMode
            ? '从系统相册选择 PNG/JPEG/WebP 图片（≤ $limit MB）；选择后点「应用」才会更新$subject。'
            : '输入绝对路径或点「选择图片」；预览无误后点「应用」才会更新$subject。';
      case _AvatarSourceKind.url:
        return 'https://…（客户端下载，只接受 PNG/JPEG/WebP，≤$limit MB）';
      case _AvatarSourceKind.base64:
        return '原始 base64 或 data:image/png;base64,…';
    }
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _selectKind(Set<_AvatarSourceKind> selection) {
    final _AvatarSourceKind kind = selection.first;
    if (kind == _kind) {
      return;
    }
    _debounceTimer?.cancel();
    _generation += 1;
    setState(() {
      _kind = kind;
      _error = null;
      _previewError = null;
      _previewBytes = null;
      _previewedPath = null;
      _galleryBytes = null;
      _galleryName = null;
    });
  }

  void _onPathChanged(String value) {
    _debounceTimer?.cancel();
    // Ownership changes with the first keystroke, not after the debounce: a
    // pick/decode/preview read started for the previous text must not land on
    // the newly typed candidate. The timer below only delays starting the new
    // preview read.
    final int generation = ++_generation;
    final String path = value.trim();
    setState(() {
      _error = null;
      _previewBytes = null;
      _previewedPath = null;
      _previewError = null;
    });
    if (path.isEmpty) {
      return;
    }
    _debounceTimer = Timer(
      _debounceDelay,
      () => unawaited(_loadPathPreview(path, generation)),
    );
  }

  Future<void> _loadPathPreview(String path, int generation) async {
    setState(() {
      _pendingReads += 1;
      _previewError = null;
    });
    try {
      final Uint8List bytes = await _validatePathBytes(path);
      if (!mounted || generation != _generation) {
        return;
      }
      setState(() {
        _previewBytes = bytes;
        _previewedPath = path;
      });
    } catch (error) {
      if (!mounted || generation != _generation) {
        return;
      }
      setState(() {
        _previewBytes = null;
        _previewedPath = null;
        _previewError = _errorMessage(error);
      });
    } finally {
      if (mounted) {
        setState(() => _pendingReads -= 1);
      }
    }
  }

  /// Reads and validates a typed/selected path through the same reader the
  /// upload uses, then proves the bytes actually decode.
  Future<Uint8List> _validatePathBytes(String path) async {
    final Uint8List bytes = await widget.reader.readPath(
      path,
      maxBytes: _maxBytes,
    );
    if (!await widget.decodeCheck(bytes)) {
      throw const AvatarPickFailure('这个文件无法解码为图片，请换一张');
    }
    return bytes;
  }

  Future<void> _pick() async {
    if (_picking) {
      return;
    }
    // A new pick represents a new candidate; results for the previous typed
    // text or an older pick are invalid from here on.
    final int generation = ++_generation;
    setState(() {
      _pendingPicks += 1;
      _error = null;
    });
    try {
      final AvatarPick? pick = await _requestPick();
      if (pick == null || !mounted) {
        // Cancelling the system dialog keeps the typed path, the preview and
        // the current avatar untouched.
        return;
      }
      await _applyPick(pick, generation);
    } finally {
      // Runs for cancel, stale results and failures alike: the operation that
      // started the busy state always releases it.
      if (mounted) {
        setState(() => _pendingPicks -= 1);
      }
    }
  }

  Future<AvatarPick?> _requestPick() async {
    try {
      return await widget.picker.pickImage();
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = widget.galleryMode ? '无法打开系统相册，请稍后重试' : '无法打开系统文件选择器，请稍后重试';
        });
      }
      return null;
    }
  }

  Future<void> _applyPick(AvatarPick selected, int generation) async {
    try {
      // The platform picked this file, but its bytes still go through the same
      // size/magic/decode checks as a typed path.
      final Uint8List bytes =
          selected.bytes ??
          await widget.reader.readPath(
            selected.path ?? '',
            maxBytes: _maxBytes,
          );
      validateAvatarBytes(
        bytes,
        sourceField: 'path',
        maxBytes: _maxBytes,
        subject: widget.subject,
      );
      if (!await widget.decodeCheck(bytes)) {
        throw const AvatarPickFailure('这个文件无法解码为图片，请换一张');
      }
      if (!mounted || generation != _generation) {
        return;
      }
      setState(() {
        _error = null;
        _previewError = null;
        _previewBytes = bytes;
        if (widget.galleryMode) {
          _galleryBytes = bytes;
          _galleryName = selected.name;
          _previewedPath = null;
        } else {
          _galleryBytes = null;
          _galleryName = null;
          final String? path = selected.path;
          if (path != null && path.isNotEmpty) {
            // Keep the path field and the picked file in sync; the field stays
            // the single source of truth for the desktop entry.
            _controller.text = path;
            _previewedPath = path;
          } else {
            _previewedPath = null;
          }
        }
      });
    } catch (error) {
      if (!mounted || generation != _generation) {
        return;
      }
      setState(() {
        _previewBytes = null;
        _previewedPath = null;
        _galleryBytes = null;
        _galleryName = null;
        _previewError = _errorMessage(error);
      });
    }
  }

  Future<void> _apply() async {
    if (widget.galleryMode && _isPathKind) {
      final Uint8List? bytes = _galleryBytes;
      if (bytes == null) {
        setState(() => _error = '请先从相册选择图片');
        return;
      }
      Navigator.of(context).pop<_AvatarChoice>((
        source: 'bytes',
        value: _galleryName ?? '',
        bytes: bytes,
      ));
      return;
    }
    if (!_isPathKind) {
      final String value = _controller.text.trim();
      if (value.isEmpty) {
        setState(() => _error = '请填写内容');
        return;
      }
      Navigator.of(context)
          .pop<_AvatarChoice>((source: _kind.name, value: value, bytes: null));
      return;
    }
    final String path = _controller.text.trim();
    if (path.isEmpty) {
      setState(() => _error = '请填写图片路径或点「选择图片」');
      return;
    }
    if (path == _previewedPath &&
        _previewBytes != null &&
        _previewError == null) {
      Navigator.of(context)
          .pop<_AvatarChoice>((source: 'path', value: path, bytes: null));
      return;
    }
    final int generation = _generation;
    setState(() {
      _pendingReads += 1;
      _error = null;
    });
    try {
      final Uint8List bytes = await _validatePathBytes(path);
      if (!mounted || generation != _generation) {
        return;
      }
      setState(() {
        _previewBytes = bytes;
        _previewedPath = path;
        _previewError = null;
      });
      Navigator.of(context)
          .pop<_AvatarChoice>((source: 'path', value: path, bytes: null));
    } catch (error) {
      if (!mounted || generation != _generation) {
        return;
      }
      setState(() {
        _previewBytes = null;
        _previewedPath = null;
        _previewError = _errorMessage(error);
      });
    } finally {
      if (mounted) {
        setState(() => _pendingReads -= 1);
      }
    }
  }

  /// User-facing message only; raw exceptions never reach the dialog.
  String _errorMessage(Object error) {
    if (error is AuthFailure) {
      return error.fields.isNotEmpty
          ? error.fields.first.message
          : error.message;
    }
    if (error is AvatarPickFailure) {
      return error.message;
    }
    return '无法读取该图片，请稍后重试';
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return AlertDialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      title: Text('更换${widget.subject}', style: text.titleMedium),
      // A long path must not stretch the dialog: keep it a stable width and let
      // the text field scroll/wrap inside instead (verified in the real Linux
      // entry with a ~90-character Chinese path).
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SegmentedButton<_AvatarSourceKind>(
                segments: _AvatarSourceKind.values
                    .map(
                      (_AvatarSourceKind kind) =>
                          ButtonSegment<_AvatarSourceKind>(
                            value: kind,
                            label: Text(_labelFor(kind)),
                          ),
                    )
                    .toList(growable: false),
                selected: <_AvatarSourceKind>{_kind},
                showSelectedIcon: false,
                onSelectionChanged: _selectKind,
              ),
              const SizedBox(height: AppSpacing.md),
              if (_isPathKind)
                ..._buildPathEntry(text)
              else
                TextField(
                  key: _AvatarSourceDialog.fieldKey,
                  controller: _controller,
                  minLines: 2,
                  maxLines: 5,
                  decoration: InputDecoration(
                    hintText: _hint,
                    errorText: _error,
                  ),
                  onChanged: (_) => setState(() => _error = null),
                ),
              const SizedBox(height: AppSpacing.sm),
              Text(_hint, style: text.bodySmall),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: _AvatarSourceDialog.applyKey,
          onPressed: _apply,
          style: FilledButton.styleFrom(minimumSize: const Size(88, 44)),
          child: const Text('应用'),
        ),
      ],
    );
  }

  String _labelFor(_AvatarSourceKind kind) {
    return switch (kind) {
      _AvatarSourceKind.path => _pathLabel,
      _AvatarSourceKind.url => '图片链接',
      _AvatarSourceKind.base64 => 'Base64',
    };
  }

  List<Widget> _buildPathEntry(TextTheme text) {
    return <Widget>[
      if (widget.galleryMode) ...<Widget>[
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonalIcon(
            key: _AvatarSourceDialog.pickGalleryKey,
            onPressed: _picking ? null : _pick,
            style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
            icon: const Icon(Icons.photo_library_outlined, size: 18),
            label: Text(_picking ? '正在打开相册…' : '从相册选择'),
          ),
        ),
        if (_galleryName != null)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.xs),
            child: Text(
              '已选择：$_galleryName',
              style: text.bodySmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.xs),
            child: Text(
              _error!,
              key: _AvatarSourceDialog.errorKey,
              style: text.bodySmall?.copyWith(color: AppColors.danger),
            ),
          ),
      ] else
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: TextField(
                key: _AvatarSourceDialog.fieldKey,
                controller: _controller,
                minLines: 2,
                maxLines: 5,
                decoration: InputDecoration(
                  hintText: '例如 /home/me/avatar.png',
                  errorText: _error,
                ),
                onChanged: _onPathChanged,
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: OutlinedButton(
                key: _AvatarSourceDialog.pickFileKey,
                onPressed: _picking ? null : _pick,
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
                child: Text(_picking ? '选择中…' : '选择图片'),
              ),
            ),
          ],
        ),
      const SizedBox(height: AppSpacing.sm),
      Center(
        child: Container(
          key: _AvatarSourceDialog.previewKey,
          width: 112,
          height: 112,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.accentSoft,
            border: Border.all(color: AppColors.border),
          ),
          child: _reading
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : _previewError != null
              ? const Icon(
                  Icons.broken_image_outlined,
                  color: AppColors.danger,
                  size: 28,
                )
              : ProfileAvatar(
                  bytes: _previewBytes,
                  size: 96,
                  showBorder: false,
                ),
        ),
      ),
      if (_previewError != null)
        Padding(
          padding: const EdgeInsets.only(top: AppSpacing.xs),
          child: Text(
            _previewError!,
            key: _AvatarSourceDialog.previewErrorKey,
            style: text.bodySmall?.copyWith(color: AppColors.danger),
            textAlign: TextAlign.center,
          ),
        ),
    ];
  }
}

class _AccountLookupDialog extends StatefulWidget {
  const _AccountLookupDialog();

  static const Key fieldKey = Key('account-lookup-field');
  static const Key submitKey = Key('account-lookup-submit');

  @override
  State<_AccountLookupDialog> createState() => _AccountLookupDialogState();
}

class _AccountLookupDialogState extends State<_AccountLookupDialog> {
  final TextEditingController _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final String value = _controller.text.trim();
    if (!RegExp(r'^[0-9]{8}$').hasMatch(value)) {
      setState(() => _error = '请输入 8 位数字账号');
      return;
    }
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surface,
      title: const Text('查看其他账号'),
      content: TextField(
        key: _AccountLookupDialog.fieldKey,
        controller: _controller,
        keyboardType: TextInputType.number,
        maxLength: 8,
        decoration: InputDecoration(hintText: '8 位账号', errorText: _error),
        onChanged: (_) => setState(() => _error = null),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: _AccountLookupDialog.submitKey,
          onPressed: _submit,
          style: FilledButton.styleFrom(minimumSize: const Size(88, 44)),
          child: const Text('查看'),
        ),
      ],
    );
  }
}

class _OtherProfileDialog extends StatelessWidget {
  const _OtherProfileDialog({required this.profile, required this.avatar});

  final Profile profile;
  final Uint8List avatar;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return AlertDialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          ProfileAvatar(bytes: avatar, size: 88, showBorder: false),
          const SizedBox(height: AppSpacing.md),
          Text(profile.username, style: text.titleMedium),
          const SizedBox(height: AppSpacing.xs),
          Text(profile.account, style: text.bodySmall),
          const SizedBox(height: AppSpacing.sm),
          Text(
            profile.signature ?? '还没有签名',
            style: text.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ],
      ),
      actions: <Widget>[
        FilledButton.icon(
          key: const Key('profile-other-home'),
          onPressed: () => Navigator.of(context).pop(profile.account),
          icon: const Icon(Icons.account_circle_outlined, size: 18),
          label: const Text('个人主页'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
