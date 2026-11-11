import 'dart:async';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/services/auth_service.dart';

/// Test double for [AuthGateway] that records calls and returns scripted results.
class FakeAuthGateway implements AuthGateway {
  final List<({String username, String password})> registerCalls =
      <({String username, String password})>[];
  final List<({String account, String password})> loginCalls =
      <({String account, String password})>[];
  int restoreCalls = 0;

  AuthUser registerResult = const AuthUser(
    account: '12345678',
    username: 'muse',
  );
  AuthUser loginResult = const AuthUser(account: '12345678', username: 'muse');

  /// What `restoreSession()` returns. Null models "nothing stored".
  AuthUser? restoreResult;

  AuthFailure? registerFailure;
  AuthFailure? loginFailure;
  AuthFailure? restoreFailure;
  AuthFailure? signOutFailure;

  /// When set, `restoreSession()` waits for it, letting tests assert the
  /// in-flight restoring state.
  Completer<void>? restoreGate;
  bool signedOut = false;

  @override
  Future<AuthUser> register({
    required String username,
    required String password,
  }) async {
    registerCalls.add((username: username, password: password));
    final AuthFailure? failure = registerFailure;
    if (failure != null) {
      throw failure;
    }
    return registerResult;
  }

  @override
  Future<AuthUser> login({
    required String account,
    required String password,
  }) async {
    loginCalls.add((account: account, password: password));
    final AuthFailure? failure = loginFailure;
    if (failure != null) {
      throw failure;
    }
    return loginResult;
  }

  @override
  Future<AuthUser?> restoreSession() async {
    restoreCalls += 1;
    final Completer<void>? gate = restoreGate;
    if (gate != null) {
      await gate.future;
    }
    final AuthFailure? failure = restoreFailure;
    if (failure != null) {
      throw failure;
    }
    return restoreResult;
  }

  @override
  Future<void> signOut() async {
    final AuthFailure? failure = signOutFailure;
    if (failure != null) {
      throw failure;
    }
    signedOut = true;
  }
}
