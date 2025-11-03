# Direct Drawing Generator (Flutter)

Flutter implementation of the "Direct Drawing Generator" experience documented in `k-os-ERI/data/saas/direct-drawing-generator.yaml` and the broader refactoring notes in `Refactoring_and_Feature_Additions.md`. The app reproduces the real-time drawing canvas, reference gallery workflow, and creative tools in a mobile-friendly layout.

## Features

- Real-time freehand canvas with pressure-friendly pan gestures
- Brush, eraser, and text tools with adjustable sizes and shared color palette
- Reference image import (kept as a background layer) with quick removal
- Undo / redo, clear canvas, and export-to-PNG actions
- Save and share workflow using `Share.plus`, with files persisted to documents directory on mobile/desktop
- Responsive layout that mirrors the desktop-style side panel from the YAML design

## Getting Started

```
flutter pub get
flutter run
```

The project targets Flutter 3.22+ (Dart 3.3). Ensure `flutter_colorpicker`, `file_picker`, `path_provider`, `provider`, and `share_plus` are available in your environment.

## Web Build

1. Enable web support once per machine: `flutter config --enable-web`
2. Install dependencies: `flutter pub get`
3. Start the app in Chrome: `flutter run -d chrome`
4. Produce a static bundle: `flutter build web`

The drawing tab renders on the web build with canvas, logs, and downloads. The story authoring flow and JWT vending are desktop-only; on the web the tab shows a placeholder and auth refreshers surface a polite message. Generated images and canvas exports trigger a browser download via an inline helper, so pop-up blocking or download permissions may apply.

## Project Structure

```
lib/
  app.dart                     # MaterialApp + theme setup
  main.dart                    # Entry point
  features/
    drawing/
      drawing_controller.dart  # State management for strokes, text, history
      drawing_page.dart        # UI layout & tool interactions
      models/                  # Stroke + text data classes and mode enum
      widgets/
        drawing_canvas.dart    # Custom painter + gesture layer
```

Assets placed in `assets/reference/` are bundled automatically (folder is pre-created with a `.gitkeep`).

## Testing

A smoke test is included under `test/widget_test.dart` to validate that the main scaffold renders. Run with:

```
flutter test
```

## Android Builds

- Run `ANDROID_KEYSTORE_B64` / `ANDROID_KEYSTORE_PASSWORD` / `ANDROID_KEY_ALIAS` / `ANDROID_KEY_PASSWORD` を環境変数に設定し、`ci/setup-android-signing.sh` を実行してください。初回セットアップ時に Android scaffolding を補完し、Secrets から展開した keystore で `android/app/build.gradle` を署名設定へ更新します。
- Produce release artifacts with `flutter build apk --release`. The shared keystore ensures APKs install as updates over prior builds.

## CI / CD

`.github/workflows/flutter-android.yml` で GitHub Actions を定義しています。プッシュ／プルリクエスト時に Flutter の解析・テスト・Android 用 APK ビルドを自動実行し、ビルドごとに `pubspec.yaml` のバージョンを単調増加で更新します。Android 署名鍵は GitHub Secrets (`ANDROID_KEYSTORE_B64` など) から復元しており、リポジトリに秘匿情報を含めずに既存インストールとの更新互換性を維持します。生成された APK と `version-info.txt` はワークフローのアーティファクトとして取得できます。

## Notes

- Web exports trigger a download using `lib/shared/web/file_saver.dart`; unsupported browsers will fall back to the native error snackbar.
- The controller disposes of decoded reference images to prevent leaking native textures.
- For production, consider persisting drawing sessions and adding richer history (multi-step clear undo, layer management) following the roadmap in the YAML document.



