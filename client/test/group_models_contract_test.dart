import 'package:bb_client/models/chat_media.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/models/group_models.dart';
import 'package:bb_client/services/chat_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ConversationRef', () {
    test('normalizes direct pair and validates group hex IDs', () {
      final ConversationRef a = ConversationRef.direct('10000002', '10000001');
      final ConversationRef b = ConversationRef.direct('10000001', '10000002');
      expect(a, equals(b));
      expect(a.id, 'dm:10000001:10000002');
      expect(a.isDirect, isTrue);
      expect(a.directPeerFor('10000001'), '10000002');
      expect(a.directPeerFor('10000003'), isNull);

      final String groupId = 'group:${'a1b2c3d4' * 4}';
      final ConversationRef group = ConversationRef.group(groupId);
      expect(group.isGroup, isTrue);
      expect(group.id, groupId);
      expect(ConversationRef.parseId(groupId), equals(group));

      expect(
        () => ConversationRef.direct('10000001', '10000001'),
        throwsFormatException,
      );
      expect(
        () => ConversationRef.fromJson(<String, dynamic>{
          'type': 'direct',
          'id': 'dm:10000002:10000001',
        }),
        throwsFormatException,
      );
      expect(
        () => ConversationRef.fromJson(<String, dynamic>{
          'type': 'group',
          'id': '10000001',
        }),
        throwsFormatException,
      );
    });
  });

  group('ChatMessage & SharedConversation', () {
    final String groupId = 'group:${'0f1e2d3c' * 4}';

    test('parses group message, system entries, and visible wrapper', () {
      final ChatMessage groupMsg = ChatMessage.fromJson(<String, dynamic>{
        'id': 'msg-g-1',
        'position': 4,
        'created_at': '2026-11-27T12:00:00Z',
        'sender_account': '10000002',
        'sender_username': 'Bob',
        'conversation': <String, dynamic>{'type': 'group', 'id': groupId},
        'kind': 'body',
        'content': <Map<String, dynamic>>[
          <String, dynamic>{'type': 'text', 'text': 'hi group'},
          <String, dynamic>{'type': 'image', 'media_id': 'img-9'},
        ],
        'attachment': null,
      });
      expect(groupMsg.isGroup, isTrue);
      expect(groupMsg.senderUsername, 'Bob');
      expect(groupMsg.targetAccount, '');
      expect(groupMsg.isMine('10000001'), isFalse);
      expect(groupMsg.isMine('10000002'), isTrue);
      groupMsg.validateReader(
        '10000001',
        conversationRef: ConversationRef.group(groupId),
      );

      final ChatMessage joined = ChatMessage.fromJson(<String, dynamic>{
        'id': 'sys-1',
        'position': 5,
        'created_at': '2026-11-27T12:01:00Z',
        'kind': 'system',
        'conversation': <String, dynamic>{'type': 'group', 'id': groupId},
        'system': <String, dynamic>{
          'type': 'member.joined',
          'account': '10000003',
          'username': 'Carol',
        },
        'text': 'Carol 加入了群聊',
      });
      expect(joined.isSystem, isTrue);
      expect(joined.system, isA<MemberJoinedSystemEvent>());
      expect(joined.systemText, 'Carol 加入了群聊');
      expect(joined.isMine('10000003'), isFalse);
      expect(messageToJson(joined)['kind'], 'system');

      final ChatMessage renamed = ChatMessage.fromJson(<String, dynamic>{
        'id': 'sys-2',
        'position': 6,
        'created_at': '2026-11-27T12:02:00Z',
        'kind': 'system',
        'conversation': <String, dynamic>{'type': 'group', 'id': groupId},
        'system': <String, dynamic>{
          'type': 'group.renamed',
          'old_name': 'Old',
          'new_name': 'New',
        },
        'text': '群名称从 Old 改为 New',
      });
      expect(renamed.system, isA<GroupRenamedSystemEvent>());

      final List<ChatMediaItem> media = buildConversationMedia(
        messages: <ChatMessage>[joined, groupMsg, renamed],
        selfAccount: '10000001',
        selfName: '我',
        peerName: 'fallback',
      );
      expect(media, hasLength(1));
      expect(media.single.senderLabel, 'Bob');
      expect(media.single.conversation?.id, groupId);

      final VisibleMessage visible = VisibleMessage.fromJson(<String, dynamic>{
        'message': messageToJson(groupMsg),
        'presentation': <String, dynamic>{
          'receipt_id': 'r1',
          'content_digest': 'd1',
        },
        'blocks': <Map<String, dynamic>>[
          <String, dynamic>{'type': 'text', 'text': 'hi group'},
        ],
      });
      expect(visible.message.conversation?.id, groupId);
      expect(visible.presentation?.peerAccount, groupId);
    });

    test(
      'parses SharedConversationPage including empty newly created group',
      () {
        final SharedConversationPage page = SharedConversationPage.fromJson(
          <String, dynamic>{
            'items': <Map<String, dynamic>>[
              <String, dynamic>{
                'conversation': <String, dynamic>{
                  'type': 'group',
                  'id': groupId,
                },
                'group_number': '10000001',
                'display_name': 'Solo Group',
                'last_message': null,
                'last_activity_at': '2026-11-27T10:00:00Z',
                'latest_position': 0,
                'history_through': 0,
                'membership_revision': 1,
                'avatar_url': '/chat/groups/10000001/avatar.png',
                'avatar_version': 'v1',
              },
              <String, dynamic>{
                'conversation': <String, dynamic>{
                  'type': 'direct',
                  'id': 'dm:10000001:10000002',
                },
                'peer_account': '10000002',
                'display_name': 'Bob',
                'last_message': <String, dynamic>{
                  'id': 'm1',
                  'position': 1,
                  'created_at': '2026-11-27T10:01:00Z',
                  'sender_account': '10000002',
                  'target_account': '10000001',
                  'kind': 'body',
                  'content': <Map<String, dynamic>>[
                    <String, dynamic>{'type': 'text', 'text': 'hey'},
                  ],
                  'attachment': null,
                },
                'last_activity_at': '2026-11-27T10:01:00Z',
                'latest_position': 1,
              },
            ],
            'next_cursor': null,
          },
        );
        expect(page.items, hasLength(2));
        expect(page.items.first, isA<GroupConversationItem>());
        expect(page.items.first.lastMessage, isNull);
        expect(page.items.first.latestPosition, 0);
        expect(page.items.last, isA<DirectConversationItem>());
      },
    );

    test('parses group message and access_changed server events', () {
      final ServerEventPage events = ServerEventPage.fromJson(<String, dynamic>{
        'items': <Map<String, dynamic>>[
          <String, dynamic>{
            'version': 1,
            'event_id': 10,
            'type': 'message.available',
            'occurred_at': '2026-11-27T10:00:00Z',
            'message_id': 'msg-1',
            'conversation': <String, dynamic>{'type': 'group', 'id': groupId},
            'membership_revision': 1,
            'position': 3,
          },
          <String, dynamic>{
            'version': 1,
            'event_id': 11,
            'type': 'conversation.access_changed',
            'occurred_at': '2026-11-27T10:02:00Z',
            'conversation': <String, dynamic>{'type': 'group', 'id': groupId},
            'active': false,
            'membership_revision': 2,
            'history_through': 3,
          },
        ],
        'next_event_id': 11,
        'has_more': false,
      });
      expect(events.items, hasLength(2));
      expect(events.items[0].isGroupMessage, isTrue);
      expect(events.items[0].peerAccount, '');
      expect(events.items[1].isAccessChanged, isTrue);
      expect(events.items[1].active, isFalse);
      expect(events.items[1].membershipRevision, 2);
      expect(events.items[1].historyThrough, 3);
    });
  });

  group('Group & Notice DTOs', () {
    final String groupId = 'group:${'deadbeef' * 4}';

    test('parses GroupProfile for owner, non-member, and dissolved', () {
      final GroupProfile stranger = GroupProfile.fromJson(<String, dynamic>{
        'conversation': <String, dynamic>{'type': 'group', 'id': groupId},
        'group_number': '10000001',
        'name': 'Public Group',
        'description': 'Hello',
        'avatar_url': '/chat/groups/10000001/avatar.png',
        'avatar_version': 'etag-1',
        'status': 'active',
        'role': null,
        'can_invite': false,
        'allow_member_invites': null,
      });
      expect(stranger.role, isNull);
      expect(stranger.canApply, isTrue);
      expect(stranger.canEdit, isFalse);

      final GroupProfile dissolved = GroupProfile.fromJson(<String, dynamic>{
        'conversation': <String, dynamic>{'type': 'group', 'id': groupId},
        'group_number': '10000001',
        'name': 'Public Group',
        'description': 'Hello',
        'avatar_url': '/chat/groups/10000001/avatar.png',
        'avatar_version': 'etag-1',
        'status': 'dissolved',
        'role': 'owner',
        'can_invite': false,
        'allow_member_invites': false,
      });
      expect(dissolved.isDissolved, isTrue);
      expect(dissolved.canEdit, isFalse);
      expect(dissolved.canDissolve, isFalse);
    });

    test('parses NoticePage and Notice actions/links', () {
      final NoticePage page = NoticePage.fromJson(<String, dynamic>{
        'items': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'notice-1',
            'type': 'group_invite',
            'title': '群聊邀请',
            'text': 'Alice 邀请你加入群聊',
            'created_at': '2026-11-27T11:00:00Z',
            'read': false,
            'state': 'pending',
            'actions': <Map<String, dynamic>>[
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
            'link': <String, dynamic>{'type': 'group', 'id': '10000001'},
          },
          <String, dynamic>{
            'id': 'notice-2',
            'type': 'group_dissolved',
            'title': '群已解散',
            'text': '群主解散了群聊',
            'created_at': '2026-11-27T11:05:00Z',
            'read': true,
            'state': 'informational',
            'actions': <Map<String, dynamic>>[],
            'link': <String, dynamic>{'type': 'group', 'id': '10000001'},
          },
        ],
        'next_cursor': 'notice-2',
        'unread_count': 1,
        'pending_count': 1,
      });
      expect(page.items, hasLength(2));
      expect(page.items.first.hasAvailableActions, isTrue);
      expect(page.items.first.link?.isGroup, isTrue);
      expect(page.items.last.hasAvailableActions, isFalse);
      expect(page.unreadCount, 1);
      expect(page.pendingCount, 1);
    });
  });
}
