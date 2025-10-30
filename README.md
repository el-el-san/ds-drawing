# Direct Drawing Generator

Flutter製の描画・AI画像/動画生成アプリケーション

![Flutter](https://img.shields.io/badge/Flutter-3.22.2-02569B?logo=flutter)
![Dart](https://img.shields.io/badge/Dart-3.3+-0175C2?logo=dart)
![License](https://img.shields.io/badge/License-MIT-green)

## 概要

Direct Drawing Generatorは、リアルタイム描画キャンバスとAI画像/動画生成機能を組み合わせたクリエイティブ制作支援ツールです。MCP (Model Context Protocol) を使用してAIサービスと連携し、描画の編集や動画生成を行います。

### 主な機能

#### 📝 Drawing タブ - リアルタイム描画 & AI画像生成
- **描画ツール**
  - ブラシ、消しゴム、テキスト配置
  - カラーパレットとサイズ調整
  - Undo/Redo機能
  - リファレンス画像の背景表示

- **AI画像生成**
  - **Nano Banana Edit**: 描画内容に基づく画像編集
  - **Seedream**: 高解像度画像生成（最大2倍アップスケール）
  - プロンプトによる編集指示
  - 生成結果のギャラリー表示とリファレンス読み込み

- **出力機能**
  - PNG形式での保存
  - 共有機能（Share Plus）
  - 状態の自動保存と復元

#### 🎬 Story タブ - テキストから動画生成 (Sora)
- **動画生成機能**
  - プロンプトベースの動画生成
  - モデル選択（sora-2 / sora-2-pro）
  - 動画長設定（4秒 / 8秒 / 12秒）
  - 解像度設定（1280x720 / 720x1280 / 1920x1080 / 1080x1920）

- **高度な機能**
  - **i2v (Image to Video)**: 開始フレーム画像から動画生成
  - **Remixモード**: 既存動画を元に編集
  - 参照画像のアップロード
  - 動画のダウンロードとプレビュー
  - リアルタイムログ表示

#### ⚙️ Settings タブ - サーバー設定
- **MCPサーバー設定**
  - Nano Banana MCP URL（画像編集AI）
  - Seedream MCP URL（高解像度画像生成AI）
  - Sora MCP URL（動画生成AI）
  - Veo MCP URL（動画生成AI）

- **アップロードAPI設定**（ビルド時に自動設定）
  - Upload Endpoint（画像アップロード用）
  - Upload Auth Endpoint（認証トークン取得用）
  - Upload Turnstile URL（Cloudflare Turnstile検証用）

- **動画ダウンロードAPI設定**
  - Story Gen API Base URL（動画ダウンロード用）

- **認証設定**（任意）
  - Upload Authorization（アップロード認証ヘッダー）
  - MCP Authorization（MCP認証ヘッダー）

## 技術スタック

- **Flutter**: 3.22.2
- **Dart**: 3.3+
- **プロトコル**: MCP (Model Context Protocol) - JSON-RPC 2.0
- **状態管理**: Provider + ChangeNotifier
- **永続化**: SharedPreferences
- **ビルド**: GitHub Actions (Android APK / Windows x64 MSIX)

### 主要な依存関係

```yaml
dependencies:
  flutter: ^3.22.2
  flutter_colorpicker: ^1.0.3
  provider: ^6.1.2
  path_provider: ^2.1.2
  file_picker: ^6.1.1
  share_plus: ^7.2.1
  collection: ^1.18.0
  http: ^1.2.0
  http_parser: ^4.0.2
  shared_preferences: ^2.2.2
  video_player: ^2.8.1
  image: ^4.1.7
  uuid: ^4.5.0
```

## プロジェクト構造

```
ds-draw/
├── .github/
│   └── workflows/
│       ├── flutter-android-openci.yml   # Android APK ビルド（OpenCI）
│       ├── flutter-android-release.yml  # Android APK リリース
│       ├── flutter-windows-x64.yml      # Windows x64 MSIX ビルド
│       └── flutter-windows-release.yml  # Windows x64 MSIX リリース
├── install-msix.ps1                     # Windows MSIX インストールスクリプト
├── flutter/
│   └── direct_drawing_generator/
│       ├── lib/
│       │   ├── app.dart                  # MaterialApp + テーマ設定
│       │   ├── main.dart                 # エントリーポイント
│       │   ├── features/
│       │   │   ├── drawing/              # 描画機能
│       │   │   │   ├── drawing_controller.dart
│       │   │   │   ├── drawing_page.dart
│       │   │   │   ├── models/           # データモデル
│       │   │   │   ├── services/         # MCP通信、画像アップロード
│       │   │   │   └── widgets/          # 描画キャンバス
│       │   │   ├── story/                # 動画生成機能
│       │   │   │   ├── story_controller.dart
│       │   │   │   ├── story_page.dart
│       │   │   │   ├── models/           # シーンモデル
│       │   │   │   └── image_crop_helper.dart
│       │   │   ├── settings/             # 設定画面
│       │   │   │   └── settings_page.dart
│       │   │   └── home/                 # ホーム画面（タブコントローラー）
│       │   │       └── home_page.dart
│       │   └── shared/                   # 共有コンポーネント
│       │       └── app_settings_controller.dart
│       ├── android/                      # Android固有設定
│       ├── windows/                      # Windows固有設定
│       ├── assets/                       # 静的アセット
│       │   └── reference/                # リファレンス画像用
│       ├── pubspec.yaml                  # 依存関係定義
│       └── README.md                     # プロジェクト固有のREADME
├── CLAUDE.md                             # Claude コーディングガイドライン
├── AGENTS.md                             # AIエージェント設定
└── README.md                             # このファイル
```


## トラブルシューティング

### 1. AI画像生成が失敗する

**原因**: MCPサーバーが起動していない、または設定が間違っている

**解決策**:
- Settings タブで `接続テスト` を実行
- MCPサーバーのURLが正しいか確認
- MCPサーバーが起動しているか確認
- 認証ヘッダーが必要な場合は設定

### 2. 動画生成がタイムアウトする

**原因**: Soraの処理に時間がかかっている

**解決策**:
- ログを確認して現在のステータスを把握
- タイムアウト時間を超えた場合、Video IDをメモしてRemixモードで再実行

### 3. リファレンス画像が表示されない

**原因**: 画像の読み込みに失敗した

**解決策**:
- サポートされている画像形式（PNG、JPEG、WebP）を使用
- ファイルサイズが大きすぎないか確認（推奨: 10MB以下）
- ログパネル（下部）でエラーメッセージを確認

### 4. GitHub Actionsビルドが失敗する

**原因**: 署名鍵や環境変数の設定不足

**解決策**:
- Android: `ANDROID_KEYSTORE_B64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD` の設定を確認
- Windows: 自動生成される自己署名証明書を使用（本番環境では適切な証明書を用意）
- GitHub Actionsログで詳細なエラーメッセージを確認

## ライセンス

このプロジェクトはMITライセンスのもとで公開されています。詳細は [LICENSE](LICENSE) ファイルをご覧ください。

Copyright (c) 2025 ERU
