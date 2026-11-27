part of 'chat_v2.dart';

const _identityField = 'expected_identity';
const _conversationField = 'conversation';
const _groupFields = <String, Set<String>>{
  '/v2/groups/create': {
    _identityField, 'operation_id', 'name', 'description', 'invitees', 'avatar',
  },
  '/v2/groups/find': {_identityField, 'group_number'},
  '/v2/groups/update': {
    _identityField, _conversationField, 'name', 'description',
    'allow_member_invites', 'avatar', 'reset_avatar',
  },
  '/v2/directory/list': {_identityField, 'after_account', 'limit'},
  '/v2/groups/members': {
    _identityField, _conversationField, 'after_account', 'limit',
  },
  '/v2/groups/invite': {_identityField, _conversationField, 'accounts'},
  '/v2/groups/apply': {_identityField, _conversationField},
  '/v2/groups/leave': {_identityField, _conversationField},
  '/v2/groups/remove_member': {_identityField, _conversationField, 'account'},
  '/v2/groups/dissolve': {_identityField, _conversationField},
  '/v2/notices/list': {_identityField, 'filter', 'cursor', 'limit'},
  '/v2/notices/mark_read': {_identityField, 'notification_id'},
  '/v2/notices/execute_action': {
    _identityField, 'notification_id', 'action_id',
  },
};

final _groupIdPattern = RegExp(r'^group:[a-f0-9]{32}$');
final _groupAccountPattern = RegExp(r'^[1-9][0-9]{7}$');
final _noticeIdPattern = RegExp(r'^[A-Za-z0-9_-]{1,200}$');

Map<String, dynamic> _groupRef(_Request request) {
  final ref = request.object(_conversationField, {'type', 'id'});
  final id = ref['id'];
  if (ref['type'] != 'group' || id is! String || !_groupIdPattern.hasMatch(id)) {
    throw request._invalid(_conversationField);
  }
  return ref;
}

void _parseGroupRequest(String path, _Request request, _Args args) {
  final fields = _groupFields[path]!;
  final values = args.values;
  if (fields.contains(_conversationField)) {
    values[_conversationField] = _groupRef(request);
  }
  if (fields.contains('limit')) {
    values['limit'] = request.optionalInteger('limit', 1, 100) ?? 50;
  }
  if (fields.contains('after_account')) {
    values['after_account'] = request.contains('after_account')
        ? request.pattern('after_account', RegExp(r'^([1-9][0-9]{7})?$'))
        : '';
  }
  if (fields.contains('notification_id')) {
    values['notification_id'] = request.pattern('notification_id', _noticeIdPattern);
  }
  switch (path) {
    case '/v2/groups/create':
      values['operation_id'] = request.operationId('operation_id');
      values['name'] = _groupText(request, 'name', 1, 80);
      values['description'] = request.contains('description')
          ? _groupText(request, 'description', 0, 500)
          : '';
      values['invitees'] = request.contains('invitees')
          ? _groupAccounts(request, 'invitees', 0)
          : <String>[];
      args.avatar = _groupAvatar(request);
    case '/v2/groups/find':
      values['group_number'] = request.pattern('group_number', _groupAccountPattern);
    case '/v2/groups/update':
      for (final (field, min, max) in [('name', 1, 80), ('description', 0, 500)]) {
        if (request.raw[field] != null) {
          values[field] = _groupText(request, field, min, max);
        }
      }
      if (request.raw['allow_member_invites'] != null) {
        values['allow_member_invites'] = request.boolean('allow_member_invites', false);
      }
      args.avatar = _groupAvatar(request);
      final reset = request.boolean('reset_avatar', false);
      if (reset && args.avatar != null) throw request._invalid('avatar');
      values['reset_avatar'] = reset;
    case '/v2/groups/invite':
      values['accounts'] = _groupAccounts(request, 'accounts', 1);
    case '/v2/groups/remove_member':
      values['account'] = request.account('account');
    case '/v2/notices/list':
      values['filter'] = request.contains('filter')
          ? request.pattern('filter', RegExp(r'^(all|pending)$'))
          : 'all';
      if (request.raw['cursor'] != null) {
        values['cursor'] = request.pattern('cursor', _noticeIdPattern);
      }
    case '/v2/notices/execute_action':
      values['action_id'] = request.pattern('action_id', _noticeIdPattern);
  }
}

String _groupText(_Request request, String field, int min, int max) {
  final value = request.string(field, allowEmpty: true)!.trim();
  final length = value.runes.length;
  if (length < min || length > max) throw request._invalid(field);
  return value;
}

List<String> _groupAccounts(_Request request, String field, int min) {
  final values = request.list(field, min, 100);
  if (values.any((value) => value is! String || !_groupAccountPattern.hasMatch(value))) {
    throw request._invalid(field);
  }
  return values.cast<String>();
}

MediaSource? _groupAvatar(_Request request) {
  if (request.raw['avatar'] == null) return null;
  const sourceKeys = {'base64', 'path', 'url'};
  final value = request.object('avatar', {...sourceKeys, 'mime_type', 'filename'});
  if (value['mime_type'] is! String ||
      value['filename'] is! String ||
      sourceKeys.where((key) => value[key] != null).length != 1 ||
      sourceKeys.any((key) => value[key] != null && value[key] is! String)) {
    throw request._invalid('avatar');
  }
  return MediaSource.fromJson(value);
}

Future<Map<String, dynamic>> _dispatchGroup(
  String path,
  ChatService chat,
  AuthIdentity captured,
  _Args args,
) async {
  final values = args.values;
  final service = chat.groups;
  ConversationRef target() => ConversationRef.fromJson(values[_conversationField],
    requireGroup: true);
  final result = switch (path) {
    '/v2/groups/create' => (await service.createGroup(
      captured: captured,
      operationId: values['operation_id'] as String,
      name: values['name'] as String,
      description: values['description'] as String,
      invitees: values['invitees'] as List<String>,
      avatar: args.avatar,
    )).toJson(),
    '/v2/groups/find' => (await service.findGroup(
      values['group_number'] as String, captured: captured,
    )).toJson(),
    '/v2/groups/update' => (await service.updateGroup(
      captured: captured,
      conversation: target(),
      name: values['name'] as String?,
      description: values['description'] as String?,
      allowMemberInvites: values['allow_member_invites'] as bool?,
      resetAvatar: values['reset_avatar'] as bool,
      avatar: args.avatar,
    )).toJson(),
    '/v2/directory/list' => (await service.listDirectory(
      captured: captured,
      afterAccount: values['after_account'] as String,
      limit: values['limit'] as int,
    )).toJson(),
    '/v2/groups/members' => (await service.listGroupMembers(
      captured: captured,
      conversation: target(),
      afterAccount: values['after_account'] as String,
      limit: values['limit'] as int,
    )).toJson(),
    '/v2/groups/invite' => (await service.inviteToGroup(
      captured: captured,
      conversation: target(),
      accounts: values['accounts'] as List<String>,
    )).toJson(),
    '/v2/groups/apply' => (await service.applyToGroup(
      captured: captured, conversation: target(),
    )).toJson(),
    '/v2/groups/leave' => (await service.leaveGroup(
      captured: captured, conversation: target(),
    )).toJson(),
    '/v2/groups/remove_member' => (await service.removeGroupMember(
      captured: captured, conversation: target(), account: values['account'] as String,
    )).toJson(),
    '/v2/groups/dissolve' => (await service.dissolveGroup(
      captured: captured, conversation: target(),
    )).toJson(),
    '/v2/notices/list' => (await service.listNotices(
      captured: captured,
      filter: values['filter'] == 'pending' ? NoticeFilter.pending : NoticeFilter.all,
      cursor: values['cursor'] as String?,
      limit: values['limit'] as int,
    )).toJson(),
    '/v2/notices/mark_read' => (await service.markNoticeRead(
      values['notification_id'] as String, captured: captured,
    )).toJson(),
    '/v2/notices/execute_action' => (await service.executeNoticeAction(
      captured: captured,
      notificationId: values['notification_id'] as String,
      actionId: values['action_id'] as String,
    )).toJson(),
    _ => throw StateError('Unregistered group route'),
  };
  return result;
}
