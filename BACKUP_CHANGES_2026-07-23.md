# Backup changes log (2026-07-23)

This file tracks all edits made in priority order so the changes can be backed up safely.

## Priority 1: Build and test stability

- Fixed broken widget test in `test/widget_test.dart`.
- Replaced template counter test (referenced missing `MyApp`) with a valid render smoke test.

## Priority 2: Sensitive data protection

- Added `flutter_secure_storage` dependency in `pubspec.yaml`.
- Migrated config persistence from plain `SharedPreferences` to secure storage in:
  - `lib/services/windows_vpn_backend.dart`
  - `lib/services/android_vpn_backend.dart`
- Added transparent migration path from legacy `SharedPreferences` key `vpn_config`.
- Redacted sensitive config details in Windows logs:
  - URL now logged in masked form.
  - UUID now logged in masked form.
- Reduced Xray log level in generated config from `debug` to `warning`.

## Priority 3: Lifecycle and runtime correctness

- Converted `VpnService.setConfig` to async/await and rethrow flow in `lib/services/vpn_service.dart`.
- Added `VpnService.shutdown()` for graceful async teardown in `lib/services/vpn_service.dart`.
- Updated app exit path to await shutdown in `lib/main.dart`.
- Fixed listener leak in `lib/screens/home_screen.dart` by storing/removing listener callback.

## Priority 4: Analyzer cleanliness and UI API updates

- Replaced deprecated `withOpacity` usage with `withValues(alpha: ...)` in:
  - `lib/screens/home_screen.dart`
  - `lib/screens/config_screen.dart`
- Replaced deprecated `Switch.activeColor` with `activeThumbColor` + `activeTrackColor` in `lib/screens/home_screen.dart`.
- Fixed async context usage checks in `lib/screens/config_screen.dart` using `mounted` guard.
- Updated constructor style lint in `lib/services/tray_service.dart`.

## Priority 5: Windows privilege model alignment

- Changed default Windows execution level from elevated to regular user:
  - `windows/runner/runner.exe.manifest` (`asInvoker`)
  - `windows/runner/CMakeLists.txt` linker UAC flag (`asInvoker`)
- Updated docs to clarify admin requirement only for TUN mode in `README.md`.

## Priority 6: Android hardening and release hygiene

- Disabled cleartext traffic by default in `android/app/src/main/AndroidManifest.xml`.
- Added release signing via `key.properties` with debug fallback for local builds in `android/app/build.gradle.kts`.

## CI and automation

- Added GitHub Actions workflow in `.github/workflows/flutter-ci.yml`:
  - `flutter pub get`
  - `flutter analyze`
  - `flutter test`

## Validation results

- `flutter analyze` -> No issues found.
- `flutter test` -> All tests passed.

## Suggested backup commands

```powershell
# 1) Save patch file
cd c:\projects\vpn_client
git diff > backup-2026-07-23.patch

# 2) Optional: create local safety branch
# (no push is performed)
git checkout -b backup/2026-07-23-priority-fixes
```
