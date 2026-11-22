import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:bb_client/tasks/task_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

({String? worker, int start, int end}) blockingTask() {
  final start = DateTime.now().microsecondsSinceEpoch;
  sleep(const Duration(milliseconds: 500));
  return (
    worker: Isolate.current.debugName,
    start: start,
    end: DateTime.now().microsecondsSinceEpoch,
  );
}

int failTask() => throw StateError('offline fixture failed');

int answerTask() => 42;

Future<void> parkedTask(SendPort started) async {
  started.send(true);
  await Completer<void>().future;
}

Future<void> Function() parkOn(SendPort started) =>
    () => parkedTask(started);

int Function() unsendableTask(ReceivePort port) =>
    () => port.hashCode;

Future<void> uncaughtTask() async {
  scheduleMicrotask(() => throw StateError('worker callback failed'));
  await Completer<void>().future;
}

void main() {
  test(
    'synchronous offline tasks overlap on independent worker isolates',
    () async {
      final scheduler = TaskScheduler(maxConcurrent: 2);
      final first = scheduler.submit(blockingTask);
      final second = scheduler.submit(blockingTask);
      final third = scheduler.submit(blockingTask);
      final [a, b, c] = await Future.wait([
        first.result,
        second.result,
        third.result,
      ]);

      expect(a.worker, isNot(Isolate.current.debugName));
      expect(b.worker, isNot(Isolate.current.debugName));
      expect(a.start, lessThan(b.end));
      expect(b.start, lessThan(a.end));
      expect(c.start >= a.end || c.start >= b.end, isTrue);
    },
  );

  test(
    'FIFO skips cancelled queued work and failure releases a slot',
    () async {
      final scheduler = TaskScheduler(maxConcurrent: 1);
      final gate = Completer<void>();
      final order = <int>[];
      final blocker = scheduler.submit(
        () => gate.future,
        execution: TaskExecution.caller,
      );
      final cancelled = scheduler.submit(
        () => order.add(-1),
        execution: TaskExecution.caller,
      );
      final failed = scheduler.submit(failTask);
      final later = scheduler.submit(
        () => order.add(1),
        execution: TaskExecution.caller,
      );
      final last = scheduler.submit(
        () => order.add(2),
        execution: TaskExecution.caller,
      );
      final cancellation = expectLater(
        cancelled.result,
        throwsA(isA<TaskCancelled>()),
      );
      final failure = expectLater(failed.result, throwsStateError);
      cancelled.cancel();
      await cancellation;
      expect(order, isEmpty);
      gate.complete();
      await Future.wait([blocker.result, failure, later.result, last.result]);
      expect(order, [1, 2]);
    },
  );

  test('running worker cancellation frees slot and returns an error', () async {
    final started = ReceivePort();
    addTearDown(started.close);
    final scheduler = TaskScheduler(maxConcurrent: 1);
    final running = scheduler.submit(parkOn(started.sendPort));
    final next = scheduler.submit(answerTask);
    final cancelled = expectLater(
      running.result,
      throwsA(isA<TaskCancelled>()),
    );
    expect(await started.first, isTrue);
    running.cancel();
    await cancelled;
    expect(await next.result, 42);
  });

  test('spawn and uncaught worker errors both free their slot', () async {
    final port = ReceivePort();
    addTearDown(port.close);
    final scheduler = TaskScheduler(maxConcurrent: 1);
    final spawn = expectLater(
      scheduler.submit(unsendableTask(port)).result,
      throwsArgumentError,
    );
    final uncaught = expectLater(
      scheduler.submit(uncaughtTask).result,
      throwsA(isA<RemoteError>()),
    );
    final next = scheduler.submit(answerTask);
    await Future.wait([spawn, uncaught]);
    expect(await next.result, 42);
  });

  test('caller cancellation holds its slot until I/O has settled', () async {
    final scheduler = TaskScheduler(maxConcurrent: 1);
    final started = Completer<void>();
    final drain = Completer<void>();
    final running = scheduler.submit(() {
      started.complete();
      return drain.future;
    }, execution: TaskExecution.caller);
    var advanced = false;
    final next = scheduler.submit(() {
      advanced = true;
    }, execution: TaskExecution.caller);
    await started.future;
    final cancelled = expectLater(
      running.result,
      throwsA(isA<TaskCancelled>()),
    );
    running.cancel();
    await Future<void>.delayed(Duration.zero);
    expect(advanced, isFalse);
    drain.complete();
    await cancelled;
    await next.result;
    expect(advanced, isTrue);
  });
}
