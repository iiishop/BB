import '../models/auth_models.dart';
import 'client_identity.dart';
import 'space_api_client.dart';
import 'space_service.dart';

/// Uses the existing client consumer authority. No implicit enrollment or rebind.
class SpaceLocalRouter {
  SpaceLocalRouter(this.service);
  final SpaceService service;

  Future<({int status, Map<String, dynamic> body})> handle({
    required String path,
    required String? ownerKey,
    required Map<String, dynamic> body,
  }) async {
    try {
      final action = path.substring('/v2/space/'.length);
      validateSpace(action, body, kind: 'local_request');
      final expected = ExpectedIdentity.fromJson(body['expected_identity']);
      final context = await service.chat.requireIdentity(expected);
      if (ownerKey == null ||
          !isValidOwnerKey(ownerKey) ||
          context.binding.ownerKeyHash != ownerKeyHash(ownerKey)) {
        throw staleBinding('Consumer capability mismatch');
      }
      final payload = Map<String, dynamic>.from(body)
        ..remove('expected_identity');
      final result = await service.call(
        action,
        payload,
        expectedIdentity: expected,
      );
      return (
        status: 200,
        body: {'identity': expected.toJson(), 'result': result},
      );
    } on FormatException {
      return _error(422, 'validation_error');
    } on AuthFailure catch (e) {
      return _error(e.status, e.code);
    } catch (_) {
      return _error(503, 'storage_unavailable');
    }
  }

  ({int status, Map<String, dynamic> body}) _error(int status, String code) => (
    status: status,
    body: {
      'error': {'code': code, 'message': code, 'fields': <String>[]},
    },
  );
}
