import 'dart:convert';
import 'dart:io';

import '../config/client_config.dart';

/// Persists the server address the user picked on first launch.
///
/// This is not a credential, so unlike [SessionStore] it stays deliberately
/// small: no generation counter, no atomic replace, no backup. A truncated or
/// hand-edited file is treated as "not configured", which brings the setup
/// screen back instead of blocking startup.
class ServerAddressStore {
  ServerAddressStore(this.file);

  ServerAddressStore.atPath(String path) : this(File(path));

  final File file;

  static const String serverUrlKey = 'server_url';

  /// The saved address, or null when nothing usable is stored.
  Future<Uri?> read() async {
    try {
      if (!await file.exists()) {
        return null;
      }
      final Object? decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) {
        return null;
      }
      final Object? raw = decoded[serverUrlKey];
      if (raw is! String || raw.trim().isEmpty) {
        return null;
      }
      return parseServerBaseUrl(raw);
    } on FormatException {
      return null;
    } on ArgumentError {
      // A file written by hand or by an older build can hold a value this
      // build rejects; that is "not configured", not a startup failure.
      return null;
    } on FileSystemException {
      return null;
    }
  }

  /// Saves [address]; the parent directory is created on demand.
  Future<void> write(Uri address) async {
    await file.parent.create(recursive: true);
    await file.writeAsString(
      jsonEncode(<String, String>{serverUrlKey: address.toString()}),
      flush: true,
    );
  }
}
