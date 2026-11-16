import 'package:flutter/material.dart';

import '../../app.dart';
import '../../models/space_models.dart';
import 'space_format.dart';
import 'space_gateway.dart';
import 'space_widgets.dart';

/// Author-only visitor detail. A non-author sees the service-provided denial;
/// the UI never hides the failure as an empty list.
class SpaceVisitorsSheet extends StatefulWidget {
  const SpaceVisitorsSheet({
    super.key,
    required this.load,
    required this.postId,
  });

  final Future<SpacePageVisitor> Function({String? cursor}) load;
  final String postId;

  @override
  State<SpaceVisitorsSheet> createState() => _SpaceVisitorsSheetState();
}

class _SpaceVisitorsSheetState extends State<SpaceVisitorsSheet> {
  final List<SpaceVisitor> _items = <SpaceVisitor>[];
  String? _cursor;
  bool _more = false;
  bool _loading = true;
  String? _error;
  bool _offline = false;

  @override
  void initState() {
    super.initState();
    _run(reset: true);
  }

  Future<void> _run({required bool reset}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final SpacePageVisitor page = await widget.load(
        cursor: reset ? null : _cursor,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        if (reset) {
          _items
            ..clear()
            ..addAll(page.items);
        } else {
          _items.addAll(page.items);
        }
        _cursor = page.nextCursor;
        _more = page.hasMore;
        _loading = false;
      });
    } catch (failure) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = spaceErrorText(failure);
        _offline = isSpaceOffline(failure);
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.62,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Text('访客明细', style: text.titleLarge),
            ),
            Expanded(
              child: _loading && _items.isEmpty
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null && _items.isEmpty
                  ? SpaceStateView(
                      icon: _offline
                          ? Icons.cloud_off_rounded
                          : Icons.lock_outline_rounded,
                      title: '无法读取访客明细',
                      message: _error!,
                      actionLabel: '重试',
                      onAction: () => _run(reset: true),
                    )
                  : _items.isEmpty
                  ? const SpaceStateView(
                      icon: Icons.visibility_outlined,
                      title: '还没有访客',
                      message: '第一次主动打开这条说说的人会出现在这里。',
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.md,
                      ),
                      itemCount: _items.length + (_more ? 1 : 0),
                      itemBuilder: (BuildContext context, int index) {
                        if (index == _items.length) {
                          return TextButton(
                            onPressed: _loading
                                ? null
                                : () => _run(reset: false),
                            child: const Text('加载更多'),
                          );
                        }
                        final SpaceVisitor visitor = _items[index];
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: SpaceAvatar(author: visitor.author),
                          title: Text(visitor.author.username),
                          subtitle: Text(
                            '${visitor.count} 次 · 最近 '
                            '${spaceRelativeTime(visitor.lastVisitedAt)}',
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class SpaceLikesSheet extends StatefulWidget {
  const SpaceLikesSheet({super.key, required this.load});

  final Future<SpacePageAuthor> Function({String? cursor}) load;

  @override
  State<SpaceLikesSheet> createState() => _SpaceLikesSheetState();
}

class _SpaceLikesSheetState extends State<SpaceLikesSheet> {
  final List<SpaceAuthor> _items = <SpaceAuthor>[];
  String? _cursor;
  bool _more = false;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _run(reset: true);
  }

  Future<void> _run({required bool reset}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final SpacePageAuthor page = await widget.load(
        cursor: reset ? null : _cursor,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        if (reset) {
          _items
            ..clear()
            ..addAll(page.items);
        } else {
          _items.addAll(page.items);
        }
        _cursor = page.nextCursor;
        _more = page.hasMore;
        _loading = false;
      });
    } catch (failure) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = spaceErrorText(failure);
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.56,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Text('点赞名单', style: text.titleLarge),
            ),
            Expanded(
              child: _loading && _items.isEmpty
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null && _items.isEmpty
                  ? SpaceStateView(
                      icon: Icons.error_outline_rounded,
                      title: '无法读取点赞名单',
                      message: _error!,
                      actionLabel: '重试',
                      onAction: () => _run(reset: true),
                    )
                  : _items.isEmpty
                  ? const SpaceStateView(
                      icon: Icons.favorite_border_rounded,
                      title: '还没有赞',
                      message: '点赞按有效账号去重，取消后不再显示。',
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.md,
                      ),
                      itemCount: _items.length + (_more ? 1 : 0),
                      itemBuilder: (BuildContext context, int index) {
                        if (index == _items.length) {
                          return TextButton(
                            onPressed: _loading
                                ? null
                                : () => _run(reset: false),
                            child: const Text('加载更多'),
                          );
                        }
                        final SpaceAuthor author = _items[index];
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: SpaceAvatar(author: author),
                          title: Text(author.username),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
