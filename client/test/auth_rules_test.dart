import 'package:bb_client/validation/auth_rules.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('username', () {
    test('accepts 3–24 characters after trimming', () {
      expect(AuthRules.validateUsername('muse'), isNull);
      expect(AuthRules.validateUsername('  muse  '), isNull);
      expect(AuthRules.validateUsername('a' * 24), isNull);
    });

    test('rejects too short and too long values with the contract message', () {
      expect(AuthRules.validateUsername(''), AuthRules.usernameLengthMessage);
      expect(AuthRules.validateUsername('ab'), AuthRules.usernameLengthMessage);
      expect(
        AuthRules.validateUsername('a' * 25),
        AuthRules.usernameLengthMessage,
      );
      expect(AuthRules.usernameLengthMessage, '用户名去除首尾空白后须为 3–24 字符');
    });
  });

  group('password', () {
    test('returns no issues for an ASCII upper/lower/digit password', () {
      expect(AuthRules.validatePassword('Secret42'), isEmpty);
    });

    test('reports every missing reason with the fixed code and message', () {
      final List<AuthFieldIssue> issues = AuthRules.validatePassword('abc');

      expect(issues.map((AuthFieldIssue issue) => issue.code), <String>[
        'min_length',
        'missing_uppercase',
        'missing_digit',
      ]);
      expect(issues.map((AuthFieldIssue issue) => issue.message), <String>[
        '密码至少 6 位',
        '密码必须包含大写字母',
        '密码必须包含数字',
      ]);
    });

    test('is not trimmed and requires ASCII letters', () {
      expect(
        AuthRules.validatePassword('  Abc123 ').isEmpty,
        isTrue,
        reason: 'spaces are characters; the server does not trim passwords',
      );
      expect(
        AuthRules.validatePassword('Äbc123').map((AuthFieldIssue i) => i.code),
        contains('missing_uppercase'),
      );
    });

    test('exposes the live checklist codes', () {
      expect(AuthRules.passwordIssueCodes(''), <String>{
        'min_length',
        'missing_uppercase',
        'missing_lowercase',
        'missing_digit',
      });
      expect(AuthRules.passwordIssueCodes('Secret42'), isEmpty);
    });
  });

  group('account', () {
    test('requires exactly eight ASCII digits', () {
      expect(AuthRules.validateAccount('87654321'), isNull);
      expect(AuthRules.validateAccount('01234567'), isNull);
      expect(
        AuthRules.validateAccount('1234567'),
        AuthRules.accountFormatMessage,
      );
      expect(
        AuthRules.validateAccount('123456789'),
        AuthRules.accountFormatMessage,
      );
      expect(
        AuthRules.validateAccount('abcdefgh'),
        AuthRules.accountFormatMessage,
      );
      expect(AuthRules.accountFormatMessage, '账号必须为 8 位数字');
    });
  });

  test('confirmation is a client-only rule', () {
    expect(
      AuthRules.validateConfirmation(
        password: 'Secret42',
        confirmation: 'Secret42',
      ),
      isNull,
    );
    expect(
      AuthRules.validateConfirmation(
        password: 'Secret42',
        confirmation: 'secret42',
      ),
      '两次输入的密码不一致',
    );
  });
}
