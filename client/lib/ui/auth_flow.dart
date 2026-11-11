import 'dart:async';

import 'package:flutter/material.dart';

import '../models/auth_models.dart';
import '../services/auth_service.dart';
import 'login_page.dart';
import 'register_page.dart';
import 'restoring_view.dart';
import 'signed_in_view.dart';

/// Auth step state machine for STEP-1.
///
/// On startup it restores a persisted credential and verifies it with
/// `GET /auth/session`; only a 200 reaches the signed-in state. An expired
/// credential returns to login with a clear message, and an unreachable server
/// keeps the credential while showing "暂时无法验证" with a retry action.
class AuthFlow extends StatefulWidget {
  const AuthFlow({super.key, required this.gateway});

  final AuthGateway gateway;

  @override
  State<AuthFlow> createState() => _AuthFlowState();
}

enum _AuthStep { restoring, login, register, signedIn }

class _AuthFlowState extends State<AuthFlow> {
  _AuthStep _step = _AuthStep.restoring;
  String? _pendingAccount;
  AuthUser? _user;
  bool _restored = false;
  String? _restoreNotice;
  bool _restoreNoticeIsError = false;
  bool _restoreNoticeRetryable = false;

  static const String _expiredMessage = '登录已失效，请重新登录';
  static const String _unverifiedMessage = '暂时无法验证登录状态，请检查网络后重试';
  static const String _storageMessage = '会话存储不可用，请检查本机存储权限后重试';

  @override
  void initState() {
    super.initState();
    unawaited(_restore());
  }

  Future<void> _restore() async {
    setState(() {
      _step = _AuthStep.restoring;
      _restoreNotice = null;
      _restoreNoticeRetryable = false;
    });
    try {
      final AuthUser? user = await widget.gateway.restoreSession();
      if (!mounted) {
        return;
      }
      setState(() {
        if (user == null) {
          _step = _AuthStep.login;
          _user = null;
        } else {
          _user = user;
          _restored = true;
          _step = _AuthStep.signedIn;
        }
      });
    } on AuthFailure catch (failure) {
      if (!mounted) {
        return;
      }
      final bool expired = failure.status == 401;
      final bool storageFault = failure.code == sessionStorageUnavailable.code;
      setState(() {
        _user = null;
        _step = _AuthStep.login;
        _restoreNotice = expired
            ? _expiredMessage
            : storageFault
            ? _storageMessage
            : _unverifiedMessage;
        _restoreNoticeIsError = expired || storageFault;
        _restoreNoticeRetryable = !expired;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _user = null;
        _step = _AuthStep.login;
        _restoreNotice = _unverifiedMessage;
        _restoreNoticeIsError = false;
        _restoreNoticeRetryable = true;
      });
    }
  }

  void _openRegister() {
    setState(() {
      _step = _AuthStep.register;
      _restoreNotice = null;
      _restoreNoticeRetryable = false;
    });
  }

  void _goToLogin(String account) {
    setState(() {
      _step = _AuthStep.login;
      _pendingAccount = account;
      _restoreNotice = null;
      _restoreNoticeRetryable = false;
    });
  }

  void _backToLogin() {
    setState(() {
      _step = _AuthStep.login;
      _restoreNotice = null;
      _restoreNoticeRetryable = false;
    });
  }

  void _handleAuthenticated(AuthUser user) {
    setState(() {
      _user = user;
      _restored = false;
      _step = _AuthStep.signedIn;
      _restoreNotice = null;
      _restoreNoticeRetryable = false;
    });
  }

  void _signOut() {
    unawaited(_performSignOut());
  }

  Future<void> _performSignOut() async {
    try {
      await widget.gateway.signOut();
    } on AuthFailure catch (failure) {
      if (!mounted) {
        return;
      }
      // The credential could not be removed: stay signed in so a restart does
      // not silently undo the logout the UI just claimed.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            failure.code == sessionStorageUnavailable.code
                ? '退出登录失败：会话存储不可用'
                : '退出登录失败：${failure.message}',
          ),
        ),
      );
      return;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _user = null;
      _restored = false;
      _pendingAccount = null;
      _restoreNotice = null;
      _restoreNoticeRetryable = false;
      _step = _AuthStep.login;
    });
  }

  @override
  Widget build(BuildContext context) {
    switch (_step) {
      case _AuthStep.restoring:
        return const RestoringView();
      case _AuthStep.login:
        return LoginPage(
          gateway: widget.gateway,
          initialAccount: _pendingAccount,
          notice: _restoreNotice,
          noticeIsError: _restoreNoticeIsError,
          onRetryRestore: _restoreNoticeRetryable ? _restore : null,
          onAuthenticated: _handleAuthenticated,
          onRequestRegister: _openRegister,
        );
      case _AuthStep.register:
        return RegisterPage(
          gateway: widget.gateway,
          onGoToLogin: _goToLogin,
          onBackToLogin: _backToLogin,
        );
      case _AuthStep.signedIn:
        return SignedInView(
          user: _user!,
          restored: _restored,
          onSignOut: _signOut,
        );
    }
  }
}
