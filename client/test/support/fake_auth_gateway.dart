import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/services/auth_service.dart';

/// Test double for [AuthGateway] that records calls and returns scripted results.
class FakeAuthGateway implements AuthGateway {
  final List<({String username, String password})> registerCalls =
      <({String username, String password})>[];
  final List<({String account, String password})> loginCalls =
      <({String account, String password})>[];

  AuthUser registerResult = const AuthUser(
    account: '12345678',
    username: 'muse',
  );
  AuthUser loginResult = const AuthUser(account: '12345678', username: 'muse');

  AuthFailure? registerFailure;
  AuthFailure? loginFailure;
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
  void signOut() {
    signedOut = true;
  }
}
