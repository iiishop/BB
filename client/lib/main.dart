import 'package:flutter/material.dart';

import 'app.dart';
import 'services/auth_api_client.dart';
import 'services/auth_service.dart';
import 'services/auth_session.dart';
import 'config/client_config.dart';

void main() {
  final ClientConfig config = ClientConfig.fromEnvironment();
  final AuthService service = AuthService(
    api: AuthApiClient(baseUri: config.serverBaseUri),
    session: AuthSession(),
  );
  runApp(BbClientApp(authGateway: service));
}
