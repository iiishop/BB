// Probe-only host. All data/HTTP work delegates to the actual BB implementation.
// Public DI decorators pause calls; no product file or external runtime is changed.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:mirrors';

import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/services/auth_api_client.dart';
import 'package:bb_client/services/auth_service.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/chat_api_client.dart';
import 'package:bb_client/services/chat_ledger.dart';
import 'package:bb_client/services/chat_service.dart';
import 'package:bb_client/services/local_auth_server.dart';
import 'package:bb_client/services/session_store.dart';

class Gate {
  String? edge;
  Completer<void> entered = Completer<void>();
  Completer<void> released = Completer<void>();
  final List<String> trace = <String>[];

  void arm(String next) {
    if (edge != null) throw StateError('barrier already armed');
    edge = next;
    entered = Completer<void>();
    released = Completer<void>();
    trace.add('arm:$next');
  }

  Future<void> pause(String at) async {
    if (edge != at) return;
    trace.add('entered:$at');
    entered.complete();
    await released.future;
    trace.add('released:$at');
  }

  void release() {
    edge = null;
    if (!released.isCompleted) released.complete();
  }
}

class GatedLedger implements ChatLedger {
  GatedLedger(this.actual, this.gate);
  final ChatLedger actual;
  final Gate gate;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #confirmPresentationAttempt)
      return confirm(invocation);
    if (invocation.memberName == #commitAck) return ack(invocation);
    if (invocation.memberName == #setConsumedThrough)
      return legacyAck(invocation);
    return reflect(actual).delegate(invocation);
  }

  dynamic invokeWithHook(Invocation invocation, String edge) {
    final arguments = Map<Symbol, dynamic>.from(invocation.namedArguments);
    // Forward all public arguments unchanged, adding only the supplied fault hook.
    // The old bbadb4e method has no hook; keep the same probe usable there.
    final method = reflect(actual).type.instanceMembers[invocation.memberName]!;
    if (method.parameters.any(
      (parameter) => parameter.simpleName == #beforeCommit,
    )) {
      final prior = arguments[#beforeCommit] as Future<void> Function()?;
      arguments[#beforeCommit] = () async {
        if (prior != null) await prior();
        await gate.pause(edge);
      };
    }
    return reflect(actual)
        .invoke(
          invocation.memberName,
          invocation.positionalArguments,
          arguments,
        )
        .reflectee;
  }

  Future<List<String>> confirm(Invocation invocation) async {
    await gate.pause('confirm-before');
    final List<String> value = await invokeWithHook(
      invocation,
      'confirm-inside',
    );
    await gate.pause('confirm-after');
    return value;
  }

  Future<int> ack(Invocation invocation) async {
    await gate.pause('ack-before');
    final int value = await invokeWithHook(invocation, 'ack-inside');
    await gate.pause('ack-after');
    return value;
  }

  Future<void> legacyAck(Invocation invocation) async {
    await gate.pause('ack-before');
    await reflect(actual).delegate(invocation);
    await gate.pause('ack-after');
  }
}

class GatedApi extends ChatApiClient {
  GatedApi({required super.baseUri, required this.gate});
  final Gate gate;

  @override
  Future<ChatMessage> sendMessage({
    required String token,
    required String targetAccount,
    required String clientNonce,
    required List<MessagePart> content,
  }) async {
    final message = await super.sendMessage(
      token: token,
      targetAccount: targetAccount,
      clientNonce: clientNonce,
      content: content,
    );
    await gate.pause('send-after-remote-commit');
    return message;
  }

  @override
  Future<MediaResponse> fetchMedia({
    required String token,
    required String mediaId,
    String? range,
  }) async {
    final response = await super.fetchMedia(
      token: token,
      mediaId: mediaId,
      range: range,
    );
    await gate.pause('download-after-fetch');
    return response;
  }
}

Future<void> main(List<String> args) async {
  final options = <String, String>{
    for (int i = 0; i < args.length; i += 2) args[i]: args[i + 1],
  };
  final sessionFile = File(options['--session-file']!);
  final gate = Gate();
  final auth = AuthService(
    api: AuthApiClient(baseUri: Uri.parse(options['--server-url']!)),
    session: AuthSession(),
    store: SessionStore(sessionFile),
  );
  final chat = ChatService(
    api: GatedApi(baseUri: Uri.parse(options['--server-url']!), gate: gate),
    session: auth.session,
    ledger: GatedLedger(
      ChatLedger.atPath('${sessionFile.parent.path}/chat-ledger.json'),
      gate,
    ),
    cacheRoot: Directory('${sessionFile.parent.path}/cache'),
    webSocketHints: false,
    eventPollInterval: const Duration(milliseconds: 100),
  );
  await auth.restoreSession();
  chat.start();
  await chat.resumeForCurrentSession();
  final local = LocalAuthServer(
    service: auth,
    chat: chat,
    port: int.parse(options['--port']!),
    onSessionEstablished: () {
      unawaited(chat.resumeForCurrentSession());
    },
  );
  await local.start();
  final control = await HttpServer.bind(
    InternetAddress.loopbackIPv4,
    int.parse(options['--control-port']!),
  );
  control.listen((request) async {
    try {
      final body = jsonDecode(
        await utf8.decoder.bind(request).join(),
      ) as Map<String, dynamic>;
      switch (request.uri.path) {
        case '/arm':
          gate.arm(body['edge'] as String);
        case '/wait':
          await gate.entered.future.timeout(const Duration(seconds: 15));
        case '/release':
          gate.release();
        case '/trace':
          break;
        default:
          throw StateError('unknown probe control');
      }
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'trace': gate.trace}));
    } catch (_) {
      request.response.statusCode = 500;
    }
    await request.response.close();
  });
  Future<void> close() async {
    gate.release();
    await control.close(force: true);
    await local.close();
    await chat.dispose();
    exit(0);
  }

  ProcessSignal.sigterm.watch().listen((_) {
    unawaited(close());
  });
  ProcessSignal.sigint.watch().listen((_) {
    unawaited(close());
  });
}
