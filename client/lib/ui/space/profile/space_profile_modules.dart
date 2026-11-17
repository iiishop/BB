import 'package:flutter/widgets.dart';

import '../../../models/space_models.dart';
import '../space_image_viewer.dart';
import 'space_profile_controller.dart';
import 'space_profile_posts_module.dart';

/// How one host (Space feed, Profile panel) may act on a post shown inside the
/// home page. Every callback is optional: a host that cannot open the shared
/// detail stack yet passes null and the page renders the same cards read-only
/// instead of inventing a second detail view.
class SpaceProfileActions {
  const SpaceProfileActions({
    this.openPost,
    this.openReference,
    this.toggleLike,
    this.openComments,
    this.repost,
    this.openImage,
    this.deletePost,
  });

  final void Function(SpacePost post)? openPost;
  final void Function(SpacePost post)? openReference;
  final void Function(SpacePost post)? toggleLike;
  final void Function(SpacePost post)? openComments;
  final void Function(SpacePost post)? repost;
  final void Function(SpacePost post, int index)? openImage;
  final void Function(SpacePost post)? deletePost;
}

/// State a registered home-page module may read.
///
/// The container owns identity, layout and module order. A module owns only its
/// own rows, pagination and scroll position, so a new module can be registered
/// without touching the posts query or its state machine.
class SpaceProfileModuleScope {
  const SpaceProfileModuleScope({
    required this.controller,
    required this.scrollController,
    required this.images,
    required this.actions,
  });

  final SpaceProfileController controller;
  final ScrollController scrollController;
  final SpaceImageLoader images;
  final SpaceProfileActions? actions;
}

/// One registered content module on a user home page.
///
/// The builder is called inside an [Expanded], so it receives the remaining
/// vertical space; multiple modules share it equally in [order].
class SpaceProfileModule {
  const SpaceProfileModule({
    required this.id,
    required this.title,
    required this.builder,
    this.order = 0,
  });

  final String id;
  final String title;
  final int order;
  final Widget Function(BuildContext context, SpaceProfileModuleScope scope)
  builder;
}

/// App-internal, opt-in module registry.
///
/// This is not a dynamic plugin loader: modules are compiled widgets registered
/// at startup (or in a test) by id.
class SpaceProfileModuleRegistry {
  SpaceProfileModuleRegistry([
    Iterable<SpaceProfileModule> modules = const <SpaceProfileModule>[],
  ]) {
    for (final SpaceProfileModule module in modules) {
      register(module);
    }
  }

  /// The shipped composition: only the posts module exists in this version.
  factory SpaceProfileModuleRegistry.standard() =>
      SpaceProfileModuleRegistry(<SpaceProfileModule>[spacePostsModule()]);

  static const String postsModuleId = 'space.posts';

  final Map<String, SpaceProfileModule> _modules =
      <String, SpaceProfileModule>{};

  void register(SpaceProfileModule module) {
    if (_modules.containsKey(module.id)) {
      throw StateError('duplicate Space profile module id: ${module.id}');
    }
    _modules[module.id] = module;
  }

  bool unregister(String id) => _modules.remove(id) != null;

  bool contains(String id) => _modules.containsKey(id);

  SpaceProfileModule? byId(String id) => _modules[id];

  List<SpaceProfileModule> get ordered {
    final List<SpaceProfileModule> list = _modules.values.toList();
    list.sort((SpaceProfileModule a, SpaceProfileModule b) {
      final int byOrder = a.order.compareTo(b.order);
      return byOrder != 0 ? byOrder : a.id.compareTo(b.id);
    });
    return list;
  }

  bool get isEmpty => _modules.isEmpty;

  int get length => _modules.length;
}
