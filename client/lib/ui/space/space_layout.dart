import 'dart:math' as math;
import 'dart:ui' show DisplayFeature;

import 'package:flutter/material.dart';

/// Width breakpoints are chosen after rendering the real widget at phone, PC
/// and simulated-fold sizes. They are UI policy, never device names.
abstract final class SpaceBreakpoints {
  /// Below this width the app uses the touch bottom bar and a single pane.
  static const double compact = 720;

  /// At or above this width a selected post gets a second, independent pane.
  static const double masterDetail = 900;

  /// Smallest pane that can still show a feed card or a detail column.
  static const double minPane = 320;

  /// Editor columns become side-by-side at this width.
  static const double composeTwoColumn = 1000;
}

/// Resolved layout for one Space frame.
///
/// Hinges and cutouts come from the platform's display features. A vertical
/// fold becomes the pane boundary; a horizontal fold confines content to the
/// larger usable band. Nothing here keys off a device name.
class SpaceLayout {
  const SpaceLayout({
    required this.size,
    required this.contentRect,
    required this.compact,
    required this.rail,
    required this.masterDetail,
    required this.verticalHingeX,
    required this.horizontalHingeY,
    required this.composeTwoColumn,
  });

  final Size size;

  /// The rect content may occupy without crossing an occlusion.
  final Rect contentRect;
  final bool compact;
  final bool rail;
  final bool masterDetail;

  /// Screen-space x of the vertical hinge, when one is present.
  final double? verticalHingeX;

  /// Screen-space y of the horizontal hinge, when one is present.
  final double? horizontalHingeY;
  final bool composeTwoColumn;

  double get contentWidth => contentRect.width;

  /// The feed/detail split, respecting the hinge when it lies inside the
  /// usable content. Both returned paddings keep content off the hinge.
  ({double leftWidth, double rightWidth}) panes() {
    if (!masterDetail) {
      return (leftWidth: contentWidth, rightWidth: 0);
    }
    final double hinge = verticalHingeX ?? contentRect.center.dx;
    final double gap = verticalHingeX == null ? 0 : 8;
    final double left = math.min(
      math.max(hinge - gap - contentRect.left, 0),
      contentWidth,
    );
    final double right = math.min(
      math.max(contentRect.right - hinge - gap, 0),
      contentWidth,
    );
    if (verticalHingeX == null) {
      final double leftWidth = math.min(
        math.max(contentWidth * 0.44, 380),
        math.min(560, contentWidth - SpaceBreakpoints.minPane),
      );
      return (leftWidth: leftWidth, rightWidth: contentWidth - leftWidth);
    }
    return (leftWidth: left, rightWidth: right);
  }

  /// Horizontal padding applied to one pane so content stays clear of a
  /// vertical hinge at its edge.
  EdgeInsets panePadding({required bool left}) {
    if (verticalHingeX == null) {
      return const EdgeInsets.symmetric(horizontal: 8);
    }
    return left
        ? const EdgeInsets.only(left: 8, right: 8)
        : const EdgeInsets.only(left: 8, right: 8);
  }

  static SpaceLayout of(BuildContext context) {
    final MediaQueryData media = MediaQuery.of(context);
    final Size size = media.size;
    DisplayFeature? vertical;
    DisplayFeature? horizontal;
    for (final DisplayFeature feature in media.displayFeatures) {
      final Rect bounds = feature.bounds;
      if (bounds.width <= 1 && bounds.height > 1) {
        vertical = feature;
      } else if (bounds.height <= 1 && bounds.width > 1) {
        horizontal = feature;
      } else if (bounds.width > 1 && bounds.height > 1) {
        // A cutout or a folded panel: keep content out of the larger axis.
        if (bounds.height >= bounds.width) {
          horizontal = feature;
        } else {
          vertical = feature;
        }
      }
    }

    Rect usable = Rect.fromLTWH(
      media.padding.left,
      media.padding.top,
      math.max(size.width - media.padding.horizontal, 0),
      math.max(size.height - media.padding.vertical, 0),
    );
    double? hingeY;
    if (horizontal != null) {
      final double y = horizontal.bounds.top;
      final Rect top = Rect.fromLTWH(
        usable.left,
        usable.top,
        usable.width,
        math.max(y - usable.top - 8, 0),
      );
      final Rect bottom = Rect.fromLTWH(
        usable.left,
        y + horizontal.bounds.height + 8,
        usable.width,
        math.max(usable.bottom - y - horizontal.bounds.height - 8, 0),
      );
      final bool useBottom = bottom.height >= top.height;
      usable = useBottom ? bottom : top;
      hingeY = y;
    }

    double? hingeX;
    if (vertical != null) {
      final double x = vertical.bounds.left;
      final Rect left = Rect.fromLTWH(
        usable.left,
        usable.top,
        math.max(x - usable.left - 8, 0),
        usable.height,
      );
      final Rect right = Rect.fromLTWH(
        x + vertical.bounds.width + 8,
        usable.top,
        math.max(usable.right - x - vertical.bounds.width - 8, 0),
        usable.height,
      );
      final bool bothFit =
          left.width >= SpaceBreakpoints.minPane &&
          right.width >= SpaceBreakpoints.minPane;
      if (!bothFit) {
        usable = left.width >= right.width ? left : right;
        hingeX = null;
      } else {
        hingeX = x;
      }
    }

    final bool compact = size.width < SpaceBreakpoints.compact;
    final bool wideEnough = size.width >= SpaceBreakpoints.masterDetail;
    final bool masterDetail =
        wideEnough &&
        (hingeX == null ||
            _paneWidth(usable, hingeX) >= SpaceBreakpoints.minPane);
    return SpaceLayout(
      size: size,
      contentRect: usable,
      compact: compact,
      rail: !compact,
      masterDetail: masterDetail,
      verticalHingeX: masterDetail ? hingeX : null,
      horizontalHingeY: hingeY,
      composeTwoColumn: size.width >= SpaceBreakpoints.composeTwoColumn,
    );
  }

  static double _paneWidth(Rect usable, double hinge) {
    final double left = hinge - usable.left - 8;
    final double right = usable.right - hinge - 8;
    return math.min(left, right);
  }
}

/// Constrains the Space surface to the usable band when a horizontal fold or
/// cutout removes part of the screen. Without an occlusion this is a no-op.
class SpaceOcclusion extends StatelessWidget {
  const SpaceOcclusion({super.key, required this.layout, required this.child});

  final SpaceLayout layout;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (layout.horizontalHingeY == null) {
      return child;
    }
    final Rect rect = layout.contentRect;
    final bool below = rect.top >= layout.horizontalHingeY!;
    return Align(
      alignment: below ? Alignment.bottomCenter : Alignment.topCenter,
      child: SizedBox(width: rect.width, height: rect.height, child: child),
    );
  }
}
