import 'dart:async';

import 'package:bb_client/ui/space/profile/space_profile_controller.dart';
import 'package:bb_client/ui/space/profile/space_profile_gateway.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_space_gateway.dart';
import 'support/fake_space_profile_gateway.dart';
import 'support/space_fixtures.dart';

const SpaceProfileMonth _nov = SpaceProfileMonth(year: 2026, month: 11);
const SpaceProfileMonth _oct = SpaceProfileMonth(year: 2026, month: 10);
const SpaceProfileMonth _sep = SpaceProfileMonth(year: 2026, month: 9);

void main() {
  test('an out-of-order month response cannot backfill the current list', () async {
    final FakeSpaceProfileGateway gateway = FakeSpaceProfileGateway();
    gateway.monthList.addAll(<SpaceProfileMonth>[_nov, _oct, _sep]);
    gateway.putPage(
      items: <SpaceProfileEntry>[
        profileEntry(postId: 'latest-1', timelineAt: '2026-11-10T12:00:00Z'),
      ],
    );
    gateway.putPage(
      month: _oct,
      items: <SpaceProfileEntry>[
        profileEntry(postId: 'oct-1', timelineAt: '2026-10-10T12:00:00Z'),
      ],
    );
    gateway.putPage(
      month: _sep,
      items: <SpaceProfileEntry>[
        profileEntry(postId: 'sep-1', timelineAt: '2026-09-10T12:00:00Z'),
      ],
    );
    gateway.holdTimeline = true;
    final SpaceProfileController controller = SpaceProfileController(
      gateway: gateway,
      space: FakeSpaceGateway(account: gateway.viewer),
      userId: gateway.account,
      viewerAccount: gateway.viewer,
      displayOffsetMinutes: 0,
    );
    addTearDown(controller.dispose);

    unawaited(controller.start());
    await pumpEventQueue();
    unawaited(controller.jumpToMonth(_oct));
    await pumpEventQueue();
    unawaited(controller.jumpToMonth(_sep));
    await pumpEventQueue();
    expect(gateway.timelineGates.length, 3);

    // September lands first; the slower latest/October responses arrive after.
    gateway.timelineGates[2].complete();
    await pumpEventQueue();
    expect(controller.entries.single.post.postId, 'sep-1');
    expect(controller.anchoredMonth, _sep);

    gateway.timelineGates[1].complete();
    gateway.timelineGates[0].complete();
    await pumpEventQueue();

    expect(controller.entries.single.post.postId, 'sep-1');
    expect(controller.anchoredMonth, _sep);
    expect(controller.phase, SpaceProfilePhase.ready);
  });

  test(
    'the visible month follows scrolling without clearing the selection',
    () async {
      final FakeSpaceProfileGateway gateway = FakeSpaceProfileGateway();
      gateway.putPage(
        month: _oct,
        items: <SpaceProfileEntry>[
          profileEntry(postId: 'oct-1', timelineAt: '2026-10-10T12:00:00Z'),
        ],
      );
      final SpaceProfileController controller = SpaceProfileController(
        gateway: gateway,
        space: FakeSpaceGateway(account: gateway.viewer),
        userId: gateway.account,
        viewerAccount: gateway.viewer,
        displayOffsetMinutes: 0,
      );
      addTearDown(controller.dispose);
      await controller.start();
      await controller.jumpToMonth(_oct);
      expect(controller.anchoredMonth, _oct);
      expect(controller.visibleMonth, _oct);
      expect(controller.monthState(_oct), SpaceMonthState.selected);

      controller.reportVisibleMonth(_sep);
      expect(controller.visibleMonth, _sep);
      expect(controller.anchoredMonth, _oct);
      expect(controller.monthState(_oct), SpaceMonthState.selected);
      expect(controller.monthState(_sep), SpaceMonthState.visible);
      expect(controller.atLatest, isFalse);
    },
  );

  test('duplicate cursor rows are not appended twice', () async {
    final FakeSpaceProfileGateway gateway = FakeSpaceProfileGateway();
    final SpaceProfileEntry first = profileEntry(
      postId: 'post-1',
      timelineAt: '2026-11-10T12:00:00Z',
    );
    gateway.putPage(
      items: <SpaceProfileEntry>[first],
      nextCursor: 'c1',
      hasMore: true,
    );
    gateway.putPage(
      cursor: 'c1',
      items: <SpaceProfileEntry>[
        first,
        profileEntry(postId: 'post-2', timelineAt: '2026-11-09T12:00:00Z'),
      ],
      hasMore: false,
    );
    final SpaceProfileController controller = SpaceProfileController(
      gateway: gateway,
      space: FakeSpaceGateway(account: gateway.viewer),
      userId: gateway.account,
      viewerAccount: gateway.viewer,
      displayOffsetMinutes: 0,
    );
    addTearDown(controller.dispose);
    await controller.start();
    await controller.loadMore();

    expect(
      controller.entries.map((SpaceProfileEntry e) => e.post.postId).toList(),
      <String>['post-1', 'post-2'],
    );
    expect(gateway.calls.length, 2);
    expect(gateway.calls.last.cursor, 'c1');
  });

  test(
    'identity falls back to the timeline author when Profile is unavailable',
    () async {
      final FakeSpaceProfileGateway gateway = FakeSpaceProfileGateway()
        ..identityFailure = StateError('no profile');
      gateway.putPage(
        items: <SpaceProfileEntry>[
          profileEntry(
            postId: 'post-1',
            timelineAt: '2026-11-10T12:00:00Z',
            author: spaceAuthor(account: '10000002', username: '海边的人'),
          ),
        ],
      );
      final SpaceProfileController controller = SpaceProfileController(
        gateway: gateway,
        space: FakeSpaceGateway(account: gateway.viewer),
        userId: gateway.account,
        viewerAccount: gateway.viewer,
        displayOffsetMinutes: 0,
      );
      addTearDown(controller.dispose);
      await controller.start();

      expect(controller.identity?.username, '海边的人');
      expect(controller.identity?.account, '10000002');
    },
  );

  test('the fixed offset decides the month at a month/year edge', () async {
    final FakeSpaceProfileGateway gateway = FakeSpaceProfileGateway();
    gateway.monthList.add(const SpaceProfileMonth(year: 2026, month: 11));
    gateway.putPage(
      items: <SpaceProfileEntry>[
        profileEntry(postId: 'post-edge', timelineAt: '2026-10-31T23:59:59Z'),
      ],
    );
    final SpaceProfileController controller = SpaceProfileController(
      gateway: gateway,
      space: FakeSpaceGateway(account: gateway.viewer),
      userId: gateway.account,
      viewerAccount: gateway.viewer,
      displayOffsetMinutes: 345,
    );
    addTearDown(controller.dispose);
    await controller.start();

    // 23:59Z + 5h45m is November 1st; both the directory request and the card
    // grouping must use this one offset.
    expect(
      controller.monthOf('2026-10-31T23:59:59Z'),
      const SpaceProfileMonth(year: 2026, month: 11),
    );
    expect(controller.months, isNotEmpty);
    expect(gateway.monthOffsets.single, 345);
    expect(gateway.calls.first.offset, 345);
    expect(
      controller.visibleMonth,
      const SpaceProfileMonth(year: 2026, month: 11),
    );
  });

  test('month-anchored continuation repeats the month binding', () async {
    final FakeSpaceProfileGateway gateway = FakeSpaceProfileGateway();
    const SpaceProfileMonth oct = SpaceProfileMonth(year: 2026, month: 10);
    gateway.putPage(
      month: oct,
      items: <SpaceProfileEntry>[
        profileEntry(postId: 'oct-newest', timelineAt: '2026-10-30T12:00:00Z'),
      ],
      nextCursor: 'month-c1',
      hasMore: true,
    );
    gateway.putPage(
      month: oct,
      cursor: 'month-c1',
      items: <SpaceProfileEntry>[
        profileEntry(postId: 'oct-older', timelineAt: '2026-10-02T12:00:00Z'),
      ],
    );
    final SpaceProfileController controller = SpaceProfileController(
      gateway: gateway,
      space: FakeSpaceGateway(account: gateway.viewer),
      userId: gateway.account,
      viewerAccount: gateway.viewer,
      displayOffsetMinutes: 0,
    );
    addTearDown(controller.dispose);
    await controller.start();
    await controller.jumpToMonth(oct);
    await controller.loadMore();

    // The server binds the cursor to the selected month; omitting it makes the
    // real receiver reject the continuation.
    expect(gateway.calls.last.month, oct);
    expect(gateway.calls.last.cursor, 'month-c1');
    expect(
      controller.entries.map((SpaceProfileEntry e) => e.post.postId).toList(),
      <String>['oct-newest', 'oct-older'],
    );
    expect(controller.error, isNull);
  });

  test(
    'a partial card seed is hydrated from the full authorized Profile',
    () async {
      final FakeSpaceProfileGateway gateway = FakeSpaceProfileGateway();
      gateway.identityResult = SpaceProfileIdentity(
        account: gateway.account,
        username: 'bob',
        signature: 'QA saved signature',
      );
      gateway.putPage(
        items: <SpaceProfileEntry>[
          profileEntry(postId: 'post-1', timelineAt: '2026-11-10T12:00:00Z'),
        ],
      );
      final SpaceProfileController controller = SpaceProfileController(
        gateway: gateway,
        space: FakeSpaceGateway(account: gateway.viewer),
        userId: gateway.account,
        viewerAccount: gateway.viewer,
        displayOffsetMinutes: 0,
        initialIdentity: SpaceProfileIdentity(
          account: gateway.account,
          username: 'bob',
        ),
      );
      addTearDown(controller.dispose);
      await controller.start();

      expect(controller.identity?.signature, 'QA saved signature');
    },
  );
}
