import 'dart:async';

import 'package:bb_client/ui/space/profile/space_profile_controller.dart';
import 'package:bb_client/ui/space/profile/space_profile_gateway.dart';
import 'package:flutter_test/flutter_test.dart';

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
      userId: gateway.account,
      viewerAccount: gateway.viewer,
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
        userId: gateway.account,
        viewerAccount: gateway.viewer,
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
      userId: gateway.account,
      viewerAccount: gateway.viewer,
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
        userId: gateway.account,
        viewerAccount: gateway.viewer,
      );
      addTearDown(controller.dispose);
      await controller.start();

      expect(controller.identity?.username, '海边的人');
      expect(controller.identity?.account, '10000002');
    },
  );

  test('an unsupported directory never calls months', () async {
    final FakeSpaceProfileGateway gateway = FakeSpaceProfileGateway(
      supportsMonths: false,
    );
    gateway.putPage(
      items: <SpaceProfileEntry>[
        profileEntry(postId: 'post-1', timelineAt: '2026-11-10T12:00:00Z'),
      ],
    );
    final SpaceProfileController controller = SpaceProfileController(
      gateway: gateway,
      userId: gateway.account,
      viewerAccount: gateway.viewer,
    );
    addTearDown(controller.dispose);
    await controller.start();

    expect(controller.directoryAvailable, isFalse);
    expect(controller.months, isEmpty);
    expect(controller.entries.length, 1);
  });
}
