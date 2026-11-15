# UpdateInstaller JVM contract regressions

This compiles the **production** `UpdateInstaller.kt` against narrow test-only
Android/Flutter API doubles, derived from Sentinel's DEA-479 counterexample.
They are outside the app source sets and never enter an APK. No new library or
plugin is installed: the compiler/stdlib come from the pinned Gradle wrapper.

Run after Flutter has generated its Android wrapper/local configuration:

```sh
flutter build apk --release --target-platform android-arm64
cd android
./gradlew :app:testUpdateInstaller
```

The task also belongs to `:app:check` and runs in the existing Android CI job,
after its existing APK build. It adds no emulator or second APK build. Local
Gradle execution took 23s before the fix and 13s after it (warm compiler/build
dependencies); these measurements do not predict cold CI startup costs.

The PackageManager double populates certificate fields **only if requested**,
as specified by [PackageInfo](https://developer.android.com/reference/android/content/pm/PackageInfo#signingInfo).
On simulated API 24/27, access to `longVersionCode` or `signingInfo` throws an
API linkage error; both were introduced at API 28. API 28/35 additionally check
the modern path, including versionCodeMajor bits. Cases cover availability,
same-signer upgrade and result confirmation, foreign/missing signatures,
wrong package, equal/older versions, and unknown-source admission.

The baseline d138a36 fails 22 of 36 cases: missing installed-package flags reject
valid upgrades, and unguarded API-28 version reads fail on older hosts. All 36
pass after the fix; no assertion was loosened. This is a JVM business-code/API
contract test, **not** a real PackageManager, APK parser, Android OS, permission
screen, or device installation test. Device evidence remains separately NOT RUN.
