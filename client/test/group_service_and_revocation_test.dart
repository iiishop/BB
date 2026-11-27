import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_media.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/models/group_models.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/avatar_cache.dart';
import 'package:bb_client/services/chat_api_client.dart';
import 'package:bb_client/services/chat_ledger.dart';
import 'package:bb_client/services/chat_service.dart';
import 'package:bb_client/services/conversation_access.dart';
import 'package:bb_client/services/group_api_client.dart';
import 'package:bb_client/services/group_service.dart';
import 'package:bb_client/services/media_disk_cache.dart';
import 'package:bb_client/services/media_source.dart';
import 'package:bb_client/services/media_stream_proxy.dart';
import 'package:bb_client/ui/chat/chat_photo_source.dart';
import 'package:bb_client/ui/media/photo_page.dart';
import 'package:flutter_test/flutter_test.dart';

final Uint8List _samplePng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC',
);

class _FakeGroupServer {
  _FakeGroupServer._(this._server);

  static Future<_FakeGroupServer> start() async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final _FakeGroupServer instance = _FakeGroupServer._(server);
    server.listen(instance._handle);
    return instance;
  }

  final HttpServer _server;
  final List<
    ({String method, String path, Map<String, dynamic>? body, String? query})
  >
  requests =
      <
        ({
          String method,
          String path,
          Map<String, dynamic>? body,
          String? query,
        })
      >[];

  int mediaStatusOverride = 200;
  bool sendAssociationHeader = false;
  int groupAvatarVersion = 1;
  final String groupId = 'group:${'1234abcd' * 4}';

  Uri get baseUri => Uri.parse('http://127.0.0.1:${_server.port}');

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final String path = Uri.decodeComponent(request.uri.path);
    final String query = request.uri.query;
    final List<int> raw = await request.fold<List<int>>(
      <int>[],
      (List<int> acc, List<int> chunk) => acc..addAll(chunk),
    );
    Map<String, dynamic>? jsonBody;
    if (raw.isNotEmpty &&
        request.headers.contentType?.mimeType == 'application/json') {
      jsonBody = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
    }
    requests.add((
      method: request.method,
      path: path,
      body: jsonBody,
      query: query,
    ));

    if (request.method == 'GET' && path == '/chat/conversations') {
      await _json(request, 200, <String, dynamic>{
        'items': <Map<String, dynamic>>[
          <String, dynamic>{
            'conversation': <String, dynamic>{'type': 'group', 'id': groupId},
            'group_number': '10000001',
            'display_name': 'Alpha',
            'last_message': null,
            'last_activity_at': '2026-11-27T10:00:00Z',
            'latest_position': 0,
            'history_through': 0,
            'membership_revision': 1,
            'avatar_url': '/chat/groups/10000001/avatar.png',
            'avatar_version': 'gv1',
          },
        ],
        'next_cursor': null,
      });
      return;
    }

    if (request.method == 'GET' &&
        path == '/chat/conversations/$groupId/messages') {
      await _json(request, 200, <String, dynamic>{
        'items': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'm-g-1',
            'position': 1,
            'created_at': '2026-11-27T10:01:00Z',
            'sender_account': '10000002',
            'sender_username': 'Bob',
            'conversation': <String, dynamic>{'type': 'group', 'id': groupId},
            'kind': 'body',
            'content': <Map<String, dynamic>>[
              <String, dynamic>{'type': 'text', 'text': 'hello'},
              <String, dynamic>{'type': 'image', 'media_id': 'm-img-1'},
            ],
            'attachment': null,
            'operation_id': 'op-secret-should-strip-without-negotiation',
          },
        ],
        'next_position': 1,
        'has_more': false,
      }, association: sendAssociationHeader);
      return;
    }

    if (request.method == 'POST' && path == '/messages') {
      await _json(request, 200, <String, dynamic>{
        'id': 'm-g-2',
        'position': 2,
        'created_at': '2026-11-27T10:02:00Z',
        'sender_account': '10000001',
        'sender_username': 'Alice',
        'conversation': jsonBody!['conversation'],
        'kind': 'body',
        'content': jsonBody['content'],
        'attachment': null,
      });
      return;
    }

    if (request.method == 'POST' && path == '/messages/attachments') {
      await _json(request, 200, <String, dynamic>{
        'id': 'm-g-3',
        'position': 3,
        'created_at': '2026-11-27T10:03:00Z',
        'sender_account': '10000001',
        'sender_username': 'Alice',
        'conversation': jsonBody!['conversation'],
        'kind': 'attachment',
        'content': null,
        'attachment': <String, dynamic>{
          'media_id': jsonBody['media_id'],
          'media_type': 'document',
          'filename': 'doc.pdf',
          'mime_type': 'application/pdf',
          'byte_size': 12,
          'cover_media_id': null,
        },
      });
      return;
    }

    if (request.method == 'POST' && path == '/media') {
      final String bodyText = utf8.decode(raw, allowMalformed: true);
      expect(bodyText, contains('name="conversation_id"'));
      expect(bodyText, contains(groupId));
      await _json(request, 200, <String, dynamic>{
        'media_id': 'uploaded-group-media',
        'media_type': 'image',
        'filename': 'pic.png',
        'mime_type': 'image/png',
        'byte_size': _samplePng.length,
        'cover_media_id': null,
      });
      return;
    }

    if (request.method == 'GET' && path == '/events') {
      await _json(request, 200, <String, dynamic>{
        'items': <Map<String, dynamic>>[
          <String, dynamic>{
            'version': 1,
            'event_id': 7,
            'type': 'conversation.access_changed',
            'occurred_at': '2026-11-27T10:04:00Z',
            'conversation': <String, dynamic>{'type': 'group', 'id': groupId},
            'active': false,
            'membership_revision': 2,
            'history_through': 3,
          },
        ],
        'next_event_id': 7,
        'has_more': false,
      });
      return;
    }

    if (request.method == 'GET' &&
        (path == '/media/m-img-1' || path == '/media/m-img-1/metadata')) {
      if (mediaStatusOverride != 200) {
        await _json(request, mediaStatusOverride, <String, dynamic>{
          'error': <String, dynamic>{
            'code': mediaStatusOverride == 403 ? 'forbidden' : 'not_found',
            'message': 'denied',
            'fields': <Object>[],
          },
        });
        return;
      }
      if (path.endsWith('/metadata')) {
        await _json(request, 200, <String, dynamic>{
          'media_id': 'm-img-1',
          'media_type': 'image',
          'filename': 'pic.png',
          'mime_type': 'image/png',
          'byte_size': 200 * 1024,
          'cover_media_id': null,
        });
        return;
      }
      request.response.statusCode = 200;
      request.response.headers.contentType = ContentType('image', 'png');
      request.response.headers.set('accept-ranges', 'bytes');
      request.response.add(_samplePng);
      await request.response.close();
      return;
    }

    if (request.method == 'GET' && path == '/chat/groups/10000001/avatar.png') {
      final String etag = 'gv$groupAvatarVersion';
      final String? inm = request.headers.value(HttpHeaders.ifNoneMatchHeader);
      if (inm == '"$etag"') {
        request.response.statusCode = 304;
        request.response.headers.set('etag', '"$etag"');
        await request.response.close();
        return;
      }
      request.response.statusCode = 200;
      request.response.headers.contentType = ContentType('image', 'png');
      request.response.headers.set('etag', '"$etag"');
      request.response.add(_samplePng);
      await request.response.close();
      return;
    }

    if (request.method == 'POST' && path.startsWith('/chat/')) {
      if (path == '/chat/groups/create' ||
          path == '/chat/groups/find' ||
          path == '/chat/groups/update' ||
          path == '/chat/groups/leave' ||
          path == '/chat/groups/remove_member' ||
          path == '/chat/groups/dissolve') {
        await _json(request, 200, <String, dynamic>{
          'conversation': <String, dynamic>{'type': 'group', 'id': groupId},
          'group_number': '10000001',
          'name': jsonBody?['name'] ?? 'Group Alpha',
          'description': jsonBody?['description'] ?? 'Desc',
          'avatar_url': '/chat/groups/10000001/avatar.png',
          'avatar_version': 'gv$groupAvatarVersion',
          'status': path == '/chat/groups/dissolve' ? 'dissolved' : 'active',
          'role': path == '/chat/groups/leave' ? null : 'owner',
          'can_invite': path != '/chat/groups/dissolve',
          'allow_member_invites': jsonBody?['allow_member_invites'] ?? false,
        });
        return;
      }
      if (path == '/chat/directory/list') {
        await _json(request, 200, <String, dynamic>{
          'items': <Map<String, dynamic>>[
            <String, dynamic>{
              'account': '10000002',
              'username': 'Bob',
              'avatar_url': '/avatars/10000002.png',
              'avatar_version': 'v1',
              'presence': 'online',
            },
          ],
          'next_cursor': null,
        });
        return;
      }
      if (path == '/chat/groups/members') {
        await _json(request, 200, <String, dynamic>{
          'items': <Map<String, dynamic>>[
            <String, dynamic>{
              'account': '10000001',
              'username': 'Alice',
              'avatar_url': '/avatars/10000001.png',
              'avatar_version': 'v1',
              'presence': 'online',
              'role': 'owner',
            },
          ],
          'next_cursor': null,
        });
        return;
      }
      if (path == '/chat/groups/invite' || path == '/chat/groups/apply') {
        await _json(request, 200, <String, dynamic>{
          'request_ids': <String>['req-1'],
        });
        return;
      }
      if (path == '/chat/notices/list') {
        await _json(request, 200, <String, dynamic>{
          'items': <Map<String, dynamic>>[],
          'next_cursor': null,
          'unread_count': 0,
          'pending_count': 0,
        });
        return;
      }
      if (path == '/chat/notices/mark_read' ||
          path == '/chat/notices/execute_action') {
        await _json(request, 200, <String, dynamic>{
          'id': jsonBody!['notification_id'],
          'type': 'group_invite',
          'title': '邀请',
          'text': '已处理',
          'created_at': '2026-11-27T10:00:00Z',
          'read': true,
          'state': path.endsWith('mark_read') ? 'pending' : 'processed',
          'actions': <Map<String, dynamic>>[],
          'link': <String, dynamic>{'type': 'group', 'id': '10000001'},
        });
        return;
      }
    }

    await _json(request, 404, <String, dynamic>{
      'error': <String, dynamic>{
        'code': 'not_found',
        'message': 'missing',
        'fields': <Object>[],
      },
    });
  }

  Future<void> _json(
    HttpRequest request,
    int status,
    Map<String, dynamic> body, {
    bool association = false,
  }) async {
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    if (association) {
      request.response.headers.set('x-bb-message-association', '1');
    }
    request.response.write(jsonEncode(body));
    await request.response.close();
  }
}

void main() {
  late _FakeGroupServer server;
  late AuthSession session;
  late ChatApiClient chatApi;
  late GroupApiClient groupApi;
  late ConversationAccessController access;
  late Directory tempDir;

  setUp(() async {
    server = await _FakeGroupServer.start();
    session = AuthSession()
      ..establish(
        token: 'tok-alice',
        user: const AuthUser(account: '10000001', username: 'Alice'),
      );
    chatApi = ChatApiClient(baseUri: server.baseUri);
    groupApi = GroupApiClient(baseUri: server.baseUri);
    access = ConversationAccessController();
    tempDir = await Directory.systemTemp.createTemp('bb_group_test_');
  });

  tearDown(() async {
    await server.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('GroupService covers all 13 REMOTE calls, validation, and group/user avatar isolation', () async {
    final AvatarCache userAvatarCache = AvatarCache(
      directory: Directory('${tempDir.path}/user-avatars'),
    );
    final AvatarCache groupAvatarCache = AvatarCache(
      directory: Directory('${tempDir.path}/group-avatars'),
    );
    // Same numeric 8-digit ID '10000001' for user & group must never collide.
    await userAvatarCache.write(
      '10000001',
      Uint8List.fromList(<int>[1, 2, 3]),
      'user-v1',
      thumb: true,
    );

    final GroupService groups = GroupService(
      api: groupApi,
      session: session,
      avatarCache: groupAvatarCache,
      access: access,
    );

    final GroupProfile created = await groups.createGroup(
      operationId: 'op-create-1',
      name: '  Alpha Team  ',
      description: '  desc  ',
      invitees: const <String>['10000002'],
      avatar: MediaSource(bytes: _samplePng),
    );
    expect(created.groupNumber, '10000001');
    expect(created.name, 'Alpha Team');
    expect(created.description, 'desc');

    // Empty/whitespace name fails with 422 before hitting the network.
    await expectLater(
      () => groups.createGroup(operationId: 'op-bad', name: '   '),
      throwsA(
        isA<AuthFailure>().having((AuthFailure f) => f.status, 'status', 422),
      ),
    );

    final GroupAvatarImage firstAvatar = await groups.loadGroupAvatar(
      groupNumber: created.groupNumber,
      avatarUrl: created.avatarUrl,
      thumb: true,
    );
    expect(firstAvatar.bytes, _samplePng);
    expect(firstAvatar.version, 'gv1');

    // User avatar cache for account '10000001' remains completely untouched.
    final CachedAvatar? userCached = await userAvatarCache.read(
      '10000001',
      thumb: true,
    );
    expect(userCached?.bytes, Uint8List.fromList(<int>[1, 2, 3]));
    expect(userCached?.version, 'user-v1');

    // Conditional 304 reuses group cache.
    final GroupAvatarImage cachedAgain = await groups.loadGroupAvatar(
      groupNumber: created.groupNumber,
      avatarUrl: created.avatarUrl,
      thumb: true,
    );
    expect(cachedAgain.bytes, _samplePng);

    await groups.findGroup('10000001');
    await groups.listDirectory();
    await groups.listGroupMembers(conversation: created.conversation);
    await groups.inviteToGroup(
      conversation: created.conversation,
      accounts: const <String>['10000002'],
    );
    await groups.applyToGroup(conversation: created.conversation);
    await groups.updateGroup(
      conversation: created.conversation,
      name: 'Renamed',
      allowMemberInvites: true,
      resetAvatar: true,
    );
    // Resetting avatar invalidates the cached group avatar immediately.
    expect(await groupAvatarCache.read('group-10000001', thumb: true), isNull);

    final NoticePage notices = await groups.listNotices(
      filter: NoticeFilter.pending,
    );
    expect(notices.items, isEmpty);
    await groups.markNoticeRead('n1');
    final Notice acted = await groups.executeNoticeAction(
      notificationId: 'n1',
      actionId: 'accept',
    );
    expect(acted.state, NoticeState.processed);

    // Leaving revokes access immediately.
    await groups.leaveGroup(conversation: created.conversation);
    expect(access.isRevoked('10000001', created.conversation.id), isTrue);

    // Rejects cross-origin avatar URL so tokens never leak.
    await expectLater(
      () => groupApi.fetchGroupAvatar(
        token: 'tok-alice',
        avatarUrl: 'https://evil.example.com/a.png',
      ),
      throwsA(
        isA<AuthFailure>().having((AuthFailure f) => f.status, 'status', 422),
      ),
    );
  });

  test('SharedConversationService strips unnegotiated operation_id and purges on revocation', () async {
    final SharedConversationService shared = SharedConversationService(
      api: chatApi,
      session: session,
      access: access,
    );
    addTearDown(shared.dispose);

    final SharedConversationPage conversations = await shared
        .listSharedConversations();
    expect(conversations.items, hasLength(1));
    final ConversationRef groupRef = conversations.items.single.conversation;

    final MessagePage history = await shared.loadConversationHistory(
      conversation: groupRef,
    );
    expect(history.items, hasLength(1));
    expect(history.items.single.operationId, isNull);

    final Attachment uploaded = await shared.uploadConversationMedia(
      conversation: groupRef,
      source: MediaSource(
        bytes: _samplePng,
        filename: 'pic.png',
        mimeType: 'image/png',
      ),
    );
    expect(uploaded.mediaId, 'uploaded-group-media');

    await shared.sendGroupMessage(
      conversation: groupRef,
      clientNonce: 'op-msg-1',
      content: <MessagePart>[const TextPart('hello')],
    );
    await shared.sendGroupAttachment(
      conversation: groupRef,
      clientNonce: 'op-att-1',
      mediaId: uploaded.mediaId,
    );

    // Load scoped media into memory cache.
    final Uint8List thumbBytes = await shared.loadScopedMediaBytes(
      conversation: groupRef,
      mediaId: 'm-img-1',
      thumb: true,
    );
    expect(thumbBytes, _samplePng);

    // Server delivers access_changed(active: false) event -> revokes & purges.
    final ServerEventPage evPage = await chatApi.events(
      token: 'tok-alice',
      includeGroups: true,
    );
    expect(server.requests.last.query, contains('include_groups=true'));
    await shared.applyServerEvent('10000001', evPage.items.single);

    expect(access.isRevoked('10000001', groupRef.id), isTrue);
    await expectLater(
      () => shared.loadScopedMediaBytes(
        conversation: groupRef,
        mediaId: 'm-img-1',
        thumb: true,
      ),
      throwsA(
        isA<AuthFailure>().having((AuthFailure f) => f.status, 'status', 403),
      ),
    );
    await expectLater(
      () => shared.loadConversationHistory(conversation: groupRef),
      throwsA(
        isA<AuthFailure>().having((AuthFailure f) => f.status, 'status', 403),
      ),
    );
  });

  test('ChatPhotoSource and MediaStreamProxy invalidate open viewers and delete disk cache on revocation', () async {
    final ChatService chat = ChatService(
      api: chatApi,
      session: session,
      ledger: ChatLedger.inMemory(),
      cacheRoot: tempDir,
      webSocketHints: false,
    );
    addTearDown(chat.dispose);

    final Directory diskDir = Directory('${tempDir.path}/media-disk-cache');
    final MediaDiskCache disk = MediaDiskCache(directory: diskDir);
    final ConversationRef group1 = ConversationRef.group(server.groupId);
    final ConversationRef group2 = ConversationRef.group(
      'group:${'ffffffff' * 4}',
    );
    registerDiskCachePurger(
      access: access,
      disk: disk,
      serverUri: server.baseUri,
    );

    final ChatMessage msg1 = ChatMessage(
      id: 'm-g-1',
      position: 1,
      senderAccount: '10000002',
      senderUsername: 'Bob',
      conversation: group1,
      createdAt: DateTime.now().toUtc(),
      kind: ChatMessageKind.body,
      parts: const <MessagePart>[ImagePart('m-img-1')],
    );
    final ChatMediaItem item1 = buildConversationMedia(
      messages: <ChatMessage>[msg1],
      selfAccount: '10000001',
      selfName: '我',
      peerName: 'Bob',
    ).single;

    final ChatPhotoSource source1 = ChatPhotoSource(
      item: item1,
      chat: chat,
      heldBytes: _samplePng,
      disk: disk,
      access: access,
    );
    addTearDown(source1.dispose);

    final ChatPhotoSource source2 = ChatPhotoSource(
      item: item1.copyWith(),
      chat: chat,
      disk: disk,
      conversation: group2,
      access: access,
    );
    addTearDown(source2.dispose);

    // Distinct scoped disk keys even when the same mediaId is referenced.
    expect(source1.diskKey, isNot(equals(source2.diskKey)));

    // Persist originals for both group1 and group2 on real disk.
    await disk.write(source1.diskKey, _samplePng);
    await disk.write(source2.diskKey, _samplePng);
    expect(await disk.read(source1.diskKey), _samplePng);
    expect(await disk.read(source2.diskKey), _samplePng);

    // Simulate restart re-indexing: a fresh MediaDiskCache recovers both keys
    // and only deletes group1's file when group1 is revoked.
    final MediaDiskCache restartedDisk = MediaDiskCache(directory: diskDir);
    final ConversationAccessController restartedAccess =
        ConversationAccessController();
    registerDiskCachePurger(
      access: restartedAccess,
      disk: restartedDisk,
      serverUri: server.baseUri,
    );
    expect(await restartedDisk.read(source1.diskKey), _samplePng);

    final PhotoPageController page = PhotoPageController(source: source1);
    addTearDown(page.dispose);
    await page.start();
    expect(page.phase, PhotoPhase.ready);
    expect(page.bytes, _samplePng);

    // Also open a loopback media stream for group1.
    final MediaStreamHandle stream = await chat.mediaStreams.open(
      'm-img-1',
      conversation: group1,
      access: access,
    );
    addTearDown(stream.close);

    // Revoke group1 -> open PhotoPage drops bytes immediately, stream closes,
    // and source1 can no longer serve held/cached bytes or read from disk.
    await access.revoke('10000001', group1.id, membershipRevision: 2);
    await restartedAccess.revoke('10000001', group1.id, membershipRevision: 2);
    expect(source1.invalidated, isTrue);
    expect(source1.heldOriginal, isNull);
    expect(page.phase, PhotoPhase.failed);
    expect(page.bytes, isNull);
    expect(source2.invalidated, isFalse);
    expect(await restartedDisk.read(source1.diskKey), isNull);
    expect(await restartedDisk.read(source2.diskKey), _samplePng);

    // Subsequent HTTP request to revoked stream fails (closed or 403).
    final HttpClient http = HttpClient();
    addTearDown(() => http.close(force: true));
    Object? streamError;
    int? streamStatus;
    try {
      final HttpClientRequest req = await http.getUrl(stream.uri);
      final HttpClientResponse res = await req.close();
      streamStatus = res.statusCode;
      await res.drain<void>();
    } catch (error) {
      streamError = error;
    }
    expect(streamError != null || streamStatus == 403, isTrue);

    // Server-side 403/404 on reopen also locally invalidates even without event.
    server.mediaStatusOverride = 403;
    final ChatPhotoSource lateSource = ChatPhotoSource(
      item: item1,
      chat: chat,
      disk: disk,
      conversation: group2,
    );
    addTearDown(lateSource.dispose);
    await expectLater(
      () => lateSource.loadPreview(),
      throwsA(
        isA<AuthFailure>().having((AuthFailure f) => f.status, 'status', 403),
      ),
    );
    expect(lateSource.invalidated, isTrue);
  });
}
