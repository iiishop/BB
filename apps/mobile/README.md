# bb_mobile

BB social platform Flutter client. This first increment is the pipeline smoke
surface used to verify build, widget tests and Linux integration tests.

## Run

```bash
flutter pub get
flutter run -d linux
```

The window opens on the **Pipeline Smoke** page: status `Ready`, one primary
action `Run smoke check` which switches the status to `Smoke check complete`.
The action is focusable and activates with Enter or Space.

## Test

```bash
flutter analyze
flutter test
flutter test integration_test -d linux

# from the repository root, strict QA runner
QA_REQUIRE_WIDGET_TESTS=1 QA_REQUIRE_INTEGRATION=1 \
  bash scripts/run_flutter_tests.sh apps/mobile
```

Android platform files are generated so the client can target real devices, but
no Android device or emulator is available in this environment — Android
execution is **NOT RUN**.
