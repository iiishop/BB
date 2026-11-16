import 'dart:convert';
import 'dart:typed_data';

import 'package:bb_client/ui/profile/avatar_picker.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/avatar_fixtures.dart';

/// DEA-482: extension and magic bytes are not enough. The real engine decoder
/// is exercised here (plain `test` = real async) so the dialog can reject a
/// truncated PNG that still starts with the PNG signature.
void main() {
  test('accepts a real PNG fixture', () async {
    expect(await isDecodableAvatarImage(peerReplacedAvatar), isTrue);
    expect(await isDecodableAvatarImage(selfIdenticon), isTrue);
  });

  test('rejects truncated, non-image and empty bytes', () async {
    expect(
      await isDecodableAvatarImage(peerReplacedAvatar.sublist(0, 20)),
      isFalse,
      reason: 'PNG signature present but the stream is truncated',
    );
    expect(
      await isDecodableAvatarImage(
        Uint8List.fromList(utf8.encode('plain text')),
      ),
      isFalse,
    );
    expect(await isDecodableAvatarImage(Uint8List(0)), isFalse);
  });
}
