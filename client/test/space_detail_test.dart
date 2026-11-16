import 'dart:async';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/space_models.dart';
import 'package:bb_client/ui/space/space_detail_view.dart';
import 'package:bb_client/ui/space/space_image_viewer.dart';
import 'package:bb_client/ui/space/space_local_store.dart';
import 'package:bb_client/ui/space/space_page.dart';
import 'package:bb_client/ui/space/space_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_space_gateway.dart';
import 'support/space_fixtures.dart';
import 'support/space_test_harness.dart';

FakeSpaceGateway gatewayWithPost(SpacePost post) {
  final FakeSpaceGateway gateway = FakeSpaceGateway();
  gateway.posts[post.postId] = post;
  gateway.postPages[''] = spacePagePost(<SpacePost>[post]);
  return gateway;
}

Future<void> openDetail(WidgetTester tester, String postId) async {
  await tester.tap(find.byKey(Key('space-post-body-$postId')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('replies use one indent level and keep the real reply target', (
    WidgetTester tester,
  ) async {
    final SpaceAuthor bob = spaceAuthor(
      account: spacePeerAccount,
      username: 'bob',
    );
    final SpaceAuthor carol = spaceAuthor(
      account: spaceThirdAccount,
      username: 'carol',
    );
    final SpaceComment root = spaceComment(
      commentId: 'root-1',
      postId: 'post-1',
      author: bob,
      text: '顶格评论',
      createdAt: '2026-11-15T10:00:00Z',
    );
    final SpaceComment first = spaceComment(
      commentId: 'r-1',
      postId: 'post-1',
      rootId: 'root-1',
      replyToId: 'root-1',
      replyToAuthor: bob,
      author: carol,
      text: '第一层回复',
      createdAt: '2026-11-15T10:01:00Z',
    );
    final SpaceComment deep = spaceComment(
      commentId: 'r-2',
      postId: 'post-1',
      rootId: 'root-1',
      replyToId: 'r-1',
      replyToAuthor: carol,
      author: bob,
      text: '更深回复',
      createdAt: '2026-11-15T10:02:00Z',
    );
    final FakeSpaceGateway gateway = gatewayWithPost(
      spacePost(
        postId: 'post-1',
        text: '有评论的说说',
        commentCount: 3,
        rootCount: 1,
        previewComments: <SpaceBranch>[
          spaceBranch(
            root: root,
            replies: <SpaceComment>[first, deep],
            remainingReplies: 0,
          ),
        ],
      ),
    );
    gateway.commentPages['post-1||'] = spacePageComment(<SpaceComment>[root]);
    gateway.commentPages['post-1|root-1|'] = spacePageComment(<SpaceComment>[
      first,
      deep,
    ]);
    await pumpSpacePage(tester, gateway: gateway);
    await openDetail(tester, 'post-1');

    final double rootX = tester
        .getTopLeft(find.byKey(const Key('space-comment-root-1')))
        .dx;
    final double firstX = tester
        .getTopLeft(find.byKey(const Key('space-comment-r-1')))
        .dx;
    final double deepX = tester
        .getTopLeft(find.byKey(const Key('space-comment-r-2')))
        .dx;
    expect(firstX, rootX + 24);
    expect(deepX, firstX);
    expect(find.textContaining('更深回复'), findsOneWidget);
  });

  testWidgets('deleted comment keeps surviving children and reply identity', (
    WidgetTester tester,
  ) async {
    final SpaceAuthor bob = spaceAuthor(
      account: spacePeerAccount,
      username: 'bob',
    );
    final SpaceAuthor carol = spaceAuthor(
      account: spaceThirdAccount,
      username: 'carol',
    );
    final SpaceComment deletedRoot = spaceComment(
      commentId: 'root-del',
      postId: 'post-1',
      author: bob,
      text: null,
      deleted: true,
    );
    final SpaceComment liveChild = spaceComment(
      commentId: 'child-live',
      postId: 'post-1',
      rootId: 'root-del',
      replyToId: 'root-del',
      replyToAuthor: bob,
      author: carol,
      text: '孩子还活着',
    );
    final FakeSpaceGateway gateway = gatewayWithPost(
      spacePost(
        postId: 'post-1',
        text: '删除评论测试',
        commentCount: 2,
        rootCount: 1,
      ),
    );
    gateway.commentPages['post-1||'] = spacePageComment(<SpaceComment>[
      deletedRoot,
    ]);
    gateway.commentPages['post-1|root-del|'] = spacePageComment(<SpaceComment>[
      liveChild,
    ]);
    await pumpSpacePage(tester, gateway: gateway);
    await openDetail(tester, 'post-1');
    await tester.tap(find.byKey(const Key('space-comment-replies-root-del')));
    await tester.pumpAndSettle();

    expect(find.text('该评论已删除'), findsOneWidget);
    expect(find.text('孩子还活着'), findsOneWidget);
    expect(find.textContaining('carol 回复 bob'), findsOneWidget);
  });

  testWidgets(
    'feed preview shows five roots and three replies with separate counts',
    (WidgetTester tester) async {
      final List<SpaceBranch> branches = <SpaceBranch>[
        for (int i = 0; i < 5; i++)
          spaceBranch(
            root: spaceComment(
              commentId: 'root-$i',
              postId: 'post-1',
              author: spaceAuthor(account: '1000000$i', username: 'user$i'),
              text: '评论 $i',
            ),
            replies: <SpaceComment>[
              for (int j = 0; j < 3; j++)
                spaceComment(
                  commentId: 'root-$i-reply-$j',
                  postId: 'post-1',
                  rootId: 'root-$i',
                  replyToId: 'root-$i',
                  replyToAuthor: spaceAuthor(
                    account: '1000000$i',
                    username: 'user$i',
                  ),
                  author: spaceAuthor(
                    account: spaceThirdAccount,
                    username: 'carol',
                  ),
                  text: '回复 $j',
                ),
            ],
            remainingReplies: i == 0 ? 1 : 0,
          ),
      ];
      final FakeSpaceGateway gateway = gatewayWithPost(
        spacePost(
          postId: 'post-1',
          text: '评论预览',
          previewComments: branches,
          remainingRoots: 1,
          rootCount: 6,
          commentCount: 20,
        ),
      );
      await pumpSpacePage(tester, gateway: gateway);

      for (int i = 0; i < 5; i++) {
        expect(find.byKey(Key('space-preview-root-root-$i')), findsOneWidget);
      }
      expect(find.byKey(const Key('space-preview-root-root-5')), findsNothing);
      expect(find.text('还有 1 条回复'), findsOneWidget);
      expect(find.text('还有 1 条评论'), findsOneWidget);
      expect(find.textContaining('评论 4'), findsOneWidget);
    },
  );

  testWidgets('root and reply pagination load on demand', (
    WidgetTester tester,
  ) async {
    final SpaceComment root = spaceComment(
      commentId: 'root-1',
      postId: 'post-1',
      text: '第一条顶格',
    );
    final SpaceComment second = spaceComment(
      commentId: 'root-2',
      postId: 'post-1',
      text: '第二条顶格',
    );
    final SpaceComment reply = spaceComment(
      commentId: 'reply-1',
      postId: 'post-1',
      rootId: 'root-1',
      replyToId: 'root-1',
      replyToAuthor: root.author,
      text: '分页回复',
    );
    final FakeSpaceGateway gateway = gatewayWithPost(
      spacePost(
        postId: 'post-1',
        text: '分页',
        previewComments: <SpaceBranch>[
          spaceBranch(root: root, remainingReplies: 1),
        ],
        remainingRoots: 1,
      ),
    );
    gateway.commentPages['post-1||'] = spacePageComment(
      <SpaceComment>[root],
      nextCursor: 'c2',
      hasMore: true,
    );
    gateway.commentPages['post-1||c2'] = spacePageComment(<SpaceComment>[
      second,
    ]);
    gateway.commentPages['post-1|root-1|'] = spacePageComment(<SpaceComment>[
      reply,
    ]);
    await pumpSpacePage(tester, gateway: gateway);
    await openDetail(tester, 'post-1');
    expect(find.text('第二条顶格'), findsNothing);

    await tester.tap(find.byKey(Key('space-detail-more-replies-root-1')));
    await tester.pumpAndSettle();
    expect(find.text('分页回复'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.byKey(SpaceDetailView.moreRootsKey),
      200,
      scrollable: find
          .descendant(
            of: find.byKey(SpaceDetailView.commentsKey),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(find.byKey(SpaceDetailView.moreRootsKey));
    await tester.pumpAndSettle();
    expect(find.text('第二条顶格'), findsOneWidget);
  });

  testWidgets('like failure reverts and reports the error', (
    WidgetTester tester,
  ) async {
    final FakeSpaceGateway gateway = gatewayWithPost(
      spacePost(postId: 'post-1', text: '点赞测试', likeCount: 1),
    );
    gateway.failNext('set_like', upstreamUnavailable);
    await pumpSpacePage(tester, gateway: gateway);
    await openDetail(tester, 'post-1');
    await tester.tap(find.byKey(SpaceDetailView.likeKey));
    await tester.pumpAndSettle();
    expect(gateway.posts['post-1']!.likeCount, 1);
    expect(find.text('赞'), findsOneWidget);
    expect(find.textContaining('无法连接服务器'), findsWidgets);
  });

  testWidgets('author sees visitor details; a non-author sees the denial', (
    WidgetTester tester,
  ) async {
    final FakeSpaceGateway gateway = gatewayWithPost(
      spacePost(
        postId: 'post-1',
        text: '作者说说',
        viewCount: 3,
        canListVisitors: true,
      ),
    );
    gateway.visitorPages['post-1|'] = spacePageVisitor(<SpaceVisitor>[
      spaceVisitor(
        author: spaceAuthor(account: spacePeerAccount, username: 'bob'),
        count: 2,
      ),
      spaceVisitor(
        author: spaceAuthor(account: spaceThirdAccount, username: 'carol'),
        count: 1,
      ),
    ]);
    await pumpSpacePage(tester, gateway: gateway);
    await openDetail(tester, 'post-1');
    expect(find.text('浏览 3'), findsOneWidget);
    await tester.tap(find.byKey(SpaceDetailView.visitorsKey));
    await tester.pumpAndSettle();
    expect(find.text('访客明细'), findsOneWidget);
    expect(find.text('bob'), findsOneWidget);
    expect(find.textContaining('2 次'), findsOneWidget);
    expect(find.text('carol'), findsOneWidget);

    final FakeSpaceGateway other = gatewayWithPost(
      spacePost(postId: 'post-2', text: '别人的说说', viewCount: 1),
    );
    other.failNext(
      'list_visitors',
      const AuthFailure(status: 403, code: 'forbidden', message: 'forbidden'),
    );
    await pumpSpacePage(
      tester,
      gateway: other,
      pageKey: const Key('other-space'),
    );
    await openDetail(tester, 'post-2');
    await tester.tap(find.byKey(SpaceDetailView.visitorsKey));
    await tester.pumpAndSettle();
    expect(find.text('无法读取访客明细'), findsOneWidget);
    expect(find.text('你没有权限执行这个操作'), findsOneWidget);
  });

  testWidgets('images and comments never add visits or batch read marks', (
    WidgetTester tester,
  ) async {
    final FakeSpaceGateway gateway = gatewayWithPost(
      spacePost(
        postId: 'post-1',
        text: '访问计数',
        images: <SpaceImage>[spaceImage(imageId: 'img-1')],
      ),
    );
    gateway.commentPages['post-1||'] = spacePageComment(const <SpaceComment>[]);
    await pumpSpacePage(tester, gateway: gateway);
    await openDetail(tester, 'post-1');
    expect(gateway.getPostCalls.length, 1);
    expect(gateway.markReadCalls, <List<String>>[
      <String>['post-1'],
    ]);

    await tester.tap(find.byKey(const Key('space-image-img-1')));
    await tester.pumpAndSettle();
    expect(find.byKey(SpaceImageViewer.pagesKey), findsOneWidget);
    await tester.tap(find.byKey(SpaceImageViewer.closeKey));
    await tester.pumpAndSettle();
    expect(gateway.getPostCalls.length, 1);
    expect(gateway.markReadCalls.length, 1);
  });

  testWidgets('form factor change keeps post, reply target, text and visit', (
    WidgetTester tester,
  ) async {
    final SpaceComment root = spaceComment(
      commentId: 'root-1',
      postId: 'post-1',
      text: '回复我',
      author: spaceAuthor(account: spacePeerAccount, username: 'bob'),
    );
    final FakeSpaceGateway gateway = gatewayWithPost(
      spacePost(
        postId: 'post-1',
        text: '折叠前后',
        previewComments: <SpaceBranch>[spaceBranch(root: root)],
      ),
    );
    gateway.commentPages['post-1||'] = spacePageComment(<SpaceComment>[root]);
    final SpaceLocalStore store = SpaceLocalStore(scopeKey: gateway.scopeKey);
    const Key pageKey = Key('fold-space');
    await pumpSpacePage(
      tester,
      gateway: gateway,
      store: store,
      pageKey: pageKey,
      size: spacePhone,
    );
    await openDetail(tester, 'post-1');
    await tester.tap(find.byKey(const Key('space-comment-reply-root-1')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('space-detail-input')),
      '还没发出去的话',
    );
    await tester.pump();
    expect(find.byKey(SpaceDetailView.replyChipKey), findsOneWidget);

    final int visits = gateway.getPostCalls.length;
    await pumpSpacePage(
      tester,
      gateway: gateway,
      store: store,
      pageKey: pageKey,
      size: spaceWide,
      remount: false,
    );
    expect(find.byKey(SpaceDetailView.detailKey), findsOneWidget);
    expect(find.byKey(SpacePage.feedListKey), findsOneWidget);
    expect(find.byKey(SpaceDetailView.replyChipKey), findsOneWidget);
    final TextField field = tester.widget<TextField>(
      find.byKey(const Key('space-detail-input')),
    );
    expect(field.controller!.text, '还没发出去的话');
    expect(gateway.getPostCalls.length, visits);

    // Collapsing back to one pane keeps the same state.
    await pumpSpacePage(
      tester,
      gateway: gateway,
      store: store,
      pageKey: pageKey,
      size: spacePhone,
      remount: false,
    );
    expect(find.byKey(SpaceDetailView.detailKey), findsOneWidget);
    expect(find.byKey(const Key('space-detail-input')), findsOneWidget);
    expect(gateway.getPostCalls.length, visits);
  });

  testWidgets('viewer index survives a resize', (WidgetTester tester) async {
    final FakeSpaceGateway gateway = gatewayWithPost(
      spacePost(
        postId: 'post-1',
        text: '十张图',
        images: <SpaceImage>[
          for (int i = 0; i < 10; i++) spaceImage(imageId: 'img-$i'),
        ],
      ),
    );
    final SpaceLocalStore store = SpaceLocalStore(scopeKey: gateway.scopeKey);
    const Key pageKey = Key('viewer-space');
    await pumpSpacePage(
      tester,
      gateway: gateway,
      store: store,
      pageKey: pageKey,
    );
    await openDetail(tester, 'post-1');
    await tester.tap(find.byKey(const Key('space-image-img-0')));
    await tester.pumpAndSettle();
    expect(find.text('1 / 10'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(find.text('2 / 10'), findsOneWidget);

    await pumpSpacePage(
      tester,
      gateway: gateway,
      store: store,
      pageKey: pageKey,
      size: spaceWide,
      remount: false,
    );
    expect(find.text('2 / 10'), findsOneWidget);
  });

  testWidgets('reference navigation keeps a local back history', (
    WidgetTester tester,
  ) async {
    final FakeSpaceGateway gateway = gatewayWithPost(
      spacePost(
        postId: 'post-c',
        text: 'C 正文',
        reference: spaceReference(
          postId: 'post-b',
          text: 'B 摘要',
          author: spaceAuthor(account: spacePeerAccount, username: 'bob'),
        ),
      ),
    );
    gateway.posts['post-b'] = spacePost(
      postId: 'post-b',
      text: 'B 正文',
      reference: spaceReference(
        postId: 'post-a',
        text: 'A 摘要',
        author: spaceAuthor(account: spaceThirdAccount, username: 'carol'),
      ),
    );
    gateway.posts['post-a'] = spacePost(postId: 'post-a', text: 'A 正文');
    await pumpSpacePage(tester, gateway: gateway);
    await openDetail(tester, 'post-c');
    expect(find.text('C 正文'), findsOneWidget);

    await tester.tap(find.byKey(SpaceReferenceCard.cardKey));
    await tester.pumpAndSettle();
    expect(find.text('B 正文'), findsOneWidget);
    await tester.tap(find.byKey(SpaceReferenceCard.cardKey));
    await tester.pumpAndSettle();
    expect(find.text('A 正文'), findsOneWidget);

    await tester.tap(find.byKey(SpaceDetailView.backKey));
    await tester.pumpAndSettle();
    expect(find.text('B 正文'), findsOneWidget);
    await tester.tap(find.byKey(SpaceDetailView.backKey));
    await tester.pumpAndSettle();
    expect(find.text('C 正文'), findsOneWidget);
    expect(find.byKey(SpaceDetailView.backKey), findsNothing);
    expect(gateway.getPostCalls.map((e) => e.postId), <String>[
      'post-c',
      'post-b',
      'post-a',
    ]);
  });

  testWidgets('author deletion closes detail and removes the feed card', (
    WidgetTester tester,
  ) async {
    final FakeSpaceGateway gateway = gatewayWithPost(
      spacePost(postId: 'post-1', text: '要删的说说', canDelete: true),
    );
    await pumpSpacePage(tester, gateway: gateway);
    await openDetail(tester, 'post-1');
    await tester.tap(find.byKey(SpaceDetailView.deletePostKey));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除').last);
    await tester.pumpAndSettle();
    expect(find.byKey(SpaceDetailView.detailKey), findsNothing);
    expect(find.byKey(const Key('space-post-post-1')), findsNothing);
    expect(gateway.posts.containsKey('post-1'), isFalse);
  });

  testWidgets('deleting a repost keeps the live source image viewer usable', (
    WidgetTester tester,
  ) async {
    final FakeSpaceGateway gateway = FakeSpaceGateway();
    final SpacePost source = spacePost(
      postId: 'source',
      images: <SpaceImage>[spaceImage(imageId: 'img-a')],
    );
    final SpacePost repost = spacePost(
      postId: 'repost',
      text: 'repost',
      reference: spaceReference(
        postId: 'source',
        text: 'source',
        image: spaceImage(imageId: 'img-a'),
      ),
    );
    gateway.posts['source'] = source;
    gateway.posts['repost'] = repost;
    gateway.postPages[''] = spacePagePost(<SpacePost>[source, repost]);
    await pumpSpacePage(
      tester,
      gateway: gateway,
      settle: false,
      autoPoll: true,
      pollInterval: const Duration(milliseconds: 10),
    );
    addTearDown(() async => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    await tester.tap(find.byKey(const Key('space-image-img-a')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final Finder viewerImage = find.descendant(
      of: find.byType(SpaceImageViewer),
      matching: find.byType(Image),
    );
    expect(viewerImage, findsOneWidget);

    gateway.eventPages.add(
      spaceEventPage(<SpaceEvent>[
        spaceEvent(eventId: 2, type: 'post.deleted', postId: 'repost'),
      ]),
    );
    await tester.pump(const Duration(milliseconds: 30));
    await tester.pump();

    expect(gateway.eventPages, isEmpty);
    // The deleted repost's reference image belongs to the live source post.
    expect(viewerImage, findsOneWidget);
  });

  test('late image response cannot refill an invalidated cache', () async {
    final FakeSpaceGateway gateway = FakeSpaceGateway();
    final SpaceImageLoader loader = SpaceImageLoader(gateway);
    gateway.imageCaptured = Completer<void>();
    gateway.imageGate = Completer<void>();
    final Future<Uint8List> loading = loader.load('img-1');
    await gateway.imageCaptured!.future;
    loader.invalidateImage('img-1');
    gateway.imageGate!.complete();

    await expectLater(loading, throwsA(isA<SpaceImageInvalidated>()));
    expect(loader.cached('img-1'), isNull);
    expect(loader.cached('img-1', variant: 'original'), isNull);

    // An unrelated surviving image still loads.
    gateway.imageBytes['img-2'] = spaceTinyPng;
    expect(await loader.load('img-2'), isNotEmpty);
  });

  testWidgets('viewer drops an image invalidated while open', (
    WidgetTester tester,
  ) async {
    final FakeSpaceGateway gateway = FakeSpaceGateway();
    gateway.imageBytes['img-1'] = spaceTinyPng;
    final SpaceImageLoader loader = SpaceImageLoader(gateway);
    final SpaceImage image = spaceImage(imageId: 'img-1');
    await tester.pumpWidget(
      MaterialApp(
        home: SpaceImageViewer(
          images: <SpaceImage>[image],
          initialIndex: 0,
          loader: loader,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);

    loader.invalidateImage('img-1');
    await tester.pumpAndSettle();

    expect(find.byType(Image), findsNothing);
    expect(find.text('原图加载失败'), findsOneWidget);
  });
}
