import 'dart:async';
import 'dart:io';

import '../models/auth_models.dart';
import '../models/chat_models.dart';
import 'auth_session.dart';
import 'chat_api_client.dart';
import 'chat_ledger.dart';

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
  bool _polling = false;
  bool _disposed = false;
  int _revision = 0;

  /// Incrementing revision so a waiter cannot miss an append between the
  /// backlog query and the wait.
  int get revision => _revision;

  void start() {
    if (_timer != null || _disposed) {
      return;
    }
    _timer = Timer.periodic(pollInterval, (_) => unawaited(pollOnce()));
    unawaited(pollOnce());
    if (webSocketHints) {
      unawaited(_connectHintSocket());
    }
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    unawaited(_socket?.close());
    _socket = null;
  }

  Future<void> dispose() async {
    _disposed = true;
    stop();
  }

  Future<void> subscribe({
    required String consumerSession,
    required String peerAccount,
  }) async {
    final AuthUser? user = session.user;
    if (user == null || !session.hasToken) {
      throw unauthenticated;
    }
    if (consumerSession.trim().isEmpty) {
      throw const AuthFailure(
        status: 422,
        code: 'validation_error',
        message: 'consumer_session 不能为空',
      );
    }
    await ledger.subscribe(user.account, consumerSession, peerAccount);
    // Registration is not consumption: keep the existing cursor untouched.
    // Await one backfill pass so an immediate read after subscribe can see the
    // pre-registration backlog instead of racing an unawaited poll.
    await pollOnce();
  }

  /// Fetches each consumer's own durable source range into its local feed.
  ///
  /// A new consumer starts from source cursor 0 and can recover pre-registration
  /// backlog for its peer. Advancing `consumer A` never marks consumer B as
  /// having accepted anything.
  Future<void> pollOnce() async {
    if (_polling || _disposed) {
      return;
    }
    final AuthUser? user = session.user;
    final String? token = session.tokenForRequest;
    if (user == null || token == null || token.isEmpty) {
      return;
    }
    _polling = true;
    try {
      final Map<String, String> subscriptions = await ledger.subscriptions(
        user.account,
      );
      for (final MapEntry<String, String> subscription
          in subscriptions.entries) {
        if (_disposed) {
          break;
        }
        await _pollConsumer(
          account: user.account,
          token: token,
          consumerSession: subscription.key,
          peerAccount: subscription.value,
        );
      }
    } on AuthFailure catch (failure) {
      if (failure.status == 401) {
        // Leave cursors untouched; a later valid login resumes.
        return;
      }
      // Network faults are retried by the timer.
    } catch (_) {
      // Same: the durable log only advances on confirmed readable events.
    } finally {
      _polling = false;
    }
  }

  Future<void> _pollConsumer({
    required String account,
    required String token,
    required String consumerSession,
    required String peerAccount,
  }) async {
    int cursor = await ledger.consumerEventCursor(account, consumerSession);
    bool advanced = true;
    while (advanced && !_disposed) {
      advanced = false;
      final ServerEventPage page = await api.events(
        token: token,
        afterEventId: cursor,
        limit: 100,
      );
      for (final ServerEvent event in page.items) {
        if (event.peerAccount == peerAccount) {
          final ChatMessage? message = await _readable(
            token,
            event.peerAccount,
            event.position,
            event.messageId,
          );
          if (message == null) {
            // Not readable yet: keep this consumer's cursor so a later poll
            // retries the source event instead of dropping it.
            return;
          }
          if (message.senderAccount != account) {
            await _append(
              LocalEvent(
                eventId: 'server:${event.eventId}',
                account: account,
                consumerSession: consumerSession,
                type: LocalEventType.messageAvailable,
                peerAccount: event.peerAccount,
                position: event.position,
                messageId: event.messageId,
              ),
            );
          }
        }
        cursor = event.eventId;
        advanced = true;
      }
      await ledger.setConsumerEventCursor(account, consumerSession, cursor);
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

  Future<void> appendEvent(LocalEvent event) async {
    final AuthUser? user = session.user;
    if (user == null || user.account != event.account) {
      return;
    }
    await _append(event);
  }

  Future<void> _append(LocalEvent event) async {
    await ledger.appendLocalEvent(
      account: event.account,
      consumerSession: event.consumerSession,
      event: event,
    );
    _revision += 1;
  }

  Future<LocalEventPage> read({
    required String consumerSession,
    required int afterCursor,
    int limit = 50,
  }) async {
    final AuthUser? user = session.user;
    if (user == null || !session.hasToken) {
      throw unauthenticated;
    }
    if (afterCursor < 0) {
      throw const AuthFailure(
        status: 422,
        code: 'validation_error',
        message: 'after_cursor 不能为负',
      );
    }
    _validateLimit(limit);
    return ledger.readLocalEvents(
      account: user.account,
      consumerSession: consumerSession,
      afterCursor: afterCursor,
      limit: limit,
    );
  }

  Future<LocalEventPage> wait({
    required String consumerSession,
    required int afterCursor,
    int limit = 50,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final AuthUser? user = session.user;
    if (user == null || !session.hasToken) {
      throw unauthenticated;
    }
    _validateLimit(limit);
    final DateTime deadline = DateTime.now().add(timeout);
    while (!_disposed) {
      final int seenRevision = _revision;
      // 1) backlog first, 2) only then subscribe/wait. The revision check
      // closes the append-between-read-and-wait gap.
      final LocalEventPage page = await read(
        consumerSession: consumerSession,
        afterCursor: afterCursor,
        limit: limit,
      );
      if (page.items.isNotEmpty) {
        return LocalEventPage(
          items: page.items,
          nextCursor: page.nextCursor,
          hasMore: page.hasMore,
          reason: 'events',
        );
      }
      if (!session.hasToken) {
        return LocalEventPage(
          items: const <LocalEventEntry>[],
          nextCursor: afterCursor,
          hasMore: false,
          reason: 'logout',
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
        // No append happened; loop until timeout (server polling may append).
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

  Future<void> _connectHintSocket() async {
    final String? token = session.tokenForRequest;
    if (token == null || token.isEmpty) {
      return;
    }
    try {
      final WebSocket socket = await api.connectEvents(token);
      _socket = socket;
      socket.listen(
        (_) => unawaited(pollOnce()),
        onError: (Object _) {},
        onDone: () {
          _socket = null;
        },
        cancelOnError: true,
      );
    } catch (_) {
      // Hints are optional; the durable GET replay remains authoritative.
    }
  }
}
