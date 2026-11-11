import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app.dart';
import '../models/auth_models.dart';
import '../services/auth_service.dart';
import '../validation/auth_rules.dart';
import 'auth_shell.dart';
import 'widgets/auth_widgets.dart';

/// Login step: account + password only (username is never accepted here).
class LoginPage extends StatefulWidget {
  const LoginPage({
    super.key,
    required this.gateway,
    required this.onAuthenticated,
    required this.onRequestRegister,
    this.initialAccount,
    this.notice,
    this.noticeIsError = false,
    this.onRetryRestore,
  });

  final AuthGateway gateway;
  final ValueChanged<AuthUser> onAuthenticated;
  final VoidCallback onRequestRegister;

  /// Prefilled after a successful registration.
  final String? initialAccount;

  /// Startup status from the persisted-session restore (expired or unverified).
  final String? notice;
  final bool noticeIsError;
  final VoidCallback? onRetryRestore;

  static const Key accountFieldKey = Key('login-account');
  static const Key passwordFieldKey = Key('login-password');
  static const Key submitButtonKey = Key('login-submit');
  static const Key errorBannerKey = Key('login-error');
  static const Key noticeKey = Key('login-notice');
  static const Key registerLinkKey = Key('login-register-link');

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  late final TextEditingController _accountController = TextEditingController(
    text: widget.initialAccount ?? '',
  );
  final TextEditingController _passwordController = TextEditingController();
  final FocusNode _accountFocus = FocusNode();
  final FocusNode _passwordFocus = FocusNode();

  bool _obscurePassword = true;
  bool _busy = false;
  bool _submitted = false;
  String? _formError;
  Map<String, String> _serverFieldErrors = <String, String>{};

  @override
  void dispose() {
    _accountController.dispose();
    _passwordController.dispose();
    _accountFocus.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  String? _validateAccount(String? value) {
    final String? serverError = _serverFieldErrors['account'];
    if (serverError != null) {
      return serverError;
    }
    return AuthRules.validateAccount(value ?? '');
  }

  String? _validatePassword(String? value) {
    final String? serverError = _serverFieldErrors['password'];
    if (serverError != null) {
      return serverError;
    }
    if ((value ?? '').isEmpty) {
      return '请输入密码';
    }
    return null;
  }

  void _clearServerError(String field) {
    if (!_serverFieldErrors.containsKey(field)) {
      return;
    }
    setState(() {
      _serverFieldErrors = Map<String, String>.of(_serverFieldErrors)
        ..remove(field);
      _formError = null;
    });
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _submitted = true;
      _formError = null;
      _serverFieldErrors = <String, String>{};
    });
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    setState(() => _busy = true);
    try {
      final AuthUser user = await widget.gateway.login(
        account: _accountController.text,
        password: _passwordController.text,
      );
      if (!mounted) {
        return;
      }
      widget.onAuthenticated(user);
    } on AuthFailure catch (failure) {
      if (!mounted) {
        return;
      }
      setState(() {
        _busy = false;
        _serverFieldErrors = _groupFieldErrors(failure.fields);
        _formError = failure.fields.isEmpty ? failure.message : null;
      });
      _formKey.currentState?.validate();
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _busy = false;
        _formError = '登录失败，请稍后重试';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final Widget form = Form(
      key: _formKey,
      autovalidateMode: _submitted
          ? AutovalidateMode.onUserInteraction
          : AutovalidateMode.disabled,
      child: AutofillGroup(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (widget.notice != null) ...<Widget>[
              AuthNotice(
                key: LoginPage.noticeKey,
                message: widget.notice!,
                isError: widget.noticeIsError,
                onRetry: widget.onRetryRestore,
              ),
              const SizedBox(height: AppSpacing.md),
            ],
            if (_formError != null) ...<Widget>[
              AuthErrorBanner(
                key: LoginPage.errorBannerKey,
                message: _formError!,
              ),
              const SizedBox(height: AppSpacing.md),
            ],
            AuthTextField(
              key: LoginPage.accountFieldKey,
              controller: _accountController,
              focusNode: _accountFocus,
              nextFocusNode: _passwordFocus,
              label: '账号',
              hint: '8 位数字账号',
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.next,
              autofillHints: const <String>[AutofillHints.username],
              inputFormatters: <TextInputFormatter>[
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(8),
              ],
              maxLength: 8,
              onChanged: (_) => _clearServerError('account'),
              validator: _validateAccount,
              prefixIcon: const Icon(Icons.badge_outlined, size: 20),
            ),
            const SizedBox(height: AppSpacing.md - 2),
            AuthTextField(
              key: LoginPage.passwordFieldKey,
              controller: _passwordController,
              focusNode: _passwordFocus,
              label: '密码',
              hint: '输入登录密码',
              obscure: _obscurePassword,
              autofillHints: const <String>[AutofillHints.password],
              textInputAction: TextInputAction.done,
              onToggleObscure: () =>
                  setState(() => _obscurePassword = !_obscurePassword),
              onChanged: (_) => _clearServerError('password'),
              onSubmitted: _submit,
              validator: _validatePassword,
              prefixIcon: const Icon(Icons.lock_outline, size: 20),
            ),
            const SizedBox(height: AppSpacing.lg),
            AuthPrimaryButton(
              key: LoginPage.submitButtonKey,
              label: '登录',
              busy: _busy,
              onPressed: _submit,
            ),
            const SizedBox(height: AppSpacing.sm + 2),
            Text('账号由注册时自动分配，可用于登录；用户名不能登录。', style: text.bodySmall),
          ],
        ),
      ),
    );

    return AuthShell(
      eyebrow: 'STEP-1 · 登录',
      title: '登录',
      subtitle: '用注册时分配的 8 位账号登录。',
      card: form,
      footer: Center(
        child: Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            Text('还没有账号？', style: text.bodySmall),
            TextButton(
              key: LoginPage.registerLinkKey,
              onPressed: widget.onRequestRegister,
              child: const Text('注册'),
            ),
          ],
        ),
      ),
    );
  }

  static Map<String, String> _groupFieldErrors(List<AuthFieldError> fields) {
    final Map<String, String> grouped = <String, String>{};
    for (final AuthFieldError error in fields) {
      final String? existing = grouped[error.field];
      grouped[error.field] = existing == null
          ? error.message
          : '$existing\n${error.message}';
    }
    return grouped;
  }
}
