import 'dart:async';
import 'dart:typed_data';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/space_models.dart';
import 'package:bb_client/ui/space/space_compose_controller.dart';
import 'package:bb_client/ui/space/space_compose_page.dart';
import 'package:bb_client/ui/space/space_image_viewer.dart';
import 'package:bb_client/ui/space/space_local_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_space_gateway.dart';
import 'support/space_fixtures.dart';

class ComposeHarness {
  ComposeHarness(this.gateway);

  final FakeSpaceGateway gateway;
  late final SpaceLocalStore store = SpaceLocalStore(
    scopeKey: gateway.scopeKey,
  );
  String? popped;
  int opens = 0;

  Future<void> pump(
    WidgetTester tester, {
    String? draftId,
    SpacePost? reference,
    Future<PickedSpaceImage?> Function()? picker,
    SpaceImageLoader? images,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => Center(
              child: TextButton(
                onPressed: () async {
                  opens += 1;
                  popped = await Navigator.of(context).push<String>(
                    MaterialPageRoute<String>(
                      builder: (BuildContext context) => SpaceComposePage(
                        gateway: gateway,
                        store: store,
                        images: images ?? SpaceImageLoader(gateway),
                        draftId: draftId,
                        referenceId: reference?.postId,
                        referencePost: reference,
                        picker: picker,
                      ),
                    ),
                  );
                },
                child: const Text('open-compose'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open-compose'));
    await tester.pumpAndSettle();
  }

  Future<void> type(WidgetTester tester, String text) async {
    await tester.enterText(find.byKey(SpaceComposePage.textKey), text);
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pumpAndSettle();
  }
}

void main() {
  testWidgets('draft autosaves, images reorder and publish returns a post id', (
    WidgetTester tester,
  ) async {
    final FakeSpaceGateway gateway = FakeSpaceGateway();
    final ComposeHarness harness = ComposeHarness(gateway);
    int picks = 0;
    final List<SpaceImage> catalog = <SpaceImage>[];
    await harness.pump(
      tester,
      picker: () async {
        picks += 1;
        final Uint8List bytes = spaceTinyPng;
        return PickedSpaceImage(bytes: bytes, filename: 'p$picks.png');
      },
    );
    expect(find.byKey(SpaceComposePage.composeKey), findsOneWidget);
    expect(find.text('已保存到服务器'), findsOneWidget);
    expect(gateway.drafts, hasLength(1));
    final String draftId = gateway.drafts.keys.single;

    // Empty original drafts cannot be published.
    final FilledButton publish = tester.widget<FilledButton>(
      find.byKey(SpaceComposePage.publishKey),
    );
    expect(publish.onPressed, isNull);

    await harness.type(tester, '今天的第一条说说');
    expect(find.text('已保存到服务器'), findsOneWidget);
    expect(gateway.drafts[draftId]!.text, '今天的第一条说说');

    await tester.tap(find.byKey(SpaceComposePage.addImageKey));
    await tester.pumpAndSettle();
    expect(gateway.drafts[draftId]!.images, hasLength(1));
    final String first = gateway.drafts[draftId]!.images.single.imageId;

    await tester.tap(find.byKey(SpaceComposePage.addImageKey));
    await tester.pumpAndSettle();
    expect(gateway.drafts[draftId]!.images, hasLength(2));
    final String second = gateway.drafts[draftId]!.images.last.imageId;
    catalog.addAll(gateway.drafts[draftId]!.images);

    // Explicit non-drag ordering is available on every platform.
    await tester.tap(find.byKey(const Key('space-compose-down-0')));
    await tester.pumpAndSettle();
    expect(
      gateway.drafts[draftId]!.images.map((SpaceImage i) => i.imageId),
      <String>[second, first],
    );

    final FilledButton enabled = tester.widget<FilledButton>(
      find.byKey(SpaceComposePage.publishKey),
    );
    expect(enabled.onPressed, isNotNull);
    await tester.tap(find.byKey(SpaceComposePage.publishKey));
    await tester.pumpAndSettle();
    expect(harness.popped, isNotNull);
    expect(gateway.posts.containsKey(harness.popped), isTrue);
    expect(gateway.posts[harness.popped]!.text, '今天的第一条说说');
    expect(gateway.drafts, isEmpty);
  });

  testWidgets('version conflict keeps local input instead of overwriting', (
    WidgetTester tester,
  ) async {
    final FakeSpaceGateway gateway = FakeSpaceGateway();
    final ComposeHarness harness = ComposeHarness(gateway);
    await harness.pump(tester);
    final String draftId = gateway.drafts.keys.single;
    // Another client commits a newer version.
    gateway.drafts[draftId] = spaceDraft(
      draftId: draftId,
      version: 2,
      text: '另一端的更新',
    );

    await harness.type(tester, '本机未同步输入');
    expect(find.byKey(SpaceComposePage.conflictKey), findsOneWidget);
    expect(gateway.drafts[draftId]!.text, '另一端的更新');
    final TextField field = tester.widget<TextField>(
      find.byKey(SpaceComposePage.textKey),
    );
    expect(field.controller!.text, '本机未同步输入');

    await tester.tap(find.byKey(SpaceComposePage.reloadServerKey));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(SpaceComposePage.textKey))
          .controller!
          .text,
      '另一端的更新',
    );
    expect(find.text('已保存到服务器'), findsOneWidget);
  });

  test('in-flight save response never marks newer input saved', () async {
    final FakeSpaceGateway gateway = FakeSpaceGateway();
    final SpaceLocalStore store = SpaceLocalStore(scopeKey: gateway.scopeKey);
    final SpaceComposeController controller = SpaceComposeController(
      gateway: gateway,
      store: store,
    );
    addTearDown(controller.dispose);
    await controller.start();

    gateway.updateDraftCommitted = Completer<void>();
    gateway.updateDraftGate = Completer<void>();
    controller.text.text = 'first edit';
    controller.onTextChanged();
    final Future<void> saving = controller.saveNow();
    await gateway.updateDraftCommitted!.future;
    // The user keeps typing before the accepted response returns.
    controller.text.text = 'latest edit';
    controller.onTextChanged();
    gateway.updateDraftGate!.complete();
    await saving;
    // The stale response must not label the newer snapshot saved; the
    // follow-up debounce save persists it.
    await Future<void>.delayed(const Duration(milliseconds: 900));

    expect(controller.phase, DraftSavePhase.saved);
    expect(gateway.drafts[controller.id!]!.text, 'latest edit');
    expect(controller.canPublish, isTrue);
    expect(await controller.publish(), isTrue);
    expect(gateway.posts[controller.publishedPostId!]!.text, 'latest edit');
  });

  test('reopened dirty buffer based on an older version is a conflict', () async {
    final FakeSpaceGateway gateway = FakeSpaceGateway();
    final SpaceOperation created = await gateway.createDraft(
      operationId: 'create',
      text: 'original',
    );
    final String draftId = created.resourceId!;
    await gateway.updateDraft(
      draftId: draftId,
      operationId: 'other-edit',
      expectedVersion: 1,
      text: 'other device edit',
      imageIds: <String>[],
    );
    final SpaceLocalStore store = SpaceLocalStore(scopeKey: gateway.scopeKey)
      ..saveDraft(
        draftId,
        const SpaceDraftBuffer(
          text: 'offline local edit',
          imageIds: <String>[],
          version: 1,
          serverText: 'original',
          dirty: true,
        ),
      );
    final SpaceComposeController controller = SpaceComposeController(
      gateway: gateway,
      store: store,
      draftId: draftId,
    );
    addTearDown(controller.dispose);

    await controller.start();
    await controller.saveNow();

    expect(controller.phase, DraftSavePhase.conflict);
    expect(controller.text.text, 'offline local edit');
    expect(controller.canPublish, isFalse);
    // The other writer's version is never silently replaced by stale input.
    expect(gateway.drafts[draftId]!.text, 'other device edit');
  });

  test('image removed while a save is in flight stays removed', () async {
    final FakeSpaceGateway gateway = FakeSpaceGateway();
    final SpaceOperation created = await gateway.createDraft(
      operationId: 'create',
      text: 'initial',
    );
    final String draftId = created.resourceId!;
    await gateway.addImage(
      draftId: draftId,
      operationId: 'image',
      expectedVersion: 1,
      filename: 'test.png',
      bytes: spaceTinyPng,
    );
    final SpaceComposeController controller = SpaceComposeController(
      gateway: gateway,
      store: SpaceLocalStore(scopeKey: gateway.scopeKey),
      draftId: draftId,
    );
    addTearDown(controller.dispose);
    await controller.start();
    final String imageId = controller.images.single.imageId;

    gateway.updateDraftCommitted = Completer<void>();
    gateway.updateDraftGate = Completer<void>();
    controller.text.text = 'first saved edit';
    controller.onTextChanged();
    final Future<void> saving = controller.saveNow();
    await gateway.updateDraftCommitted!.future;
    await controller.removeImage(imageId);
    expect(controller.images, isEmpty);
    gateway.updateDraftGate!.complete();
    await saving;
    await Future<void>.delayed(const Duration(milliseconds: 900));

    // The older receipt carries the removed image; it must not restore it and
    // the follow-up save must delete it on the server.
    expect(controller.images, isEmpty);
    expect(gateway.drafts[draftId]!.images, isEmpty);
  });

  test('image upload confirmation keeps already-dirty text', () async {
    final FakeSpaceGateway gateway = FakeSpaceGateway();
    final SpaceComposeController controller = SpaceComposeController(
      gateway: gateway,
      store: SpaceLocalStore(scopeKey: gateway.scopeKey),
      picker: () async => PickedSpaceImage(
        bytes: spaceTinyPng,
        filename: 'p.png',
      ),
    );
    addTearDown(controller.dispose);
    await controller.start();
    controller.text.text = 'unsaved before image selection';
    controller.onTextChanged();
    await controller.addImage();

    expect(controller.images, hasLength(1));
    expect(controller.text.text, 'unsaved before image selection');
    await controller.saveNow();
    expect(
      gateway.drafts[controller.id!]!.text,
      'unsaved before image selection',
    );
  });

  test(
    'upload confirmation cannot adopt a newer external writer as baseline',
    () async {
      final FakeSpaceGateway gateway = FakeSpaceGateway();
      final SpaceComposeController controller = SpaceComposeController(
        gateway: gateway,
        store: SpaceLocalStore(scopeKey: gateway.scopeKey),
        picker: () async => PickedSpaceImage(
          bytes: spaceTinyPng,
          filename: 'p.png',
        ),
      );
      addTearDown(controller.dispose);
      await controller.start();
      controller.text.text = 'pending local text';
      controller.onTextChanged();

      gateway.addImageCommitted = Completer<SpaceOperation>();
      gateway.addImageGate = Completer<void>();
      final Future<void> uploading = controller.addImage();
      final SpaceOperation receipt = await gateway.addImageCommitted!.future;
      final String draftId = controller.id!;
      final SpaceDraft afterUpload = await gateway.getDraft(draftId);
      expect(afterUpload.version, receipt.resourceVersion);
      // Another client commits after our upload was accepted but before its
      // receipt reaches the controller.
      await gateway.updateDraft(
        draftId: draftId,
        operationId: 'other-client',
        expectedVersion: afterUpload.version,
        text: 'other client committed',
        imageIds: afterUpload.images.map((SpaceImage i) => i.imageId).toList(),
      );
      gateway.addImageGate!.complete();
      await uploading;
      await Future<void>.delayed(const Duration(milliseconds: 900));

      expect(gateway.drafts[draftId]!.text, 'other client committed');
      expect(controller.text.text, 'pending local text');
      expect(controller.phase, DraftSavePhase.conflict);
    },
  );

  testWidgets('offline input stays local and survives reopening the draft', (
    WidgetTester tester,
  ) async {
    final FakeSpaceGateway gateway = FakeSpaceGateway();
    final ComposeHarness harness = ComposeHarness(gateway);
    await harness.pump(tester);
    final String draftId = gateway.drafts.keys.single;
    gateway.failNext('update_draft', upstreamUnavailable);

    await harness.type(tester, '离线时写下的内容');
    expect(find.text('离线：仅保存在本机'), findsOneWidget);
    expect(gateway.drafts[draftId]!.text, '');
    expect(harness.store.draft(draftId)!.text, '离线时写下的内容');
    await tester.tap(find.text('重试保存'));
    await tester.pumpAndSettle();
    expect(gateway.updateOperationIds.length, 2);
    expect(gateway.updateOperationIds.first, gateway.updateOperationIds.last);
    expect(find.text('已保存到服务器'), findsOneWidget);

    // Close and reopen the same draft: the unsynced text is still there.
    await tester.tap(find.byKey(SpaceComposePage.closeKey));
    await tester.pumpAndSettle();
    await harness.pump(tester, draftId: draftId);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    final TextField reopened = tester.widget<TextField>(
      find.byKey(SpaceComposePage.textKey),
    );
    expect(reopened.controller!.text, '离线时写下的内容');
    expect(find.text('已保存到服务器'), findsOneWidget);
    expect(harness.store.draft(draftId)!.text, '离线时写下的内容');
  });

  testWidgets('repost can publish only a reference and keeps its source', (
    WidgetTester tester,
  ) async {
    final FakeSpaceGateway gateway = FakeSpaceGateway();
    final SpacePost source = spacePost(
      postId: 'post-source',
      text: '原说说内容',
      author: spaceAuthor(account: spacePeerAccount, username: 'bob'),
    );
    gateway.posts['post-source'] = source;
    final ComposeHarness harness = ComposeHarness(gateway);
    await harness.pump(tester, reference: source, draftId: null);
    final String draftId = gateway.drafts.keys.single;
    expect(gateway.drafts[draftId]!.referenceId, 'post-source');
    final FilledButton publish = tester.widget<FilledButton>(
      find.byKey(SpaceComposePage.publishKey),
    );
    expect(publish.onPressed, isNotNull);
    await tester.tap(find.byKey(SpaceComposePage.publishKey));
    await tester.pumpAndSettle();
    expect(gateway.posts[harness.popped]!.reference!.postId, 'post-source');
  });

  testWidgets('upload failure blocks publishing until retry succeeds', (
    WidgetTester tester,
  ) async {
    final FakeSpaceGateway gateway = FakeSpaceGateway();
    final ComposeHarness harness = ComposeHarness(gateway);
    await harness.pump(
      tester,
      picker: () async =>
          PickedSpaceImage(bytes: spaceTinyPng, filename: 'retry.png'),
    );
    gateway.failNext('add_image', upstreamUnavailable);
    await tester.tap(find.byKey(SpaceComposePage.addImageKey));
    await tester.pumpAndSettle();
    expect(find.text('上传失败'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(SpaceComposePage.publishKey))
          .onPressed,
      isNull,
    );

    await tester.tap(find.byKey(const Key('space-compose-retry-retry.png')));
    await tester.pumpAndSettle();
    expect(find.text('上传失败'), findsNothing);
    expect(gateway.addImageOperationIds.length, 2);
    expect(
      gateway.addImageOperationIds.first,
      gateway.addImageOperationIds.last,
    );
    expect(
      tester
          .widget<FilledButton>(find.byKey(SpaceComposePage.publishKey))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('draft creation retries with the same operation id', (
    WidgetTester tester,
  ) async {
    final FakeSpaceGateway gateway = FakeSpaceGateway();
    final ComposeHarness harness = ComposeHarness(gateway);
    gateway.failNext('create_draft', upstreamUnavailable);
    await harness.pump(tester);
    expect(find.text('离线：仅保存在本机'), findsOneWidget);
    await tester.tap(find.text('重试保存'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(gateway.createDraftOperationIds.length, 2);
    expect(
      gateway.createDraftOperationIds.first,
      gateway.createDraftOperationIds.last,
    );
    expect(gateway.drafts, hasLength(1));
    expect(find.text('已保存到服务器'), findsOneWidget);
  });

  testWidgets(
    'publish retries with the same operation id after an unknown result',
    (WidgetTester tester) async {
      final FakeSpaceGateway gateway = FakeSpaceGateway();
      final ComposeHarness harness = ComposeHarness(gateway);
      await harness.pump(tester);
      await harness.type(tester, '发布重试');
      gateway.failNext('publish_draft', upstreamUnavailable);
      await tester.tap(find.byKey(SpaceComposePage.publishKey));
      await tester.pumpAndSettle();
      expect(harness.popped, isNull);
      expect(find.textContaining('无法连接服务器'), findsWidgets);
      await tester.tap(find.byKey(SpaceComposePage.publishKey));
      await tester.pumpAndSettle();
      expect(harness.popped, isNotNull);
      expect(gateway.publishOperationIds.length, 2);
      expect(
        gateway.publishOperationIds.first,
        gateway.publishOperationIds.last,
      );
    },
  );

  testWidgets('discard deletes the draft and its local buffer', (
    WidgetTester tester,
  ) async {
    final FakeSpaceGateway gateway = FakeSpaceGateway();
    final ComposeHarness harness = ComposeHarness(gateway);
    await harness.pump(tester);
    await harness.type(tester, '不要了');
    final String draftId = gateway.drafts.keys.single;
    await tester.tap(find.byKey(SpaceComposePage.discardKey));
    await tester.pumpAndSettle();
    await tester.tap(find.text('丢弃草稿'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('丢弃草稿'));
    await tester.pumpAndSettle();
    expect(gateway.drafts, isEmpty);
    expect(harness.store.draft(draftId), isNull);
    expect(harness.popped, isNull);
  });
}
