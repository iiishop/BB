import 'package:bb_client/services/client_identity.dart';
import 'package:flutter_test/flutter_test.dart';

/// Strict wire validation for the shared `expected_identity` / owner capability
/// shapes (`chat_v2.py`: Opaque 1..200 `[A-Za-z0-9_-]`, account
/// `^[1-9][0-9]{7}$`, revision 1..2^53-1, owner key 43 base64url chars).
void main() {
  Map<String, dynamic> valid() => <String, dynamic>{
    'account': '10000001',
    'auth_generation': 'g-abc_DEF-123',
    'consumer_id': 'c-abc_DEF-123',
    'binding_revision': 1,
  };

  test('accepts a well-formed identity and round-trips it', () {
    final ExpectedIdentity identity = ExpectedIdentity.fromJson(valid());
    expect(identity.account, '10000001');
    expect(identity.authGeneration, 'g-abc_DEF-123');
    expect(identity.consumerId, 'c-abc_DEF-123');
    expect(identity.bindingRevision, 1);
    expect(ExpectedIdentity.fromJson(identity.toJson()).matches(identity), isTrue);
  });

  test('rejects unknown fields instead of ignoring them', () {
    expect(
      () => ExpectedIdentity.fromJson(<String, dynamic>{
        ...valid(),
        'extra': true,
      }),
      throwsFormatException,
    );
    expect(
      () => ExpectedIdentity.fromJson(<String, dynamic>{
        ...valid(),
        'session_id': 'x',
      }),
      throwsFormatException,
    );
  });

  test('rejects non-contract account strings', () {
    for (final String account in <String>[
      '01234567',
      '1234567',
      '123456789',
      'abcdefgh',
      '1000000 ',
    ]) {
      expect(
        () => ExpectedIdentity.fromJson(<String, dynamic>{
          ...valid(),
          'account': account,
        }),
        throwsFormatException,
        reason: account,
      );
    }
  });

  test('rejects opaque values outside [A-Za-z0-9_-]{1,200}', () {
    for (final String value in <String>[
      '',
      'has.dot',
      'has:colon',
      'has space',
      'has/slash',
      'a' * 201,
    ]) {
      expect(
        () => ExpectedIdentity.fromJson(<String, dynamic>{
          ...valid(),
          'auth_generation': value,
        }),
        throwsFormatException,
        reason: value,
      );
      expect(
        () => ExpectedIdentity.fromJson(<String, dynamic>{
          ...valid(),
          'consumer_id': value,
        }),
        throwsFormatException,
        reason: value,
      );
    }
    expect(
      ExpectedIdentity.fromJson(<String, dynamic>{
        ...valid(),
        'auth_generation': 'a' * 200,
      }).authGeneration,
      'a' * 200,
    );
  });

  test('rejects revisions outside 1..2^53-1 and non-ints', () {
    for (final Object? revision in <Object?>[
      0,
      -1,
      maxBindingRevision + 1,
      true,
      '1',
      1.0,
      null,
    ]) {
      expect(
        () => ExpectedIdentity.fromJson(<String, dynamic>{
          ...valid(),
          'binding_revision': revision,
        }),
        throwsFormatException,
        reason: '$revision',
      );
    }
    expect(
      ExpectedIdentity.fromJson(<String, dynamic>{
        ...valid(),
        'binding_revision': maxBindingRevision,
      }).bindingRevision,
      maxBindingRevision,
    );
  });

  test('owner capability is 43 base64url chars and only its hash persists', () {
    final String key = newOwnerKey();
    expect(key, hasLength(43));
    expect(isValidOwnerKey(key), isTrue);
    expect(isValidOwnerKey('A' * 42), isFalse);
    expect(isValidOwnerKey('A' * 44), isFalse);
    expect(isValidOwnerKey('A' * 43 + '.'), isFalse);
    final String hash = ownerKeyHash(key);
    expect(hash, matches(RegExp(r'^[a-f0-9]{64}$')));
    expect(hash, ownerKeyHash(key));
    expect(hash, isNot(contains(key)));
  });
}
