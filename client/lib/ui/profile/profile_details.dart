import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../app.dart';
import '../../models/auth_models.dart';
import '../../models/profile_models.dart';
import '../../services/profile_service.dart';
import '../widgets/profile_avatar.dart';
import 'profile_artwork.dart';
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
    this.showCover = false,
    this.coverBytes,
    this.coverMimeType,
    this.children = const <Widget>[],
  });

  final String title;
  final String name;
  final String numberLabel;
  final String number;
  final String description;
  final Uint8List? avatar;
  final bool showCover;
  final Uint8List? coverBytes;
  final String? coverMimeType;
  final List<Widget> children;

  static const Key closeButtonKey = Key('profile-details-close');

  @override
  Widget build(BuildContext context) {
    final List<Widget> bodyItems = <Widget>[
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
    ];

    if (!showCover) {
      return Material(
        color: AppColors.paper,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            AppBar(
              title: Text(title),
              leading: CloseButton(
                key: closeButtonKey,
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(AppSpacing.lg),
                children: bodyItems,
              ),
            ),
          ],
        ),
      );
    }

    return Material(
      color: AppColors.paper,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final double coverHeight = profileCoverHeight(
            Size(constraints.maxWidth, constraints.maxHeight),
          );
          return ListView(
            padding: EdgeInsets.zero,
            children: <Widget>[
              ProfileSeaCover(
                height: coverHeight,
                imageBytes: coverBytes,
                imageMimeType: coverMimeType,
                backBar: Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                  child: Row(
                    children: <Widget>[
                      DecoratedBox(
                        decoration: const BoxDecoration(
                          color: Color(0x3D0B1020),
                          shape: BoxShape.circle,
                        ),
                        child: CloseButton(
                          key: closeButtonKey,
                          color: AppColors.surface,
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Text(
                          title,
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(
                                color: AppColors.surface,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.2,
                              ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: bodyItems,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
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
  int _profileGeneration = 0;
  int _coverGeneration = 0;
  Profile? _profile;
  Uint8List? _avatar;
  CoverImage? _cover;
  bool _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load(notifyStart: false));
  }

  @override
  void didUpdateWidget(covariant PersonProfilePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.account != widget.account ||
        oldWidget.gateway != widget.gateway) {
      _profileGeneration += 1;
      _coverGeneration += 1;
      _profile = null;
      _avatar = null;
      _cover = null;
      _loading = true;
      _error = null;
      unawaited(_load(notifyStart: false));
    }
  }

  Future<void> _load({required bool notifyStart}) async {
    final String targetAccount = widget.account;
    final ProfileGateway gateway = widget.gateway;
    final int generation = ++_profileGeneration;
    if (notifyStart && mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final Profile profile = await gateway.loadProfile(account: targetAccount);
      if (!mounted ||
          generation != _profileGeneration ||
          targetAccount != widget.account ||
          gateway != widget.gateway) {
        return;
      }
      if (profile.account != targetAccount) {
        throw const FormatException('profile account mismatch');
      }
      final AvatarImage avatar = await gateway.loadAvatar(
        account: targetAccount,
      );
      if (!mounted ||
          generation != _profileGeneration ||
          targetAccount != widget.account ||
          gateway != widget.gateway) {
        return;
      }
      if (avatar.account != targetAccount) {
        throw const FormatException('avatar account mismatch');
      }
      setState(() {
        _profile = profile;
        _avatar = avatar.bytes;
        _loading = false;
        _error = null;
      });
      unawaited(_loadCover(targetAccount: targetAccount, gateway: gateway));
    } catch (error) {
      if (!mounted ||
          generation != _profileGeneration ||
          targetAccount != widget.account ||
          gateway != widget.gateway) {
        return;
      }
      setState(() {
        _loading = false;
        _error = error;
      });
    }
  }

  Future<void> _loadCover({
    required String targetAccount,
    required ProfileGateway gateway,
  }) async {
    final int generation = ++_coverGeneration;
    try {
      final CoverImage cover = await gateway.loadCover(account: targetAccount);
      if (!mounted ||
          generation != _coverGeneration ||
          targetAccount != widget.account ||
          gateway != widget.gateway ||
          cover.account != targetAccount) {
        return;
      }
      setState(() => _cover = cover);
    } catch (_) {
      // Cover reads are supplementary: a read failure keeps the packaged
      // default sea-wave cover so the peer profile stays usable.
    }
  }

  @override
  Widget build(BuildContext context) {
    final Profile? profile = _profile;
    if (!_loading &&
        _error == null &&
        profile != null &&
        profile.account == widget.account) {
      final CoverImage? cover =
          (_cover != null && _cover!.account == widget.account) ? _cover : null;
      return ProfileDetails(
        title: '个人资料',
        name: profile.username,
        numberLabel: 'BB号',
        number: profile.account,
        description: profile.signature ?? '',
        avatar: _avatar,
        showCover: true,
        coverBytes: cover?.bytes,
        coverMimeType: cover?.mimeType,
      );
    }
    return Material(
      color: AppColors.paper,
      child: Column(
        children: <Widget>[
          AppBar(title: const Text('个人资料'), leading: const CloseButton()),
          Expanded(
            child: _error != null
                ? Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(AppSpacing.lg),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Text(
                            _error is AuthFailure
                                ? (_error! as AuthFailure).message
                                : '资料加载失败，请重试',
                          ),
                          TextButton(
                            onPressed: () =>
                                unawaited(_load(notifyStart: true)),
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
  }
}
