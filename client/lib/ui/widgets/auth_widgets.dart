import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app.dart';
import '../../validation/auth_rules.dart';

/// The small square BB monogram used by both layouts.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.onDark = false, this.size = 44});

  final bool onDark;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: onDark ? AppColors.surface : AppColors.accent,
        borderRadius: BorderRadius.circular(AppRadius.brand),
      ),
      child: Text(
        'BB',
        style: TextStyle(
          color: onDark ? AppColors.accentDeep : AppColors.surface,
          fontSize: size * 0.34,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

/// Wordmark row used above the form on narrow screens.
class BrandHeader extends StatelessWidget {
  const BrandHeader({super.key});

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Row(
      children: <Widget>[
        const BrandMark(size: 40),
        const SizedBox(width: AppSpacing.sm + AppSpacing.xs),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              'BB',
              style: text.titleLarge?.copyWith(
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            Text('私人社交', style: text.bodySmall),
          ],
        ),
      ],
    );
  }
}

/// White content card shared by every auth step.
class AuthCard extends StatelessWidget {
  const AuthCard({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.border),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x0F161D1E),
            blurRadius: 28,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: child,
    );
  }
}

/// Readable, announced failure message shown above the form fields.
class AuthErrorBanner extends StatelessWidget {
  const AuthErrorBanner({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      label: '错误：$message',
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm + AppSpacing.xs,
          ),
          decoration: BoxDecoration(
            color: AppColors.dangerSurface,
            borderRadius: BorderRadius.circular(AppRadius.field),
            border: Border.all(color: AppColors.dangerBorder),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Icon(
                Icons.error_outline,
                size: 18,
                color: AppColors.danger,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  message,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppColors.danger,
                    fontSize: 13,
                    height: 1.45,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Full-width primary action with a busy state that keeps its height stable.
class AuthPrimaryButton extends StatelessWidget {
  const AuthPrimaryButton({
    super.key,
    required this.label,
    required this.busy,
    required this.onPressed,
  });

  final String label;
  final bool busy;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      onPressed: busy ? null : onPressed,
      child: busy
          ? Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.surface,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm + AppSpacing.xs),
                Text(label),
              ],
            )
          : Text(label),
    );
  }
}

/// Text field with a visible label, optional obscure toggle and inline error.
class AuthTextField extends StatelessWidget {
  const AuthTextField({
    super.key,
    required this.controller,
    required this.label,
    required this.hint,
    this.validator,
    this.focusNode,
    this.nextFocusNode,
    this.obscure = false,
    this.onToggleObscure,
    this.keyboardType,
    this.textInputAction,
    this.autofillHints,
    this.inputFormatters,
    this.maxLength,
    this.onChanged,
    this.prefixIcon,
  });

  final TextEditingController controller;
  final String label;
  final String hint;
  final String? Function(String?)? validator;
  final FocusNode? focusNode;
  final FocusNode? nextFocusNode;
  final bool obscure;
  final VoidCallback? onToggleObscure;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final Iterable<String>? autofillHints;
  final List<TextInputFormatter>? inputFormatters;
  final int? maxLength;
  final ValueChanged<String>? onChanged;
  final Widget? prefixIcon;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      focusNode: focusNode,
      validator: validator,
      obscureText: obscure,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      autofillHints: autofillHints,
      inputFormatters: inputFormatters,
      maxLength: maxLength,
      onChanged: onChanged,
      onFieldSubmitted: nextFocusNode == null
          ? null
          : (String _) => nextFocusNode!.requestFocus(),
      style: const TextStyle(
        color: AppColors.ink,
        fontSize: 16,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.3,
      ),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        counterText: '',
        prefixIcon: prefixIcon,
        suffixIcon: onToggleObscure == null
            ? null
            : IconButton(
                onPressed: onToggleObscure,
                tooltip: obscure ? '显示密码' : '隐藏密码',
                icon: Icon(
                  obscure
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  size: 20,
                ),
              ),
      ),
    );
  }
}

/// Live password rule checklist; text carries the meaning, the icon reinforces.
class PasswordRules extends StatelessWidget {
  const PasswordRules({super.key, required this.password});

  final String password;

  static const List<(String, String)> _rules = <(String, String)>[
    ('min_length', AuthRules.passwordMinLengthMessage),
    ('missing_uppercase', AuthRules.passwordUppercaseMessage),
    ('missing_lowercase', AuthRules.passwordLowercaseMessage),
    ('missing_digit', AuthRules.passwordDigitMessage),
  ];

  @override
  Widget build(BuildContext context) {
    final Set<String> missing = AuthRules.passwordIssueCodes(password);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final (String code, String message) in _rules)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.xs + 2),
            child: Row(
              children: <Widget>[
                Icon(
                  missing.contains(code)
                      ? Icons.radio_button_unchecked
                      : Icons.check_circle,
                  size: 15,
                  color: missing.contains(code)
                      ? AppColors.inkMuted
                      : AppColors.success,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    message,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: missing.contains(code)
                          ? AppColors.inkMuted
                          : AppColors.success,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
