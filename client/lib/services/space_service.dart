import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../models/auth_models.dart';
import 'auth_session.dart';
import 'chat_service.dart';
import 'client_identity.dart';
import 'space_api_client.dart';
export '../models/space_models.dart';
export 'space_methods.g.dart';

/// Authorization and durable dispatch shared by UI and protected local routes.
/// No content cache: every read revalidates live server permissions/deletion.
class SpaceService {
  SpaceService({required this.api, required this.session, required this.chat});
  final SpaceApiClient api;
  final AuthSession session;
  final ChatService chat;

  Future<Map<String, dynamic>> call(
    String action,
    Map<String, dynamic> body, {
    ExpectedIdentity? expectedIdentity,
  }) async {
    validateSpace(action, body);
    final captured = session.identity;
    if (captured == null) throw unauthenticated;
    Future<void> fence() async {
      if (!session.isCurrent(captured)) throw staleIdentity;
      if (expectedIdentity != null) {
        await chat.requireIdentity(expectedIdentity);
      }
      if (!session.isCurrent(captured)) throw staleIdentity;
    }

    await fence();
    final consumer = expectedIdentity?.consumerId ?? 'human';
    final scope = jsonEncode([
      api.baseUri.toString(),
      captured.account,
      consumer,
    ]);
    final id = body['operation_id'] as String?;
    if (action == 'get_operation') {
      final plan = await chat.ledger.spaceOperation(scope, id!);
      await fence();
      if (plan == null) throw spaceFailure(404, 'not_found');
      final result = await api.call(action, body, token: captured.token);
      await chat.ledger.commitSpaceOperation(scope, id, result);
      await fence();
      return result;
    }
    if (id != null) {
      final digest = sha256
          .convert(utf8.encode(jsonEncode(_canonical([action, body]))))
          .toString();
      final previous = await chat.ledger.planSpaceOperation(
        scope,
        id,
        action,
        digest,
      );
      await fence();
      if (previous != null) {
        // Reconcile first. An explicit same-ID retry remains idempotent even if
        // an earlier request is still in flight; never generate a replacement ID.
        try {
          final result = await api.call('get_operation', {
            'operation_id': id,
          }, token: captured.token);
          await chat.ledger.commitSpaceOperation(scope, id, result);
          await fence();
          return result;
        } on AuthFailure catch (e) {
          if (e.status != 404) rethrow;
        }
        await fence();
      }
    }
    // Captured token belongs to the accepted account even if login switches
    // during IO. Persist only its receipt before fencing the outward response.
    final result = await api.call(action, body, token: captured.token);
    if (id != null) await chat.ledger.commitSpaceOperation(scope, id, result);
    await fence();
    return result;
  }
}

Object? _canonical(Object? value) {
  if (value is Map<String, dynamic>) {
    return {
      for (final key in value.keys.toList()..sort())
        key: _canonical(value[key]),
    };
  }
  if (value is List) return value.map(_canonical).toList();
  return value;
}
