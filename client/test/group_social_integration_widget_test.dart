import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:bb_client/app.dart';
import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_media.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/models/group_models.dart';
import 'package:bb_client/services/auth_api_client.dart';
import 'package:bb_client/services/auth_service.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/avatar_cache.dart';
import 'package:bb_client/services/chat_api_client.dart';
import 'package:bb_client/services/chat_ledger.dart';
import 'package:bb_client/services/chat_service.dart';
import 'package:bb_client/services/conversation_access.dart';
import 'package:bb_client/services/group_api_client.dart';
import 'package:bb_client/services/group_service.dart';
import 'package:bb_client/services/heartbeat_controller.dart';
import 'package:bb_client/services/http_transport.dart';
import 'package:bb_client/services/media_disk_cache.dart';
import 'package:bb_client/services/profile_api_client.dart';
import 'package:bb_client/services/profile_service.dart';
import 'package:bb_client/ui/chat/chat_composer.dart';
import 'package:bb_client/ui/chat/chat_page.dart';
import 'package:bb_client/ui/chat/chat_photo_source.dart';
import 'package:bb_client/ui/chat/chat_system_entry.dart';
import 'package:bb_client/ui/chat/chat_workspace.dart';
import 'package:bb_client/ui/chat/media_save.dart';
import 'package:bb_client/ui/chat/media_viewer.dart';
import 'package:bb_client/ui/chat/user_directory_picker.dart';
import 'package:bb_client/ui/chat/users_view.dart';
import 'package:bb_client/ui/home_view.dart';
import 'package:bb_client/ui/notifications/notification_center.dart';
import 'package:bb_client/ui/profile/avatar_picker.dart';
import 'package:bb_client/ui/profile/group_profile_panel.dart';
import 'package:bb_client/ui/widgets/profile_avatar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_auth_gateway.dart';

final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC',
);

/// Real loopback HTTP server backing wired UI widget tests so tests exercise
/// live HTTP parsing, caching, validation, and revocation end-to-end inside
/// Flutter without mocked service shortcuts.
class _UiSocialServer {
  _UiSocialServer._(this._server);

  static Future<_UiSocialServer> start() async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final _UiSocialServer instance = _UiSocialServer._(server);
    server.listen(instance._handle);
    return instance;
  }

  final HttpServer _server;
  Uri get baseUri => Uri.parse('http://127.0.0.1:${_server.port}');

  final String group1Id = 'group:${'a1b2c3d4' * 4}';
  final String group2Id = 'group:${'e5f60718' * 4}';

  bool createdGroup1 = false;
  bool group1Dissolved = false;
  bool group1MemberRemoved = false;
  bool group1AllowMemberInvites = false;
  String group1Name = 'Alpha群';
  String group1Desc = '初始简介';
  GroupRole? selfRole = GroupRole.owner;
  int group1HistoryThrough = 0;
  int noticeListCalls = 0;
  bool accessRevokedEventPending = false;
  bool mixedEventsPagePending = false;
  bool inviteNoticeAccepted = false;
  bool inviteNoticeRead = false;
  bool paginatedNoticesMode = false;
  bool paginatedPendingAccepted = false;
  bool paginatedPendingInvalidated = false;
  bool paginatedPendingTwoPages = false;
  bool paginatedSecondPendingAccepted = false;
  bool notificationEventPending = false;
  bool notificationEventArrived = false;
  Completer<void>? holdNoticeRefresh;
  bool noticeRefreshHeldStarted = false;
  Completer<void>? holdNoticeLoadMore;
  bool clearNoticeLoadMoreHoldOnHit = false;
  bool noticeLoadMoreHeldStarted = false;
  int allNoticePageTwoResponses = 0;
  Uint8List group1Avatar = _png;
  String group1AvatarVersion = 'gv1';
  final Uint8List resetGroupAvatarBytes = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNQXtcDAAJVAV4On0tgAAAAAElFTkSuQmCC',
  );
  Completer<void>? beforeRead;
  Completer<void>? holdFind;
  Completer<void>? holdAvatar;
  Completer<void>? beforeUpdateCommit;
  Completer<void>? holdUpdate;

  final List<Map<String, dynamic>> createdRequests = <Map<String, dynamic>>[];
  final List<Map<String, dynamic>> sentMessages = <Map<String, dynamic>>[];
  final List<String> executeActions = <String>[];

  late final List<Map<String, dynamic>> group1Messages = <Map<String, dynamic>>[
    <String, dynamic>{
      'id': 'g1-sys-join',
      'position': 1,
      'created_at': '2026-11-27T10:00:00Z',
      'kind': 'system',
      'conversation': <String, dynamic>{'type': 'group', 'id': group1Id},
      'system': <String, dynamic>{
        'type': 'member.joined',
        'account': '10000002',
        'username': 'Bob',
      },
      'text': 'Bob 加入了群聊',
    },
    <String, dynamic>{
      'id': 'g1-msg-1',
      'position': 2,
      'sender_account': '10000002',
      'sender_username': 'Bob',
      'conversation': <String, dynamic>{'type': 'group', 'id': group1Id},
      'created_at': '2026-11-27T10:01:00Z',
      'kind': 'body',
      'content': <Map<String, dynamic>>[
        <String, dynamic>{'type': 'text', 'text': 'group hello'},
        <String, dynamic>{'type': 'image', 'media_id': 'g-img-1'},
      ],
      'attachment': null,
    },
  ];

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    request.response.persistentConnection = false;
    final String path = Uri.decodeComponent(request.uri.path);
    final List<int> raw = await request.fold<List<int>>(
      <int>[],
      (List<int> acc, List<int> chunk) => acc..addAll(chunk),
    );
    Map<String, dynamic>? jsonBody;
    if (raw.isNotEmpty &&
        request.headers.contentType?.mimeType == 'application/json') {
      jsonBody = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
    }

    if (request.method == 'GET' && path == '/profile/10000001') {
      await _json(request, 200, <String, dynamic>{
        'account': '10000001',
        'username': 'Alice',
        'signature': 'hello',
        'avatar_url': '/avatars/10000001.png',
        'avatar_version': 'u1',
      });
      return;
    }
    if (request.method == 'GET' && path == '/profile/10000002') {
      await _json(request, 200, <String, dynamic>{
        'account': '10000002',
        'username': 'Bob',
        'signature': 'peer bio',
        'avatar_url': '/avatars/10000002.png',
        'avatar_version': 'u2',
      });
      return;
    }
    if (request.method == 'GET' &&
        (path == '/avatars/10000001.png' ||
            path == '/avatars/10000002.png' ||
            path == '/chat/groups/10000001/avatar.png')) {
      final bool isGroup = path.startsWith('/chat/groups/');
      final Uint8List bytes = isGroup ? group1Avatar : _png;
      final String etag = isGroup ? group1AvatarVersion : 'av1';
      final Completer<void>? hold = isGroup ? holdAvatar : null;
      if (hold != null) {
        holdAvatar = null;
        await hold.future;
      }
      request.response.statusCode = 200;
      request.response.headers.contentType = ContentType('image', 'png');
      request.response.headers.set('etag', '"$etag"');
      request.response.add(bytes);
      await request.response.close();
      return;
    }
    if (request.method == 'GET' && path == '/users') {
      await _json(request, 200, <String, dynamic>{
        'items': <Map<String, dynamic>>[
          <String, dynamic>{
            'account': '10000002',
            'username': 'Bob',
            'avatar_url': '/avatars/10000002.png',
            'avatar_version': 'u2',
            'presence': 'online',
            'last_message': null,
            'last_activity_at': '2026-11-27T09:50:00Z',
          },
        ],
        'next_cursor': null,
      });
      return;
    }
    if (request.method == 'GET' && path == '/conversations') {
      await _json(request, 200, <String, dynamic>{
        'items': const <Object>[],
        'next_cursor': null,
      });
      return;
    }
    if (request.method == 'GET' && path == '/conversations/10000002/messages') {
      await _json(request, 200, <String, dynamic>{
        'items': const <Object>[],
        'next_position': 0,
        'has_more': false,
      });
      return;
    }
    if (request.method == 'GET' && path == '/chat/conversations') {
      final List<Map<String, dynamic>> items = <Map<String, dynamic>>[
        if (createdGroup1 && selfRole != null && !group1Dissolved)
          <String, dynamic>{
            'conversation': <String, dynamic>{'type': 'group', 'id': group1Id},
            'group_number': '10000001',
            'display_name': group1Name,
            'last_message': null,
            'last_activity_at': '2026-11-27T11:00:00Z',
            'latest_position': group1Messages.length,
            'history_through': group1HistoryThrough,
            'membership_revision': 1,
            'avatar_url': '/chat/groups/10000001/avatar.png',
            'avatar_version': group1AvatarVersion,
          },
        if (inviteNoticeAccepted)
          <String, dynamic>{
            'conversation': <String, dynamic>{'type': 'group', 'id': group2Id},
            'group_number': '10000002',
            'display_name': 'Beta群',
            'last_message': null,
            'last_activity_at': '2026-11-27T11:05:00Z',
            'latest_position': 0,
            'history_through': 0,
            'membership_revision': 1,
            'avatar_url': '',
            'avatar_version': 'gv0',
          },
      ];
      await _json(request, 200, <String, dynamic>{
        'items': items,
        'next_cursor': null,
      });
      return;
    }
    if (request.method == 'GET' &&
        path == '/chat/conversations/$group1Id/messages') {
      if (selfRole == null || group1Dissolved) {
        await _json(request, 403, <String, dynamic>{
          'error': <String, dynamic>{
            'code': 'forbidden',
            'message': '已无权查看该群聊天记录',
            'fields': <Object>[],
          },
        });
        return;
      }
      final String? after = request.uri.queryParameters['after_position'];
      final List<Map<String, dynamic>> items = after == null
          ? group1Messages
          : group1Messages
                .where((m) => (m['position'] as int) > int.parse(after))
                .toList();
      await _json(request, 200, <String, dynamic>{
        'items': items,
        'next_position': items.isEmpty ? 0 : items.last['position'],
        'has_more': false,
      });
      return;
    }
    if (request.method == 'POST' && path == '/messages') {
      sentMessages.add(jsonBody!);
      final Map<String, dynamic> msg = <String, dynamic>{
        'id': 'sent-${sentMessages.length}',
        'position': group1Messages.length + 1,
        'sender_account': '10000001',
        'sender_username': 'Alice',
        'conversation': jsonBody['conversation'],
        'created_at': '2026-11-27T11:10:00Z',
        'kind': 'body',
        'content': jsonBody['content'],
        'attachment': null,
      };
      group1Messages.add(msg);
      await _json(request, 200, msg);
      return;
    }
    if (request.method == 'GET' && path == '/events') {
      final List<Map<String, dynamic>> events = <Map<String, dynamic>>[];
      int nextEventId = 0;
      if (mixedEventsPagePending) {
        mixedEventsPagePending = false;
        selfRole = null;
        events.add(<String, dynamic>{
          'version': 1,
          'event_id': 2,
          'type': 'notification.available',
          'occurred_at': '2026-11-27T11:11:00Z',
          'notification_id': 'notice-invite-1',
        });
        events.add(<String, dynamic>{
          'version': 1,
          'event_id': 7,
          'type': 'conversation.access_changed',
          'occurred_at': '2026-11-27T11:12:00Z',
          'conversation': <String, dynamic>{'type': 'group', 'id': group1Id},
          'active': false,
          'membership_revision': 2,
          'history_through': 2,
        });
        nextEventId = 7;
      } else if (notificationEventPending) {
        notificationEventPending = false;
        notificationEventArrived = true;
        events.add(<String, dynamic>{
          'version': 1,
          'event_id': 1,
          'type': 'notification.available',
          'occurred_at': '2026-11-27T11:13:00Z',
          'notification_id': 'notice-event-added-1',
        });
        nextEventId = 1;
      } else if (accessRevokedEventPending) {
        accessRevokedEventPending = false;
        selfRole = null;
        events.add(<String, dynamic>{
          'version': 1,
          'event_id': 1,
          'type': 'conversation.access_changed',
          'occurred_at': '2026-11-27T11:12:00Z',
          'conversation': <String, dynamic>{'type': 'group', 'id': group1Id},
          'active': false,
          'membership_revision': 2,
          'history_through': 2,
        });
        nextEventId = 1;
      }
      await _json(request, 200, <String, dynamic>{
        'items': events,
        'next_event_id': nextEventId,
        'has_more': false,
      });
      return;
    }
    if (request.method == 'GET' && path == '/events/head') {
      await _json(request, 200, <String, dynamic>{'event_id': 0});
      return;
    }
    if (request.method == 'GET' && path == '/media/g-img-1') {
      if (selfRole == null || group1Dissolved) {
        await _json(request, 403, <String, dynamic>{
          'error': <String, dynamic>{
            'code': 'forbidden',
            'message': '无权访问',
            'fields': <Object>[],
          },
        });
        return;
      }
      request.response.statusCode = 200;
      request.response.headers.contentType = ContentType('image', 'png');
      request.response.headers.set('content-length', '${_png.length}');
      request.response.add(_png);
      await request.response.close();
      return;
    }
    if (request.method == 'GET' && path == '/media/g-img-1/metadata') {
      await _json(request, 200, <String, dynamic>{
        'media_id': 'g-img-1',
        'media_type': 'image',
        'filename': 'g.png',
        'mime_type': 'image/png',
        'byte_size': _png.length,
        'cover_media_id': null,
      });
      return;
    }
    if (request.method == 'POST' && path == '/chat/groups/create') {
      createdGroup1 = true;
      group1Name = jsonBody!['name'] as String;
      group1Desc = jsonBody['description'] as String? ?? '';
      createdRequests.add(jsonBody);
      await _json(request, 200, _groupProfileJson('10000001'));
      return;
    }
    if (request.method == 'POST' && path == '/chat/groups/find') {
      final Completer<void>? before = beforeRead;
      if (before != null) {
        beforeRead = null;
        await before.future;
      }
      final String num = jsonBody!['group_number'] as String;
      final Map<String, dynamic> snapshot = _groupProfileJson(num);
      final Completer<void>? hold = holdFind;
      if (hold != null) {
        holdFind = null;
        await hold.future;
      }
      await _json(request, 200, snapshot);
      return;
    }
    if (request.method == 'POST' && path == '/chat/groups/update') {
      final Completer<void>? before = beforeUpdateCommit;
      if (before != null) {
        beforeUpdateCommit = null;
        await before.future;
      }
      if (jsonBody!['reset_avatar'] == true) {
        group1Avatar = resetGroupAvatarBytes;
        group1AvatarVersion = 'gv2';
      }
      if (jsonBody.containsKey('name')) {
        group1Name = jsonBody['name'] as String;
      }
      if (jsonBody.containsKey('description')) {
        group1Desc = jsonBody['description'] as String;
      }
      if (jsonBody.containsKey('allow_member_invites')) {
        group1AllowMemberInvites = jsonBody['allow_member_invites'] as bool;
      }
      final Map<String, dynamic> committed = _groupProfileJson('10000001');
      final Completer<void>? held = holdUpdate;
      if (held != null) {
        holdUpdate = null;
        await held.future;
      }
      await _json(request, 200, committed);
      return;
    }
    if (request.method == 'POST' && path == '/chat/groups/members') {
      await _json(request, 200, <String, dynamic>{
        'items': <Map<String, dynamic>>[
          <String, dynamic>{
            'account': '10000001',
            'username': 'Alice',
            'avatar_url': '/avatars/10000001.png',
            'avatar_version': 'u1',
            'presence': 'online',
            'role': 'owner',
          },
          if (!group1MemberRemoved)
            <String, dynamic>{
              'account': '10000002',
              'username': 'Bob',
              'avatar_url': '/avatars/10000002.png',
              'avatar_version': 'u2',
              'presence': 'online',
              'role': 'member',
            },
        ],
        'next_cursor': null,
      });
      return;
    }
    if (request.method == 'POST' && path == '/chat/groups/remove_member') {
      group1MemberRemoved = true;
      await _json(request, 200, _groupProfileJson('10000001'));
      return;
    }
    if (request.method == 'POST' && path == '/chat/groups/dissolve') {
      group1Dissolved = true;
      await _json(request, 200, _groupProfileJson('10000001'));
      return;
    }
    if (request.method == 'POST' && path == '/chat/groups/leave') {
      selfRole = null;
      await _json(request, 200, _groupProfileJson('10000001'));
      return;
    }
    if (request.method == 'POST' && path == '/chat/notices/list') {
      noticeListCalls += 1;
      if (paginatedNoticesMode) {
        final String filter = jsonBody?['filter'] as String? ?? 'all';
        final String? cursor = jsonBody?['cursor'] as String?;
        // The blocked response represents the request's pre-invalidation data.
        final bool inviteInvalidatedAtRequest = paginatedPendingInvalidated;
        if (holdNoticeRefresh != null && cursor == null) {
          noticeRefreshHeldStarted = true;
          await holdNoticeRefresh!.future;
        }
        if (holdNoticeLoadMore != null && cursor != null) {
          noticeLoadMoreHeldStarted = true;
          final Completer<void> blocker = holdNoticeLoadMore!;
          if (clearNoticeLoadMoreHoldOnHit) {
            holdNoticeLoadMore = null;
          }
          await blocker.future;
        }
        final String inviteState = inviteInvalidatedAtRequest
            ? 'invalidated'
            : paginatedPendingAccepted
            ? 'processed'
            : 'pending';
        final Map<String, dynamic> olderInvite = <String, dynamic>{
          'id': 'dcf091d4b3f941269deae8748a4fa894',
          'type': 'group_invitation',
          'title': '入群邀请',
          'text': paginatedPendingAccepted
              ? 'Alice 邀请你加入「old」\n处理结果：已接受'
              : 'Alice 邀请你加入「old」',
          'created_at': '2026-11-27T21:37:50.022Z',
          'read': true,
          'state': inviteState,
          'actions': inviteState == 'pending'
              ? <Map<String, dynamic>>[
                  <String, dynamic>{
                    'id': 'accept',
                    'label': '接受',
                    'available': true,
                  },
                  <String, dynamic>{
                    'id': 'reject',
                    'label': '拒绝',
                    'available': true,
                  },
                ]
              : const <Map<String, dynamic>>[],
          'link': <String, dynamic>{'type': 'group', 'id': '27973482'},
        };
        final Map<String, dynamic> extraPending = <String, dynamic>{
          'id': 'pending-page2-invite-2',
          'type': 'group_invitation',
          'title': '入群邀请',
          'text': paginatedSecondPendingAccepted
              ? 'Alice 邀请你加入「older-pending」\n处理结果：已接受'
              : 'Alice 邀请你加入「older-pending」',
          'created_at': '2026-11-27T21:37:49.000Z',
          'read': true,
          'state': paginatedSecondPendingAccepted ? 'processed' : 'pending',
          'actions': paginatedSecondPendingAccepted
              ? const <Map<String, dynamic>>[]
              : <Map<String, dynamic>>[
                  <String, dynamic>{
                    'id': 'accept',
                    'label': '接受',
                    'available': true,
                  },
                  <String, dynamic>{
                    'id': 'reject',
                    'label': '拒绝',
                    'available': true,
                  },
                ],
          'link': <String, dynamic>{'type': 'group', 'id': '27973483'},
        };
        if (filter == 'pending') {
          if (cursor == null) {
            final List<Map<String, dynamic>> firstPending =
                <Map<String, dynamic>>[
                  if (!paginatedPendingAccepted) olderInvite,
                ];
            if (paginatedPendingTwoPages) {
              await _json(request, 200, <String, dynamic>{
                'items': firstPending,
                'next_cursor': 'pending-cursor-2',
                'unread_count': 100,
                'pending_count':
                    firstPending.length +
                    (paginatedSecondPendingAccepted ? 0 : 1),
              });
              return;
            }
            await _json(request, 200, <String, dynamic>{
              'items': firstPending,
              'next_cursor': null,
              'unread_count': 100,
              'pending_count': firstPending.length,
            });
            return;
          }
          if (cursor == 'pending-cursor-2') {
            await _json(request, 200, <String, dynamic>{
              'items': <Map<String, dynamic>>[
                if (!paginatedSecondPendingAccepted) extraPending,
              ],
              'next_cursor': null,
              'unread_count': 100,
              'pending_count':
                  (paginatedPendingAccepted ? 0 : 1) +
                  (paginatedSecondPendingAccepted ? 0 : 1),
            });
            return;
          }
        }
        if (cursor == null) {
          final List<Map<String, dynamic>> items = <Map<String, dynamic>>[
            if (notificationEventArrived)
              <String, dynamic>{
                'id': 'notice-event-added-1',
                'type': 'group_member_joined',
                'title': '新通知事件',
                'text': '服务端事件新增通知',
                'created_at': '2026-11-27T21:38:00.000Z',
                'read': false,
                'state': 'informational',
                'actions': const <Map<String, dynamic>>[],
                'link': <String, dynamic>{'type': 'group', 'id': '90051534'},
              },
            for (int i = 0; i < (notificationEventArrived ? 99 : 100); i += 1)
              <String, dynamic>{
                'id': 'recent-processed-$i',
                'type': 'group_invitation',
                'title': '入群邀请',
                'text': 'Alice 邀请你加入「recent」\n处理结果：已拒绝',
                'created_at':
                    '2026-11-27T21:37:50.${(999 - i).toString().padLeft(3, '0')}Z',
                'read': false,
                'state': 'processed',
                'actions': const <Map<String, dynamic>>[],
                'link': <String, dynamic>{'type': 'group', 'id': '90051534'},
              },
          ];
          await _json(request, 200, <String, dynamic>{
            'items': items,
            'next_cursor': '4bdbf08bf02c41e89899cdd42464875a',
            'unread_count': 100,
            'pending_count':
                (paginatedPendingAccepted || paginatedPendingInvalidated)
                ? 0
                : 1,
          });
          return;
        }
        if (cursor == '4bdbf08bf02c41e89899cdd42464875a') {
          allNoticePageTwoResponses += 1;
          await _json(request, 200, <String, dynamic>{
            'items': <Map<String, dynamic>>[olderInvite],
            'next_cursor': null,
            'unread_count': 100,
            'pending_count': paginatedPendingAccepted ? 0 : 1,
          });
          return;
        }
      }
      await _json(request, 200, <String, dynamic>{
        'items': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'notice-invite-1',
            'type': 'group_invite',
            'title': '群聊邀请',
            'text': 'Bob 邀请你加入 Beta群',
            'created_at': '2026-11-27T10:30:00Z',
            'read': inviteNoticeRead,
            'state': inviteNoticeAccepted ? 'processed' : 'pending',
            'actions': <Map<String, dynamic>>[
              <String, dynamic>{
                'id': 'accept',
                'label': '同意',
                'available': !inviteNoticeAccepted,
              },
              <String, dynamic>{
                'id': 'reject',
                'label': '拒绝',
                'available': !inviteNoticeAccepted,
              },
            ],
            'link': <String, dynamic>{'type': 'group', 'id': '10000002'},
          },
          <String, dynamic>{
            'id': 'notice-dissolved-1',
            'type': 'group_dissolved',
            'title': '群已解散',
            'text': 'Alpha群 已被解散',
            'created_at': '2026-11-27T10:20:00Z',
            'read': true,
            'state': 'invalidated',
            'actions': <Map<String, dynamic>>[
              <String, dynamic>{
                'id': 'accept',
                'label': '已失效按钮',
                'available': true,
              },
            ],
            'link': <String, dynamic>{'type': 'group', 'id': '10000003'},
          },
        ],
        'next_cursor': null,
        'unread_count': inviteNoticeRead ? 0 : 1,
        'pending_count': inviteNoticeAccepted ? 0 : 1,
      });
      return;
    }
    if (request.method == 'POST' && path == '/chat/notices/mark_read') {
      inviteNoticeRead = true;
      await _json(request, 200, <String, dynamic>{
        'id': 'notice-invite-1',
        'type': 'group_invite',
        'title': '群聊邀请',
        'text': 'Bob 邀请你加入 Beta群',
        'created_at': '2026-11-27T10:30:00Z',
        'read': true,
        'state': inviteNoticeAccepted ? 'processed' : 'pending',
        'actions': <Map<String, dynamic>>[],
        'link': <String, dynamic>{'type': 'group', 'id': '10000002'},
      });
      return;
    }
    if (request.method == 'POST' && path == '/chat/notices/execute_action') {
      final String id = jsonBody!['notification_id'] as String;
      final String actionId = jsonBody['action_id'] as String;
      executeActions.add('$id:$actionId');
      if (id == 'dcf091d4b3f941269deae8748a4fa894') {
        paginatedPendingAccepted = actionId == 'accept';
      } else if (id == 'pending-page2-invite-2') {
        paginatedSecondPendingAccepted = actionId == 'accept';
      } else {
        inviteNoticeAccepted = actionId == 'accept';
      }
      await _json(request, 200, <String, dynamic>{
        'id': id,
        'type': 'group_invite',
        'title': '群聊邀请',
        'text': '已处理',
        'created_at': '2026-11-27T10:30:00Z',
        'read': inviteNoticeRead,
        'state': 'processed',
        'actions': <Map<String, dynamic>>[],
        'link': <String, dynamic>{'type': 'group', 'id': '10000002'},
      });
      return;
    }

    await _json(request, 404, <String, dynamic>{
      'error': <String, dynamic>{
        'code': 'not_found',
        'message': 'not_found',
        'fields': <Object>[],
      },
    });
  }

  Map<String, dynamic> _groupProfileJson(String number) {
    final bool isFirst = number == '10000001';
    final bool dissolved = isFirst ? group1Dissolved : true;
    final GroupRole? role = isFirst ? selfRole : null;
    return <String, dynamic>{
      'conversation': <String, dynamic>{
        'type': 'group',
        'id': isFirst ? group1Id : group2Id,
      },
      'group_number': number,
      'name': isFirst ? group1Name : 'Beta群',
      'description': isFirst ? group1Desc : '已解散群简介',
      'avatar_url': isFirst ? '/chat/groups/10000001/avatar.png' : '',
      'avatar_version': isFirst ? group1AvatarVersion : 'gv0',
      'status': dissolved ? 'dissolved' : 'active',
      'role': role?.name,
      'can_invite':
          !dissolved && (role == GroupRole.owner || group1AllowMemberInvites),
      'allow_member_invites': group1AllowMemberInvites,
    };
  }

  Future<void> _json(
    HttpRequest request,
    int status,
    Map<String, dynamic> body,
  ) async {
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(body));
    await request.response.close();
  }
}

class _FakeAvatarPicker implements AvatarImagePicker {
  @override
  Future<AvatarPick?> pickImage() async => null;
}

class _AllowLoopbackHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)..idleTimeout = Duration.zero;
}

Future<void> _settle(WidgetTester tester, {int rounds = 20}) async {
  for (int i = 0; i < rounds; i += 1) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _UiSocialServer server;
  late Directory tempDir;
  late AuthSession session;
  late ProfileService profile;
  late HeartbeatController heartbeat;
  late ChatService chat;
  late ConversationAccessController access;
  late GroupService groups;
  late SharedConversationService shared;
  late MediaDiskCache disk;

  setUpAll(() {
    HttpOverrides.global = _AllowLoopbackHttpOverrides();
  });

  setUp(() async {
    server = await _UiSocialServer.start();
    tempDir = await Directory.systemTemp.createTemp('bb_ui_social_');
    final HttpTransport transport = HttpTransport(factory: () => HttpClient());
    session = AuthSession()
      ..establish(
        token: 'tok-alice',
        user: const AuthUser(account: '10000001', username: 'Alice'),
      );
    final AuthService auth = AuthService(
      api: AuthApiClient(baseUri: server.baseUri),
      session: session,
    );
    profile = ProfileService(
      api: ProfileApiClient(baseUri: server.baseUri),
      auth: auth,
      cache: AvatarCache(directory: Directory('${tempDir.path}/user-avatars')),
    );
    heartbeat = HeartbeatController(auth: auth);
    final ChatApiClient chatApi = ChatApiClient(
      baseUri: server.baseUri,
      transport: transport,
    );
    chat = ChatService(
      api: chatApi,
      session: session,
      ledger: ChatLedger.inMemory(),
      cacheRoot: Directory('${tempDir.path}/chat-cache'),
      webSocketHints: false,
    );
    access = ConversationAccessController();
    disk = MediaDiskCache(directory: Directory('${tempDir.path}/disk'));
    registerDiskCachePurger(
      access: access,
      disk: disk,
      serverUri: server.baseUri,
    );
    groups = GroupService(
      api: GroupApiClient(baseUri: server.baseUri, transport: transport),
      session: session,
      avatarCache: AvatarCache(
        directory: Directory('${tempDir.path}/group-avatars'),
      ),
      access: access,
    );
    shared = SharedConversationService(
      api: chatApi,
      session: session,
      access: access,
    );
  });

  tearDown(() async {
    heartbeat.stop();
    shared.dispose();
    await chat.dispose();
    await server.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<void> pumpHome(
    WidgetTester tester, {
    Size size = const Size(375, 812),
    List<DisplayFeature> features = const <DisplayFeature>[],
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(displayFeatures: features, disableAnimations: true),
          child: child!,
        ),
        home: HomeView(
          user: const AuthUser(account: '10000001', username: 'Alice'),
          profile: profile,
          auth: FakeAuthGateway(),
          heartbeat: heartbeat,
          chat: chat,
          groups: groups,
          shared: shared,
          avatarPicker: _FakeAvatarPicker(),
          onSignedOut: (_) {},
          onSessionExpired: () {},
        ),
      ),
    );
    await _settle(tester);
  }

  testWidgets(
    'A1/A4/A5/A6/A10: create solo group from Home, send message with sender attribution, edit profile, navigate member->DM',
    (WidgetTester tester) async {
      // Seed user avatar cache for account '10000001' to prove group number
      // '10000001' never overwrites user avatar cache.
      await tester.runAsync(
        () => profile.cache.write(
          '10000001',
          Uint8List.fromList(<int>[9, 8, 7]),
          'u1',
          thumb: true,
        ),
      );

      await pumpHome(tester, size: const Size(375, 812));

      // Open "+" -> "创建群", skip invitees (solo group A1), submit group name.
      await tester.tap(find.byKey(HomeView.groupMenuKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('创建群'));
      await tester.pump(const Duration(milliseconds: 400));
      await _settle(tester);
      await tester.tap(find.byKey(UserDirectoryPicker.confirmKey));
      await tester.pump(const Duration(milliseconds: 400));
      await _settle(tester);

      await tester.enterText(find.byType(TextFormField).first, '  Alpha群  ');
      await tester.tap(find.text('保存群资料'));
      await _settle(tester);
      expect(server.createdRequests.single['invitees'], isEmpty);
      expect(server.createdRequests.single['name'], 'Alpha群');

      // Empty newly created group appears directly in list with group_number cache isolated.
      expect(
        find.byKey(UsersListView.groupRowKey(server.group1Id)),
        findsOneWidget,
      );
      final CachedAvatar? untouchedUserAvatar = await tester
          .runAsync<CachedAvatar?>(
            () => profile.cache.read('10000001', thumb: true),
          );
      expect(untouchedUserAvatar?.bytes, <int>[9, 8, 7]);

      // Tap group row -> opens ChatPage showing system entry, Bob attribution,
      // group number subtitle (never "在线").
      await tester.tap(find.byKey(UsersListView.groupRowKey(server.group1Id)));
      await _settle(tester);
      expect(find.byType(ChatSystemEntry), findsOneWidget);
      expect(find.text('Bob 加入了群聊'), findsOneWidget);
      expect(
        find.descendant(of: find.byType(ChatPage), matching: find.text('Bob')),
        findsOneWidget,
      );
      expect(find.text('群号 10000001'), findsOneWidget);

      // Send a group message via shared endpoint.
      await tester.enterText(
        find.byKey(ChatComposer.inputKey),
        'hello group ui',
      );
      await tester.pump();
      await tester.tap(find.byKey(ChatComposer.sendKey));
      await _settle(tester);
      expect(server.sentMessages.single['conversation'], <String, dynamic>{
        'type': 'group',
        'id': server.group1Id,
      });
      expect(find.text('hello group ui'), findsOneWidget);

      // Tap group header avatar -> GroupProfilePanel as owner -> edit group name
      // -> close profile -> verify ChatPage header updates immediately on phone,
      // then pop to UsersListView and verify list updates before re-entering.
      await tester.tap(find.byKey(ChatPage.headerProfileKey));
      await _settle(tester);
      expect(find.byType(GroupProfilePanel), findsOneWidget);
      await tester.tap(find.text('编辑群资料'));
      await _settle(tester);
      await tester.enterText(find.byType(TextFormField).first, 'Renamed group');
      await tester.tap(find.text('保存群资料'));
      await _settle(tester);
      expect(server.group1Name, 'Renamed group');
      expect(find.text('Renamed group'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await _settle(tester);
      expect(
        tester.widget<Text>(find.byKey(ChatPage.headerNameKey)).data,
        'Renamed group',
      );

      // Pop back to Home list -> updated name is shown -> re-open chat & profile.
      await tester.binding.handlePopRoute();
      await _settle(tester);
      expect(
        find.descendant(
          of: find.byKey(UsersListView.groupRowKey(server.group1Id)),
          matching: find.text('Renamed group'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(UsersListView.groupRowKey(server.group1Id)));
      await _settle(tester);
      expect(
        tester.widget<Text>(find.byKey(ChatPage.headerNameKey)).data,
        'Renamed group',
      );

      await tester.tap(find.byKey(ChatPage.headerProfileKey));
      await _settle(tester);
      expect(find.byType(GroupProfilePanel), findsOneWidget);
      await tester.tap(find.text('允许所有成员邀请'));
      await _settle(tester);
      expect(server.group1AllowMemberInvites, isTrue);

      await tester.tap(find.text('查看成员'));
      await _settle(tester);
      expect(
        find.byKey(const ValueKey<String>('remove-member-10000002')),
        findsOneWidget,
      );
      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('group-members-list')),
          matching: find.text('Bob'),
        ),
      );
      await _settle(tester);

      // Reused existing 1:1 DM page opened for Bob!
      expect(find.byKey(ChatPage.headerNameKey), findsOneWidget);
      expect(find.text('Bob'), findsWidgets);
      expect(find.text('在线'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 35));
    },
  );

  testWidgets(
    'A2/A7/A9: third-tab NotificationCenter stays independent, respects read vs pending, executes actions, and opens dissolved profile',
    (WidgetTester tester) async {
      await pumpHome(tester, size: const Size(1280, 900));

      // Switch to third navigation tab.
      await tester.tap(find.byKey(HomeView.navNotificationsKey));
      await _settle(tester);
      expect(find.text('群聊邀请'), findsOneWidget);
      expect(find.text('群已解散'), findsOneWidget);
      // Invalidated entry hides its action button.
      expect(
        find.byKey(
          NotificationCenter.actionKey('notice-dissolved-1', 'accept'),
        ),
        findsNothing,
      );

      // Filtering pending before reading still keeps invite pending; marking read
      // does not execute or remove it from pending!
      await tester.tap(find.text('标为已读'));
      await _settle(tester);
      await tester.tap(find.byKey(NotificationCenter.pendingKey));
      await _settle(tester);
      expect(
        find.byKey(NotificationCenter.entryKey('notice-invite-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(NotificationCenter.entryKey('notice-dissolved-1')),
        findsNothing,
      );

      // Execute action 'accept' -> processed & cleared from pending filter.
      await tester.tap(
        find.byKey(NotificationCenter.actionKey('notice-invite-1', 'accept')),
      );
      await _settle(tester);
      expect(server.executeActions, <String>['notice-invite-1:accept']);
      expect(find.text('没有待处理的通知'), findsOneWidget);

      // Switch back to All and open dissolved group's read-only profile via link.
      await tester.tap(find.byKey(NotificationCenter.allKey));
      await _settle(tester);
      await tester.tap(find.text('查看资料').last);
      await _settle(tester);
      expect(find.text('该群已解散'), findsOneWidget);
      expect(find.text('申请加入'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 35));
    },
  );

  testWidgets(
    'A6/A8: folded split workspace & open MediaViewer drop group and disk cache immediately on revocation',
    (WidgetTester tester) async {
      server.createdGroup1 = true;
      await pumpHome(
        tester,
        size: const Size(900, 768),
        features: const <DisplayFeature>[
          DisplayFeature(
            bounds: Rect.fromLTWH(450, 0, 8, 768),
            type: DisplayFeatureType.hinge,
            state: DisplayFeatureState.postureFlat,
          ),
        ],
      );
      expect(find.byKey(ChatWorkspace.toggleKey), findsOneWidget);
      expect(
        find.byKey(UsersListView.groupRowKey(server.group1Id)),
        findsOneWidget,
      );

      // Select group in folded split ChatWorkspace.
      await tester.tap(find.byKey(UsersListView.groupRowKey(server.group1Id)));
      await _settle(tester);
      expect(find.text('group hello'), findsOneWidget);

      // Seed disk cache for group media and open MediaViewer with access controller.
      final ConversationRef groupRef = ConversationRef.group(server.group1Id);
      final ChatMediaItem item = buildConversationMedia(
        messages: <ChatMessage>[
          ChatMessage(
            id: 'g1-msg-1',
            position: 2,
            senderAccount: '10000002',
            senderUsername: 'Bob',
            conversation: groupRef,
            createdAt: DateTime.now().toUtc(),
            kind: ChatMessageKind.body,
            parts: const <MessagePart>[ImagePart('g-img-1')],
          ),
        ],
        selfAccount: '10000001',
        selfName: '我',
        peerName: 'Bob',
      ).single;
      final ChatPhotoSource photoSource = ChatPhotoSource(
        item: item,
        chat: chat,
        disk: disk,
        access: access,
        conversation: groupRef,
      );
      await tester.runAsync(() => disk.write(photoSource.diskKey, _png));
      photoSource.dispose();
      expect(await tester.runAsync(() => disk.read(photoSource.diskKey)), _png);

      // Open MediaViewer inside the widget tree.
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: MediaViewer(
            items: <ChatMediaItem>[item],
            initialIndex: 0,
            chat: chat,
            saveService: MediaSaveService(chat: chat),
            conversation: groupRef,
            access: access,
          ),
        ),
      );
      await _settle(tester);
      expect(find.byType(MediaViewer), findsOneWidget);

      // Simulate server revocation event (leave/removed/dissolved).
      await tester.runAsync(
        () => access.revoke('10000001', server.group1Id, membershipRevision: 2),
      );
      await _settle(tester);
      expect(
        await tester.runAsync(() => disk.read(photoSource.diskKey)),
        isNull,
      );

      // Re-mount split workspace under same revoked access -> group vanishes immediately.
      await pumpHome(tester, size: const Size(1280, 900));
      expect(
        find.byKey(UsersListView.groupRowKey(server.group1Id)),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 35));
    },
  );

  testWidgets(
    'A5/A7/A8/§8: group unread badge excludes historyThrough, confirms display after visible, and mixed event page refreshes notices + revokes access',
    (WidgetTester tester) async {
      server.createdGroup1 = true;
      server.group1HistoryThrough = 1;
      server.group1Messages
        ..clear()
        ..addAll(<Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'g1-pre',
            'position': 1,
            'sender_account': '10000002',
            'sender_username': 'Bob',
            'conversation': <String, dynamic>{
              'type': 'group',
              'id': server.group1Id,
            },
            'created_at': '2026-11-27T09:55:00Z',
            'kind': 'body',
            'content': <Map<String, dynamic>>[
              <String, dynamic>{'type': 'text', 'text': 'pre-join old'},
            ],
            'attachment': null,
          },
          <String, dynamic>{
            'id': 'g1-sys',
            'position': 2,
            'created_at': '2026-11-27T10:00:00Z',
            'kind': 'system',
            'conversation': <String, dynamic>{
              'type': 'group',
              'id': server.group1Id,
            },
            'system': <String, dynamic>{
              'type': 'member.joined',
              'account': '10000001',
              'username': 'Alice',
            },
            'text': 'Alice 加入了群聊',
          },
          <String, dynamic>{
            'id': 'g1-post',
            'position': 3,
            'sender_account': '10000002',
            'sender_username': 'Bob',
            'conversation': <String, dynamic>{
              'type': 'group',
              'id': server.group1Id,
            },
            'created_at': '2026-11-27T10:01:00Z',
            'kind': 'body',
            'content': <Map<String, dynamic>>[
              <String, dynamic>{'type': 'text', 'text': 'post-join unread'},
            ],
            'attachment': null,
          },
        ]);

      await pumpHome(tester, size: const Size(1280, 900));
      // Only post-join non-system message 'g1-post' counts towards unread badge.
      expect(
        tester
            .widget<Text>(find.byKey(UsersListView.unreadKey(server.group1Id)))
            .data,
        '1',
      );
      Set<String> displayed =
          await tester.runAsync(
            () => chat.ledger.displayedMessageIds('10000001'),
          ) ??
          <String>{};
      expect(displayed, isNot(contains('g1-post')));
      expect(displayed, isNot(contains('g1-pre')));

      // Switch to NotificationCenter tab (mounts NotificationCenterHost & obscures
      // chat surface) while another post-join inbound message arrives.
      await tester.tap(find.byKey(HomeView.navNotificationsKey));
      await _settle(tester);
      final int noticeCallsBefore = server.noticeListCalls;
      server.group1Messages.add(<String, dynamic>{
        'id': 'g1-obscured',
        'position': 4,
        'sender_account': '10000002',
        'sender_username': 'Bob',
        'conversation': <String, dynamic>{
          'type': 'group',
          'id': server.group1Id,
        },
        'created_at': '2026-11-27T10:02:00Z',
        'kind': 'body',
        'content': <Map<String, dynamic>>[
          <String, dynamic>{'type': 'text', 'text': 'arrived while covered'},
        ],
        'attachment': null,
      });
      await tester.pump(const Duration(seconds: 3));
      await _settle(tester);
      displayed =
          await tester.runAsync(
            () => chat.ledger.displayedMessageIds('10000001'),
          ) ??
          <String>{};
      expect(displayed, isNot(contains('g1-post')));
      expect(displayed, isNot(contains('g1-obscured')));

      // Return to Chat and open group -> body renders visible -> exact post-join
      // message IDs are confirmed in ledger and badge clears; pre-join stays
      // unrecorded.
      await tester.tap(find.byKey(HomeView.navChatKey));
      await _settle(tester);
      await tester.tap(find.byKey(UsersListView.groupRowKey(server.group1Id)));
      await _settle(tester);
      expect(find.text('post-join unread'), findsOneWidget);
      expect(find.text('arrived while covered'), findsOneWidget);
      displayed =
          await tester.runAsync(
            () => chat.ledger.displayedMessageIds('10000001'),
          ) ??
          <String>{};
      expect(displayed, containsAll(<String>['g1-post', 'g1-obscured']));
      expect(displayed, isNot(contains('g1-pre')));
      expect(displayed, isNot(contains('g1-sys')));
      expect(
        find.byKey(UsersListView.unreadKey(server.group1Id)),
        findsNothing,
      );

      // Mixed /events?include_groups=true page: notification.available (event 2)
      // followed by conversation.access_changed(active:false) (event 7) in the
      // same HTTP page must BOTH refresh NotificationCenterHost AND revoke
      // membership/evict the group cleanly.
      server.mixedEventsPagePending = true;
      await tester.pump(const Duration(seconds: 3));
      await _settle(tester);
      expect(server.noticeListCalls, greaterThan(noticeCallsBefore));
      expect(access.isRevoked('10000001', server.group1Id), isTrue);
      expect(
        find.byKey(UsersListView.groupRowKey(server.group1Id)),
        findsNothing,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 35));
    },
  );

  testWidgets(
    'A7: older read invitation past all page 1 remains actionable across pending filter, load more, and event refresh',
    (WidgetTester tester) async {
      server.paginatedNoticesMode = true;
      const String targetId = 'dcf091d4b3f941269deae8748a4fa894';
      await pumpHome(tester, size: const Size(1280, 900));

      // Navigate to Notifications: "全部" loads page 1 (100 processed items)
      // with next_cursor pointing to page 2 containing the older invitation.
      await tester.tap(find.byKey(HomeView.navNotificationsKey));
      await _settle(tester);
      expect(find.byKey(NotificationCenter.entryKey(targetId)), findsNothing);

      // Switching to "待处理" must query filter=pending and show the actionable
      // older read invitation instead of reporting "没有待处理的通知".
      await tester.tap(find.byKey(NotificationCenter.pendingKey));
      await _settle(tester);
      expect(find.text('没有待处理的通知'), findsNothing);
      expect(find.byKey(NotificationCenter.entryKey(targetId)), findsOneWidget);
      expect(
        find.byKey(NotificationCenter.actionKey(targetId, 'accept')),
        findsOneWidget,
      );

      // Pending filter itself supports subsequent pages (loadMoreKey) and acts
      // by exact notification ID.
      server.paginatedPendingTwoPages = true;
      await tester.tap(find.byKey(NotificationCenter.allKey));
      await _settle(tester);
      await tester.tap(find.byKey(NotificationCenter.pendingKey));
      await _settle(tester);
      await tester.tap(find.byKey(NotificationCenter.loadMoreKey));
      await _settle(tester);
      expect(
        find.byKey(NotificationCenter.entryKey('pending-page2-invite-2')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(
          NotificationCenter.actionKey('pending-page2-invite-2', 'accept'),
        ),
      );
      await _settle(tester);
      expect(server.executeActions, contains('pending-page2-invite-2:accept'));

      // Switching back to "全部" can load page 2 via loadMoreKey, preserves
      // page 2 across notification.available event refresh, and executes by ID.
      await tester.tap(find.byKey(NotificationCenter.allKey));
      await _settle(tester);
      final Finder scrollable = find.byType(Scrollable).last;
      await tester.scrollUntilVisible(
        find.byKey(NotificationCenter.loadMoreKey),
        600,
        scrollable: scrollable,
      );
      await _settle(tester);
      await tester.tap(find.byKey(NotificationCenter.loadMoreKey));
      await _settle(tester);
      await tester.scrollUntilVisible(
        find.byKey(NotificationCenter.entryKey(targetId)),
        600,
        scrollable: scrollable,
      );
      expect(find.byKey(NotificationCenter.entryKey(targetId)), findsOneWidget);

      // Fire notification.available while viewing "全部" page 2 -> refreshes
      // opened pages so page-2 entry stays present & actionable by current ID.
      server.notificationEventPending = true;
      await tester.pump(const Duration(seconds: 3));
      await _settle(tester);
      expect(server.notificationEventArrived, isTrue);
      await tester.ensureVisible(
        find.byKey(NotificationCenter.actionKey(targetId, 'accept')),
      );
      await tester.tap(
        find.byKey(NotificationCenter.actionKey(targetId, 'accept')),
      );
      await _settle(tester);
      expect(server.executeActions, contains('$targetId:accept'));

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 35));
    },
  );

  testWidgets(
    'A7: delayed notice refresh completing after loadMore preserves expanded page two',
    (WidgetTester tester) async {
      server.paginatedNoticesMode = true;
      const String targetId = 'dcf091d4b3f941269deae8748a4fa894';
      await pumpHome(tester, size: const Size(1280, 900));

      // Navigate to Notifications ("全部" page 1) and scroll to loadMoreKey.
      await tester.tap(find.byKey(HomeView.navNotificationsKey));
      await _settle(tester);
      final Finder scrollable = find.byType(Scrollable).last;
      await tester.scrollUntilVisible(
        find.byKey(NotificationCenter.loadMoreKey),
        600,
        scrollable: scrollable,
      );
      await _settle(tester);

      // Order 1 (Sentinel qa3 reproducer): background refresh starts first and
      // stalls; user taps loadMore; page 2 completes FIRST, then delayed
      // first-page refresh resolves SECOND. Page 2 must stay visible and
      // actionable without re-showing loadMoreKey.
      server.holdNoticeRefresh = Completer<void>();
      server.notificationEventPending = true;
      await tester.pump(const Duration(seconds: 3));
      await _settle(tester);
      expect(server.noticeRefreshHeldStarted, isTrue);

      await tester.tap(find.byKey(NotificationCenter.loadMoreKey));
      await _settle(tester);
      await tester.scrollUntilVisible(
        find.byKey(NotificationCenter.actionKey(targetId, 'accept')),
        300,
        scrollable: scrollable,
      );
      await _settle(tester);
      expect(
        find.byKey(NotificationCenter.actionKey(targetId, 'accept')),
        findsOneWidget,
      );

      server.holdNoticeRefresh!.complete();
      server.holdNoticeRefresh = null;
      await _settle(tester);
      expect(
        find.byKey(NotificationCenter.actionKey(targetId, 'accept')),
        findsOneWidget,
      );
      expect(find.byKey(NotificationCenter.loadMoreKey), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 35));
    },
  );

  testWidgets(
    'A7: concurrent notice refresh completing before delayed loadMore preserves page two',
    (WidgetTester tester) async {
      server.paginatedNoticesMode = true;
      const String targetId = 'dcf091d4b3f941269deae8748a4fa894';
      await pumpHome(tester, size: const Size(1280, 900));

      await tester.tap(find.byKey(HomeView.navNotificationsKey));
      await _settle(tester);
      final Finder scrollable = find.byType(Scrollable).last;
      await tester.scrollUntilVisible(
        find.byKey(NotificationCenter.loadMoreKey),
        600,
        scrollable: scrollable,
      );
      await _settle(tester);

      // Background refresh AND user loadMore overlap; refresh completes FIRST
      // (prepending a new event notice on page 1), then delayed loadMore
      // resolves SECOND. Both page 1 refresh and page 2 invitation must remain
      // visible and actionable by current ID.
      server.holdNoticeRefresh = Completer<void>();
      server.holdNoticeLoadMore = Completer<void>();
      server.notificationEventPending = true;
      await tester.pump(const Duration(seconds: 3));
      await _settle(tester);
      expect(server.noticeRefreshHeldStarted, isTrue);

      await tester.tap(find.byKey(NotificationCenter.loadMoreKey));
      await _settle(tester);
      expect(server.noticeLoadMoreHeldStarted, isTrue);

      // Release refresh FIRST while loadMore is still in flight.
      server.holdNoticeRefresh!.complete();
      server.holdNoticeRefresh = null;
      await _settle(tester);
      expect(server.notificationEventArrived, isTrue);

      // Now release loadMore SECOND.
      server.holdNoticeLoadMore!.complete();
      server.holdNoticeLoadMore = null;
      await _settle(tester);

      await tester.drag(scrollable, const Offset(0, -400));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(NotificationCenter.actionKey(targetId, 'accept')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(NotificationCenter.actionKey(targetId, 'accept')),
        findsOneWidget,
      );
      expect(find.byKey(NotificationCenter.loadMoreKey), findsNothing);
      await tester.tap(
        find.byKey(NotificationCenter.actionKey(targetId, 'accept')),
      );
      await _settle(tester);
      expect(server.executeActions, contains('$targetId:accept'));

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 35));
    },
  );

  testWidgets(
    'A7: refresh with unchanged next_cursor invalidates stalled page two and shows updated invalidated state',
    (WidgetTester tester) async {
      server.paginatedNoticesMode = true;
      server.clearNoticeLoadMoreHoldOnHit = true;
      const String targetId = 'dcf091d4b3f941269deae8748a4fa894';
      await pumpHome(tester, size: const Size(1280, 900));

      // Open Notifications -> "全部", scroll to loadMoreKey and click it while
      // pre-dissolve page 2 response stalls.
      await tester.tap(find.byKey(HomeView.navNotificationsKey));
      await _settle(tester);
      final Finder scrollable = find.byType(Scrollable).last;
      await tester.scrollUntilVisible(
        find.byKey(NotificationCenter.loadMoreKey),
        600,
        scrollable: scrollable,
      );
      await _settle(tester);

      final Completer<void> stalledOldPage2 = Completer<void>();
      server.holdNoticeLoadMore = stalledOldPage2;
      await tester.tap(find.byKey(NotificationCenter.loadMoreKey));
      await _settle(tester);
      expect(server.noticeLoadMoreHeldStarted, isTrue);

      // Simulate group dissolution: page 1 keeps the SAME next_cursor while
      // pending_count becomes 0 and page 2 now carries state=invalidated. Switch
      // to Chat and back to Notifications to trigger page 1 refresh first.
      server.paginatedPendingInvalidated = true;
      final int callsBeforeRefresh = server.noticeListCalls;
      await tester.tap(find.byKey(HomeView.navChatKey));
      await _settle(tester);
      await tester.tap(find.byKey(HomeView.navNotificationsKey));
      await _settle(tester);
      expect(server.noticeListCalls, greaterThan(callsBeforeRefresh));

      // Now deliver the delayed pre-dissolve page 2 response. Host must discard
      // it, re-fetch page 2, and render the invalidated entry WITHOUT "accept".
      stalledOldPage2.complete();
      await _settle(tester);

      final Finder targetRow = find.byKey(
        NotificationCenter.entryKey(targetId),
      );
      await tester.scrollUntilVisible(
        targetRow,
        500,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.ensureVisible(targetRow);
      await tester.pumpAndSettle();
      expect(targetRow, findsOneWidget);
      expect(
        find.byKey(NotificationCenter.actionKey(targetId, 'accept')),
        findsNothing,
      );
      expect(server.allNoticePageTwoResponses, 2);
      expect(find.byKey(NotificationCenter.loadMoreKey), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 35));
    },
  );

  testWidgets(
    'A6: split desktop layout updates both ChatPage header and UsersListView row after group rename',
    (WidgetTester tester) async {
      server.createdGroup1 = true;
      await pumpHome(tester, size: const Size(1280, 900));

      await tester.tap(find.byKey(UsersListView.groupRowKey(server.group1Id)));
      await _settle(tester);
      expect(
        tester.widget<Text>(find.byKey(ChatPage.headerNameKey)).data,
        'Alpha群',
      );

      await tester.tap(find.byKey(ChatPage.headerProfileKey));
      await _settle(tester);
      await tester.tap(find.text('编辑群资料'));
      await _settle(tester);
      await tester.enterText(
        find.byType(TextFormField).first,
        'Renamed desktop group',
      );
      await tester.tap(find.text('保存群资料'));
      await _settle(tester);
      expect(server.group1Name, 'Renamed desktop group');

      await tester.binding.handlePopRoute();
      await _settle(tester);
      expect(
        tester.widget<Text>(find.byKey(ChatPage.headerNameKey)).data,
        'Renamed desktop group',
      );
      expect(
        find.descendant(
          of: find.byKey(UsersListView.groupRowKey(server.group1Id)),
          matching: find.text('Renamed desktop group'),
        ),
        findsOneWidget,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 35));
    },
  );

  testWidgets(
    'A6: dismissed profile query completing after rename cannot revert ChatPage header',
    (WidgetTester tester) async {
      server.createdGroup1 = true;
      await pumpHome(tester, size: const Size(375, 812));

      await tester.tap(find.byKey(UsersListView.groupRowKey(server.group1Id)));
      await _settle(tester);
      expect(
        tester.widget<Text>(find.byKey(ChatPage.headerNameKey)).data,
        'Alpha群',
      );

      final Completer<void> held = Completer<void>();
      server.holdFind = held;
      await tester.tap(find.byKey(ChatPage.headerProfileKey));
      await _settle(tester);
      expect(server.holdFind, isNull);
      await tester.binding.handlePopRoute();
      await _settle(tester);

      await tester.tap(find.byKey(ChatPage.headerProfileKey));
      await _settle(tester);
      await tester.tap(find.text('编辑群资料'));
      await _settle(tester);
      await tester.enterText(
        find.byType(TextFormField).first,
        'Renamed desktop group',
      );
      await tester.tap(find.text('保存群资料'));
      await _settle(tester);
      expect(server.group1Name, 'Renamed desktop group');

      await tester.binding.handlePopRoute();
      await _settle(tester);
      expect(
        tester.widget<Text>(find.byKey(ChatPage.headerNameKey)).data,
        'Renamed desktop group',
      );

      held.complete();
      await _settle(tester);
      expect(
        tester.widget<Text>(find.byKey(ChatPage.headerNameKey)).data,
        'Renamed desktop group',
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 35));
    },
  );

  testWidgets(
    'A6: pre-reset group avatar response arriving after reset cannot overwrite ChatPage header or thumbnail cache',
    (WidgetTester tester) async {
      server.createdGroup1 = true;
      await pumpHome(tester, size: const Size(375, 812));

      final Completer<void> held = Completer<void>();
      server.holdAvatar = held;
      await tester.tap(find.byKey(UsersListView.groupRowKey(server.group1Id)));
      await _settle(tester);
      expect(server.holdAvatar, isNull);

      await tester.tap(find.byKey(ChatPage.headerProfileKey));
      await _settle(tester);
      await tester.tap(find.text('编辑群资料'));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('group-edit-avatar-reset')));
      await tester.tap(find.text('保存群资料'));
      await _settle(tester);
      expect(server.group1AvatarVersion, 'gv2');

      await tester.binding.handlePopRoute();
      await _settle(tester);
      Uint8List? headerBytes() => tester
          .widget<ProfileAvatar>(find.byKey(ChatPage.headerProfileKey))
          .bytes;
      expect(headerBytes(), orderedEquals(server.resetGroupAvatarBytes));

      held.complete();
      await _settle(tester);
      final CachedAvatar? cached = await tester.runAsync<CachedAvatar?>(
        () => groups.avatarCache.read('group-10000001', thumb: true),
      );
      expect(headerBytes(), orderedEquals(server.resetGroupAvatarBytes));
      expect(cached?.version, 'gv2');
      expect(cached?.bytes, orderedEquals(server.resetGroupAvatarBytes));

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 35));
    },
  );

  testWidgets(
    'A6: folded layout updates both ChatPage header and UsersListView row after group rename',
    (WidgetTester tester) async {
      server.createdGroup1 = true;
      await pumpHome(
        tester,
        size: const Size(900, 768),
        features: const <DisplayFeature>[
          DisplayFeature(
            bounds: Rect.fromLTWH(450, 0, 8, 768),
            type: DisplayFeatureType.hinge,
            state: DisplayFeatureState.postureFlat,
          ),
        ],
      );

      await tester.tap(find.byKey(UsersListView.groupRowKey(server.group1Id)));
      await _settle(tester);
      expect(
        tester.widget<Text>(find.byKey(ChatPage.headerNameKey)).data,
        'Alpha群',
      );

      await tester.tap(find.byKey(ChatPage.headerProfileKey));
      await _settle(tester);
      await tester.tap(find.text('编辑群资料'));
      await _settle(tester);
      await tester.enterText(
        find.byType(TextFormField).first,
        'Renamed folded group',
      );
      await tester.tap(find.text('保存群资料'));
      await _settle(tester);
      expect(server.group1Name, 'Renamed folded group');

      await tester.binding.handlePopRoute();
      await _settle(tester);
      expect(
        tester.widget<Text>(find.byKey(ChatPage.headerNameKey)).data,
        'Renamed folded group',
      );
      expect(
        find.descendant(
          of: find.byKey(UsersListView.groupRowKey(server.group1Id)),
          matching: find.text('Renamed folded group'),
        ),
        findsOneWidget,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 35));
    },
  );

  testWidgets(
    'A6: earlier committed rename response arriving after later rename preserves latest title',
    (WidgetTester tester) async {
      server.createdGroup1 = true;
      await pumpHome(tester, size: const Size(375, 812));

      await tester.tap(find.byKey(UsersListView.groupRowKey(server.group1Id)));
      await _settle(tester);

      Future<void> saveName(String name) async {
        await tester.tap(find.byKey(ChatPage.headerProfileKey));
        await _settle(tester);
        await tester.tap(find.text('编辑群资料'));
        await _settle(tester);
        await tester.enterText(find.byType(TextFormField).first, name);
        await tester.tap(find.text('保存群资料'));
        await _settle(tester);
        expect(server.group1Name, name);
        await tester.binding.handlePopRoute();
        await _settle(tester);
      }

      final Completer<void> first = Completer<void>();
      server.holdUpdate = first;
      await saveName('First edit');
      expect(server.holdUpdate, isNull);
      await saveName('Final edit');
      expect(
        tester.widget<Text>(find.byKey(ChatPage.headerNameKey)).data,
        'Final edit',
      );

      first.complete();
      await _settle(tester);
      expect(server.group1Name, 'Final edit');
      expect(
        tester.widget<Text>(find.byKey(ChatPage.headerNameKey)).data,
        'Final edit',
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 35));
    },
  );

  testWidgets(
    'A6: earlier-started rename that commits last on server becomes authoritative title',
    (WidgetTester tester) async {
      server.createdGroup1 = true;
      await pumpHome(tester, size: const Size(375, 812));

      await tester.tap(find.byKey(UsersListView.groupRowKey(server.group1Id)));
      await _settle(tester);

      Future<void> saveName(String name) async {
        await tester.tap(find.byKey(ChatPage.headerProfileKey));
        await _settle(tester);
        await tester.tap(find.text('编辑群资料'));
        await _settle(tester);
        await tester.enterText(find.byType(TextFormField).first, name);
        await tester.tap(find.text('保存群资料'));
        await _settle(tester);
        if (name == 'Final edit') {
          expect(server.group1Name, name);
        }
        await tester.binding.handlePopRoute();
        await _settle(tester);
      }

      final Completer<void> first = Completer<void>();
      server.beforeUpdateCommit = first;
      await saveName('First edit');
      expect(server.beforeUpdateCommit, isNull);
      await saveName('Final edit');
      expect(
        tester.widget<Text>(find.byKey(ChatPage.headerNameKey)).data,
        'Final edit',
      );

      first.complete();
      await _settle(tester);
      expect(server.group1Name, 'First edit');
      expect(
        tester.widget<Text>(find.byKey(ChatPage.headerNameKey)).data,
        'First edit',
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 35));
    },
  );

  testWidgets(
    'A6: second client update observed via findGroup before delayed write response preserves latest title',
    (WidgetTester tester) async {
      server.createdGroup1 = true;
      await pumpHome(tester, size: const Size(375, 812));

      await tester.tap(find.byKey(UsersListView.groupRowKey(server.group1Id)));
      await _settle(tester);

      final Completer<void> first = Completer<void>();
      server.holdUpdate = first;
      await tester.tap(find.byKey(ChatPage.headerProfileKey));
      await _settle(tester);
      await tester.tap(find.text('编辑群资料'));
      await _settle(tester);
      await tester.enterText(find.byType(TextFormField).first, 'First edit');
      await tester.tap(find.text('保存群资料'));
      await _settle(tester);
      expect(server.holdUpdate, isNull);
      expect(server.group1Name, 'First edit');
      await tester.binding.handlePopRoute();
      await _settle(tester);

      final GroupApiClient otherClient = GroupApiClient(
        baseUri: server.baseUri,
        transport: HttpTransport(factory: () => HttpClient()),
      );
      await tester.runAsync(
        () => otherClient.updateGroup(
          token: session.identity!.token,
          conversation: ConversationRef.group(server.group1Id),
          name: 'Final edit',
        ),
      );
      expect(server.group1Name, 'Final edit');

      await tester.tap(find.byKey(ChatPage.headerProfileKey));
      await _settle(tester);
      expect(find.text('Final edit'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await _settle(tester);
      expect(
        tester.widget<Text>(find.byKey(ChatPage.headerNameKey)).data,
        'Final edit',
      );

      first.complete();
      await _settle(tester);
      expect(server.group1Name, 'Final edit');
      expect(
        tester.widget<Text>(find.byKey(ChatPage.headerNameKey)).data,
        'Final edit',
      );

      await tester.binding.handlePopRoute();
      await _settle(tester);
      expect(
        find.descendant(
          of: find.byKey(UsersListView.groupRowKey(server.group1Id)),
          matching: find.text('Final edit'),
        ),
        findsOneWidget,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 35));
    },
  );

  testWidgets(
    'A6: earlier-started findGroup reading newer second-client edit before stale write response preserves latest title',
    (WidgetTester tester) async {
      server.createdGroup1 = true;
      await pumpHome(tester, size: const Size(375, 812));

      await tester.tap(find.byKey(UsersListView.groupRowKey(server.group1Id)));
      await _settle(tester);

      await tester.tap(find.byKey(ChatPage.headerProfileKey));
      await _settle(tester);
      await tester.binding.handlePopRoute();
      await _settle(tester);

      final Completer<void> first = Completer<void>();
      final Completer<void> gate = Completer<void>();
      server.beforeRead = gate;
      server.holdUpdate = first;
      await tester.tap(find.byKey(ChatPage.headerProfileKey));
      await _settle(tester);
      expect(server.beforeRead, isNull);
      await tester.tap(find.text('编辑群资料'));
      await _settle(tester);
      await tester.enterText(find.byType(TextFormField).first, 'First edit');
      await tester.tap(find.text('保存群资料'));
      await _settle(tester);
      expect(server.holdUpdate, isNull);
      expect(server.group1Name, 'First edit');
      await tester.binding.handlePopRoute();
      await _settle(tester);

      final GroupApiClient otherClient = GroupApiClient(
        baseUri: server.baseUri,
        transport: HttpTransport(factory: () => HttpClient()),
      );
      await tester.runAsync(
        () => otherClient.updateGroup(
          token: session.identity!.token,
          conversation: ConversationRef.group(server.group1Id),
          name: 'Final edit',
        ),
      );
      expect(server.group1Name, 'Final edit');

      gate.complete();
      await _settle(tester);
      expect(
        tester.widget<Text>(find.byKey(ChatPage.headerNameKey)).data,
        'Final edit',
      );

      first.complete();
      await _settle(tester);
      expect(server.group1Name, 'Final edit');
      expect(
        tester.widget<Text>(find.byKey(ChatPage.headerNameKey)).data,
        'Final edit',
      );

      await tester.binding.handlePopRoute();
      await _settle(tester);
      expect(
        find.descendant(
          of: find.byKey(UsersListView.groupRowKey(server.group1Id)),
          matching: find.text('Final edit'),
        ),
        findsOneWidget,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 35));
    },
  );

  testWidgets(
    'A6: two overlapping profile queries preserve the most recently observed title',
    (WidgetTester tester) async {
      server.createdGroup1 = true;
      await pumpHome(tester, size: const Size(375, 812));

      await tester.tap(find.byKey(UsersListView.groupRowKey(server.group1Id)));
      await _settle(tester);

      Future<void> openThenClose() async {
        await tester.tap(find.byKey(ChatPage.headerProfileKey));
        await _settle(tester);
        await tester.binding.handlePopRoute();
        await _settle(tester);
      }

      final Completer<void> first = Completer<void>();
      server.beforeRead = first;
      await openThenClose();
      expect(server.beforeRead, isNull);

      final Completer<void> second = Completer<void>();
      server.holdFind = second;
      await openThenClose();
      expect(server.holdFind, isNull);

      final GroupApiClient otherClient = GroupApiClient(
        baseUri: server.baseUri,
        transport: HttpTransport(factory: () => HttpClient()),
      );
      await tester.runAsync(
        () => otherClient.updateGroup(
          token: session.identity!.token,
          conversation: ConversationRef.group(server.group1Id),
          name: 'Final edit',
        ),
      );
      expect(server.group1Name, 'Final edit');

      first.complete();
      await _settle(tester);
      expect(
        tester.widget<Text>(find.byKey(ChatPage.headerNameKey)).data,
        'Final edit',
      );

      second.complete();
      await _settle(tester);
      expect(server.group1Name, 'Final edit');
      expect(
        tester.widget<Text>(find.byKey(ChatPage.headerNameKey)).data,
        'Final edit',
      );

      await tester.binding.handlePopRoute();
      await _settle(tester);
      expect(
        find.descendant(
          of: find.byKey(UsersListView.groupRowKey(server.group1Id)),
          matching: find.text('Final edit'),
        ),
        findsOneWidget,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 35));
    },
  );
}
