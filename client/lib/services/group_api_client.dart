import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../models/auth_models.dart';
import '../models/chat_models.dart';
import '../models/group_models.dart';
import 'http_transport.dart';
import 'profile_api_client.dart';

/// Pure-Dart HTTP client for `group.REMOTE` endpoints and group avatars.
///
/// Mirrors `server/contract/src/bb_auth_contract/group.py`.
class GroupApiClient {
  GroupApiClient({
    required this.baseUri,
    this.timeout = const Duration(seconds: 15),
    this.transport,
  });

  final Uri baseUri;
  final Duration timeout;
  final HttpTransport? transport;

  late final HttpTransport _http =
      transport ?? HttpTransport(connectionTimeout: timeout);

  static const int maxJsonBytes = 8 * 1024 * 1024;
  static const int maxAvatarResponseBytes = 5 * 1024 * 1024;

  Future<GroupProfile> createGroup({
    required String token,
    required String operationId,
    required String name,
    String description = '',
    List<String> invitees = const <String>[],
    GroupAvatarBytes? avatar,
  }) async {
    final Map<String, dynamic> payload = <String, dynamic>{
      'operation_id': operationId,
      'name': name,
      'description': description,
      'invitees': invitees,
      if (avatar != null) 'avatar': avatar.toJson(),
    };
    return _postProfile('/chat/groups/create', token: token, payload: payload);
  }

  Future<GroupProfile> findGroup({
    required String token,
    required String groupNumber,
  }) => _postProfile(
    '/chat/groups/find',
    token: token,
    payload: <String, dynamic>{'group_number': groupNumber},
  );

  Future<GroupProfile> updateGroup({
    required String token,
    required ConversationRef conversation,
    String? name,
    String? description,
    bool? allowMemberInvites,
    GroupAvatarBytes? avatar,
    bool resetAvatar = false,
  }) async {
    final Map<String, dynamic> payload = <String, dynamic>{
      'conversation': conversation.toJson(),
      'name': ?name,
      'description': ?description,
      'allow_member_invites': ?allowMemberInvites,
      if (avatar != null) 'avatar': avatar.toJson(),
      if (resetAvatar) 'reset_avatar': true,
    };
    return _postProfile('/chat/groups/update', token: token, payload: payload);
  }

  Future<DirectoryPage> listDirectory({
    required String token,
    String afterAccount = '',
    int limit = 50,
  }) async {
    final Map<String, dynamic> json = await _postJson(
      '/chat/directory/list',
      token: token,
      payload: <String, dynamic>{'after_account': afterAccount, 'limit': limit},
    );
    return _parse(() => DirectoryPage.fromJson(json));
  }

  Future<GroupMemberPage> listGroupMembers({
    required String token,
    required ConversationRef conversation,
    String afterAccount = '',
    int limit = 50,
  }) async {
    final Map<String, dynamic> json = await _postJson(
      '/chat/groups/members',
      token: token,
      payload: <String, dynamic>{
        'conversation': conversation.toJson(),
        'after_account': afterAccount,
        'limit': limit,
      },
    );
    return _parse(() => GroupMemberPage.fromJson(json));
  }

  Future<GroupRequestsResult> inviteToGroup({
    required String token,
    required ConversationRef conversation,
    required List<String> accounts,
  }) async {
    final Map<String, dynamic> json = await _postJson(
      '/chat/groups/invite',
      token: token,
      payload: <String, dynamic>{
        'conversation': conversation.toJson(),
        'accounts': accounts,
      },
    );
    return _parse(() => GroupRequestsResult.fromJson(json));
  }

  Future<GroupRequestsResult> applyToGroup({
    required String token,
    required ConversationRef conversation,
  }) async {
    final Map<String, dynamic> json = await _postJson(
      '/chat/groups/apply',
      token: token,
      payload: <String, dynamic>{'conversation': conversation.toJson()},
    );
    return _parse(() => GroupRequestsResult.fromJson(json));
  }

  Future<GroupProfile> leaveGroup({
    required String token,
    required ConversationRef conversation,
  }) => _postProfile(
    '/chat/groups/leave',
    token: token,
    payload: <String, dynamic>{'conversation': conversation.toJson()},
  );

  Future<GroupProfile> removeGroupMember({
    required String token,
    required ConversationRef conversation,
    required String account,
  }) => _postProfile(
    '/chat/groups/remove_member',
    token: token,
    payload: <String, dynamic>{
      'conversation': conversation.toJson(),
      'account': account,
    },
  );

  Future<GroupProfile> dissolveGroup({
    required String token,
    required ConversationRef conversation,
  }) => _postProfile(
    '/chat/groups/dissolve',
    token: token,
    payload: <String, dynamic>{'conversation': conversation.toJson()},
  );

  Future<NoticePage> listNotices({
    required String token,
    NoticeFilter filter = NoticeFilter.all,
    String? cursor,
    int limit = 50,
  }) async {
    final Map<String, dynamic> json = await _postJson(
      '/chat/notices/list',
      token: token,
      payload: <String, dynamic>{
        'filter': filter.wire,
        'cursor': ?cursor,
        'limit': limit,
      },
    );
    return _parse(() => NoticePage.fromJson(json));
  }

  Future<Notice> markNoticeRead({
    required String token,
    required String notificationId,
  }) async {
    final Map<String, dynamic> json = await _postJson(
      '/chat/notices/mark_read',
      token: token,
      payload: <String, dynamic>{'notification_id': notificationId},
    );
    return _parse(() => Notice.fromJson(json));
  }

  Future<Notice> executeNoticeAction({
    required String token,
    required String notificationId,
    required String actionId,
  }) async {
    final Map<String, dynamic> json = await _postJson(
      '/chat/notices/execute_action',
      token: token,
      payload: <String, dynamic>{
        'notification_id': notificationId,
        'action_id': actionId,
      },
    );
    return _parse(() => Notice.fromJson(json));
  }

  /// Fetches a group avatar from its server-issued [avatarUrl] with optional
  /// `If-None-Match` and `?variant=thumb`. Rejects cross-origin URLs so a
  /// session token can never leave the configured server.
  Future<AvatarFetch> fetchGroupAvatar({
    required String token,
    required String avatarUrl,
    String? ifNoneMatch,
    bool thumb = false,
  }) async {
    final Uri resolved = baseUri.resolve(avatarUrl);
    if (resolved.scheme != baseUri.scheme ||
        resolved.host != baseUri.host ||
        resolved.port != baseUri.port) {
      throw const AuthFailure(
        status: 422,
        code: 'validation_error',
        message: '群头像地址不在当前服务器域内',
      );
    }
    final Uri target = thumb
        ? resolved.replace(
            queryParameters: <String, String>{
              ...resolved.queryParameters,
              'variant': 'thumb',
            },
          )
        : resolved;
    final Map<String, String> headers = <String, String>{
      HttpHeaders.authorizationHeader: 'Bearer $token',
      HttpHeaders.acceptHeader: 'image/png, image/jpeg, image/webp',
      if (ifNoneMatch != null && ifNoneMatch.isNotEmpty)
        HttpHeaders.ifNoneMatchHeader: '"$ifNoneMatch"',
    };
    final response = await _http.send(
      'GET',
      target,
      service: 'group',
      timeout: timeout,
      maxBytes: maxAvatarResponseBytes,
      headers: headers,
    );
    if (response.status == HttpStatus.notModified) {
      return AvatarFetch(
        notModified: true,
        bytes: Uint8List(0),
        version: _stripQuotes(response.headers['etag']) ?? ifNoneMatch ?? '',
      );
    }
    if (response.status != HttpStatus.ok) {
      throw _decodeFailure(
        response.status,
        utf8.decode(response.bytes, allowMalformed: true),
      );
    }
    if (response.bytes.isEmpty) {
      throw upstreamMalformed;
    }
    final String? version = _stripQuotes(response.headers['etag']);
    if (version == null || version.isEmpty) {
      throw upstreamMalformed;
    }
    return AvatarFetch(
      notModified: false,
      bytes: response.bytes,
      version: version,
    );
  }

  Future<Map<String, dynamic>> _postJson(
    String path, {
    required String token,
    required Map<String, dynamic> payload,
  }) async => (await _post(path, token: token, payload: payload)).body;

  Future<GroupProfile> _postProfile(
    String path, {
    required String token,
    required Map<String, dynamic> payload,
  }) async {
    final response = await _post(path, token: token, payload: payload);
    final header = response.headers['x-bb-group-profile-revision'];
    return _parse(
      () => GroupProfile.fromJson(
        response.body,
        revision: header == null ? null : GroupProfileRevision.parse(header),
      ),
    );
  }

  Future<({Map<String, dynamic> body, Map<String, String> headers})> _post(
    String path, {
    required String token,
    required Map<String, dynamic> payload,
  }) async {
    final response = await _http.send(
      'POST',
      baseUri.resolve(path),
      service: 'group',
      timeout: timeout,
      maxBytes: maxJsonBytes,
      headers: <String, String>{
        HttpHeaders.authorizationHeader: 'Bearer $token',
        HttpHeaders.acceptHeader: 'application/json',
        HttpHeaders.contentTypeHeader: ContentType.json.toString(),
      },
      body: utf8.encode(jsonEncode(payload)),
    );
    final String rawBody = utf8.decode(response.bytes, allowMalformed: true);
    if (response.status != HttpStatus.ok) {
      throw _decodeFailure(response.status, rawBody);
    }
    try {
      final Object? decoded = jsonDecode(rawBody);
      if (decoded is Map<String, dynamic>) {
        return (body: decoded, headers: response.headers);
      }
    } on FormatException {
      // Fall through.
    }
    throw upstreamMalformed;
  }

  T _parse<T>(T Function() parser) {
    try {
      return parser();
    } on FormatException {
      throw upstreamMalformed;
    }
  }

  AuthFailure _decodeFailure(int status, String rawBody) {
    try {
      final Object? decoded = jsonDecode(rawBody);
      if (decoded is Map<String, dynamic>) {
        final Object? error = decoded['error'];
        if (error is Map<String, dynamic>) {
          final Object? code = error['code'];
          final Object? message = error['message'];
          final Object? rawFields = error['fields'];
          if (code is String && message is String) {
            final List<AuthFieldError> fields = <AuthFieldError>[];
            if (rawFields is List) {
              for (final Object? entry in rawFields) {
                try {
                  fields.add(AuthFieldError.fromJson(entry));
                } on FormatException {
                  // Ignore malformed field entries.
                }
              }
            }
            return AuthFailure(
              status: status,
              code: code,
              message: message,
              fields: fields,
            );
          }
        }
      }
    } on FormatException {
      // Fall through.
    }
    if (status == 401) {
      return unauthenticated;
    }
    return upstreamMalformed;
  }

  static String? _stripQuotes(String? etag) {
    if (etag == null) {
      return null;
    }
    String value = etag.trim();
    if (value.startsWith('"') && value.endsWith('"') && value.length >= 2) {
      value = value.substring(1, value.length - 1);
    }
    return value;
  }
}
