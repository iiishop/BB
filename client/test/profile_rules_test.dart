import 'dart:convert';
import 'dart:io';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/validation/profile_rules.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Unicode code point counting', () {
    test('counts code points, not UTF-16 units', () {
      expect(codePointLength('abc'), 3);
      expect(codePointLength('🌏'), 1);
      expect(codePointLength('a🌏b'), 3);
      expect('🌏'.length, 2, reason: 'UTF-16 would over-count emoji');
    });
  });

  group('nickname rules', () {
    test('trims and accepts 3–24 code points', () {
      expect(normalizeUsername('  Alice  '), 'Alice');
      expect(normalizeUsername('🌏🌏🌏'), '🌏🌏🌏');
      expect(normalizeUsername('🌏' * 24), '🌏' * 24);
    });

    test('rejects short, long and null', () {
      expect(_code(() => normalizeUsername('ab')), 'length');
      expect(_code(() => normalizeUsername('x' * 25)), 'length');
      expect(_code(() => normalizeUsername('   ')), 'length');
      expect(_code(() => normalizeUsername(null)), 'type');
    });
  });

  group('signature rules', () {
    test('trims, accepts 49 and clears empty/null', () {
      expect(normalizeSignature('  你好🌏  '), '你好🌏');
      expect(normalizeSignature('🌏' * 49), '🌏' * 49);
      expect(normalizeSignature(null), isNull);
      expect(normalizeSignature(' \t '), isNull);
    });

    test('rejects 50 code points', () {
      expect(_code(() => normalizeSignature('🌏' * 50)), 'length');
    });
  });

  group('account rules', () {
    test('accepts eight ASCII digits and absent/null', () {
      expect(normalizeAccount('12345678'), '12345678');
      expect(normalizeAccount(null), isNull);
    });

    test('rejects full-width digits and wrong lengths', () {
      expect(_code(() => normalizeAccount('１２３４５６７８')), 'format');
      expect(_code(() => normalizeAccount('1234567')), 'format');
    });
  });

  group('avatar source rules', () {
    test('detects absolute POSIX and Windows paths', () {
      expect(isAbsoluteAvatarPath('/synthetic/avatar.png'), isTrue);
      expect(isAbsoluteAvatarPath(r'C:\synthetic\avatar.png'), isTrue);
      expect(isAbsoluteAvatarPath(r'C:/synthetic/avatar.png'), isTrue);
      expect(isAbsoluteAvatarPath('relative.png'), isFalse);
    });

    test('accepts http/https URLs only, without credentials', () {
      expect(isSupportedAvatarUrl('https://example.invalid/x.png'), isTrue);
      expect(isSupportedAvatarUrl('http://127.0.0.1:8000/x'), isTrue);
      expect(isSupportedAvatarUrl('file:///tmp/x.png'), isFalse);
      expect(
        isSupportedAvatarUrl('https://user:pass@example.invalid/x'),
        isFalse,
      );
    });

    test('requires exactly one source, counting null-valued keys', () {
      expect(
        _code(() => resolveAvatarSource(<String, dynamic>{})),
        'one_source',
      );
      expect(
        _code(
          () => resolveAvatarSource(<String, dynamic>{
            'path': '/x',
            'url': 'https://example.invalid/x',
          }),
        ),
        'one_source',
      );
      expect(
        _code(
          () => resolveAvatarSource(<String, dynamic>{
            'base64': 'a',
            'path': null,
          }),
        ),
        'one_source',
      );
    });

    test('rejects relative path, non-http url and empty base64', () {
      expect(
        _code(
          () => resolveAvatarSource(<String, dynamic>{'path': 'relative.png'}),
        ),
        'format',
      );
      expect(
        _code(
          () => resolveAvatarSource(<String, dynamic>{'url': 'file:///tmp/x'}),
        ),
        'format',
      );
      expect(
        _code(() => resolveAvatarSource(<String, dynamic>{'base64': ''})),
        'required',
      );
      expect(
        _code(() => resolveAvatarSource(<String, dynamic>{'base64': null})),
        'required',
      );
    });
  });

  group('shared contract cases (server/contract/profile-cases.json)', () {
    final File file = File('../server/contract/profile-cases.json');
    final List<dynamic> cases =
        jsonDecode(file.readAsStringSync()) as List<dynamic>;

    test('the shared corpus has 49 cases', () {
      expect(cases, hasLength(49));
    });

    for (final Object? entry in cases) {
      final Map<String, dynamic> testCase = entry! as Map<String, dynamic>;
      test('${testCase['id']} (${testCase['operation']})', () {
        final String operation = testCase['operation']! as String;
        final Map<String, dynamic> input =
            (testCase['input'] as Map<String, dynamic>?) ?? <String, dynamic>{};
        final Map<String, dynamic>? expected =
            testCase['normalized'] as Map<String, dynamic>?;
        final int? expectedStatus = testCase['status'] as int?;
        final String? expectedFieldCode = testCase['field_code'] as String?;

        Map<String, dynamic>? result;
        AuthFailure? failure;
        try {
          result = _applyCase(operation, input);
        } on AuthFailure catch (error) {
          failure = error;
        }

        if (expectedStatus != null) {
          expect(failure, isNotNull, reason: 'expected a typed failure');
          expect(failure!.status, expectedStatus);
          expect(
            failure.fields.map((AuthFieldError f) => f.code),
            contains(expectedFieldCode),
          );
        } else {
          expect(failure, isNull, reason: 'unexpected failure: $failure');
          expect(result, expected);
        }
      });
    }
  });
}

Map<String, dynamic> _applyCase(String operation, Map<String, dynamic> input) {
  switch (operation) {
    case 'patch_profile':
      _rejectExtra(input, const <String>{'username', 'signature'});
      final Map<String, dynamic> out = <String, dynamic>{};
      if (input.containsKey('username')) {
        out['username'] = normalizeUsername(input['username'] as String?);
      }
      if (input.containsKey('signature')) {
        out['signature'] = normalizeSignature(input['signature'] as String?);
      }
      return out;
    case 'view_avatar':
    case 'view_nickname':
    case 'view_signature':
      _rejectExtra(input, const <String>{'account'});
      final Map<String, dynamic> out = <String, dynamic>{};
      if (input.containsKey('account')) {
        out['account'] = normalizeAccount(input['account'] as String?);
      }
      return out;
    case 'update_nickname':
      _rejectExtra(input, const <String>{'value'});
      if (!input.containsKey('value')) {
        throw _field('value', 'required');
      }
      return <String, dynamic>{
        'value': normalizeUsername(input['value'] as String?),
      };
    case 'update_signature':
      _rejectExtra(input, const <String>{'value'});
      return <String, dynamic>{
        'value': normalizeSignature(input['value'] as String?),
      };
    case 'update_avatar':
      _rejectExtra(input, <String>{'path', 'url', 'base64'});
      final ({String source, String value}) resolved = resolveAvatarSource(
        input,
      );
      return <String, dynamic>{resolved.source: resolved.value};
    default:
      throw StateError('unknown operation $operation');
  }
}

void _rejectExtra(Map<String, dynamic> input, Set<String> allowed) {
  for (final String key in input.keys) {
    if (!allowed.contains(key)) {
      throw _field(key, 'extra');
    }
  }
}

AuthFailure _field(String field, String code) => AuthFailure(
  status: 422,
  code: 'validation_error',
  message: '输入有误',
  fields: <AuthFieldError>[
    AuthFieldError(field: field, code: code, message: 'invalid'),
  ],
);

String? _code(void Function() action) {
  try {
    action();
  } on AuthFailure catch (failure) {
    return failure.fields.first.code;
  }
  return null;
}
