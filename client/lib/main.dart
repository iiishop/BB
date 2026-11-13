import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'config/client_config.dart';
import 'config/session_path.dart';
import 'services/auth_api_client.dart';
import 'services/auth_service.dart';
import 'services/auth_session.dart';
import 'services/avatar_cache.dart';
import 'services/chat_api_client.dart';
import 'services/chat_ledger.dart';
import 'services/chat_service.dart';
import 'services/heartbeat_controller.dart';
import 'services/profile_api_client.dart';
import 'services/profile_service.dart';
import 'services/server_address_store.dart';
import 'services/session_store.dart';
import 'ui/server_setup_page.dart';
import 'ui/server_settings_scope.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final File sessionFile = await _resolveSessionFile();
  runApp(
    BbRoot(
      sessionFile: sessionFile,
      addressStore: ServerAddressStore(_serverAddressFile(sessionFile)),
      compiledAddress: compiledServerAddress(),
    ),
  );
}

/// Owns the chosen server address and the service stack built against it.
///
/// Address resolution order: saved value, then a compiled `BB_API_BASE_URL`,
/// then the setup screen. Changing the address tears the stack down, clears the
/// credential that belonged to the old server, and builds a new one.
class BbRoot extends StatefulWidget {
  const BbRoot({
    super.key,
    required this.sessionFile,
    required this.addressStore,
    this.compiledAddress,
  });

  final File sessionFile;
  final ServerAddressStore addressStore;
  final Uri? compiledAddress;

  @override
  State<BbRoot> createState() => _BbRootState();
}

class _BbRootState extends State<BbRoot> {
  _AppServices? _services;
  Uri? _address;
  bool _loading = true;
  bool _changing = false;

  @override
  void initState() {
    super.initState();
    unawaited(_restore());
  }

  @override
  void dispose() {
    unawaited(_services?.dispose());
    super.dispose();
  }

  Future<void> _restore() async {
    final Uri? saved = await widget.addressStore.read();
    final Uri? resolved = saved ?? widget.compiledAddress;
    if (resolved == null) {
      if (mounted) {
        setState(() => _loading = false);
      }
      return;
    }
    final _AppServices services = await _AppServices.create(
      resolved,
      widget.sessionFile,
    );
    if (!mounted) {
      await services.dispose();
      return;
    }
    setState(() {
      _services = services;
      _address = resolved;
      _loading = false;
    });
  }

  /// Persists [address] and rebuilds everything against it.
  ///
  /// Throws when the address cannot be saved so [ServerSetupPage] can report it
  /// instead of pretending the client reconnected.
  Future<void> _connect(Uri address) async {
    final _AppServices? previous = _services;
    final bool changed = address != _address;
    if (previous != null) {
      setState(() => _loading = true);
      _services = null;
      await previous.dispose();
    }
    if (changed) {
      await widget.addressStore.write(address);
      if (_address != null) {
        await _resetCredentialState(widget.sessionFile);
      }
    }
    final _AppServices services = await _AppServices.create(
      address,
      widget.sessionFile,
    );
    if (!mounted) {
      await services.dispose();
      return;
    }
    setState(() {
      _services = services;
      _address = address;
      _loading = false;
      _changing = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final _AppServices? services = _services;
    if (services != null && !_changing) {
      return ServerSettingsScope(
        onChange: () => setState(() => _changing = true),
        child: BbClientApp(
          key: ValueKey<Uri>(services.baseUri),
          authGateway: services.auth,
          profile: services.profile,
          heartbeat: services.heartbeat,
          chat: services.chat,
        ),
      );
    }
    if (_loading) {
      return MaterialApp(
        title: 'BB',
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(),
        home: const Scaffold(
          body: Center(child: CircularProgressIndicator()),
        ),
      );
    }
    return MaterialApp(
      title: 'BB',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: ServerSetupPage(
        initialAddress: _address,
        changing: _address != null,
        onSubmit: _connect,
        onCancel: _address == null ? null : () => setState(() => _changing = false),
      ),
    );
  }
}

/// The services that depend on the server address, built and disposed as one
/// unit so a server switch cannot leave the previous poller running.
class _AppServices {
  _AppServices._({
    required this.baseUri,
    required this.auth,
    required this.profile,
    required this.heartbeat,
    required this.chat,
  });

  final Uri baseUri;
  final AuthService auth;
  final ProfileService profile;
  final HeartbeatController heartbeat;
  final ChatService chat;

  static Future<_AppServices> create(Uri baseUri, File sessionFile) async {
    final AuthSession session = AuthSession();
    final AuthService auth = AuthService(
      api: AuthApiClient(baseUri: baseUri),
      session: session,
      store: SessionStore(sessionFile),
    );
    final ProfileService profile = ProfileService(
      api: ProfileApiClient(baseUri: baseUri),
      auth: auth,
      cache: AvatarCache(directory: await _avatarCacheDirectory(sessionFile)),
    );
    final HeartbeatController heartbeat = HeartbeatController(auth: auth);
    final ChatService chat = ChatService(
      api: ChatApiClient(baseUri: baseUri),
      session: session,
      ledger: ChatLedger.atPath(await _chatLedgerPath(sessionFile)),
      cacheRoot: await _chatCacheDirectory(sessionFile),
    );
    chat.start();
    return _AppServices._(
      baseUri: baseUri,
      auth: auth,
      profile: profile,
      heartbeat: heartbeat,
      chat: chat,
    );
  }

  Future<void> dispose() async {
    heartbeat.stop();
    await chat.dispose();
  }
}

/// Drops the credential and the chat ledger that belonged to the previous
/// server.
///
/// A token is only meaningful to the server that issued it, and the ledger keys
/// operations by that server's message and consumer identities. Caches are kept:
/// they are content-addressed by account and version, and re-downloading them
/// costs far more than the odd stale avatar.
Future<void> _resetCredentialState(File sessionFile) async {
  final String separator = Platform.pathSeparator;
  for (final String path in <String>[
    sessionFile.path,
    '${sessionFile.parent.path}$separator${chatLedgerFileName()}',
  ]) {
    try {
      final File file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    } on FileSystemException {
      // Leaving the file behind makes the next restore fail closed with a 401
      // and a fresh login; there is no safe recovery to attempt here.
    }
  }
}

String chatLedgerFileName() => 'chat-ledger.json';

File _serverAddressFile(File sessionFile) {
  return File(
    '${sessionFile.parent.path}${Platform.pathSeparator}server.json',
  );
}

/// Session file location.
///
/// Desktop keeps the resolver shared with the standalone Dart entry so both
/// processes read the same credential. Android/iOS have no home directory in
/// pure Dart, so the Flutter app resolves the platform app-support directory.
/// `BB_SESSION_FILE` still overrides everything.
Future<File> _resolveSessionFile() async {
  final String? override = sessionFileFromEnvironment();
  if (override != null) {
    return File(override).absolute;
  }
  if (Platform.isAndroid || Platform.isIOS) {
    final Directory directory = await getApplicationSupportDirectory();
    return File('${directory.path}${Platform.pathSeparator}session.json');
  }
  return File(defaultDesktopSessionFilePath());
}

Future<String> _chatLedgerPath(File sessionFile) async {
  return '${sessionFile.parent.path}${Platform.pathSeparator}'
      '${chatLedgerFileName()}';
}

Future<Directory> _chatCacheDirectory(File sessionFile) async {
  const String compiled = String.fromEnvironment('BB_CHAT_CACHE_DIR');
  final String? override = compiled.trim().isNotEmpty
      ? compiled.trim()
      : Platform.environment['BB_CHAT_CACHE_DIR']?.trim();
  if (override != null && override.isNotEmpty) {
    return Directory(override);
  }
  return Directory(
    '${sessionFile.parent.path}${Platform.pathSeparator}chat-cache',
  );
}

/// Avatar cache lives next to the session by default so it is per-install and
/// never a hardcoded path.
Future<Directory> _avatarCacheDirectory(File sessionFile) async {
  const String compiled = String.fromEnvironment('BB_AVATAR_CACHE_DIR');
  final String? override = compiled.trim().isNotEmpty
      ? compiled.trim()
      : Platform.environment['BB_AVATAR_CACHE_DIR']?.trim();
  if (override != null && override.isNotEmpty) {
    return Directory(override);
  }
  return Directory(
    '${sessionFile.parent.path}${Platform.pathSeparator}avatar-cache',
  );
}
