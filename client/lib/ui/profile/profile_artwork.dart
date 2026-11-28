import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../app.dart';
import '../widgets/profile_avatar.dart';

/// Height of the phone Profile cover.
///
/// The issue asks for the cover to take about a quarter of a normal portrait
/// phone screen; the clamps keep that ratio honest on very short phones (where
/// a pure ratio would squash the back bar) and on tall ones (where it would
/// start to look like a full-page wallpaper).
double profileCoverHeight(Size viewport) =>
    (viewport.height * 0.25).clamp(168.0, 260.0);

/// Shared packaged default cover (the sea-wave crop from the approved mockup).
///
/// The server owns the displayed cover and returns this same crop for accounts
/// without an upload; the bundle copy only bridges the first frames while the
/// fetch is in flight.
const String defaultCoverAsset = 'assets/profile/default-cover.png';

/// The sea-wave header band.
///
/// The displayed image comes from the server (`GET /covers/{account}`). While
/// loading, or when the fetch has not produced bytes yet, the identical
/// packaged crop is shown; the painted fallback only covers a missing asset, so
/// the header never flashes an empty rectangle. The cover is a header band, not
/// a page wallpaper, and the back affordance stays legible over the scrim.
class ProfileSeaCover extends StatelessWidget {
  const ProfileSeaCover({
    super.key,
    required this.height,
    this.backBar,
    this.imageBytes,
    this.imageMimeType,
    this.loading = false,
    this.fadeDuration = Duration.zero,
    this.topScrimHeightFactor = 0.5,
    this.topScrimMaxAlpha = 0.45,
    this.bottomScrimHeightFactor = 0.3,
    this.bottomScrimMaxAlpha = 0.28,
  });

  final double height;

  /// Back button + title row, laid over the sky.
  final Widget? backBar;

  /// Server display bytes (custom cover or the default image).
  final Uint8List? imageBytes;
  final String? imageMimeType;

  /// Shows the animated shimmer sweep while waiting for a cover response when
  /// motion is enabled.
  final bool loading;

  /// Crossfade duration when swapping cover images; zero skips animation.
  final Duration fadeDuration;
  final double topScrimHeightFactor;
  final double topScrimMaxAlpha;
  final double bottomScrimHeightFactor;
  final double bottomScrimMaxAlpha;

  static const Key coverKey = Key('profile-cover');
  static const Key defaultCoverKey = Key('profile-cover-default');
  static const Key loadingShimmerKey = Key('profile-cover-shimmer');

  @override
  Widget build(BuildContext context) {
    final Uint8List? bytes = imageBytes;
    final Widget image;
    if (bytes != null && bytes.isNotEmpty) {
      image = Image.memory(
        bytes,
        key: ValueKey<Uint8List>(bytes),
        fit: BoxFit.cover,
        gaplessPlayback: true,
        alignment: Alignment.center,
        errorBuilder: (BuildContext context, Object error, StackTrace? stack) =>
            _paintedFallback(),
      );
    } else {
      image = Image.asset(
        defaultCoverAsset,
        key: defaultCoverKey,
        fit: BoxFit.cover,
        alignment: Alignment.center,
        errorBuilder: (BuildContext context, Object error, StackTrace? stack) =>
            _paintedFallback(),
      );
    }
    final Widget art = fadeDuration > Duration.zero
        ? AnimatedSwitcher(
            duration: fadeDuration,
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            layoutBuilder:
                (Widget? currentChild, List<Widget> previousChildren) => Stack(
                  fit: StackFit.expand,
                  children: <Widget>[...previousChildren, ?currentChild],
                ),
            child: image,
          )
        : image;
    final bool showShimmer =
        loading && !MediaQuery.disableAnimationsOf(context);
    return SizedBox(
      key: coverKey,
      height: height,
      width: double.infinity,
      child: ColoredBox(
        color: const Color(0xFF101A2A),
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            art,
            _CoverScrims(
              topHeightFactor: topScrimHeightFactor,
              topMaxAlpha: topScrimMaxAlpha,
              bottomHeightFactor: bottomScrimHeightFactor,
              bottomMaxAlpha: bottomScrimMaxAlpha,
            ),
            if (showShimmer) const _CoverShimmer(key: loadingShimmerKey),
            if (backBar != null)
              Positioned(
                left: 4,
                right: AppSpacing.lg,
                top: 0,
                child: backBar!,
              ),
          ],
        ),
      ),
    );
  }

  Widget _paintedFallback() => const CustomPaint(painter: _SeaPainter());
}

/// Top and bottom scrims shared by the image and the painted fallback.
class _CoverScrims extends StatelessWidget {
  const _CoverScrims({
    required this.topHeightFactor,
    required this.topMaxAlpha,
    required this.bottomHeightFactor,
    required this.bottomMaxAlpha,
  });

  final double topHeightFactor;
  final double topMaxAlpha;
  final double bottomHeightFactor;
  final double bottomMaxAlpha;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          Align(
            alignment: Alignment.topCenter,
            child: FractionallySizedBox(
              heightFactor: topHeightFactor,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: <Color>[
                      const Color(0xFF0B1020).withValues(alpha: topMaxAlpha),
                      const Color(0xFF0B1020).withValues(alpha: 0),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: FractionallySizedBox(
              heightFactor: bottomHeightFactor,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: <Color>[
                      const Color(0xFF101A2A).withValues(alpha: 0),
                      const Color(0xFF101A2A).withValues(alpha: bottomMaxAlpha),
                    ],
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

class _CoverShimmer extends StatefulWidget {
  const _CoverShimmer({super.key});

  @override
  State<_CoverShimmer> createState() => _CoverShimmerState();
}

class _CoverShimmerState extends State<_CoverShimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1700),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: IgnorePointer(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (BuildContext context, Widget? _) {
            final double travel = _controller.value * 4.6;
            return DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment(-4.16 + travel, -0.20),
                  end: Alignment(0.24 + travel, 0.20),
                  stops: const <double>[0.16, 0.44, 0.72],
                  colors: const <Color>[
                    Color(0x00FFFFFF),
                    Color(0x6BFFFFFF),
                    Color(0x00FFFFFF),
                  ],
                ),
              ),
              child: const SizedBox.expand(),
            );
          },
        ),
      ),
    );
  }
}

class _SeaPainter extends CustomPainter {
  const _SeaPainter();

  static const Color _skyTop = Color(0xFF1B2138);
  static const Color _skyMid = Color(0xFF4C5677);
  static const Color _skyLow = Color(0xFFB48D88);
  static const Color _waterTop = Color(0xFF33405C);
  static const Color _waterBottom = Color(0xFF101A2A);
  static const Color _land = Color(0xFF141B2B);
  static const Color _moon = Color(0xFFEBC9A6);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) {
      return;
    }
    final double horizon = size.height * 0.56;
    final Rect skyRect = Rect.fromLTWH(0, 0, size.width, horizon);
    final Rect seaRect = Rect.fromLTWH(
      0,
      horizon,
      size.width,
      size.height - horizon,
    );

    canvas.drawRect(
      skyRect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[_skyTop, _skyMid, _skyLow],
          stops: <double>[0, 0.62, 1],
        ).createShader(skyRect),
    );

    final math.Random random = math.Random(5);

    // A few faint stars keep the upper sky from looking like a flat ramp.
    final Paint star = Paint();
    for (int i = 0; i < 16; i++) {
      star.color = const Color(0xFFF4E9DC)
          .withValues(alpha: 0.12 + random.nextDouble() * 0.3);
      canvas.drawCircle(
        Offset(
          size.width * random.nextDouble(),
          size.height * random.nextDouble() * 0.34,
        ),
        0.6 + random.nextDouble() * 0.9,
        star,
      );
    }

    // Moon and its soft halo.
    final Offset moon = Offset(size.width * 0.76, size.height * 0.23);
    final double moonRadius = math.min(size.width, size.height) * 0.048;
    canvas.drawCircle(
      moon,
      moonRadius * 4.2,
      Paint()
        ..shader = RadialGradient(
          colors: <Color>[
            _moon.withValues(alpha: 0.3),
            _moon.withValues(alpha: 0),
          ],
        ).createShader(Rect.fromCircle(center: moon, radius: moonRadius * 4.2)),
    );
    canvas.drawCircle(
      moon,
      moonRadius,
      Paint()..color = _moon.withValues(alpha: 0.95),
    );

    // Far headlands: soft curves that frame the water, low on the horizon.
    final Path leftRidge = Path()
      ..moveTo(0, horizon)
      ..lineTo(0, horizon - size.height * 0.1)
      ..quadraticBezierTo(
        size.width * 0.04,
        horizon - size.height * 0.17,
        size.width * 0.1,
        horizon - size.height * 0.19,
      )
      ..cubicTo(
        size.width * 0.17,
        horizon - size.height * 0.21,
        size.width * 0.22,
        horizon - size.height * 0.11,
        size.width * 0.31,
        horizon,
      )
      ..close();
    canvas.drawPath(leftRidge, Paint()..color = _land.withValues(alpha: 0.92));

    final Path rightRidge = Path()
      ..moveTo(size.width, horizon)
      ..lineTo(size.width, horizon - size.height * 0.08)
      ..quadraticBezierTo(
        size.width * 0.95,
        horizon - size.height * 0.16,
        size.width * 0.89,
        horizon - size.height * 0.16,
      )
      ..cubicTo(
        size.width * 0.84,
        horizon - size.height * 0.16,
        size.width * 0.8,
        horizon - size.height * 0.06,
        size.width * 0.76,
        horizon,
      )
      ..close();
    canvas.drawPath(rightRidge, Paint()..color = _land.withValues(alpha: 0.85));

    canvas.drawRect(
      seaRect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[_waterTop, _waterBottom],
        ).createShader(seaRect),
    );

    // The moon's reflection: a soft column that the glitter sits inside.
    final double pathWidth = size.width * 0.42;
    final Rect reflection = Rect.fromLTWH(
      moon.dx - pathWidth / 2,
      horizon - moonRadius,
      pathWidth,
      (size.height - horizon) * 0.92,
    );
    // Soft side edges: a horizontal gradient that fades to nothing at both
    // sides instead of a visible column boundary.
    canvas.drawRect(
      reflection,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: <Color>[
            _moon.withValues(alpha: 0),
            _moon.withValues(alpha: 0.14),
            _moon.withValues(alpha: 0),
          ],
          stops: const <double>[0, 0.5, 1],
        ).createShader(reflection),
    );

    // Glitter, concentrated under the moon and thinning towards the shore.
    final Paint glitter = Paint()..strokeCap = StrokeCap.round;
    for (double y = horizon + 2; y < size.height - 2; y += 3.6) {
      final double t = ((y - horizon) / (size.height - horizon)).clamp(
        0.0,
        1.0,
      );
      final double spread = size.width * (0.05 + t * 0.16);
      final int strokes = 1 + (t * 2.4).floor();
      for (int i = 0; i < strokes; i++) {
        final double x = moon.dx + (random.nextDouble() - 0.5) * 2 * spread;
        final double length = (2 + random.nextDouble() * 9) * (0.6 + t);
        glitter
          ..color = _moon.withValues(
            alpha: (0.42 - t * 0.3) * (0.5 + random.nextDouble() * 0.5),
          )
          ..strokeWidth = 0.8 + random.nextDouble() * 1.4;
        canvas.drawLine(Offset(x, y), Offset(x + length, y), glitter);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _SeaPainter oldDelegate) => false;
}

/// Avatar framed by the Material-3 cookie outline.
///
/// The photograph is a plain circle and never rotates. Only the cream outline
/// turns: on first appearance after the route/hero settles it sweeps the
/// scallops past the photo and comes to rest, then stays still for as long as
/// the page is open. There is no repeating ticker, so the page is never kept
/// awake by decoration.
class ScallopedAvatar extends StatefulWidget {
  const ScallopedAvatar({
    super.key,
    required this.bytes,
    required this.size,
    this.loading = false,
    this.onTap,
    this.semanticLabel,
    this.playRing = true,
    this.lobes = 9,
  });

  final Uint8List? bytes;
  final double size;
  final bool loading;
  final VoidCallback? onTap;
  final String? semanticLabel;

  /// Tests and reduced-motion builds can switch the landing sweep off; the
  /// resting outline is always the same shape.
  final bool playRing;

  /// Nine lobes mirrors the Material 3 `Cookie9Sided` reference shape.
  final int lobes;

  static const Key plateKey = Key('profile-avatar-plate');
  static const Key photoKey = Key('profile-avatar-photo');
  static const Key ringRotationKey = Key('profile-avatar-ring');

  /// One full lobe period at nine lobes.
  static const double sweepTurns = 0.42;

  @override
  State<ScallopedAvatar> createState() => _ScallopedAvatarState();
}

class _ScallopedAvatarState extends State<ScallopedAvatar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );
  late final Animation<double> _turns = Tween<double>(
    begin: -ScallopedAvatar.sweepTurns,
    end: 0,
  ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));

  bool _planned = false;
  bool _started = false;
  bool _restingOnly = false;
  Animation<double>? _routeAnimation;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_planned) {
      return;
    }
    _planned = true;
    _planRingSweep();
  }

  /// The sweep belongs after landing: while a hero flight or route transition
  /// is still running the outline waits, so the photo appears to arrive and
  /// only then settle its rim.
  void _planRingSweep() {
    if (MediaQuery.disableAnimationsOf(context)) {
      _restingOnly = true;
      _started = true;
      return;
    }
    if (!widget.playRing) {
      _started = true;
      return;
    }
    final Animation<double>? route = ModalRoute.of(context)?.animation;
    if (route == null || route.status == AnimationStatus.completed) {
      _started = true;
      _controller.forward(from: 0);
      return;
    }
    _routeAnimation = route;
    route.addStatusListener(_onRouteStatus);
    if (route.status == AnimationStatus.completed) {
      _onRouteStatus(AnimationStatus.completed);
    }
  }

  void _onRouteStatus(AnimationStatus status) {
    if (_started || status != AnimationStatus.completed || !mounted) {
      return;
    }
    _started = true;
    _routeAnimation?.removeStatusListener(_onRouteStatus);
    _routeAnimation = null;
    _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _routeAnimation?.removeStatusListener(_onRouteStatus);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final double size = widget.size;
    final double photoSize = size * 0.78;
    final Widget photo = Container(
      key: ScallopedAvatar.photoKey,
      width: photoSize,
      height: photoSize,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.surface,
      ),
      padding: const EdgeInsets.all(2),
      child: ProfileAvatar(
        bytes: widget.bytes,
        size: photoSize - 4,
        showBorder: false,
        loading: widget.loading,
        semanticLabel: null,
      ),
    );

    final Widget plate = SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          RotationTransition(
            key: ScallopedAvatar.ringRotationKey,
            turns: widget.playRing && !_restingOnly
                ? _turns
                : const AlwaysStoppedAnimation<double>(0),
            // Expressive shape motion: the lobes are deepest while the rim
            // turns and relax back to the resting outline as it settles.
            child: AnimatedBuilder(
              animation: _turns,
              builder: (BuildContext context, Widget? child) {
                final double pass = _turns.value / -ScallopedAvatar.sweepTurns;
                return CustomPaint(
                  key: ScallopedAvatar.plateKey,
                  size: Size.square(size),
                  painter: _ScallopPainter(
                    lobes: 9,
                    depth: 0.085 + 0.05 * pass,
                    color: const Color(0xFFF1EBDD),
                  ),
                );
              },
            ),
          ),
          photo,
        ],
      ),
    );

    final Widget content = Semantics(
      button: widget.onTap != null,
      label: widget.semanticLabel ?? (widget.onTap == null ? '个人头像' : '更换头像'),
      child: SizedBox(
        width: size,
        height: size,
        child: widget.onTap == null
            ? plate
            : GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: widget.onTap,
                // Keep the whole plate tappable without wrapping it in an
                // InkWell: an ink splash would repaint the moving rim.
                child: plate,
              ),
      ),
    );
    return content;
  }
}

class _ScallopPainter extends CustomPainter {
  const _ScallopPainter({
    required this.lobes,
    required this.depth,
    required this.color,
  });

  final int lobes;
  final double depth;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final double radius = size.shortestSide / 2;
    final Offset center = size.center(Offset.zero);
    final Path path = _path(center, radius);
    canvas.drawShadow(path, const Color(0x33131A1B), 6, false);
    canvas.drawPath(path, Paint()..color = color);
  }

  Path _path(Offset center, double radius) {
    const int samples = 360;
    final Path path = Path();
    for (int i = 0; i <= samples; i++) {
      final double t = i / samples * 2 * math.pi;
      // Smooth petals: 9 lobes, same family as MaterialShapes Cookie9Sided.
      final double r = radius * (1 - depth + depth * math.cos(lobes * t));
      final double x = center.dx + r * math.cos(t);
      final double y = center.dy + r * math.sin(t);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    return path..close();
  }

  @override
  bool shouldRepaint(covariant _ScallopPainter oldDelegate) =>
      oldDelegate.lobes != lobes ||
      oldDelegate.depth != depth ||
      oldDelegate.color != color;
}
