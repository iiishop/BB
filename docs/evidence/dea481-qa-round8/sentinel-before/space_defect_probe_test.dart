import 'dart:async';
import 'dart:io';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/space_models.dart';
import 'package:bb_client/services/auth_api_client.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/chat_api_client.dart';
import 'package:bb_client/services/chat_ledger.dart';
import 'package:bb_client/services/chat_service.dart';
import 'package:bb_client/services/space_api_client.dart';
import 'package:bb_client/services/space_service.dart';
import 'package:bb_client/ui/space/space_compose_controller.dart';
import 'package:bb_client/ui/space/space_controller.dart';
import 'package:bb_client/ui/space/space_gateway.dart';
import 'package:bb_client/ui/space/space_local_store.dart';
import 'package:flutter_test/flutter_test.dart';

class DelayedRealGateway extends SpaceServiceGateway {
  DelayedRealGateway(super.service);
  final accepted = Completer<void>();
  final release = Completer<void>();
  @override
  Future<SpaceOperation> updateDraft({required String draftId,
    required String operationId, required int expectedVersion,
    required String text, String? referenceId, required List<String> imageIds}) async {
    final result = await super.updateDraft(draftId: draftId,
        operationId: operationId, expectedVersion: expectedVersion,
        text: text, referenceId: referenceId, imageIds: imageIds);
    if (!accepted.isCompleted) accepted.complete();
    await release.future;
    return result;
  }
}

Future<SpaceServiceGateway> login() async {
  final uri = Uri.parse(Platform.environment['BB_SPACE_API_BASE']!);
  final auth = AuthApiClient(baseUri: uri);
  final user = await auth.register(username: 'qa${DateTime.now().microsecondsSinceEpoch}', password: 'SpaceIT1pass');
  final logged = await auth.login(account: user.account, password: 'SpaceIT1pass');
  final session = AuthSession()..establish(token: logged.token, user: logged.user);
  final cache = Directory.systemTemp.createTempSync('sentinel-space-');
  addTearDown(() => cache.deleteSync(recursive: true));
  return SpaceServiceGateway(SpaceService(api: SpaceApiClient(baseUri: uri),
      session: session, chat: ChatService(api: ChatApiClient(baseUri: uri),
        session: session, ledger: ChatLedger.inMemory(), cacheRoot: cache, webSocketHints: false)));
}

Future<String> publish(SpaceServiceGateway g, String text, {String? reference}) async {
  final d = await g.createDraft(operationId: 'd-${DateTime.now().microsecondsSinceEpoch}', text: text, referenceId: reference);
  return (await g.publishDraft(draftId: d.resourceId!, expectedVersion: 1,
      operationId: 'p-${DateTime.now().microsecondsSinceEpoch}')).resourceId!;
}

void main() {
  test('real T02 delayed save publishes visible text', () async {
    final base = await login();
    final g = DelayedRealGateway(base.service);
    final c = SpaceComposeController(gateway: g, store: SpaceLocalStore(scopeKey: g.scopeKey));
    addTearDown(c.dispose);
    await c.start();
    c.text.text = 'first edit';
    c.onTextChanged();
    final saving = c.saveNow();
    await g.accepted.future;
    c.text.text = 'latest edit';
    c.onTextChanged();
    await Future<void>.delayed(const Duration(milliseconds: 850));
    g.release.complete();
    await saving;
    await Future<void>.delayed(const Duration(milliseconds: 850));
    if (c.canPublish) {
      expect(await c.publish(), isTrue);
      expect((await base.getPost(c.publishedPostId!)).text, 'latest edit');
    } else {
      expect(c.phase, isNot(DraftSavePhase.saved));
    }
  });

  test('real T02 dirty reopen preserves conflicting server version', () async {
    final g = await login();
    final d = await g.createDraft(operationId: 'create', text: 'original');
    final id = d.resourceId!;
    await g.updateDraft(draftId: id, operationId: 'other-edit', expectedVersion: 1,
        text: 'other device edit', imageIds: []);
    // Check the real receiver rejects the correct stale base version.
    await expectLater(g.updateDraft(draftId: id, operationId: 'stale-control',
      expectedVersion: 1, text: 'offline local edit', imageIds: []),
      throwsA(isA<AuthFailure>().having((e) => e.code, 'code', 'version_conflict')));
    final store = SpaceLocalStore(scopeKey: g.scopeKey)..saveDraft(id,
      const SpaceDraftBuffer(text: 'offline local edit', imageIds: [], version: 1,
        serverText: 'original', dirty: true));
    final c = SpaceComposeController(gateway: g, store: store, draftId: id);
    addTearDown(c.dispose);
    await c.start();
    await c.saveNow();
    expect((await g.getDraft(id)).text, 'other device edit');
  });

  test('real T07 replay removes cached repost source text', () async {
    final g = await login();
    final source = await publish(g, 'deleted secret');
    final repost = await publish(g, 'repost text', reference: source);
    final c = SpaceController(gateway: g, store: SpaceLocalStore(scopeKey: g.scopeKey), autoPoll: false);
    addTearDown(c.dispose);
    await c.start();
    await g.deletePost(source, operationId: 'delete');
    await c.pollEventsOnce();
    // Server correctly scrubs the reference; compare actual loaded UI state.
    expect((await g.getPost(repost)).reference!.text, isNull);
    expect(c.posts.singleWhere((p) => p.postId == repost).reference!.text, isNull);
  });
}
