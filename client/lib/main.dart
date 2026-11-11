import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'config/client_config.dart';
import 'config/session_path.dart';
import 'services/auth_api_client.dart';
import 'services/auth_service.dart';
import 'services/auth_session.dart';
import 'services/session_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final ClientConfig config = ClientConfig.fromEnvironment();
  final AuthService service = AuthService(
    api: AuthApiClient(baseUri: config.serverBaseUri),
    session: AuthSession(),
    store: SessionStore(await _resolveSessionFile()),
  );
  runApp(BbClientApp(authGateway: service));
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
