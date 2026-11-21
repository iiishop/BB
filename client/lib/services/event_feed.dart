import 'dart:async';
import 'dart:io';
import 'dart:math';

import '../models/auth_models.dart';
import '../models/chat_models.dart';
import 'auth_session.dart';
import 'chat_api_client.dart';
import 'chat_ledger.dart';
import 'client_identity.dart';

/// Durable local event feed for DSH consumers.
///
/// The server event stream is only an edge hint. This class replays it into a
/// persisted, per-account/per-consumer cursor log. `read`/`wait` never advance
/// the chat consumption position; only an explicit ACK does.
class EventFeed {
  EventFeed({
    required this.api,
    required this.session,
    required this.ledger,
    this.pollInterval = const Duration(seconds: 2),
    this.webSocketHints = true,
  });

  final ChatApiClient api;
  final AuthSession session;
  final ChatLedger ledger;
  final Duration pollInterval;
  final bool webSocketHints;

  Timer? _timer;
  WebSocket? _socket;
  Timer? _reconnectTimer;
  final Random _jitter = Random();
  bool _connecting = false;
  int _socketEpoch = 0;
  int _retryAttempt = 0;
  AuthIdentity? _hintIdentity;
  int _replayEpoch = 0;
  Future<void>? _activePoll;
  Future<void>? _replayCommit;
  Future<void>? _disposal;
  AuthFailure? lastFailure;
  bool _disposed = false;
  int _revision = 0;

  /// Incrementing revision so a waiter cannot miss an append between the
  /// backlog query and the wait.
  int get revision => _revision;

  void start() {
    if (_timer != null || _disposed) {
      return;
    }
    _timer = Timer.periodic(pollInterval, (_) {
      _checkHintConnection();
      unawaited(_backgroundPoll());
    });
    unawaited(_backgroundPoll());
    _checkHintConnection();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _replayEpoch++;
    _activePoll = null;
    _socketEpoch++;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _retryAttempt = 0;
    unawaited(_socket?.close());
    _socket = null;
  }

  Future<void> dispose() {
    if (_disposal case final disposal?) return disposal;
    _disposed = true;
    stop();
    // Let any write already admitted by the ledger settle. Late HTTP
    // responses cannot queue new replay writes or start additional requests.
    return _disposal = _replayCommit ?? Future<void>.value();
  }

  Future<void> subscribe({
    required String consumerSession,
    String? peerAccount,
    bool discover = false,
    ExpectedIdentity? expectedIdentity,
  }) async {
    final AuthIdentity? captured = session.identity;
    if (captured == null) {
      throw unauthenticated;
    }
    if (expectedIdentity != null &&
        (expectedIdentity.account != captured.account ||
            expectedIdentity.authGeneration != captured.authGeneration)) {
      throw staleIdentity;
    }
    if (consumerSession.trim().isEmpty) {
      throw const AuthFailure(
        status: 422,
        code: 'validation_error',
        message: 'consumer_session 不能为空',
      );
    }
    final int epoch = _replayEpoch;
    await ledger.subscribe(
      captured.account,
      consumerSession,
      peerAccount,
      discover: discover,
      expectedIdentity: expectedIdentity,
      stillCurrent: () => session.isCurrent(captured),
    );
    if (!session.isCurrent(captured)) {
      throw unauthenticated;
    }
    // Registration is not consumption: keep the existing cursor untouched.
    // Await one backfill pass so an immediate read after subscribe can see the
    // pre-registration backlog instead of racing an unawaited poll.
    // A poll that started before registration cannot satisfy this backfill.
    await _activePoll;
    if (epoch == _replayEpoch) await _pollAll(captured);
  }

  /// Fetches each consumer's own durable source range into its local feed.
  ///
  /// A new consumer starts from source cursor 0 and can recover pre-registration
  /// backlog for its peer. Advancing `consumer A` never marks consumer B as
  /// having accepted anything.
  Future<void> _backgroundPoll() async {
    final int epoch = _replayEpoch;
    try {
      await pollOnce();
      if (epoch == _replayEpoch) lastFailure = null;
    } on AuthFailure catch (failure) {
      // Scheduled work has no HTTP caller. Preserve the failure for diagnostics;
      // explicit subscribe/poll still throws identity/storage errors.
      if (epoch == _replayEpoch) lastFailure = failure;
    } on FileSystemException {
      if (epoch != _replayEpoch) return;
      lastFailure = const AuthFailure(
        status: 503,
        code: 'storage_unavailable',
        message: '事件存储不可用',
      );
    }
  }

  Future<void> pollOnce() async {
    if (_disposed) return;
    final AuthIdentity? captured = session.identity;
    if (captured == null) return;
    await _pollAll(captured);
  }

  Future<void> _pollAll(AuthIdentity captured) async {
    if (_disposed) return;
    if (_activePoll != null) return _activePoll!;
    final int epoch = _replayEpoch;
    bool requireCurrentReplay() {
      if (epoch != _replayEpoch) throw const _ReplayStopped();
      if (!session.isCurrent(captured)) throw staleIdentity;
      return true;
    }

    final Future<void> run = _replaySubscriptions(
      captured,
      requireCurrentReplay,
    ).onError<_ReplayStopped>((_, _) {});
    _activePoll = run;
    try {
      await run;
    } finally {
      if (identical(_activePoll, run)) _activePoll = null;
    }
  }

  Future<T> _commitReplay<T>(Future<T> commit) {
    // Replay commits enter the same serialized ledger. The latest settles
    // after previously queued writes, including those from stopped runs.
    _replayCommit = commit.then<void>((_) {}, onError: (Object _) {});
    return commit;
  }

  Future<void> _replaySubscriptions(
    AuthIdentity captured,
    bool Function() requireCurrentReplay,
  ) async {
    await deliverPendingFor(captured.account);
    requireCurrentReplay();
    final Map<String, List<String>> subscriptions = await ledger.subscriptions(
      captured.account,
    );
    for (final MapEntry<String, List<String>> subscription
        in subscriptions.entries) {
      requireCurrentReplay();
      final Set<String> peers = subscription.value.toSet();
      if (await ledger.discoversConversations(
        captured.account,
        subscription.key,
      )) {
        String after = '';
        do {
          requireCurrentReplay();
          final ConversationRecordPage page = await api.conversations(
            token: captured.token,
            afterAccount: after,
            limit: 100,
          );
          requireCurrentReplay();
          for (final ConversationRecord row in page.items) {
            requireCurrentReplay();
            await _commitReplay(
              ledger.subscribe(
                captured.account,
                subscription.key,
                row.peerAccount,
                stillCurrent: requireCurrentReplay,
              ),
            );
            peers.add(row.peerAccount);
          }
          if (page.nextCursor == null) break;
          if (page.nextCursor!.compareTo(after) <= 0) {
            throw const FormatException('conversation cursor did not advance');
          }
          after = page.nextCursor!;
        } while (true);
      }
      for (final String peer in peers) {
        requireCurrentReplay();
        try {
          await _pollConsumer(
            captured: captured,
            consumerSession: subscription.key,
            peerAccount: peer,
            requireCurrentReplay: requireCurrentReplay,
          );
        } on AuthFailure catch (failure) {
          // Only peer-local availability failures can be isolated. Shared
          // identity, owner/CAS and storage failures must remain visible.
          if (!const <String>{
            'not_found',
            'upstream_unavailable',
            'upstream_timeout',
            'network_error',
          }.contains(failure.code)) {
            rethrow;
          }
        }
      }
    }
  }

  Future<void> _pollConsumer({
    required AuthIdentity captured,
    required String consumerSession,
    required String peerAccount,
    required void Function() requireCurrentReplay,
  }) async {
    int cursor = await ledger.subscriptionCursor(
      captured.account,
      consumerSession,
      peerAccount,
    );
    // Snapshot the binding that admits this feed's events. v2 callbacks must
    // carry the origin identity; a later rebind never rewrites it.
    final ExpectedIdentity? originIdentity = await ledger.originIdentityForFeed(
      captured.account,
      consumerSession,
    );
    bool advanced = true;
    while (advanced) {
      requireCurrentReplay();
      advanced = false;
      final ServerEventPage page = await api.events(
        token: captured.token,
        afterEventId: cursor,
        limit: 100,
      );
      requireCurrentReplay();
      for (final ServerEvent event in page.items) {
        requireCurrentReplay();
        if (event.peerAccount == peerAccount) {
          final ChatMessage? message = await _readable(
            captured.token,
            event.peerAccount,
            event.position,
            event.messageId,
          );
          requireCurrentReplay();
          if (message == null) {
            // Not readable yet: keep this consumer's cursor so a later poll
            // retries the source event instead of dropping it.
            return;
          }
          if (message.senderAccount != captured.account) {
            await _commitReplay(
              _append(
                LocalEvent(
                  eventId: 'server:${event.eventId}',
                  account: captured.account,
                  consumerSession: consumerSession,
                  type: LocalEventType.messageAvailable,
                  peerAccount: event.peerAccount,
                  position: event.position,
                  messageId: event.messageId,
                  originIdentity: originIdentity?.toJson(),
                ),
                requireCurrentReplay: requireCurrentReplay,
              ),
            );
          }
        }
        cursor = event.eventId;
        advanced = true;
      }
      requireCurrentReplay();
      await _commitReplay(
        ledger.setSubscriptionCursor(
          captured.account,
          consumerSession,
          peerAccount,
          cursor,
          beforeMutation: requireCurrentReplay,
        ),
      );
      if (!page.hasMore) {
        break;
      }
    }
  }

  Future<ChatMessage?> _readable(
    String token,
    String peer,
    int position,
    String messageId,
  ) async {
    if (position <= 0) {
      return null;
    }
    final MessagePage page = await api.conversation(
      token: token,
      account: peer,
      afterPosition: position - 1,
      limit: 1,
    );
    for (final ChatMessage message in page.items) {
      if (message.position == position && message.id == messageId) {
        return message;
      }
    }
    return null;
  }

  /// Delivers pending terminal facts for [account] regardless of who is
  /// currently logged in. Public reads still use only the current account.
  Future<void> deliverPendingFor(String account) async {
    final int delivered = await ledger.deliverPendingEvents(account);
    if (delivered > 0) {
      _revision += 1;
    }
  }

  Future<void> appendEvent(LocalEvent event) async {
    // Internal accepted-task event: it belongs to event.account even if a
    // different account is currently logged in. Only internal callers reach
    // this method; no local API exposes it.
    await _append(event);
  }

  Future<void> _append(
    LocalEvent event, {
    void Function()? requireCurrentReplay,
  }) async {
    await ledger.appendLocalEvent(
      account: event.account,
      consumerSession: event.consumerSession,
      event: event,
      beforeMutation: requireCurrentReplay,
    );
    _revision += 1;
  }

  Future<LocalEventPage> read({
    required String consumerSession,
    required int afterCursor,
    int limit = 50,
    ExpectedIdentity? expectedIdentity,
  }) async {
    final AuthIdentity captured = _captureReadIdentity(expectedIdentity);
    if (afterCursor < 0) {
      throw const AuthFailure(
        status: 422,
        code: 'validation_error',
        message: 'after_cursor 不能为负',
      );
    }
    _validateLimit(limit);
    final LocalEventPage page = await _readAs(
      captured,
      consumerSession: consumerSession,
      afterCursor: afterCursor,
      limit: limit,
      expectedIdentity: expectedIdentity,
    );
    if (!session.isCurrent(captured)) {
      throw expectedIdentity == null ? unauthenticated : staleIdentity;
    }
    return page;
  }

  AuthIdentity _captureReadIdentity(ExpectedIdentity? expected) {
    final AuthIdentity? captured = session.identity;
    if (expected != null &&
        (captured == null ||
            expected.account != captured.account ||
            expected.authGeneration != captured.authGeneration)) {
      throw staleIdentity;
    }
    if (captured == null) throw unauthenticated;
    return captured;
  }

  Future<LocalEventPage> _readAs(
    AuthIdentity captured, {
    required String consumerSession,
    required int afterCursor,
    required int limit,
    required ExpectedIdentity? expectedIdentity,
  }) async {
    await deliverPendingFor(captured.account);
    return ledger.readLocalEvents(
      account: captured.account,
      consumerSession: consumerSession,
      afterCursor: afterCursor,
      limit: limit,
      expectedIdentity: expectedIdentity,
      stillCurrent: expectedIdentity == null
          ? null
          : () => session.isCurrent(captured),
    );
  }

  Future<LocalEventPage> wait({
    required String consumerSession,
    required int afterCursor,
    int limit = 50,
    Duration timeout = const Duration(seconds: 60),
    ExpectedIdentity? expectedIdentity,
  }) async {
    final AuthIdentity captured = _captureReadIdentity(expectedIdentity);
    if (afterCursor < 0) {
      throw const AuthFailure(
        status: 422,
        code: 'validation_error',
        message: 'after_cursor 不能为负',
      );
    }
    _validateLimit(limit);
    final DateTime deadline = DateTime.now().add(timeout);
    while (!_disposed) {
      final AuthIdentity? current = session.identity;
      if (current == null) {
        if (expectedIdentity != null) throw staleIdentity;
        return LocalEventPage(
          items: const <LocalEventEntry>[],
          nextCursor: afterCursor,
          hasMore: false,
          reason: 'logout',
        );
      }
      if (!captured.sameAs(current)) {
        if (expectedIdentity != null) throw staleIdentity;
        // A→B, A→B→A and same-account re-login all change the generation.
        // Return the original cursor and never expose the new account's data.
        return LocalEventPage(
          items: const <LocalEventEntry>[],
          nextCursor: afterCursor,
          hasMore: false,
          reason: 'cancelled',
        );
      }

      final int seenRevision = _revision;
      // 1) backlog first, 2) only then subscribe/wait. The revision check
      // closes the append-between-read-and-wait gap.
      final LocalEventPage page = await _readAs(
        captured,
        consumerSession: consumerSession,
        afterCursor: afterCursor,
        limit: limit,
        expectedIdentity: expectedIdentity,
      );
      if (!session.isCurrent(captured)) {
        if (expectedIdentity != null) throw staleIdentity;
        final bool loggedOut = session.identity == null;
        return LocalEventPage(
          items: const <LocalEventEntry>[],
          nextCursor: afterCursor,
          hasMore: false,
          reason: loggedOut ? 'logout' : 'cancelled',
        );
      }
      if (_disposed) break;
      if (page.items.isNotEmpty) {
        return LocalEventPage(
          items: page.items,
          nextCursor: page.nextCursor,
          hasMore: page.hasMore,
          reason: 'events',
        );
      }
      final Duration remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        return LocalEventPage(
          items: const <LocalEventEntry>[],
          nextCursor: afterCursor,
          hasMore: false,
          reason: 'timeout',
        );
      }
      final Duration slice = remaining < const Duration(milliseconds: 100)
          ? remaining
          : const Duration(milliseconds: 100);
      await Future<void>.delayed(slice);
      if (_revision == seenRevision) {
        continue;
      }
    }
    return LocalEventPage(
      items: const <LocalEventEntry>[],
      nextCursor: afterCursor,
      hasMore: false,
      reason: 'cancelled',
    );
  }

  static void _validateLimit(int limit) {
    if (limit < 1 || limit > 100) {
      throw const AuthFailure(
        status: 422,
        code: 'validation_error',
        message: 'limit 必须是 1–100 的整数',
      );
    }
  }

  bool get _hintsRunning => webSocketHints && !_disposed && _timer != null;

  void _checkHintConnection() {
    if (!_hintsRunning) return;
    final current = session.identity;
    if (!(current?.sameAs(_hintIdentity) ?? _hintIdentity == null)) {
      _socketEpoch++;
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      _retryAttempt = 0;
      final old = _socket;
      _socket = null;
      unawaited(old?.close());
    }
    _hintIdentity = current;
    if (_reconnectTimer == null) unawaited(_connectHintSocket());
  }

  void _scheduleReconnect() {
    if (!_hintsRunning || _reconnectTimer != null) return;
    // Equal jitter: 0.5–1 s, 1–2 s, ... capped at 15–30 s. A socket
    // that immediately closes must not reset the exponential backoff.
    final int ceiling = min(30000, 1000 * (1 << min(_retryAttempt++, 5)));
    _reconnectTimer = Timer(
      Duration(milliseconds: ceiling ~/ 2 + _jitter.nextInt(ceiling ~/ 2 + 1)),
      () {
        _reconnectTimer = null;
        unawaited(_connectHintSocket());
      },
    );
  }

  Future<void> _replayAfterConnect(AuthIdentity captured, int epoch) async {
    try {
      if (_activePoll != null) await _backgroundPoll();
    } finally {
      // An older snapshot cannot cover the handshake gap, even if it fails.
      if (_hintsRunning &&
          epoch == _socketEpoch &&
          session.isCurrent(captured)) {
        await _backgroundPoll();
      }
    }
  }

  Future<void> _connectHintSocket() async {
    if (!_hintsRunning || _connecting || _socket != null) return;
    final AuthIdentity? captured = session.identity;
    if (captured == null) return;
    final int epoch = _socketEpoch;
    _connecting = true;
    try {
      final WebSocket socket = await api.connectEvents(captured.token);
      if (!_hintsRunning ||
          epoch != _socketEpoch ||
          !session.isCurrent(captured)) {
        await socket.close();
        return;
      }
      _socket = socket;
      final stable = Stopwatch()..start();
      void disconnected() {
        if (!identical(_socket, socket)) return;
        _socket = null;
        unawaited(socket.close());
        if (stable.elapsed >= const Duration(seconds: 30)) _retryAttempt = 0;
        _scheduleReconnect();
      }

      socket.listen(
        (_) => unawaited(_backgroundPoll()),
        onError: (Object _) => disconnected(),
        onDone: disconnected,
        cancelOnError: true,
      );
      // Recover the gap even if no new hint arrives after the handshake.
      unawaited(_replayAfterConnect(captured, epoch));
    } catch (_) {
      // Hints are optional; durable replay keeps running during backoff.
      if (epoch == _socketEpoch) _scheduleReconnect();
    } finally {
      _connecting = false;
      if (epoch != _socketEpoch && _hintsRunning) {
        unawaited(_connectHintSocket());
      }
    }
  }
}

class _ReplayStopped implements Exception {
  const _ReplayStopped();
}
