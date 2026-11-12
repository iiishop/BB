import 'dart:math';

import '../models/auth_models.dart';

/// Error code identifying a request made with an identity that is no longer
/// the client's current login (account, auth generation or re-login).
const String staleIdentityCode = 'stale_identity';

/// Error code identifying a consumer/binding conflict: the consumer belongs to
/// another account, the binding revision moved, or an exclusive owner lost a
/// version comparison.
const String staleBindingCode = 'stale_binding';

/// Error code identifying a missing display fact before an ACK.
const String consumptionGapCode = 'consumption_gap';

/// Error code identifying old consumption state that cannot be migrated
/// without inventing evidence.
const String migrationRequiredCode = 'migration_required';

const AuthFailure staleIdentity = AuthFailure(
  status: 409,
  code: staleIdentityCode,
  message: '身份已变化，旧请求不能继续，请重新登录或显式重绑',
);

AuthFailure staleBinding(String message) => AuthFailure(
  status: 409,
  code: staleBindingCode,
  message: message,
);

AuthFailure consumptionGap(String message, {List<AuthFieldError> fields = const <AuthFieldError>[]}) =>
    AuthFailure(
      status: 409,
      code: consumptionGapCode,
      message: message,
      fields: fields,
    );

AuthFailure migrationRequired(String message, {List<AuthFieldError> fields = const <AuthFieldError>[]}) =>
    AuthFailure(
      status: 409,
      code: migrationRequiredCode,
      message: message,
      fields: fields,
    );

/// Client-issued identity metadata attached to one protected v2 call.
///
/// It carries no credential: `account` is the authenticated account (business
/// parameters keep using `account` for the peer), `auth_generation` is an
/// opaque value that changes on every login/restore and never restarts from a
/// zero counter, `consumer_id` is the client-persisted stable consumer, and
/// `binding_revision` increases whenever the consumer's binding changes.
class ExpectedIdentity {
  const ExpectedIdentity({
    required this.account,
    required this.authGeneration,
    required this.consumerId,
    required this.bindingRevision,
  });

  final String account;
  final String authGeneration;
  final String consumerId;
  final int bindingRevision;

  static final RegExp _accountPattern = RegExp(r'^\d{8}$');
  static final RegExp _opaquePattern = RegExp(r'^[A-Za-z0-9._:-]{1,128}$');

  static bool isValidAccount(String value) => _accountPattern.hasMatch(value);

  static bool isValidOpaque(String value) =>
      value.isNotEmpty && _opaquePattern.hasMatch(value);

  /// Returns whether both objects describe exactly the same identity.
  ///
  /// A re-login (A→B→A and same-account re-login alike) changes
  /// [authGeneration], so an identity captured before the switch never matches
  /// again.
  bool matches(ExpectedIdentity? other) {
    return other != null &&
        other.account == account &&
        other.authGeneration == authGeneration &&
        other.consumerId == consumerId &&
        other.bindingRevision == bindingRevision;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'account': account,
    'auth_generation': authGeneration,
    'consumer_id': consumerId,
    'binding_revision': bindingRevision,
  };

  factory ExpectedIdentity.fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      throw const FormatException('expected_identity must be an object');
    }
    final Object? account = json['account'];
    final Object? authGeneration = json['auth_generation'];
    final Object? consumerId = json['consumer_id'];
    final Object? bindingRevision = json['binding_revision'];
    if (account is! String ||
        !isValidAccount(account) ||
        authGeneration is! String ||
        !isValidOpaque(authGeneration) ||
        consumerId is! String ||
        !isValidOpaque(consumerId) ||
        bindingRevision is! int ||
        bindingRevision < 1) {
      throw const FormatException('expected_identity has invalid fields');
    }
    return ExpectedIdentity(
      account: account,
      authGeneration: authGeneration,
      consumerId: consumerId,
      bindingRevision: bindingRevision,
    );
  }

  static ExpectedIdentity? tryParse(Object? json) {
    try {
      return ExpectedIdentity.fromJson(json);
    } on FormatException {
      return null;
    }
  }

  @override
  String toString() =>
      'ExpectedIdentity($account,$consumerId@$bindingRevision)';
}

/// One stable client consumer and its current account binding.
///
/// The consumer id survives re-login and host-session rebuilds; the binding
/// revision increases whenever the account/auth generation behind it changes.
class ConsumerBinding {
  const ConsumerBinding({
    required this.consumerId,
    required this.account,
    required this.authGeneration,
    required this.bindingRevision,
    this.aliases = const <String>{},
  });

  final String consumerId;
  final String account;
  final String authGeneration;
  final int bindingRevision;

  /// Client-owned `(account, legacy consumer_session)` aliases that resolve to
  /// this consumer. They are never credentials.
  final Set<String> aliases;

  ExpectedIdentity get identity => ExpectedIdentity(
    account: account,
    authGeneration: authGeneration,
    consumerId: consumerId,
    bindingRevision: bindingRevision,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'consumer_id': consumerId,
    'account': account,
    'auth_generation': authGeneration,
    'binding_revision': bindingRevision,
    'aliases': aliases.toList()..sort(),
  };

  @override
  String toString() => 'ConsumerBinding($consumerId,$account@$bindingRevision)';
}

final Random _random = Random.secure();

String _randomHex(int bytes) {
  final StringBuffer buffer = StringBuffer();
  for (int i = 0; i < bytes; i++) {
    buffer.write(_random.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

/// New opaque authentication generation. It is random per login, so a process
/// restart can never resurrect a previous generation from a zero counter.
String newAuthGeneration() => 'g-${_randomHex(16)}';

/// New stable opaque consumer id generated by the client.
String newConsumerId() => 'c-${_randomHex(16)}';
