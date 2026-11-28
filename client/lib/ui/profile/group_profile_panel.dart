import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../app.dart';
import 'profile_details.dart';

/// UI visibility only. The service still authorizes every read and mutation.
enum GroupProfileRole { visitor, member, owner }

class GroupProfilePanel extends StatelessWidget {
  const GroupProfilePanel({
    super.key,
    required this.number,
    required this.name,
    required this.description,
    required this.role,
    this.avatar,
    this.dissolved = false,
    this.canInvite = false,
    this.allowMemberInvites = false,
    this.onApply,
    this.onInvite,
    this.onEdit,
    this.onMembers,
    this.onLeave,
    this.onDisband,
    this.onAllowMemberInvitesChanged,
  });

  final String number;
  final String name;
  final String description;
  final Uint8List? avatar;
  final GroupProfileRole role;
  final bool dissolved;
  final bool canInvite;
  final bool allowMemberInvites;
  final VoidCallback? onApply;
  final VoidCallback? onInvite;
  final VoidCallback? onEdit;
  final VoidCallback? onMembers;
  final VoidCallback? onLeave;
  final VoidCallback? onDisband;
  final ValueChanged<bool>? onAllowMemberInvitesChanged;

  @override
  Widget build(BuildContext context) => ProfileDetails(
    title: '群资料',
    name: name,
    numberLabel: '群号',
    number: number,
    description: description,
    avatar: avatar,
    children: <Widget>[
      if (dissolved)
        const Text('该群已解散', style: TextStyle(color: AppColors.inkMuted)),
      if (!dissolved) ...<Widget>[
        if (role == GroupProfileRole.visitor)
          FilledButton(onPressed: onApply, child: const Text('申请加入')),
        if (role != GroupProfileRole.visitor) ...<Widget>[
          OutlinedButton(onPressed: onMembers, child: const Text('查看成员')),
          if (role == GroupProfileRole.owner || canInvite)
            OutlinedButton(onPressed: onInvite, child: const Text('邀请用户')),
          if (role == GroupProfileRole.member)
            TextButton(onPressed: onLeave, child: const Text('退出群聊')),
        ],
        if (role == GroupProfileRole.owner) ...<Widget>[
          OutlinedButton(onPressed: onEdit, child: const Text('编辑群资料')),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('允许所有成员邀请'),
            value: allowMemberInvites,
            onChanged: onAllowMemberInvitesChanged == null
                ? null
                : (value) => onAllowMemberInvitesChanged!(value!),
          ),
          TextButton(
            onPressed: onDisband,
            style: TextButton.styleFrom(foregroundColor: AppColors.danger),
            child: const Text('解散群聊'),
          ),
        ],
      ],
    ],
  );
}

/// Shared creation/edit fields. Avatar selection and submission are host-owned;
/// no UI-generated group number or default-avatar bytes enter the service.
class GroupDetailsForm extends StatefulWidget {
  const GroupDetailsForm({
    super.key,
    required this.onSubmit,
    this.initialName = '',
    this.initialDescription = '',
    this.busy = false,
    this.error,
  });
  final void Function(String name, String? description) onSubmit;
  final String initialName;
  final String initialDescription;
  final bool busy;
  final String? error;

  @override
  State<GroupDetailsForm> createState() => _GroupDetailsFormState();
}

class _GroupDetailsFormState extends State<GroupDetailsForm> {
  final GlobalKey<FormState> _form = GlobalKey<FormState>();
  late final TextEditingController _name = TextEditingController(
    text: widget.initialName,
  );
  late final TextEditingController _description = TextEditingController(
    text: widget.initialDescription,
  );

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Form(
    key: _form,
    child: ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: <Widget>[
        TextFormField(
          controller: _name,
          enabled: !widget.busy,
          decoration: const InputDecoration(labelText: '群名称（必填）'),
          validator: (value) =>
              value == null || value.trim().isEmpty ? '请输入群名称' : null,
        ),
        const SizedBox(height: AppSpacing.md),
        TextFormField(
          controller: _description,
          enabled: !widget.busy,
          decoration: const InputDecoration(labelText: '简介（选填）'),
          minLines: 3,
          maxLines: 6,
        ),
        const SizedBox(height: AppSpacing.lg),
        if (widget.error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.md),
            child: Text(
              widget.error!,
              style: const TextStyle(color: AppColors.danger),
            ),
          ),
        FilledButton(
          onPressed: widget.busy
              ? null
              : () {
                  if (_form.currentState!.validate()) {
                    widget.onSubmit(
                      _name.text.trim(),
                      _description.text.trim().isEmpty
                          ? null
                          : _description.text.trim(),
                    );
                  }
                },
          child: Text(widget.busy ? '正在保存…' : '保存群资料'),
        ),
      ],
    ),
  );
}
