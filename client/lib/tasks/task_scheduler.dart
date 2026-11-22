import 'dart:async';
import 'dart:collection';
import 'dart:isolate';

enum TaskExecution { worker, caller }

class TaskCancelled implements Exception {
  const TaskCancelled();
}

/// A FIFO scheduler with one concurrency budget for workers and async I/O.
class TaskScheduler {
  TaskScheduler({required this.maxConcurrent}) {
    if (maxConcurrent < 1) {
      throw RangeError.range(maxConcurrent, 1, null, 'maxConcurrent');
    }
  }

  final int maxConcurrent;
  final _queued = Queue<TaskHandle<Object?>>();
  int _running = 0;

  /// Worker tasks must be sendable between isolates. Caller tasks can share
  /// isolate-bound resources and must settle their own I/O on cancellation.
  TaskHandle<T> submit<T>(
    FutureOr<T> Function() task, {
    TaskExecution execution = TaskExecution.worker,
  }) {
    final handle = TaskHandle<T>._(this, task, execution);
    _queued.addLast(handle);
    _dispatch();
    return handle;
  }

  void _dispatch() {
    while (_running < maxConcurrent && _queued.isNotEmpty) {
      final next = _queued.removeFirst();
      _running++;
      unawaited(next._run());
    }
  }

  void _release() {
    _running--;
    _dispatch();
  }
}

class TaskHandle<T> {
  TaskHandle._(this._scheduler, this._task, this._execution);

  TaskScheduler? _scheduler;
  FutureOr<T> Function()? _task;
  final TaskExecution _execution;
  final _result = Completer<T>();
  Isolate? _worker;
  bool _cancelled = false;

  Future<T> get result => _result.future;

  /// Queued work never runs after cancellation. Running work retains its slot
  /// until the worker has exited or the caller task has settled.
  void cancel() {
    if (_cancelled || _result.isCompleted) return;
    _cancelled = true;
    if (_scheduler!._queued.remove(this)) {
      _task = null;
      _scheduler = null;
      _result.completeError(const TaskCancelled());
    } else {
      _worker?.kill(priority: Isolate.immediate);
    }
  }

  Future<void> _run() async {
    final task = _task!;
    _task = null;
    try {
      final value = await (_execution == TaskExecution.worker
          ? _runWorker(task)
          : Future<T>.microtask(() {
              if (_cancelled) throw const TaskCancelled();
              return task();
            }));
      if (_cancelled) throw const TaskCancelled();
      _result.complete(value);
    } catch (error, stack) {
      _result.completeError(_cancelled ? const TaskCancelled() : error, stack);
    } finally {
      final scheduler = _scheduler!;
      _scheduler = null;
      scheduler._release();
    }
  }

  Future<T> _runWorker(FutureOr<T> Function() task) async {
    final port = ReceivePort();
    // Attach the receiver before the worker can return or fail to start.
    final reply = port.first;
    try {
      final worker = _worker = await Isolate.spawn(
        _execute<T>,
        (port.sendPort, task),
        onError: port.sendPort,
        onExit: port.sendPort,
      );
      if (_cancelled) worker.kill(priority: Isolate.immediate);
      return switch (await reply) {
        (true, final value) => value as T,
        (false, final Object error, final StackTrace stack) =>
          Error.throwWithStackTrace(error, stack),
        [final String error, final String stack] => throw RemoteError(
          error,
          stack,
        ),
        _ => throw StateError('Task worker exited without a result.'),
      };
    } finally {
      _worker = null;
      port.close();
    }
  }
}

Future<void> _execute<T>((SendPort, FutureOr<T> Function()) request) async {
  final (port, task) = request;
  try {
    Isolate.exit(port, (true, await task()));
  } catch (error, stack) {
    Isolate.exit(port, (false, error, stack));
  }
}
