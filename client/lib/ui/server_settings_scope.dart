import 'package:flutter/widgets.dart';

/// Exposes the "change server" action to any screen below the bootstrap.
///
/// An inherited widget rather than a constructor-parameter chain: the login
/// footer is the only consumer today, and the alternative is threading a
/// callback through `BbClientApp` → `AuthFlow` → `LoginPage` for one button.
class ServerSettingsScope extends InheritedWidget {
  const ServerSettingsScope({
    super.key,
    required this.onChange,
    required super.child,
  });

  final VoidCallback onChange;

  static VoidCallback? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<ServerSettingsScope>()
        ?.onChange;
  }

  @override
  bool updateShouldNotify(ServerSettingsScope oldWidget) =>
      onChange != oldWidget.onChange;
}
