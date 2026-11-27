import 'dart:convert';
import 'dart:io';

import '../models/auth_models.dart';
import '../models/conversation_models.dart';
import 'chat_api_client.dart';
import 'http_transport.dart';

/// Shared HTTP projections used by the guarded event and notification feed.
class ChatDeliveryRemote {
  ChatDeliveryRemote(this.api);

  final ChatApiClient api;
  late final HttpTransport _transport = api.transport ??
      HttpTransport(connectionTimeout: api.timeout);

  Future<Map<String, dynamic>> request(
    String token,
    String path, {
    Map<String, String>? query,
  }) async {
    final uri = api.baseUri.resolve(path).replace(queryParameters: query);
    final response = await _transport.send(
      'GET',
      uri,
      service: 'chat',
      timeout: api.timeout,
      maxBytes: ChatApiClient.maxJsonBytes,
      headers: {
        HttpHeaders.authorizationHeader: 'Bearer $token',
      },
    );
    if (response.status == 401) throw unauthenticated;
    try {
      final value = jsonDecode(utf8.decode(response.bytes));
      if (value is Map<String, dynamic>) {
        if (response.status == 200) return value;
        final error = value['error'];
        if (error is Map<String, dynamic> && error['code'] is String) {
          throw AuthFailure(
            status: response.status,
            code: error['code'] as String,
            message: '服务器未完成请求',
          );
        }
      }
    } on FormatException {
      throw upstreamMalformed;
    }
    throw upstreamMalformed;
  }

  Future<int> eventHead(String token) async {
    final result = await request(token, '/events/head',
      query: {'include_groups': 'true'});
    final head = result['event_id'];
    if (head is! int || head < 0) throw upstreamMalformed;
    return head;
  }

  static List<Map<String, dynamic>> jsonItems(Map<String, dynamic> page) {
    final values = page['items'];
    if (values is! List || values.any((value) => value is! Map<String, dynamic>)) {
      throw upstreamMalformed;
    }
    return values.cast<Map<String, dynamic>>();
  }
}

bool isGroupId(String value) => isValidGroupConversationId(value);
Map<String, dynamic> groupRef(String id) => ConversationRef.group(id).toJson();
