import 'dart:async';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/space_models.dart';
import 'package:bb_client/ui/space/space_controller.dart';
import 'package:bb_client/ui/space/space_detail_controller.dart';
import 'package:bb_client/ui/space/space_local_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_space_gateway.dart';
import 'support/space_fixtures.dart';

SpaceController controllerFor(
  FakeSpaceGateway gateway, {
  SpaceLocalStore? store,
}) {
  final SpaceController controller = SpaceController(
    gateway: gateway,
    store: store ?? SpaceLocalStore(scopeKey: gateway.scopeKey),
    autoPoll: false,
    pollInterval: null,
  );
  addTearDown(controller.dispose);
  return controller;
}

void main() {
  test(
    'background refresh reports new posts without moving the list',
    () async {
      final FakeSpaceGateway gateway = FakeSpaceGateway();
      final SpacePost old = spacePost(postId: 'post-old', text: '旧说说');
      final SpacePost fresh = spacePost(postId: 'post-new', text: '新说说');
      gateway.postPages[''] = spacePagePost(<SpacePost>[old]);
      final SpaceController controller = controllerFor(gateway);
      await controller.start();
      expect(controller.posts.map((SpacePost p) => p.postId), <String>[
        'post-old',
      ]);

      gateway.postPages[''] = spacePagePost(<SpacePost>[fresh, old]);
      await controller.refresh(explicit: false);

      expect(controller.hasUnseenNewPosts, isTrue);
      expect(controller.pendingNewPosts, 1);
      expect(controller.posts.single.postId, 'post-old');

      controller.applyPendingPosts();
      expect(controller.posts.map((SpacePost p) => p.postId), <String>[
        'post-new',
        'post-old',
      ]);
      expect(controller.hasUnseenNewPosts, isFalse);
    },
  );

  test('pagination deduplicates a repeated page', () async {
    final FakeSpaceGateway gateway = FakeSpaceGateway();
    final SpacePost one = spacePost(postId: 'post-1');
    final SpacePost two = spacePost(postId: 'post-2');
    gateway.postPages[''] = spacePagePost(
      <SpacePost>[one],
      nextCursor: 'c1',
      hasMore: true,
    );
    gateway.postPages['c1'] = spacePagePost(<SpacePost>[two, one]);
    final SpaceController controller = controllerFor(gateway);
    await controller.start();
    await controller.loadMore();
    expect(controller.posts.map((SpacePost p) => p.postId), <String>[
      'post-1',
      'post-2',
    ]);
  });

  test(
    'detail stack keeps local reference history and one visit per active open',
    () async {
      final FakeSpaceGateway gateway = FakeSpaceGateway();
      for (final String id in <String>['A', 'B', 'C']) {
        gateway.posts[id] = spacePost(postId: id, text: 'post $id');
      }
      final SpaceController controller = controllerFor(gateway);
      gateway.postPages[''] = spacePagePost(<SpacePost>[gateway.posts['C']!]);
      await controller.start();

      await controller.openPost('C');
      await controller.openReference('B');
      await controller.openReference('A');
      expect(controller.detailHistory, <String>['C', 'B', 'A']);
      expect(gateway.getPostCalls.map((e) => e.postId), <String>[
        'C',
        'B',
        'A',
      ]);

      controller.backDetail();
      expect(controller.detailHistory, <String>['C', 'B']);
      expect(controller.selectedPostId, 'B');
      controller.backDetail();
      expect(controller.selectedPostId, 'C');
      controller.backDetail();
      expect(controller.detailOpen, isFalse);

      // A new active open gets a new visit ID; retries never do.
      await controller.openPost('C');
      final String? visit = gateway.getPostCalls.last.visitId;
      expect(visit, isNotNull);
      expect(gateway.getPostCalls.length, 4);
    },
  );

  test(
    'post.deleted event scrubs cached references in other loaded posts',
    () async {
      final FakeSpaceGateway gateway = FakeSpaceGateway();
      final SpacePost source = spacePost(
        postId: 'post-1',
        text: 'deleted secret',
      );
      final SpacePost repost = spacePost(
        postId: 'post-2',
        text: 'repost text',
        reference: SpaceReference(
          postId: 'post-1',
          deleted: false,
          author: source.author,
          text: 'deleted secret',
          image: null,
        ),
      );
      gateway.posts['post-1'] = source;
      gateway.posts['post-2'] = repost;
      gateway.postPages[''] = spacePagePost(<SpacePost>[source, repost]);
      gateway.overviewResult = spaceOverview(latestEventId: 1);
      final SpaceController controller = controllerFor(gateway);
      await controller.start();

      gateway.eventPages.add(
        spaceEventPage(<SpaceEvent>[
          spaceEvent(eventId: 2, type: 'post.deleted', postId: 'post-1'),
        ]),
      );
      await controller.pollEventsOnce();

      expect(controller.posts.any((SpacePost p) => p.postId == 'post-1'),
          isFalse);
      final SpacePost cached = controller.posts.singleWhere(
        (SpacePost p) => p.postId == 'post-2',
      );
      expect(cached.reference!.deleted, isTrue);
      expect(cached.reference!.text, isNull);
      expect(cached.reference!.author, isNull);
    },
  );

  test(
    'stale refresh response cannot resurrect a deleted post or reference',
    () async {
      final FakeSpaceGateway gateway = FakeSpaceGateway();
      final SpacePost source = spacePost(
        postId: 'post-1',
        text: 'source secret',
      );
      final SpacePost repost = spacePost(
        postId: 'post-2',
        text: 'repost',
        reference: SpaceReference(
          postId: 'post-1',
          deleted: false,
          author: source.author,
          text: 'source secret',
          image: null,
        ),
      );
      gateway.posts['post-1'] = source;
      gateway.posts['post-2'] = repost;
      gateway.postPages[''] = spacePagePost(<SpacePost>[source, repost]);
      gateway.overviewResult = spaceOverview(latestEventId: 1);
      final SpaceController controller = controllerFor(gateway);
      await controller.start();

      gateway.holdListPosts = true;
      gateway.listPostsCaptured = Completer<void>();
      gateway.listPostsGate = Completer<void>();
      final Future<void> refreshing = controller.refresh();
      await gateway.listPostsCaptured!.future;
      gateway.eventPages.add(
        spaceEventPage(<SpaceEvent>[
          spaceEvent(eventId: 2, type: 'post.deleted', postId: 'post-1'),
        ]),
      );
      await controller.pollEventsOnce();
      gateway.listPostsGate!.complete();
      await refreshing;

      expect(
        controller.posts.any((SpacePost p) => p.postId == 'post-1'),
        isFalse,
      );
      expect(
        controller.posts
            .singleWhere((SpacePost p) => p.postId == 'post-2')
            .reference!
            .text,
        isNull,
      );
    },
  );

  test(
    'stale detail response keeps a deleted reference invalidated',
    () async {
      final FakeSpaceGateway gateway = FakeSpaceGateway();
      final SpacePost source = spacePost(
        postId: 'post-1',
        text: 'source secret',
      );
      final SpacePost repost = spacePost(
        postId: 'post-2',
        text: 'repost',
        reference: SpaceReference(
          postId: 'post-1',
          deleted: false,
          author: source.author,
          text: 'source secret',
          image: null,
        ),
      );
      gateway.posts['post-2'] = repost;
      final Set<String> tombstones = <String>{};
      final SpaceDetailController detail = SpaceDetailController(
        gateway: gateway,
        store: SpaceLocalStore(scopeKey: gateway.scopeKey),
        postId: 'post-2',
        visitId: 'visit-1',
        isTombstoned: (String id) => tombstones.contains(id),
      );
      addTearDown(detail.dispose);
      await detail.load();
      expect(detail.post!.reference!.text, 'source secret');

      tombstones.add('post-1');
      await detail.refreshFacts();
      expect(detail.post!.reference!.deleted, isTrue);
      expect(detail.post!.reference!.text, isNull);
    },
  );

  test(
    'feed like rollback cannot restore a deletion event',
    () async {
      final FakeSpaceGateway gateway = FakeSpaceGateway();
      final SpacePost source = spacePost(
        postId: 'post-1',
        text: 'deleted source secret',
      );
      final SpacePost repost = spacePost(
        postId: 'post-2',
        text: 'repost',
        reference: SpaceReference(
          postId: 'post-1',
          deleted: false,
          author: source.author,
          text: 'deleted source secret',
          image: null,
        ),
      );
      gateway.posts['post-1'] = source;
      gateway.posts['post-2'] = repost;
      gateway.postPages[''] = spacePagePost(<SpacePost>[source, repost]);
      gateway.overviewResult = spaceOverview(latestEventId: 1);
      final SpaceController controller = controllerFor(gateway);
      await controller.start();

      gateway.setLikeCaptured = Completer<void>();
      gateway.setLikeGate = Completer<void>();
      gateway.failSetLikeAfterGate = true;
      final SpacePost target = controller.posts.singleWhere(
        (SpacePost p) => p.postId == 'post-2',
      );
      final Future<void> liking = controller.togglePostLike(target);
      await gateway.setLikeCaptured!.future;
      gateway.eventPages.add(
        spaceEventPage(<SpaceEvent>[
          spaceEvent(eventId: 2, type: 'post.deleted', postId: 'post-1'),
        ]),
      );
      await controller.pollEventsOnce();
      expect(
        controller.posts
            .singleWhere((SpacePost p) => p.postId == 'post-2')
            .reference!
            .text,
        isNull,
      );
      gateway.setLikeGate!.complete();
      await liking;

      // The failure rollback may revert the like fields but must not put the
      // pre-deletion object (and its reference text) back.
      final SpacePost after = controller.posts.singleWhere(
        (SpacePost p) => p.postId == 'post-2',
      );
      expect(after.reference!.text, isNull);
      expect(after.reference!.deleted, isTrue);
      expect(after.liked, repost.liked);
    },
  );

  test(
    'detail like rollback cannot restore a deleted reference',
    () async {
      final FakeSpaceGateway gateway = FakeSpaceGateway();
      final SpacePost source = spacePost(
        postId: 'post-1',
        text: 'deleted source secret',
      );
      final SpacePost repost = spacePost(
        postId: 'post-2',
        text: 'repost',
        reference: SpaceReference(
          postId: 'post-1',
          deleted: false,
          author: source.author,
          text: 'deleted source secret',
          image: null,
        ),
      );
      gateway.posts['post-2'] = repost;
      final Set<String> tombstones = <String>{};
      final SpaceDetailController detail = SpaceDetailController(
        gateway: gateway,
        store: SpaceLocalStore(scopeKey: gateway.scopeKey),
        postId: 'post-2',
        visitId: 'visit-1',
        isTombstoned: (String id) => tombstones.contains(id),
      );
      addTearDown(detail.dispose);
      await detail.load();

      gateway.setLikeCaptured = Completer<void>();
      gateway.setLikeGate = Completer<void>();
      gateway.failSetLikeAfterGate = true;
      final Future<bool> liking = detail.toggleLike();
      await gateway.setLikeCaptured!.future;
      tombstones.add('post-1');
      detail.onReferenceDeletedEvent('post-1');
      expect(detail.post!.reference!.text, isNull);
      gateway.setLikeGate!.complete();
      await liking;

      expect(detail.post!.reference!.deleted, isTrue);
      expect(detail.post!.reference!.text, isNull);
    },
  );

  test(
    'comment deletion scrubs feed previews and notification snippets',
    () async {
      final FakeSpaceGateway gateway = FakeSpaceGateway();
      final SpaceComment root = spaceComment(
        commentId: 'comment-1',
        postId: 'post-1',
        text: 'deleted comment secret',
      );
      final SpaceComment child = spaceComment(
        commentId: 'comment-2',
        postId: 'post-1',
        rootId: 'comment-1',
        replyToId: 'comment-1',
        text: 'surviving child',
      );
      final SpacePost post = spacePost(
        postId: 'post-1',
        previewComments: <SpaceBranch>[
          spaceBranch(root: root, replies: <SpaceComment>[child]),
        ],
      );
      gateway.posts['post-1'] = post;
      gateway.postPages[''] = spacePagePost(<SpacePost>[post]);
      gateway.notificationPage = spacePageNotification(<SpaceNotification>[
        spaceNotification(
          notificationId: 'n1',
          kind: 'comment',
          postId: 'post-1',
          commentId: 'comment-1',
          snippet: 'deleted comment secret',
        ),
      ]);
      gateway.overviewResult = spaceOverview(latestEventId: 1);
      final SpaceController controller = controllerFor(gateway);
      await controller.start();
      await controller.loadNotifications(reset: true);
      expect(
        controller.posts.single.previewComments.single.root.text,
        'deleted comment secret',
      );
      expect(controller.notifications.single.snippet, 'deleted comment secret');

      gateway.eventPages.add(
        spaceEventPage(<SpaceEvent>[
          spaceEvent(
            eventId: 2,
            type: 'comment.deleted',
            postId: 'post-1',
            commentId: 'comment-1',
          ),
        ]),
      );
      await controller.pollEventsOnce();

      final SpaceBranch preview =
          controller.posts.single.previewComments.single;
      expect(preview.root.text, isNull);
      expect(preview.root.deleted, isTrue);
      expect(preview.replies.single.commentId, 'comment-2');
      expect(preview.replies.single.text, 'surviving child');
      expect(controller.notifications.single.snippet, isNull);

      // A stale notification page must not put the body back either.
      await controller.loadNotifications(reset: true);
      expect(controller.notifications.single.snippet, isNull);
    },
  );

  test(
    'late reply page cannot revive a deleted comment',
    () async {
      final FakeSpaceGateway gateway = FakeSpaceGateway();
      final SpaceComment root = spaceComment(
        commentId: 'root',
        postId: 'post-1',
        text: 'root',
      );
      final SpaceComment reply = spaceComment(
        commentId: 'reply',
        postId: 'post-1',
        rootId: 'root',
        replyToId: 'root',
        text: 'deleted reply secret',
      );
      final SpaceComment child = spaceComment(
        commentId: 'child',
        postId: 'post-1',
        rootId: 'root',
        replyToId: 'reply',
        text: 'surviving child',
      );
      final SpacePost post = spacePost(
        postId: 'post-1',
        previewComments: <SpaceBranch>[
          spaceBranch(
            root: root,
            replies: <SpaceComment>[reply, child],
          ),
        ],
      );
      gateway.posts['post-1'] = post;
      gateway.postPages[''] = spacePagePost(<SpacePost>[post]);
      gateway.commentPages['post-1||'] = spacePageComment(
        <SpaceComment>[root],
      );
      gateway.commentPages['post-1|root|'] = spacePageComment(
        <SpaceComment>[reply, child],
      );
      gateway.overviewResult = spaceOverview(latestEventId: 1);
      final SpaceController controller = controllerFor(gateway);
      await controller.start();
      final SpaceDetailController detail = (await controller.openPost(
        'post-1',
      ))!;

      gateway.holdReplies = true;
      gateway.repliesCaptured = Completer<void>();
      gateway.repliesGate = Completer<void>();
      final Future<void> expanding = detail.expandReplies('root');
      await gateway.repliesCaptured!.future;
      gateway.eventPages.add(
        spaceEventPage(<SpaceEvent>[
          spaceEvent(
            eventId: 2,
            type: 'comment.deleted',
            postId: 'post-1',
            commentId: 'reply',
          ),
        ]),
      );
      await controller.pollEventsOnce();
      expect(
        detail.replies['root']!
            .singleWhere((SpaceComment c) => c.commentId == 'reply')
            .text,
        isNull,
      );
      gateway.repliesGate!.complete();
      await expanding;

      final List<SpaceComment> replies = detail.replies['root']!;
      expect(
        replies.singleWhere((SpaceComment c) => c.commentId == 'reply').text,
        isNull,
      );
      expect(
        replies.singleWhere((SpaceComment c) => c.commentId == 'child').text,
        'surviving child',
      );
    },
  );

  test(
    'comment deletion marks notifications unavailable, not only snippet-less',
    () async {
      final FakeSpaceGateway gateway = FakeSpaceGateway();
      gateway.posts['post-1'] = spacePost(postId: 'post-1');
      gateway.postPages[''] = spacePagePost(
        <SpacePost>[gateway.posts['post-1']!],
      );
      gateway.notificationPage = spacePageNotification(<SpaceNotification>[
        spaceNotification(
          notificationId: 'n1',
          kind: 'comment',
          postId: 'post-1',
          commentId: 'comment-1',
          targetPostId: 'post-1',
          snippet: 'deleted comment secret',
        ),
      ]);
      gateway.overviewResult = spaceOverview(latestEventId: 1);
      final SpaceController controller = controllerFor(gateway);
      await controller.start();
      await controller.loadNotifications(reset: true);

      gateway.holdNotifications = true;
      gateway.notificationsCaptured = Completer<void>();
      gateway.notificationsGate = Completer<void>();
      final Future<void> loading = controller.loadNotifications(reset: true);
      await gateway.notificationsCaptured!.future;
      gateway.eventPages.add(
        spaceEventPage(<SpaceEvent>[
          spaceEvent(
            eventId: 2,
            type: 'comment.deleted',
            postId: 'post-1',
            commentId: 'comment-1',
          ),
        ]),
      );
      await controller.pollEventsOnce();
      SpaceNotification notice = controller.notifications.single;
      expect(notice.snippet, isNull);
      expect(notice.accessible, isFalse);
      expect(notice.deleted, isTrue);

      gateway.notificationsGate!.complete();
      await loading;
      notice = controller.notifications.single;
      expect(notice.snippet, isNull);
      expect(notice.accessible, isFalse);
      expect(notice.deleted, isTrue);
    },
  );

  test(
    'post deletion marks its notifications deleted, including late pages',
    () async {
      final FakeSpaceGateway gateway = FakeSpaceGateway();
      final SpacePost post = spacePost(postId: 'post-1', text: 'post secret');
      gateway.posts['post-1'] = post;
      gateway.postPages[''] = spacePagePost(<SpacePost>[post]);
      gateway.notificationPage = spacePageNotification(<SpaceNotification>[
        spaceNotification(
          notificationId: 'n1',
          kind: 'comment',
          postId: 'post-1',
          commentId: 'comment-1',
          targetPostId: 'post-1',
          snippet: 'comment secret',
        ),
      ]);
      gateway.overviewResult = spaceOverview(latestEventId: 1);
      final SpaceController controller = controllerFor(gateway);
      await controller.start();
      await controller.loadNotifications(reset: true);

      gateway.holdNotifications = true;
      gateway.notificationsCaptured = Completer<void>();
      gateway.notificationsGate = Completer<void>();
      final Future<void> loading = controller.loadNotifications(reset: true);
      await gateway.notificationsCaptured!.future;
      gateway.eventPages.add(
        spaceEventPage(<SpaceEvent>[
          spaceEvent(eventId: 2, type: 'post.deleted', postId: 'post-1'),
        ]),
      );
      await controller.pollEventsOnce();
      SpaceNotification notice = controller.notifications.single;
      expect(notice.snippet, isNull);
      expect(notice.accessible, isFalse);
      expect(notice.deleted, isTrue);

      gateway.notificationsGate!.complete();
      await loading;
      notice = controller.notifications.single;
      expect(notice.snippet, isNull);
      expect(notice.accessible, isFalse);
      expect(notice.deleted, isTrue);
    },
  );

  test(
    'deleting a repost source keeps the surviving repost notification usable',
    () async {
      final FakeSpaceGateway gateway = FakeSpaceGateway();
      final SpacePost source = spacePost(postId: 'post-1', text: 'source');
      final SpacePost repost = spacePost(postId: 'post-2', text: 'surviving');
      gateway.posts['post-1'] = source;
      gateway.posts['post-2'] = repost;
      gateway.postPages[''] = spacePagePost(<SpacePost>[source, repost]);
      gateway.notificationPage = spacePageNotification(<SpaceNotification>[
        spaceNotification(
          notificationId: 'n1',
          kind: 'repost',
          postId: 'post-1',
          targetPostId: 'post-2',
          snippet: 'surviving repost',
        ),
      ]);
      gateway.overviewResult = spaceOverview(latestEventId: 1);
      final SpaceController controller = controllerFor(gateway);
      await controller.start();
      await controller.loadNotifications(reset: true);

      gateway.eventPages.add(
        spaceEventPage(<SpaceEvent>[
          spaceEvent(eventId: 2, type: 'post.deleted', postId: 'post-1'),
        ]),
      );
      await controller.pollEventsOnce();

      final SpaceNotification notice = controller.notifications.single;
      expect(notice.accessible, isTrue);
      expect(notice.deleted, isFalse);
      expect(notice.snippet, 'surviving repost');
    },
  );

  test('local delete invalidates its owned image caches', () async {
    final FakeSpaceGateway gateway = FakeSpaceGateway();
    final SpacePost deleted = spacePost(
      postId: 'post-1',
      images: <SpaceImage>[spaceImage(imageId: 'img-1')],
    );
    final SpacePost live = spacePost(
      postId: 'post-2',
      images: <SpaceImage>[spaceImage(imageId: 'img-2')],
    );
    gateway.posts['post-1'] = deleted;
    gateway.posts['post-2'] = live;
    gateway.postPages[''] = spacePagePost(<SpacePost>[deleted, live]);
    gateway.overviewResult = spaceOverview(latestEventId: 1);
    final SpaceController controller = controllerFor(gateway);
    await controller.start();
    await controller.images.load('img-1', variant: 'original');
    await controller.images.load('img-1');
    await controller.images.load('img-2', variant: 'original');
    expect(controller.images.cached('img-1', variant: 'original'), isNotNull);

    expect(
      await controller.deletePost(
        controller.posts.singleWhere(
          (SpacePost p) => p.postId == 'post-1',
        ),
      ),
      isTrue,
    );

    expect(controller.images.cached('img-1', variant: 'original'), isNull);
    expect(controller.images.cached('img-1'), isNull);
    expect(controller.images.cached('img-2', variant: 'original'), isNotNull);
  });

  test(
    'deleting a post opened outside the feed invalidates its image cache',
    () async {
      final FakeSpaceGateway gateway = FakeSpaceGateway();
      final SpacePost old = spacePost(
        postId: 'old',
        images: <SpaceImage>[spaceImage(imageId: 'img-old')],
      );
      final SpacePost live = spacePost(
        postId: 'live',
        images: <SpaceImage>[spaceImage(imageId: 'img-live')],
      );
      gateway.posts['old'] = old;
      gateway.posts['live'] = live;
      gateway.postPages[''] = spacePagePost(<SpacePost>[live]);
      gateway.overviewResult = spaceOverview(latestEventId: 1);
      final SpaceController controller = controllerFor(gateway);
      await controller.start();
      final SpaceDetailController detail = (await controller.openPost(
        'old',
      ))!;
      await controller.images.load('img-old', variant: 'original');
      await controller.images.load('img-live', variant: 'original');

      gateway.eventPages.add(
        spaceEventPage(<SpaceEvent>[
          spaceEvent(eventId: 2, type: 'post.deleted', postId: 'old'),
        ]),
      );
      await controller.pollEventsOnce();

      expect(controller.images.cached('img-old', variant: 'original'), isNull);
      expect(detail.deleted, isTrue);
      expect(
        controller.images.cached('img-live', variant: 'original'),
        isNotNull,
      );
    },
  );

  test('detail local delete invalidates its owned images', () async {
    final FakeSpaceGateway gateway = FakeSpaceGateway();
    final SpacePost old = spacePost(
      postId: 'old',
      images: <SpaceImage>[spaceImage(imageId: 'img-old')],
    );
    gateway.posts['old'] = old;
    gateway.postPages[''] = spacePagePost(<SpacePost>[]);
    gateway.overviewResult = spaceOverview(latestEventId: 1);
    final SpaceController controller = controllerFor(gateway);
    await controller.start();
    final SpaceDetailController detail = (await controller.openPost('old'))!;
    await controller.images.load('img-old', variant: 'original');
    expect(controller.images.cached('img-old', variant: 'original'), isNotNull);

    expect(await detail.deletePost(), isTrue);

    expect(controller.images.cached('img-old', variant: 'original'), isNull);
  });

  test(
    'post.deleted event removes the post and invalidates its images',
    () async {
      final FakeSpaceGateway gateway = FakeSpaceGateway();
      final SpacePost post = spacePost(
        postId: 'post-1',
        images: <SpaceImage>[spaceImage(imageId: 'img-a')],
      );
      gateway.posts['post-1'] = post;
      gateway.postPages[''] = spacePagePost(<SpacePost>[post]);
      gateway.overviewResult = spaceOverview(latestEventId: 1);
      final SpaceController controller = controllerFor(gateway);
      await controller.start();
      await controller.images.load('img-a');

      gateway.eventPages.add(
        spaceEventPage(<SpaceEvent>[
          spaceEvent(eventId: 2, type: 'post.deleted', postId: 'post-1'),
        ]),
      );
      await controller.pollEventsOnce();

      expect(controller.posts, isEmpty);
      expect(controller.images.cached('img-a'), isNull);
      expect(controller.detailOpen, isFalse);
    },
  );

  test('duplicate events are applied once and the cursor advances', () async {
    final FakeSpaceGateway gateway = FakeSpaceGateway();
    final SpacePost post = spacePost(postId: 'post-1');
    gateway.posts['post-1'] = post;
    gateway.postPages[''] = spacePagePost(<SpacePost>[post]);
    gateway.overviewResult = spaceOverview(latestEventId: 1);
    final SpaceController controller = controllerFor(gateway);
    await controller.start();
    await controller.openPost('post-1');
    final int commentsBefore = gateway.calls
        .where((String c) => c == 'get_post')
        .length;

    gateway.eventPages.add(
      spaceEventPage(<SpaceEvent>[
        spaceEvent(eventId: 2, type: 'post.changed', postId: 'post-1'),
        spaceEvent(eventId: 2, type: 'post.changed', postId: 'post-1'),
      ]),
    );
    await controller.pollEventsOnce();
    await Future<void>.delayed(Duration.zero);
    expect(
      gateway.calls.where((String c) => c == 'get_post').length,
      commentsBefore + 1,
    );
  });

  test(
    'notification acknowledgement only covers the observed version',
    () async {
      final FakeSpaceGateway gateway = FakeSpaceGateway();
      final SpacePost post = spacePost(postId: 'post-1');
      gateway.posts['post-1'] = post;
      gateway.postPages[''] = spacePagePost(<SpacePost>[post]);
      final SpaceNotification old = spaceNotification(
        notificationId: 'n1',
        kind: 'like',
        version: 2,
        actorCount: 2,
        unread: true,
      );
      final SpaceNotification newer = spaceNotification(
        notificationId: 'n1',
        kind: 'like',
        version: 3,
        actorCount: 3,
        unread: true,
      );
      gateway.notificationPage = spacePageNotification(<SpaceNotification>[
        old,
      ]);
      final SpaceController controller = controllerFor(gateway);
      await controller.start();
      controller.showNotifications();
      await Future<void>.delayed(Duration.zero);
      expect(controller.notifications.single.version, 2);

      // A third person likes between render and acknowledgement.
      controller.notifications[0] = newer;
      await controller.ackNotification(old);
      expect(gateway.ackCalls.single.single.version, 2);
      expect(controller.notifications.single.unread, isTrue);

      await controller.ackNotification(controller.notifications.single);
      expect(gateway.ackCalls.last.single.version, 3);
    },
  );

  test(
    'opening a notification focuses an unloaded comment and acknowledges it',
    () async {
      final FakeSpaceGateway gateway = FakeSpaceGateway();
      final SpacePost post = spacePost(postId: 'post-1', commentCount: 1);
      gateway.posts['post-1'] = post;
      gateway.postPages[''] = spacePagePost(<SpacePost>[post]);
      final SpaceComment root = spaceComment(
        commentId: 'root-1',
        postId: 'post-1',
        text: '顶格评论',
        author: spaceAuthor(account: spacePeerAccount, username: 'bob'),
      );
      final SpaceComment deep = spaceComment(
        commentId: 'deep-1',
        postId: 'post-1',
        rootId: 'root-1',
        replyToId: 'root-1',
        replyToAuthor: root.author,
        text: '深层回复',
        author: spaceAuthor(account: spaceThirdAccount, username: 'carol'),
      );
      // The root page does not contain the branch the notification points at.
      gateway.commentPages['post-1||'] = spacePageComment(
        const <SpaceComment>[],
      );
      gateway.contexts['deep-1'] = spaceContext(
        postId: 'post-1',
        root: root,
        target: deep,
        parent: root,
        nearby: <SpaceComment>[deep],
      );
      final SpaceNotification notification = spaceNotification(
        notificationId: 'n-deep',
        kind: 'reply',
        postId: 'post-1',
        targetPostId: 'post-1',
        commentId: 'deep-1',
        version: 4,
        snippet: '深层回复',
      );
      gateway.notificationPage = spacePageNotification(<SpaceNotification>[
        notification,
      ]);
      final SpaceController controller = controllerFor(gateway);
      await controller.start();
      controller.showNotifications();
      await Future<void>.delayed(Duration.zero);

      await controller.openNotification(notification);

      expect(controller.section, SpaceSection.notifications);
      expect(controller.detail?.highlightedCommentId, 'deep-1');
      expect(
        controller.detail?.replies['root-1']!.map(
          (SpaceComment c) => c.commentId,
        ),
        contains('deep-1'),
      );
      expect(gateway.ackCalls.single.single.version, 4);
    },
  );

  test('resizing never creates a second visit', () async {
    final FakeSpaceGateway gateway = FakeSpaceGateway();
    final SpacePost post = spacePost(postId: 'post-1');
    gateway.posts['post-1'] = post;
    gateway.postPages[''] = spacePagePost(<SpacePost>[post]);
    final SpaceController controller = controllerFor(gateway);
    await controller.start();
    await controller.openPost('post-1');
    final String? visit = gateway.getPostCalls.last.visitId;
    expect(visit, isNotNull);
    // A retry within the same visit reuses the ID.
    await controller.detail!.load();
    expect(gateway.getPostCalls.last.visitId, visit);
    expect(gateway.getPostCalls.length, 2);
  });

  test(
    'reconnect replays deletions, clears cached bytes and keeps drafts',
    () async {
      final FakeSpaceGateway gateway = FakeSpaceGateway();
      final SpacePost post = spacePost(
        postId: 'post-1',
        images: <SpaceImage>[spaceImage(imageId: 'img-a')],
      );
      gateway.posts['post-1'] = post;
      gateway.postPages[''] = spacePagePost(<SpacePost>[post]);
      gateway.overviewResult = spaceOverview(latestEventId: 1);
      final SpaceLocalStore store = SpaceLocalStore(scopeKey: gateway.scopeKey);
      store.saveDraft(
        'draft-local',
        const SpaceDraftBuffer(text: '还没发出去', imageIds: <String>[]),
      );
      final SpaceController controller = controllerFor(gateway, store: store);
      await controller.start();
      await controller.images.load('img-a');

      gateway.failNext('list_posts', upstreamUnavailable);
      await controller.refresh(explicit: true);
      expect(controller.offline, isTrue);
      expect(controller.posts.single.postId, 'post-1');

      gateway.eventPages.add(
        spaceEventPage(<SpaceEvent>[
          spaceEvent(eventId: 2, type: 'post.deleted', postId: 'post-1'),
        ], nextEventId: 2),
      );
      gateway.postPages[''] = spacePagePost(const <SpacePost>[]);
      await controller.refresh(explicit: true);
      expect(controller.offline, isFalse);
      expect(controller.posts, isEmpty);
      expect(controller.images.cached('img-a'), isNull);
      expect(store.draft('draft-local')!.text, '还没发出去');
    },
  );

  test('offline state is distinct from an empty feed', () async {
    final FakeSpaceGateway gateway = FakeSpaceGateway();
    gateway.failNext('list_posts', upstreamUnavailable);
    final SpaceController controller = controllerFor(gateway);
    await controller.start();
    expect(controller.offline, isTrue);
    expect(controller.phase, SpacePhase.error);
    expect(controller.feedError, isNotNull);
    expect(controller.posts, isEmpty);
  });

  test('local buffers never cross account or server scopes', () {
    final SpaceLocalStore one = SpaceLocalStore(scopeKey: 'http://a|1');
    final SpaceLocalStore two = SpaceLocalStore(scopeKey: 'http://a|2');
    one.saveDraft(
      'draft-1',
      const SpaceDraftBuffer(text: '甲', imageIds: <String>[]),
    );
    expect(two.draft('draft-1'), isNull);
    expect(one.draft('draft-1')!.text, '甲');
  });
}
