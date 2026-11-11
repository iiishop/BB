/// Client-side mirror of the shared STEP-1 validation contract.
///
/// These rules exist for immediate inline feedback only. The server is the only
/// authority: the client never blocks on a rule the server does not enforce and
/// never invents a different message for a field the server validates.
library;

/// One validation reason, shaped like a server `fields[]` entry.
class AuthFieldIssue {
  const AuthFieldIssue({
    required this.field,
    required this.code,
    required this.message,
  });

  final String field;
  final String code;
  final String message;
}

/// Shared password / username / account rules.
abstract final class AuthRules {
  static const int usernameMinLength = 3;
  static const int usernameMaxLength = 24;
  static const int passwordMinLength = 6;

  static const String usernameLengthMessage = '用户名去除首尾空白后须为 3–24 字符';
  static const String passwordMinLengthMessage = '密码至少 6 位';
  static const String passwordUppercaseMessage = '密码必须包含大写字母';
  static const String passwordLowercaseMessage = '密码必须包含小写字母';
  static const String passwordDigitMessage = '密码必须包含数字';
  static const String accountFormatMessage = '账号必须为 8 位数字';
  static const String confirmMismatchMessage = '两次输入的密码不一致';

  static final RegExp _accountPattern = RegExp(r'^[0-9]{8}$');
  static final RegExp _uppercase = RegExp('[A-Z]');
  static final RegExp _lowercase = RegExp('[a-z]');
  static final RegExp _digit = RegExp('[0-9]');

  /// Username must be 3–24 characters after trimming; duplicates are allowed.
  static String? validateUsername(String raw) {
    final int length = raw.trim().length;
    if (length < usernameMinLength || length > usernameMaxLength) {
      return usernameLengthMessage;
    }
    return null;
  }

  /// Password is never trimmed; ASCII A–Z / a–z / 0–9 drive the checks.
  static List<AuthFieldIssue> validatePassword(String password) {
    final List<AuthFieldIssue> issues = <AuthFieldIssue>[];
    if (password.length < passwordMinLength) {
      issues.add(
        const AuthFieldIssue(
          field: 'password',
          code: 'min_length',
          message: passwordMinLengthMessage,
        ),
      );
    }
    if (!_uppercase.hasMatch(password)) {
      issues.add(
        const AuthFieldIssue(
          field: 'password',
          code: 'missing_uppercase',
          message: passwordUppercaseMessage,
        ),
      );
    }
    if (!_lowercase.hasMatch(password)) {
      issues.add(
        const AuthFieldIssue(
          field: 'password',
          code: 'missing_lowercase',
          message: passwordLowercaseMessage,
        ),
      );
    }
    if (!_digit.hasMatch(password)) {
      issues.add(
        const AuthFieldIssue(
          field: 'password',
          code: 'missing_digit',
          message: passwordDigitMessage,
        ),
      );
    }
    return issues;
  }

  /// Login account: exactly eight ASCII digits.
  static String? validateAccount(String raw) {
    if (!_accountPattern.hasMatch(raw.trim())) {
      return accountFormatMessage;
    }
    return null;
  }

  /// Confirmation is a client-only convenience; the server never receives it.
  static String? validateConfirmation({
    required String password,
    required String confirmation,
  }) {
    if (password != confirmation) {
      return confirmMismatchMessage;
    }
    return null;
  }

  /// Groups password issues by code for the live requirement checklist.
  static Set<String> passwordIssueCodes(String password) {
    return validatePassword(password)
        .map((AuthFieldIssue issue) => issue.code)
        .toSet();
  }
}
