import 'dart:io';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/chat_api_client.dart';
import 'package:bb_client/services/chat_ledger.dart';
import 'package:bb_client/services/event_feed.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_chat_backend.dart';

const _alice = '10000001';
const _bob = '10000002';
const _carol = '10000003';

void main() {
  test(
    'paged replay recovers from a cold ledger with exact scoped events',
    () async {
      final backend = await FakeChatBackend.start(
        users: {_alice: 'alice', _bob: 'bob', _carol: 'carol'},
      );
      addTearDown(backend.close);
      final root = await Directory.systemTemp.createTemp(
        'bb-feed-persistence-',
      );
      addTearDown(() => root.delete(recursive: true));
      final path = '${root.path}/ledger.json';
      final api = ChatApiClient(baseUri: backend.baseUri);
      final session = AuthSession();
      void login(String account) => session.establish(
        token: backend.tokenFor(account),
        user: AuthUser(account: account, username: 'synthetic-$account'),
      );

      EventFeed open(ChatLedger ledger) {
        final feed = EventFeed(
          api: api,
          session: session,
          ledger: ledger,
          webSocketHints: false,
        );
        addTearDown(feed.dispose);
        return feed;
      }

      int? writesBeforeFailure;
      login(_alice);
      final first = open(
        ChatLedger.atPath(
          path,
          beforeReplace: () async {
            if (writesBeforeFailure case final int remaining) {
              if (remaining == 0) {
                throw const FileSystemException('synthetic rename failure');
              }
              writesBeforeFailure = remaining - 1;
            }
          },
        ),
      );
      await first.subscribe(consumerSession: 'multi', peerAccount: _bob);
      await first.subscribe(consumerSession: 'multi', peerAccount: _carol);
      await first.subscribe(consumerSession: 'bob-only', peerAccount: _bob);
      login(_bob);
      // Use the same local consumer string to verify separate account scopes.
      await first.subscribe(consumerSession: 'multi', peerAccount: _alice);

      final bobMessages = <String>[];
      for (var index = 1; index <= 103; index++) {
        bobMessages.add(
          await backend.seedMessage(
            sender: _bob,
            target: _alice,
            text: 'bob-$index',
          ),
        );
      }
      final carolMessages = [
        for (var index = 1; index <= 3; index++)
          await backend.seedMessage(
            sender: _carol,
            target: _alice,
            text: 'carol-$index',
          ),
      ];
      final aliceMessage = await backend.seedMessage(
        sender: _alice,
        target: _bob,
        text: 'alice-104',
      );

      login(_alice);
      // All 100 entries on the first upstream page persist, then the source
      // checkpoint fails. Cold replay must deduplicate that page and finish.
      writesBeforeFailure = 100;
      await expectLater(first.pollOnce(), throwsA(isA<FileSystemException>()));
      await first.dispose();

      final cold = ChatLedger.atPath(path);
      expect(await cold.localEventHead(_alice, 'multi'), 100);
      expect(await cold.subscriptionCursor(_alice, 'multi', _bob), 0);
      expect(await cold.localEventHead(_alice, 'bob-only'), 0);
      expect(await cold.localEventHead(_bob, 'multi'), 0);

      final resumed = open(cold);
      await resumed.pollOnce();
      await resumed.pollOnce();
      login(_bob);
      await resumed.pollOnce();
      await resumed.dispose();

      final reopened = ChatLedger.atPath(path);
      Future<void> verify(
        String account,
        String consumer,
        Map<String, Map<int, String>> expectedByPeer,
      ) async {
        final all = <LocalEventEntry>[];
        var cursor = 0;
        while (true) {
          final page = await reopened.readLocalEvents(
            account: account,
            consumerSession: consumer,
            afterCursor: cursor,
            limit: 17,
          );
          expect(
            page.hasMore,
            all.length + page.items.length <
                expectedByPeer.values.fold<int>(
                  0,
                  (count, events) => count + events.length,
                ),
          );
          if (page.items.isEmpty) {
            expect(page.nextCursor, cursor);
            break;
          }
          expect(
            page.items.map((entry) => entry.cursor),
            List.generate(page.items.length, (index) => cursor + index + 1),
          );
          all.addAll(page.items);
          cursor = page.nextCursor;
          expect(cursor, all.length);
        }

        final expected = {
          for (final peer in expectedByPeer.entries)
            for (final event in peer.value.entries) (peer.key, event.key),
        };
        expect(all, hasLength(expected.length));
        expect(
          all.map((entry) => entry.event.eventId).toSet(),
          hasLength(expected.length),
        );
        expect(all.map((entry) => entry.event.account).toSet(), {account});
        expect(all.map((entry) => entry.event.consumerSession).toSet(), {
          consumer,
        });
        expect(
          all.map((entry) {
            final event = entry.event;
            return (event.peerAccount, event.position);
          }).toSet(),
          expected,
        );
        for (final scope in expectedByPeer.entries) {
          final peer = scope.key;
          expect(
            await reopened.consumedThrough(account, peer, consumerId: consumer),
            0,
          );
          // The feed stores a position notification. Resolve message IDs
          // through authenticated history for each account and peer.
          final history = <int, String>{};
          var position = 0;
          while (true) {
            final page = await api.conversation(
              token: backend.tokenFor(account),
              account: peer,
              afterPosition: position,
              limit: 25,
            );
            for (final message in page.items) {
              if (message.senderAccount == peer) {
                history[message.position] = message.id;
              }
            }
            if (!page.hasMore) break;
            expect(page.nextPosition, greaterThan(position));
            position = page.nextPosition;
          }
          expect(history, scope.value);
        }
      }

      final bobRange = {
        for (final (index, id) in bobMessages.indexed) index + 1: id,
      };
      final carolRange = {
        for (final (index, id) in carolMessages.indexed) index + 1: id,
      };
      await verify(_alice, 'multi', {_bob: bobRange, _carol: carolRange});
      await verify(_alice, 'bob-only', {_bob: bobRange});
      await verify(_bob, 'multi', {
        _alice: {104: aliceMessage},
      });
      expect(await reopened.localEventHead(_bob, 'bob-only'), 0);
      expect(await reopened.localEventHead(_carol, 'multi'), 0);
    },
  );
}
