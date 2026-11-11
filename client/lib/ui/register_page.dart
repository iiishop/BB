import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app.dart';
import '../models/auth_models.dart';
import '../services/auth_service.dart';
import '../validation/auth_rules.dart';
import 'auth_shell.dart';
import 'widgets/auth_widgets.dart';

/// Registration step: username + password + confirmation.
///
/// On success the server-assigned account replaces the form so the user can
/// copy it before continuing to login.
class RegisterPage extends StatefulWidget {
  const RegisterPage({
    super.key,
    required this.gateway,
    required this.onGoToLogin,
    required this.onBackToLogin,
  });

  final AuthGateway gateway;
  final ValueChanged<String> onGoToLogin;
  final VoidCallback onBackToLogin;

  static const Key usernameFieldKey = Key('register-username');
  static const Key passwordFieldKey = Key('register-password');
  static const Key confirmFieldKey = Key('register-confirm');
  static const Key submitButtonKey = Key('register-submit');
  static const Key errorBannerKey = Key('register-error');
  static const Key copyAccountButtonKey = Key('register-copy-account');
  static const Key goToLoginButtonKey = Key('register-go-login');
  static const Key registerAnotherButtonKey = Key('register-another');
  static const Key backToLoginLinkKey = Key('register-back-login');
  static const Key accountValueKey = Key('register-account-value');

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _confirmController = TextEditingController();
  final FocusNode _usernameFocus = FocusNode();
  final FocusNode _passwordFocus = FocusNode();
  final FocusNode _confirmFocus = FocusNode();

  bool _obscurePassword = true;
  bool _obscureConfirm = true;
  bool _busy = false;
  bool _submitted = false;
  String? _formError;
  Map<String, String> _serverFieldErrors = <String, String>{};
  AuthUser? _created;

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    _usernameFocus.dispose();
    _passwordFocus.dispose();
    _confirmFocus.dispose();
    super.dispose();
  }

  String? _validateUsername(String? value) {
    final String? serverError = _serverFieldErrors['username'];
    if (serverError != null) {
      return serverError;
    }
    return AuthRules.validateUsername(value ?? '');
  }

  String? _validatePassword(String? value) {
    final String? serverError = _serverFieldErrors['password'];
    if (serverError != null) {
      return serverError;
    }
    final List<AuthFieldIssue> issues = AuthRules.validatePassword(value ?? '');
    return issues.isEmpty ? null : issues.first.message;
  }

  String? _validateConfirm(String? value) {
    return AuthRules.validateConfirmation(
      password: _passwordController.text,
      confirmation: value ?? '',
    );
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
      final AuthUser user = await widget.gateway.register(
        username: _usernameController.text.trim(),
        password: _passwordController.text,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _busy = false;
        _created = user;
      });
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
        _formError = '注册失败，请稍后重试';
      });
    }
  }

  Future<void> _copyAccount(String account) async {
    await Clipboard.setData(ClipboardData(text: account));
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('账号已复制')));
  }

  void _registerAnother() {
    setState(() {
      _created = null;
      _submitted = false;
      _formError = null;
      _serverFieldErrors = <String, String>{};
      _usernameController.clear();
      _passwordController.clear();
      _confirmController.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final AuthUser? created = _created;
    if (created != null) {
      return AuthShell(
        eyebrow: 'STEP-1 · 注册完成',
        title: '账号已创建',
        subtitle: '这是你的登录账号，请先保存再继续。',
        card: _AccountCreatedCard(
          user: created,
          onCopy: () => _copyAccount(created.account),
          onGoToLogin: () => widget.onGoToLogin(created.account),
          onRegisterAnother: _registerAnother,
        ),
      );
    }

    final TextTheme text = Theme.of(context).textTheme;
    return AuthShell(
      eyebrow: 'STEP-1 · 注册',
      title: '创建账号',
      subtitle: '设置用户名和密码，账号由服务端自动分配。',
      card: Form(
        key: _formKey,
        autovalidateMode: _submitted
            ? AutovalidateMode.onUserInteraction
            : AutovalidateMode.disabled,
        child: AutofillGroup(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (_formError != null) ...<Widget>[
                AuthErrorBanner(
                  key: RegisterPage.errorBannerKey,
                  message: _formError!,
                ),
                const SizedBox(height: AppSpacing.md),
              ],
              AuthTextField(
                key: RegisterPage.usernameFieldKey,
                controller: _usernameController,
                focusNode: _usernameFocus,
                nextFocusNode: _passwordFocus,
                label: '用户名',
                hint: '3–24 个字符，可重复',
                textInputAction: TextInputAction.next,
                autofillHints: const <String>[AutofillHints.newUsername],
                onChanged: (_) => _clearServerError('username'),
                validator: _validateUsername,
                prefixIcon: const Icon(Icons.person_outline, size: 20),
              ),
              const SizedBox(height: AppSpacing.md - 2),
              AuthTextField(
                key: RegisterPage.passwordFieldKey,
                controller: _passwordController,
                focusNode: _passwordFocus,
                nextFocusNode: _confirmFocus,
                label: '密码',
                hint: '至少 6 位，含大小写字母和数字',
                obscure: _obscurePassword,
                textInputAction: TextInputAction.next,
                autofillHints: const <String>[AutofillHints.newPassword],
                onToggleObscure: () =>
                    setState(() => _obscurePassword = !_obscurePassword),
                onChanged: (_) {
                  _clearServerError('password');
                  setState(() {});
                },
                validator: _validatePassword,
                prefixIcon: const Icon(Icons.lock_outline, size: 20),
              ),
              const SizedBox(height: AppSpacing.sm + 2),
              PasswordRules(password: _passwordController.text),
              const SizedBox(height: AppSpacing.md),
              AuthTextField(
                key: RegisterPage.confirmFieldKey,
                controller: _confirmController,
                focusNode: _confirmFocus,
                label: '确认密码',
                hint: '再次输入密码',
                obscure: _obscureConfirm,
                textInputAction: TextInputAction.done,
                autofillHints: const <String>[AutofillHints.newPassword],
                onToggleObscure: () =>
                    setState(() => _obscureConfirm = !_obscureConfirm),
                validator: _validateConfirm,
                prefixIcon: const Icon(Icons.verified_user_outlined, size: 20),
              ),
              const SizedBox(height: AppSpacing.lg),
              AuthPrimaryButton(
                key: RegisterPage.submitButtonKey,
                label: '创建账号',
                busy: _busy,
                onPressed: _submit,
              ),
              const SizedBox(height: AppSpacing.sm + 2),
              Text('注册成功后，服务端会分配一个唯一的 8 位账号。', style: text.bodySmall),
            ],
          ),
        ),
      ),
      footer: Center(
        child: Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            Text('已有账号？', style: text.bodySmall),
            TextButton(
              key: RegisterPage.backToLoginLinkKey,
              onPressed: widget.onBackToLogin,
              child: const Text('返回登录'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Success state: the assigned account is the whole point of this screen.
class _AccountCreatedCard extends StatelessWidget {
  const _AccountCreatedCard({
    required this.user,
    required this.onCopy,
    required this.onGoToLogin,
    required this.onRegisterAnother,
  });

  final AuthUser user;
  final VoidCallback onCopy;
  final VoidCallback onGoToLogin;
  final VoidCallback onRegisterAnother;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          children: <Widget>[
            const Icon(Icons.check_circle, color: AppColors.success, size: 20),
            const SizedBox(width: AppSpacing.sm),
            Text(
              '注册成功',
              style: text.titleMedium?.copyWith(color: AppColors.success),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        Text('你的账号', style: text.bodySmall),
        const SizedBox(height: AppSpacing.sm),
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm + AppSpacing.xs,
          ),
          decoration: BoxDecoration(
            color: AppColors.accentSoft,
            borderRadius: BorderRadius.circular(AppRadius.field),
            border: Border.all(color: AppColors.successBorder),
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Semantics(
                  liveRegion: true,
                  label: '分配的账号 ${user.account}',
                  child: Text(
                    user.account,
                    key: RegisterPage.accountValueKey,
                    style: text.displaySmall?.copyWith(
                      color: AppColors.accentDeep,
                      fontSize: 34,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 3,
                      fontFeatures: const <FontFeature>[
                        FontFeature.tabularFigures(),
                      ],
                    ),
                  ),
                ),
              ),
              IconButton(
                key: RegisterPage.copyAccountButtonKey,
                onPressed: onCopy,
                tooltip: '复制账号',
                icon: const Icon(Icons.copy_rounded, size: 20),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.sm + 2),
        Text('账号用于登录，请记住；用户名只作展示。', style: text.bodySmall),
        const SizedBox(height: AppSpacing.lg),
        FilledButton(
          key: RegisterPage.goToLoginButtonKey,
          onPressed: onGoToLogin,
          child: const Text('去登录'),
        ),
        const SizedBox(height: AppSpacing.sm),
        TextButton(
          key: RegisterPage.registerAnotherButtonKey,
          onPressed: onRegisterAnother,
          child: const Text('注册另一个账号'),
        ),
      ],
    );
  }
}

Map<String, String> _groupFieldErrors(List<AuthFieldError> fields) {
  final Map<String, String> grouped = <String, String>{};
  for (final AuthFieldError error in fields) {
    final String? existing = grouped[error.field];
    grouped[error.field] = existing == null
        ? error.message
        : '$existing\n${error.message}';
  }
  return grouped;
}
