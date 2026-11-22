import 'package:bb_client/ui/profile/profile_panel.dart';
import 'package:flutter_test/flutter_test.dart';

/// Opens the phone Profile edit sheet.
///
/// DEA-492 replaced the inline avatar/nickname/signature controls on the phone
/// page with a single 编辑资料 entry; the actions behind it are unchanged.
Future<void> openProfileEditSheet(WidgetTester tester) async {
  expect(
    find.byKey(ProfilePanel.editProfileKey),
    findsOneWidget,
    reason: 'phone page must offer the 编辑资料 entry',
  );
  await tester.ensureVisible(find.byKey(ProfilePanel.editProfileKey));
  await tester.tap(find.byKey(ProfilePanel.editProfileKey));
  await tester.pumpAndSettle();
}
