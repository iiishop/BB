import 'package:flutter/material.dart';

import '../models/auth_models.dart';
import '../services/auth_service.dart';
import 'login_page.dart';
import 'register_page.dart';
import 'signed_in_view.dart';

/// Auth step state machine for STEP-1.
///
/// Login <-> Register, and a session-checked completion view. Navigation stays
/// inside this flow so widget tests can drive every step without a router.
class AuthFlow extends StatefulWidget {
  const AuthFlow({super.key, required this.gateway});

  final AuthGateway gateway;

  @override
  State<AuthFlow> createState() => _AuthFlowState();
}

enum _AuthStep { login, register, signedIn }

class _AuthFlowState extends State<AuthFlow> {
  _AuthStep _step = _AuthStep.login;
  String? _pendingAccount;
  AuthUser? _user;

  void _openRegister() {
    setState(() => _step = _AuthStep.register);
  }

  void _goToLogin(String account) {
    setState(() {
      _step = _AuthStep.login;
      _pendingAccount = account;
    });
  }

  void _backToLogin() {
    setState(() => _step = _AuthStep.login);
  }

  void _handleAuthenticated(AuthUser user) {
    setState(() {
      _user = user;
      _step = _AuthStep.signedIn;
    });
  }

  void _signOut() {
    widget.gateway.signOut();
    setState(() {
      _user = null;
      _pendingAccount = null;
      _step = _AuthStep.login;
    });
  }

  @override
  Widget build(BuildContext context) {
    switch (_step) {
      case _AuthStep.login:
        return LoginPage(
          gateway: widget.gateway,
          initialAccount: _pendingAccount,
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
        return SignedInView(user: _user!, onSignOut: _signOut);
    }
  }
}
