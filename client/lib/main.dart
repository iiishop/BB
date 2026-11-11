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
import 'services/heartbeat_controller.dart';
import 'services/profile_api_client.dart';
import 'services/profile_service.dart';
import 'services/session_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final ClientConfig config = ClientConfig.fromEnvironment();
  final File sessionFile = await _resolveSessionFile();
  final AuthSession session = AuthSession();
  final AuthService auth = AuthService(
    api: AuthApiClient(baseUri: config.serverBaseUri),
    session: session,
    store: SessionStore(sessionFile),
  );
  final ProfileService profile = ProfileService(
    api: ProfileApiClient(baseUri: config.serverBaseUri),
    auth: auth,
    cache: AvatarCache(directory: await _avatarCacheDirectory(sessionFile)),
  );
  final HeartbeatController heartbeat = HeartbeatController(auth: auth);

  runApp(
    BbClientApp(authGateway: auth, profile: profile, heartbeat: heartbeat),
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
    return File(override);
  }
  if (Platform.isAndroid || Platform.isIOS) {
    final Directory directory = await getApplicationSupportDirectory();
    return File('${directory.path}${Platform.pathSeparator}session.json');
  }
  return File(defaultDesktopSessionFilePath());
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
