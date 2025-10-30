import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../shared/app_settings_controller.dart';
import '../drawing/drawing_page.dart' show ServerSettingsDialog;
import '../drawing/models/app_settings.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final AppSettingsController controller = context.watch<AppSettingsController>();
    final AppSettings settings = controller.settings;
    final bool requiresManualUploadConfig =
        !AppSettings.hasEmbeddedUploadConfig ||
        !AppSettings.hasEmbeddedTokenEndpoint ||
        !AppSettings.hasEmbeddedTurnstileUrl;

    return Scaffold(
      backgroundColor: const Color(0xff0f141b),
      appBar: AppBar(
        title: const Text('サーバー設定'),
        backgroundColor: const Color(0xff1b2430),
        elevation: 2,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Card(
                color: const Color(0xff18212b),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const Text('現在の設定', style: TextStyle(color: Colors.white70, fontSize: 16, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 12),
                      Text(
                        requiresManualUploadConfig
                            ? 'アップロード/Expose/トークン関連の設定は手動で入力できます。'
                            : 'アップロード/Expose/トークン関連の設定はアプリ内に固定されています。',
                        style: const TextStyle(color: Colors.white38, fontSize: 12),
                      ),
                      const SizedBox(height: 12),
                      if (!AppSettings.hasEmbeddedUploadConfig)
                        _SettingsRow(label: 'Upload Endpoint', value: settings.uploadEndpoint),
                      if (!AppSettings.hasEmbeddedTokenEndpoint)
                        _SettingsRow(label: 'Upload Auth Endpoint', value: settings.uploadAuthEndpoint),
                      if (!AppSettings.hasEmbeddedTurnstileUrl)
                        _SettingsRow(label: 'Turnstile Verify URL', value: settings.uploadTurnstileUrl),
                      if (!AppSettings.hasEmbeddedUploadConfig ||
                          !AppSettings.hasEmbeddedTokenEndpoint ||
                          !AppSettings.hasEmbeddedTurnstileUrl)
                        const SizedBox(height: 12),
                      _SettingsRow(label: 'Nano Banana MCP', value: settings.nanoBananaEndpoint),
                      _SettingsRow(label: 'Seedream MCP', value: settings.seedreamEndpoint),
                      _SettingsRow(label: 'Sora MCP', value: settings.soraEndpoint),
                      _SettingsRow(label: 'Veo MCP', value: settings.veoEndpoint),
                      const SizedBox(height: 20),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          icon: const Icon(Icons.settings_suggest),
                          label: const Text('設定を編集'),
                          onPressed: () async {
                            final AppSettings? updated = await showDialog<AppSettings>(
                              context: context,
                              builder: (BuildContext context) => ServerSettingsDialog(initial: settings),
                            );
                            if (updated != null) {
                              await controller.update(updated);
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('設定を保存しました。')),
                                );
                              }
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: Card(
                  color: const Color(0xff18212b),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        const Text('ヒント', style: TextStyle(color: Colors.white70, fontSize: 16, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 12),
                        Text(
                          requiresManualUploadConfig
                              ? '・ローカル開発で利用する場合は Upload / Auth / Turnstile を手動で入力してください。'
                              : '・アップロード関連のエンドポイントはアプリに組み込み済みです。',
                          style: const TextStyle(color: Colors.white54),
                        ),
                        const SizedBox(height: 8),
                        const Text('・Sora MCP を設定すると、テキスト→動画生成後に自動ダウンロードまで行えます。', style: TextStyle(color: Colors.white54)),
                        const SizedBox(height: 8),
                        const Text('・Veo MCP を設定すると、Veo3.1 I2V での画像→動画生成が利用可能になります。', style: TextStyle(color: Colors.white54)),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final bool isEmpty = value.trim().isEmpty;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 140,
            child: Text(
              label,
              style: const TextStyle(color: Colors.white60, fontWeight: FontWeight.w500),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              isEmpty ? '未設定' : value,
              style: TextStyle(color: isEmpty ? Colors.white38 : Colors.white70),
            ),
          ),
        ],
      ),
    );
  }
}
