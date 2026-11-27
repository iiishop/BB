import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../app.dart';
import '../../models/auth_models.dart';
import '../../models/profile_models.dart';
import '../../services/profile_service.dart';
import '../widgets/profile_avatar.dart';
import 'profile_panel.dart';

/// Content shared by person and group details. The surrounding presentation is
/// ProfilePanelFrame; it deliberately has no Space cover or author timeline.
class ProfileDetails extends StatelessWidget {
  const ProfileDetails({
    super.key,
    required this.title,
    required this.name,
    required this.numberLabel,
    required this.number,
    required this.description,
    this.avatar,
    this.children = const <Widget>[],
  });

  final String title;
  final String name;
  final String numberLabel;
  final String number;
  final String description;
  final Uint8List? avatar;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Material(
    color: AppColors.paper,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AppBar(
          title: Text(title),
          leading: CloseButton(onPressed: () => Navigator.of(context).pop()),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            children: <Widget>[
              Align(
                alignment: Alignment.centerLeft,
                child: ProfileAvatar(
                  bytes: avatar,
                  size: 80,
                  semanticLabel: '$title头像',
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              Text(name, style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: AppSpacing.sm),
              SelectableText(
                '$numberLabel $number',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: AppSpacing.lg),
              Text(description.isEmpty ? '暂无介绍' : description),
              for (final Widget child in children) ...<Widget>[
                const SizedBox(height: AppSpacing.md),
                child,
              ],
            ],
          ),
        ),
      ],
    ),
  );
}

Future<void> openPersonProfile(
  BuildContext context, {
  required String account,
  required ProfileGateway gateway,
}) => openProfileSurface<void>(
  context,
  label: '个人资料',
  builder: (_) => PersonProfilePanel(account: account, gateway: gateway),
);

/// Read-only peer profile; never invokes the signed-in user's edit controls.
class PersonProfilePanel extends StatefulWidget {
  const PersonProfilePanel({
    super.key,
    required this.account,
    required this.gateway,
  });
  final String account;
  final ProfileGateway gateway;

  @override
  State<PersonProfilePanel> createState() => _PersonProfilePanelState();
}

class _PersonProfilePanelState extends State<PersonProfilePanel> {
  late Future<({Profile profile, Uint8List avatar})> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  @override
  void didUpdateWidget(covariant PersonProfilePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.account != widget.account ||
        oldWidget.gateway != widget.gateway) {
      _future = _load();
    }
  }

  Future<({Profile profile, Uint8List avatar})> _load() async {
    final Profile profile = await widget.gateway.loadProfile(
      account: widget.account,
    );
    if (profile.account != widget.account) {
      throw const FormatException('profile account mismatch');
    }
    final AvatarImage avatar = await widget.gateway.loadAvatar(
      account: widget.account,
    );
    return (profile: profile, avatar: avatar.bytes);
  }

  @override
  Widget build(BuildContext context) =>
      FutureBuilder<({Profile profile, Uint8List avatar})>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.hasData &&
              snapshot.connectionState == ConnectionState.done) {
            final data = snapshot.data!;
            return ProfileDetails(
              title: '个人资料',
              name: data.profile.username,
              numberLabel: 'BB号',
              number: data.profile.account,
              description: data.profile.signature ?? '',
              avatar: data.avatar,
            );
          }
          return Material(
            color: AppColors.paper,
            child: Column(
              children: <Widget>[
                AppBar(title: const Text('个人资料'), leading: const CloseButton()),
                Expanded(
                  child: snapshot.hasError
                      ? Center(
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.all(AppSpacing.lg),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                Text(
                                  snapshot.error is AuthFailure
                                      ? (snapshot.error! as AuthFailure).message
                                      : '资料加载失败，请重试',
                                ),
                                TextButton(
                                  onPressed: () =>
                                      setState(() => _future = _load()),
                                  child: const Text('重试'),
                                ),
                              ],
                            ),
                          ),
                        )
                      : const Center(child: CircularProgressIndicator()),
                ),
              ],
            ),
          );
        },
      );
}
