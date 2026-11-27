import 'package:flutter/material.dart';

import '../../app.dart';

/// A business system entry has its own semantics, never a sender or time label.
/// The shared message adapter supplies its text after contract integration.
class ChatSystemEntry extends StatelessWidget {
  const ChatSystemEntry({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Semantics(
    label: '系统提示',
    child: Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.sm,
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodySmall
            ?.copyWith(color: AppColors.inkMuted),
      ),
    ),
  );
}
