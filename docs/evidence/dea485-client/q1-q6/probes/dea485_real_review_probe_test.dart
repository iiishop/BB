// Review-only failing probes for b6becc4. Never part of default test/ CI.
// Move each scenario into the existing normal entry after its production fix.
import 'dart:async';
import 'dart:io';

import 'package:bb_client/models/space_models.dart';
import 'package:bb_client/services/auth_api_client.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/chat_api_client.dart';
import 'package:bb_client/services/chat_ledger.dart';
import 'package:bb_client/services/chat_service.dart';
import 'package:bb_client/services/space_api_client.dart';
import 'package:bb_client/services/space_service.dart';
import 'package:bb_client/ui/space/profile/space_profile_adapter.dart';
import 'package:bb_client/ui/space/profile/space_profile_controller.dart';
import 'package:bb_client/ui/space/profile/space_profile_gateway.dart';
import 'package:bb_client/ui/space/space_controller.dart';
import 'package:bb_client/ui/space/space_follow_store.dart';
import 'package:bb_client/ui/space/space_gateway.dart';
import 'package:bb_client/ui/space/space_local_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/fake_space_gateway.dart';
import '../test/support/space_fixtures.dart';
import '../test/support/space_test_harness.dart';

void main() {
  test('QA real HTTP month continuation retains its query binding', () async {
    final base = Uri.parse(Platform.environment['BB_SPACE_API_BASE']!);
    final cache = Directory.systemTemp.createTempSync('dea485-review-');
    addTearDown(() => cache.deleteSync(recursive: true));
    final auth = AuthApiClient(baseUri: base);
    final user = await auth.register(
      username: 'qa${DateTime.now().microsecondsSinceEpoch}',
      password: 'ProfileIT1pass',
    );
    final login = await auth.login(
      account: user.account,
      password: 'ProfileIT1pass',
    );
    final session = AuthSession()
      ..establish(token: login.token, user: login.user);
    final chat = ChatService(
      api: ChatApiClient(baseUri: base),
      session: session,
      ledger: ChatLedger.inMemory(),
      cacheRoot: cache,
      webSocketHints: false,
    );
    final space = SpaceServiceGateway(
      SpaceService(
        api: SpaceApiClient(baseUri: base),
        session: session,
        chat: chat,
      ),
    );
    for (var i = 0; i < 3; i++) {
      final d = await space.createDraft(
        operationId: 'qa-d-$i',
        text: 'month item $i',
      );
      await space.publishDraft(
        draftId: d.resourceId!,
        operationId: 'qa-p-$i',
        expectedVersion: d.resourceVersion!,
      );
    }
    final months = await space.listProfileMonths(
      targetAccount: user.account,
      timezoneOffsetMinutes: 0,
    );
    final m = months.items.single;
    final wire = '${m.year}-${m.month.toString().padLeft(2, '0')}';
    final first = await space.listProfilePosts(
      targetAccount: user.account,
      timezoneOffsetMinutes: 0,
      month: wire,
      limit: 1,
    );
    // Adjacent legal real-receiver request succeeds with month repeated.
    final next = await space.listProfilePosts(
      targetAccount: user.account,
      timezoneOffsetMinutes: 0,
      month: wire,
      cursor: first.nextCursor,
      limit: 1,
    );
    expect(next.items, hasLength(1));
    expect(next.items.single.postId, isNot(first.items.single.postId));
    final c = SpaceProfileController(
      gateway: SpaceProfileAdapter(space: space),
      space: space,
      userId: user.account,
      viewerAccount: user.account,
      displayOffsetMinutes: 0,
      pageSize: 1,
    );
    addTearDown(c.dispose);
    await c.start();
    await c.jumpToMonth(SpaceProfileMonth(year: m.year, month: m.month));
    expect(c.entries, hasLength(1));
    expect(c.hasMore, isTrue);
    await c.loadMore();
    expect(
      c.error,
      isNull,
      reason: 'Month-anchored continuation must be accepted by the real server',
    );
    expect(c.entries, hasLength(2));
  });
}
