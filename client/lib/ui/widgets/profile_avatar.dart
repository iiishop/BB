import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../app.dart';

/// Circular avatar that renders the exact bytes the client fetched.
///
/// The server owns avatar data; this widget never invents a fallback image and
/// shows an explicit placeholder while loading, on error, or before the first
/// fetch, so a missing avatar is visible rather than silently wrong.
class ProfileAvatar extends StatelessWidget {
  const ProfileAvatar({
    super.key,
    required this.bytes,
    this.size = 56,
    this.showBorder = true,
    this.loading = false,
    this.onTap,
    this.semanticLabel,
  });

  final Uint8List? bytes;
  final double size;
  final bool showBorder;
  final bool loading;
  final VoidCallback? onTap;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final Widget image = ClipOval(
      child: SizedBox(
        width: size,
        height: size,
        child: bytes == null || bytes!.isEmpty
            ? ColoredBox(
                color: AppColors.accentSoft,
                child: Icon(
                  Icons.person_outline_rounded,
                  size: size * 0.46,
                  color: AppColors.accentDeep,
                ),
              )
            : Image.memory(
                bytes!,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                filterQuality: FilterQuality.medium,
                errorBuilder:
                    (BuildContext context, Object error, StackTrace? stack) {
                      return ColoredBox(
                        color: AppColors.dangerSurface,
                        child: Icon(
                          Icons.broken_image_outlined,
                          size: size * 0.4,
                          color: AppColors.danger,
                        ),
                      );
                    },
              ),
      ),
    );

    final Widget bordered = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.surface,
        border: showBorder
            ? Border.all(color: AppColors.surface, width: 3)
            : null,
        boxShadow: showBorder
            ? const <BoxShadow>[
                BoxShadow(
                  color: Color(0x1A161D1E),
                  blurRadius: 18,
                  offset: Offset(0, 6),
                ),
              ]
            : null,
      ),
      child: image,
    );

    final Widget content = Stack(
      alignment: Alignment.center,
      children: <Widget>[
        bordered,
        if (loading)
          Container(
            width: size,
            height: size,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Color(0x66161D1E),
            ),
            child: const Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              ),
            ),
          ),
      ],
    );

    if (onTap == null) {
      return semanticLabel == null
          ? content
          : Semantics(label: semanticLabel, child: content);
    }
    return Semantics(
      button: true,
      label: semanticLabel ?? '打开个人资料',
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: content,
      ),
    );
  }
}
