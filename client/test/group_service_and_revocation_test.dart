import 'dart:async';
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
  int group2AvatarVersion = 1;
  String group1Name = 'Group Alpha';
  String group2Name = 'Group Beta';
  Completer<void>? holdFind;
  Completer<void>? holdAvatar;
  Completer<void>? beforeUpdateCommit;
  Completer<void>? holdUpdate;
  final Uint8List resetPng = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNQXtcDAAJVAV4On0tgAAAAAElFTkSuQmCC',
  );
  final String groupId = 'group:${'1234abcd' * 4}';
  final String group2Id = 'group:${'abcd1234' * 4}';
  List<Map<String, dynamic>>? sharedConversationsOverride;
  List<Map<String, dynamic>>? eventsOverride;
  List<Map<String, dynamic>> noticesOverride = <Map<String, dynamic>>[];

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
        'items':
            sharedConversationsOverride ??
            <Map<String, dynamic>>[
              <String, dynamic>{
                'conversation': <String, dynamic>{
                  'type': 'group',
                  'id': groupId,
                },
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

    if (request.method == 'GET' && path == '/conversations') {
      await _json(request, 200, <String, dynamic>{
        'items': <Map<String, dynamic>>[
          <String, dynamic>{
            'peer_account': '10000002',
            'last_message': <String, dynamic>{
              'id': 'dm-1',
              'position': 1,
              'sender_account': '10000002',
              'target_account': '10000001',
              'created_at': '2026-11-27T09:50:00Z',
              'kind': 'body',
              'content': <Map<String, dynamic>>[
                <String, dynamic>{'type': 'text', 'text': 'legacy dm'},
              ],
              'attachment': null,
            },
            'last_activity_at': '2026-11-27T09:50:00Z',
            'latest_position': 1,
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
      final List<Map<String, dynamic>> items =
          eventsOverride ??
          <Map<String, dynamic>>[
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
          ];
      await _json(request, 200, <String, dynamic>{
        'items': items,
        'next_event_id': items.isEmpty ? 0 : items.last['event_id'],
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

    if (request.method == 'GET' &&
        (path == '/chat/groups/10000001/avatar.png' ||
            path == '/chat/groups/10000002/avatar.png')) {
      final bool isFirst = path == '/chat/groups/10000001/avatar.png';
      final int ver = isFirst ? groupAvatarVersion : group2AvatarVersion;
      final String etag = isFirst ? 'gv$ver' : 'g2v$ver';
      final Uint8List bodyBytes = (isFirst && ver > 1) ? resetPng : _samplePng;
      final Completer<void>? hold = isFirst ? holdAvatar : null;
      if (hold != null) {
        holdAvatar = null;
        await hold.future;
      }
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
      request.response.add(bodyBytes);
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
        final String requestedNumber =
            (jsonBody?['group_number'] as String?) ??
            (jsonBody?['conversation']?['id'] == group2Id
                ? '10000002'
                : '10000001');
        final bool isFirst = requestedNumber == '10000001';
        if (path == '/chat/groups/update') {
          if (isFirst && beforeUpdateCommit != null) {
            final Completer<void> before = beforeUpdateCommit!;
            beforeUpdateCommit = null;
            await before.future;
          }
          if (jsonBody?['reset_avatar'] == true) {
            if (isFirst) {
              groupAvatarVersion += 1;
            } else {
              group2AvatarVersion += 1;
            }
          }
          if (jsonBody?.containsKey('name') ?? false) {
            if (isFirst) {
              group1Name = jsonBody!['name'] as String;
            } else {
              group2Name = jsonBody!['name'] as String;
            }
          }
        }
        final Map<String, dynamic> payload = <String, dynamic>{
          'conversation': <String, dynamic>{
            'type': 'group',
            'id': isFirst ? groupId : group2Id,
          },
          'group_number': requestedNumber,
          'name': isFirst
              ? (jsonBody?['name'] ?? group1Name)
              : (jsonBody?['name'] ?? group2Name),
          'description': jsonBody?['description'] ?? 'Desc',
          'avatar_url': '/chat/groups/$requestedNumber/avatar.png',
          'avatar_version': isFirst
              ? 'gv$groupAvatarVersion'
              : 'g2v$group2AvatarVersion',
          'status': path == '/chat/groups/dissolve' ? 'dissolved' : 'active',
          'role': path == '/chat/groups/leave' ? null : 'owner',
          'can_invite': path != '/chat/groups/dissolve',
          'allow_member_invites': jsonBody?['allow_member_invites'] ?? false,
        };
        if (path == '/chat/groups/find' && isFirst && holdFind != null) {
          final Completer<void> hold = holdFind!;
          holdFind = null;
          await hold.future;
        }
        if (path == '/chat/groups/update' && isFirst && holdUpdate != null) {
          final Completer<void> hold = holdUpdate!;
          holdUpdate = null;
          await hold.future;
        }
        await _json(request, 200, payload);
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
          'items': noticesOverride,
          'next_cursor': null,
          'unread_count': noticesOverride.length,
          'pending_count': noticesOverride.length,
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

  test('uses group_number from shared conversation list to load group profile while preserving direct chat shape', () async {
    final SharedConversationService shared = SharedConversationService(
      api: chatApi,
      session: session,
      access: access,
    );
    addTearDown(shared.dispose);
    final GroupService groups = GroupService(
      api: groupApi,
      session: session,
      avatarCache: AvatarCache(
        directory: Directory('${tempDir.path}/group-avatars-profile'),
      ),
      access: access,
    );

    server.sharedConversationsOverride = <Map<String, dynamic>>[
      <String, dynamic>{
        'conversation': <String, dynamic>{
          'type': 'direct',
          'id': 'dm:10000001:10000002',
        },
        'peer_account': '10000002',
        'display_name': 'Bob',
        'last_message': <String, dynamic>{
          'id': 'dm-1',
          'position': 1,
          'sender_account': '10000002',
          'target_account': '10000001',
          'created_at': '2026-11-27T09:50:00Z',
          'kind': 'body',
          'content': <Map<String, dynamic>>[
            <String, dynamic>{'type': 'text', 'text': 'legacy dm'},
          ],
          'attachment': null,
        },
        'last_activity_at': '2026-11-27T09:50:00Z',
        'latest_position': 1,
      },
      <String, dynamic>{
        'conversation': <String, dynamic>{
          'type': 'group',
          'id': server.groupId,
        },
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
    ];

    final SharedConversationPage sharedPage = await shared
        .listSharedConversations();
    expect(sharedPage.items, hasLength(2));
    final DirectConversationItem directItem =
        sharedPage.items[0] as DirectConversationItem;
    final GroupConversationItem groupItem =
        sharedPage.items[1] as GroupConversationItem;
    expect(directItem.peerAccount, '10000002');
    expect(directItem.lastMessage.targetAccount, '10000001');
    expect(groupItem.groupNumber, '10000001');
    expect(shared.groupNumberFor('10000001', server.groupId), '10000001');

    // Legacy private conversation list shape stays intact.
    final ConversationRecordPage legacyConvs = await chatApi.conversations(
      token: 'tok-alice',
    );
    expect(legacyConvs.items, hasLength(1));
    expect(legacyConvs.items.single.peerAccount, '10000002');
    expect(legacyConvs.items.single.lastMessage.targetAccount, '10000001');

    // Query group profile via both SharedConversationService.loadGroupProfile
    // and GroupService.findGroupForConversationItem using group_number.
    final GroupProfile fromShared = await shared.loadGroupProfile(
      conversation: groupItem.conversation,
      groups: groups,
    );
    final GroupProfile fromItem = await groups.findGroupForConversationItem(
      groupItem,
    );
    expect(fromShared.groupNumber, '10000001');
    expect(fromShared.conversation, groupItem.conversation);
    expect(fromItem.groupNumber, '10000001');

    final List<
      ({String method, String path, Map<String, dynamic>? body, String? query})
    >
    findCalls = server.requests
        .where((r) => r.path == '/chat/groups/find')
        .toList();
    expect(findCalls, hasLength(2));
    for (final call in findCalls) {
      expect(call.body, <String, dynamic>{'group_number': '10000001'});
    }

    // Rejects direct conversation refs cleanly rather than hitting /chat/groups/find.
    await expectLater(
      () => shared.loadGroupProfile(
        conversation: directItem.conversation,
        groups: groups,
      ),
      throwsA(
        isA<AuthFailure>().having((AuthFailure f) => f.status, 'status', 422),
      ),
    );
  });

  test('distinguishes pre-leave vs post-rejoin group message events by membership_revision and survives event replay', () async {
    final SharedConversationService shared = SharedConversationService(
      api: chatApi,
      session: session,
      access: access,
    );
    addTearDown(shared.dispose);
    final GroupService groups = GroupService(
      api: groupApi,
      session: session,
      avatarCache: AvatarCache(
        directory: Directory('${tempDir.path}/group-avatars-replay'),
      ),
      access: access,
    );

    final ConversationRef groupRef = ConversationRef.group(server.groupId);

    // 1. Sync active membership at revision 1 (history_through: 0), then receive
    // a revision-1 group message and a legacy direct message.
    await shared.listSharedConversations();
    server.eventsOverride = <Map<String, dynamic>>[
      <String, dynamic>{
        'version': 1,
        'event_id': 1,
        'type': 'message.available',
        'occurred_at': '2026-11-27T10:01:00Z',
        'message_id': 'm-g-rev1',
        'conversation': <String, dynamic>{
          'type': 'group',
          'id': server.groupId,
        },
        'membership_revision': 1,
        'position': 2,
      },
      <String, dynamic>{
        'version': 1,
        'event_id': 2,
        'type': 'message.available',
        'occurred_at': '2026-11-27T10:01:30Z',
        'message_id': 'm-dm-1',
        'peer_account': '10000002',
        'position': 4,
      },
    ];
    final ServerEventPage initialEvents = await chatApi.events(
      token: 'tok-alice',
      includeGroups: true,
    );
    expect(
      await shared.applyServerEvent('10000001', initialEvents.items[0]),
      ServerEventDisposition.groupCurrentMessage,
    );
    expect(
      await shared.applyServerEvent('10000001', initialEvents.items[1]),
      ServerEventDisposition.directMessage,
    );

    // 2. Member leaves locally before access_changed arrives -> replaying rev=1
    // event must NOT reactivate membership.
    await groups.leaveGroup(conversation: groupRef);
    expect(access.isRevoked('10000001', groupRef.id), isTrue);
    expect(
      await shared.applyServerEvent('10000001', initialEvents.items[0]),
      ServerEventDisposition.revokedGroupMessage,
    );
    expect(access.isRevoked('10000001', groupRef.id), isTrue);

    // 3. Server delivers access_changed(active: false, rev: 2), then user
    // rejoins at rev: 3 with history_through: 5, followed by replay of old rev: 1,
    // stale rev: 2 revoke, a pos=5 pre-rejoin boundary event, and a true
    // post-rejoin rev: 3 pos=6 event + direct message.
    server.eventsOverride = <Map<String, dynamic>>[
      <String, dynamic>{
        'version': 1,
        'event_id': 3,
        'type': 'conversation.access_changed',
        'occurred_at': '2026-11-27T10:02:00Z',
        'conversation': <String, dynamic>{
          'type': 'group',
          'id': server.groupId,
        },
        'active': false,
        'membership_revision': 2,
        'history_through': 0,
      },
      <String, dynamic>{
        'version': 1,
        'event_id': 4,
        'type': 'conversation.access_changed',
        'occurred_at': '2026-11-27T10:05:00Z',
        'conversation': <String, dynamic>{
          'type': 'group',
          'id': server.groupId,
        },
        'active': true,
        'membership_revision': 3,
        'history_through': 5,
      },
      <String, dynamic>{
        'version': 1,
        'event_id': 5,
        'type': 'message.available',
        'occurred_at': '2026-11-27T10:01:00Z',
        'message_id': 'm-g-rev1',
        'conversation': <String, dynamic>{
          'type': 'group',
          'id': server.groupId,
        },
        'membership_revision': 1,
        'position': 2,
      },
      <String, dynamic>{
        'version': 1,
        'event_id': 6,
        'type': 'conversation.access_changed',
        'occurred_at': '2026-11-27T10:02:00Z',
        'conversation': <String, dynamic>{
          'type': 'group',
          'id': server.groupId,
        },
        'active': false,
        'membership_revision': 2,
        'history_through': 0,
      },
      <String, dynamic>{
        'version': 1,
        'event_id': 7,
        'type': 'message.available',
        'occurred_at': '2026-11-27T10:04:00Z',
        'message_id': 'm-g-gap',
        'conversation': <String, dynamic>{
          'type': 'group',
          'id': server.groupId,
        },
        'membership_revision': 3,
        'position': 5,
      },
      <String, dynamic>{
        'version': 1,
        'event_id': 8,
        'type': 'message.available',
        'occurred_at': '2026-11-27T10:06:00Z',
        'message_id': 'm-g-rev3',
        'conversation': <String, dynamic>{
          'type': 'group',
          'id': server.groupId,
        },
        'membership_revision': 3,
        'position': 6,
      },
      <String, dynamic>{
        'version': 1,
        'event_id': 9,
        'type': 'message.available',
        'occurred_at': '2026-11-27T10:06:30Z',
        'message_id': 'm-dm-2',
        'peer_account': '10000002',
        'position': 5,
      },
      <String, dynamic>{
        'version': 1,
        'event_id': 10,
        'type': 'notification.available',
        'occurred_at': '2026-11-27T10:07:00Z',
        'notification_id': 'n-app-1',
      },
    ];

    final ServerEventPage replayPage = await chatApi.events(
      token: 'tok-alice',
      includeGroups: true,
    );
    final List<ServerEventDisposition> outcomes = <ServerEventDisposition>[];
    for (final ServerEvent ev in replayPage.items) {
      outcomes.add(await shared.applyServerEvent('10000001', ev));
    }
    expect(outcomes, <ServerEventDisposition>[
      ServerEventDisposition.groupAccessRevoked, // event_id 3 (rev 2 revoke)
      ServerEventDisposition.groupAccessGranted, // event_id 4 (rev 3 rejoin)
      ServerEventDisposition
          .staleGroupMessage, // event_id 5 (pre-leave rev 1 replay)
      ServerEventDisposition
          .staleAccessEvent, // event_id 6 (stale rev 2 revoke replay)
      ServerEventDisposition
          .staleGroupMessage, // event_id 7 (pos <= historyThrough)
      ServerEventDisposition
          .groupCurrentMessage, // event_id 8 (post-rejoin rev 3, pos 6)
      ServerEventDisposition
          .directMessage, // event_id 9 (legacy direct untouched)
      ServerEventDisposition
          .notificationAvailable, // event_id 10 (notification.available)
    ]);
    final ServerEvent noticeEvent = replayPage.items.last;
    expect(noticeEvent.isNotificationAvailable, isTrue);
    expect(noticeEvent.notificationId, 'n-app-1');
    server.noticesOverride = <Map<String, dynamic>>[
      <String, dynamic>{
        'id': 'n-app-1',
        'type': 'group_application',
        'title': '入群申请',
        'text': 'Charlie 申请加入群',
        'created_at': '2026-11-27T10:07:00Z',
        'read': false,
        'state': 'pending',
        'actions': <Map<String, dynamic>>[
          <String, dynamic>{'id': 'approve', 'label': '同意', 'available': true},
          <String, dynamic>{'id': 'reject', 'label': '拒绝', 'available': true},
        ],
        'link': <String, dynamic>{'type': 'group', 'id': '10000001'},
      },
    ];
    final Notice? notice = await groups.findNoticeById(
      noticeEvent.notificationId,
    );
    expect(notice?.id, 'n-app-1');
    expect(notice?.actions.map((NoticeAction a) => a.id).toList(), <String>[
      'approve',
      'reject',
    ]);
    expect(access.isRevoked('10000001', groupRef.id), isFalse);
    expect(access.stateFor('10000001', groupRef.id)?.membershipRevision, 3);
    expect(access.stateFor('10000001', groupRef.id)?.historyThrough, 5);
  });

  test('GroupService orders profile broadcasts and avatar cache writes while preserving same-version queries and other groups', () async {
    final AvatarCache cache = AvatarCache(directory: tempDir);
    final GroupService groups = GroupService(
      api: groupApi,
      session: session,
      avatarCache: cache,
      access: access,
    );
    final List<GroupProfile> emitted = <GroupProfile>[];
    final StreamSubscription<GroupProfile> sub = groups.groupUpdates.listen(
      emitted.add,
    );
    addTearDown(sub.cancel);
    final ConversationRef group1Ref = ConversationRef.group(server.groupId);

    // 1. Stale findGroup('10000001') completing after updateGroup must not broadcast.
    final Completer<void> heldFind = Completer<void>();
    server.holdFind = heldFind;
    final Future<GroupProfile> staleFind = groups.findGroup('10000001');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final GroupProfile renamed = await groups.updateGroup(
      conversation: group1Ref,
      name: 'Renamed Alpha',
    );
    expect(renamed.name, 'Renamed Alpha');
    heldFind.complete();
    await staleFind;
    await Future<void>.delayed(Duration.zero);
    expect(emitted.map((GroupProfile p) => p.name).toList(), <String>[
      'Renamed Alpha',
    ]);

    // 2. Repeated same-version findGroup('10000001') and independent group2 both emit.
    await groups.findGroup('10000001');
    await groups.findGroup('10000002');
    await Future<void>.delayed(Duration.zero);
    expect(emitted.length, 3);
    expect(emitted[1].name, 'Renamed Alpha');
    expect(emitted[2].groupNumber, '10000002');

    // 3. Stale loadGroupAvatar('10000001') completing after resetAvatar must not
    //    overwrite 'gv2' in cache; repeated same-version 304 and group2 still succeed.
    final Completer<void> heldAvatar = Completer<void>();
    server.holdAvatar = heldAvatar;
    final Future<GroupAvatarImage> staleAvatar = groups.loadGroupAvatar(
      groupNumber: '10000001',
      avatarUrl: '/chat/groups/10000001/avatar.png',
      thumb: true,
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await groups.updateGroup(conversation: group1Ref, resetAvatar: true);
    final GroupAvatarImage freshAvatar = await groups.loadGroupAvatar(
      groupNumber: '10000001',
      avatarUrl: '/chat/groups/10000001/avatar.png',
      thumb: true,
    );
    expect(freshAvatar.version, 'gv2');
    heldAvatar.complete();
    final GroupAvatarImage resolvedStale = await staleAvatar;
    expect(resolvedStale.version, 'gv2');
    final CachedAvatar? diskThumb = await cache.read(
      'group-10000001',
      thumb: true,
    );
    expect(diskThumb?.version, 'gv2');
    expect(diskThumb?.bytes, orderedEquals(server.resetPng));

    // Same-version 304 repeat & other group load still work cleanly.
    final GroupAvatarImage repeated = await groups.loadGroupAvatar(
      groupNumber: '10000001',
      avatarUrl: '/chat/groups/10000001/avatar.png',
      thumb: true,
    );
    expect(repeated.version, 'gv2');
    final GroupAvatarImage group2Avatar = await groups.loadGroupAvatar(
      groupNumber: '10000002',
      avatarUrl: '/chat/groups/10000002/avatar.png',
      thumb: true,
    );
    expect(group2Avatar.version, 'g2v1');

    // 4. Concurrent AvatarCache write + newer write keeps latest generation.
    await Future.wait(<Future<void>>[
      cache.write('group-10000003', _samplePng, 'v1', thumb: true),
      cache.write('group-10000003', server.resetPng, 'v2', thumb: true),
    ]);
    final CachedAvatar? latestDirect = await cache.read(
      'group-10000003',
      thumb: true,
    );
    expect(latestDirect?.version, 'v2');
    expect(latestDirect?.bytes, orderedEquals(server.resetPng));

    // 5. Overlapping updateGroup calls reconcile to server's authoritative commit
    //    for both response-delayed-after-commit and commit-last orders.
    emitted.clear();
    final Completer<void> holdFirstReply = Completer<void>();
    server.holdUpdate = holdFirstReply;
    final Future<GroupProfile> firstCommitted = groups.updateGroup(
      conversation: group1Ref,
      name: 'First edit',
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await groups.updateGroup(conversation: group1Ref, name: 'Final edit');
    holdFirstReply.complete();
    final GroupProfile resolvedFirst = await firstCommitted;
    await Future<void>.delayed(Duration.zero);
    expect(resolvedFirst.name, 'Final edit');
    expect(emitted.last.name, 'Final edit');

    emitted.clear();
    final Completer<void> holdFirstCommit = Completer<void>();
    server.beforeUpdateCommit = holdFirstCommit;
    final Future<GroupProfile> lastCommitted = groups.updateGroup(
      conversation: group1Ref,
      name: 'First edit',
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await groups.updateGroup(conversation: group1Ref, name: 'Final edit');
    holdFirstCommit.complete();
    final GroupProfile resolvedLast = await lastCommitted;
    await Future<void>.delayed(Duration.zero);
    expect(resolvedLast.name, 'First edit');
    expect(emitted.last.name, 'First edit');

    // 6. Another session's edit observed via findGroup before an in-flight
    //    local updateGroup response completes must not revert to the older write,
    //    while an earlier-started write that commits after the read converges
    //    to the write's newer server state.
    emitted.clear();
    final Completer<void> holdLocalReply = Completer<void>();
    server.holdUpdate = holdLocalReply;
    final Future<GroupProfile> delayedLocal = groups.updateGroup(
      conversation: group1Ref,
      name: 'First edit',
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await groupApi.updateGroup(
      token: 'token-1',
      conversation: group1Ref,
      name: 'Final edit',
    );
    final GroupProfile refreshed = await groups.findGroup('10000001');
    expect(refreshed.name, 'Final edit');
    holdLocalReply.complete();
    final GroupProfile afterDelayed = await delayedLocal;
    await Future<void>.delayed(Duration.zero);
    expect(afterDelayed.name, 'Final edit');
    expect(emitted.map((GroupProfile p) => p.name), <String>[
      'Final edit',
      'Final edit',
    ]);

    emitted.clear();
    final Completer<void> holdCommitUntilAfterRead = Completer<void>();
    server.beforeUpdateCommit = holdCommitUntilAfterRead;
    final Future<GroupProfile> lateCommit = groups.updateGroup(
      conversation: group1Ref,
      name: 'Late server commit',
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final GroupProfile beforeCommitRead = await groups.findGroup('10000001');
    expect(beforeCommitRead.name, 'Final edit');
    holdCommitUntilAfterRead.complete();
    final GroupProfile resolvedLateCommit = await lateCommit;
    await Future<void>.delayed(Duration.zero);
    expect(resolvedLateCommit.name, 'Late server commit');
    expect(emitted.last.name, 'Late server commit');
  });
}
