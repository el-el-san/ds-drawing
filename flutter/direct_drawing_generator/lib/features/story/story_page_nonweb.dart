import 'dart:async';
import 'package:universal_io/io.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:media_kit_video/media_kit_video.dart' as mk_video;
import 'package:video_thumbnail/video_thumbnail.dart';

import '../../shared/app_settings_controller.dart';
import '../drawing/models/app_settings.dart';
import 'story_controller.dart';
import 'image_crop_helper.dart';
import 'models/story_scene.dart';

class StoryPage extends StatefulWidget {
  const StoryPage({super.key});

  @override
  State<StoryPage> createState() => _StoryPageState();
}

class _StoryPageState extends State<StoryPage> {
  StoryController? _storyController;

  void _handleStoryControllerChanged() {
    if (!mounted) {
      return;
    }
    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final StoryController controller = _storyController ?? context.read<StoryController>();
      controller.init();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final StoryController controller = context.read<StoryController>();
    if (!identical(_storyController, controller)) {
      _storyController?.removeListener(_handleStoryControllerChanged);
      _storyController = controller;
      _storyController!.addListener(_handleStoryControllerChanged);
    }
  }

  @override
  void dispose() {
    _storyController?.removeListener(_handleStoryControllerChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final StoryController controller = _storyController ?? context.watch<StoryController>();
    final AppSettingsController settingsController = context.watch<AppSettingsController>();
    final AppSettings settings = settingsController.settings;

    return Scaffold(
      backgroundColor: const Color(0xff0f141b),
      appBar: AppBar(
        title: const Text('ストーリー / 動画生成ツール'),
        backgroundColor: const Color(0xff1b2430),
        elevation: 2,
        actions: <Widget>[
          IconButton(
            tooltip: 'シーンを追加',
            icon: const Icon(Icons.add_circle_outline),
            onPressed: controller.addScene,
          ),
          IconButton(
            tooltip: 'サーバー設定',
            icon: const Icon(Icons.settings),
            onPressed: () => DefaultTabController.of(context).animateTo(2),
          ),
        ],
      ),
      body: SafeArea(
        child: controller.scenes.isEmpty
            ? const Center(
                child: Text(
                  'シーンが見つかりません',
                  style: TextStyle(color: Colors.white54),
                ),
              )
            : ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: controller.scenes.length,
                itemBuilder: (BuildContext context, int index) {
                  final StoryScene scene = controller.scenes[index];
                  return _SceneCard(
                    scene: scene,
                    settings: settings,
                    onDelete: controller.scenes.length > 1
                        ? () => controller.removeScene(scene.id)
                        : null,
                  );
                },
              ),
      ),
    );
  }
}

/// 各シーンのカード
class _SceneCard extends StatefulWidget {
  const _SceneCard({
    required this.scene,
    required this.settings,
    this.onDelete,
  });

  final StoryScene scene;
  final AppSettings settings;
  final VoidCallback? onDelete;

  @override
  State<_SceneCard> createState() => _SceneCardState();
}

class _SceneCardState extends State<_SceneCard> {
  final TextEditingController _promptController = TextEditingController();
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _manualRemixVideoIdController = TextEditingController();
  final ScrollController _logScrollController = ScrollController();
  bool _isExpanded = true;
  bool _logPanelExpanded = false;
  double _logPanelHeight = 240.0; // ログパネルの高さ（ドラッグ可能）
  int _lastLogCount = 0; // オートスクロール用に直近のログ件数を保持

  bool get _isEndpointReady {
    final AppSettings settings = widget.settings;
    if (widget.scene.videoProvider == StoryVideoProvider.veo31I2v) {
      return settings.veoEndpoint.trim().isNotEmpty;
    }
    return settings.soraEndpoint.trim().isNotEmpty;
  }

  String get _endpointLabel {
    return widget.scene.videoProvider == StoryVideoProvider.veo31I2v ? 'Veo MCP' : 'Sora MCP';
  }

  String get _missingEndpointMessage {
    return '設定タブで$_endpointLabelエンドポイントを設定してください。';
  }

  Widget _buildVideoToolSelector(ThemeData theme, bool isRunning) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('動画ツール', style: theme.textTheme.titleMedium?.copyWith(color: Colors.white70)),
        const SizedBox(height: 8),
        DropdownButtonFormField<StoryVideoProvider>(
          value: widget.scene.videoProvider,
          dropdownColor: const Color(0xff1b2430),
          decoration: const InputDecoration(
            filled: true,
            fillColor: Color(0xff111827),
            border: OutlineInputBorder(),
            labelText: '生成ツール',
          ),
          items: const <DropdownMenuItem<StoryVideoProvider>>[
            DropdownMenuItem<StoryVideoProvider>(
              value: StoryVideoProvider.sora,
              child: Text('Sora (テキスト→動画)'),
            ),
            DropdownMenuItem<StoryVideoProvider>(
              value: StoryVideoProvider.veo31I2v,
              child: Text('Veo3.1 I2V (画像→動画)'),
            ),
          ],
          onChanged: isRunning
              ? null
              : (StoryVideoProvider? value) {
                  if (value == null || value == widget.scene.videoProvider) {
                    return;
                  }
                  setState(() {
                    widget.scene.videoProvider = value;
                    if (value == StoryVideoProvider.sora) {
                      _ensureValidSizeForSoraModel();
                    } else {
                      _ensureVeoDefaults();
                    }
                  });
                  _syncSceneData();
                  if (widget.scene.i2vImageBytes != null) {
                    _cropI2vImage();
                  }
                },
        ),
      ],
    );
  }

  Widget _buildSoraSettings(ThemeData theme, bool isRunning) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Card(
          color: const Color(0xff0f141b),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
              color: widget.scene.isRemixEnabled ? const Color(0xfffacc15) : const Color(0xff253143),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    const Icon(Icons.auto_fix_high, color: Color(0xfffacc15), size: 20),
                    const SizedBox(width: 8),
                    Text(
                      'Remix（リミックス）',
                      style: theme.textTheme.titleSmall?.copyWith(color: Colors.white70),
                    ),
                    const Spacer(),
                    Switch(
                      value: widget.scene.isRemixEnabled,
                      onChanged: isRunning
                          ? null
                          : (bool value) {
                              setState(() {
                                widget.scene.isRemixEnabled = value;
                                if (value) {
                                  widget.scene.videoProvider = StoryVideoProvider.sora;
                                  widget.scene.manualRemixVideoId = widget.scene.manualRemixVideoId.trim();
                                  widget.scene.isRunning = false;
                                } else {
                                  widget.scene.manualRemixVideoId = '';
                                }
                              });
                              _syncSceneData();
                            },
                      activeColor: const Color(0xfffacc15),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                AnimatedCrossFade(
                  duration: const Duration(milliseconds: 220),
                  crossFadeState: widget.scene.isRemixEnabled ? CrossFadeState.showSecond : CrossFadeState.showFirst,
                  firstChild: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      DropdownButtonFormField<String>(
                        value: widget.scene.model,
                        dropdownColor: const Color(0xff1b2430),
                        decoration: const InputDecoration(
                          filled: true,
                          fillColor: Color(0xff111827),
                          border: OutlineInputBorder(),
                          labelText: 'モデル',
                        ),
                        items: const <DropdownMenuItem<String>>[
                          DropdownMenuItem<String>(value: 'sora-2', child: Text('sora-2')),
                          DropdownMenuItem<String>(value: 'sora-2-pro', child: Text('sora-2-pro')),
                        ],
                        onChanged: isRunning
                            ? null
                            : (String? value) {
                                setState(() {
                                  widget.scene.model = value ?? 'sora-2';
                                  if (widget.scene.model == 'sora-2-pro') {
                                    widget.scene.size = '1792x1024';
                                  }
                                });
                                _syncSceneData();
                                if (widget.scene.i2vImageBytes != null) {
                                  _cropI2vImage();
                                }
                              },
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: DropdownButtonFormField<int>(
                              value: widget.scene.seconds,
                              dropdownColor: const Color(0xff1b2430),
                              decoration: const InputDecoration(
                                filled: true,
                                fillColor: Color(0xff111827),
                                border: OutlineInputBorder(),
                                labelText: '秒数',
                              ),
                              items: const <DropdownMenuItem<int>>[
                                DropdownMenuItem<int>(value: 4, child: Text('4秒')),
                                DropdownMenuItem<int>(value: 8, child: Text('8秒')),
                                DropdownMenuItem<int>(value: 12, child: Text('12秒')),
                              ],
                              onChanged: isRunning
                                  ? null
                                  : (int? value) {
                                      setState(() {
                                        widget.scene.seconds = value ?? 12;
                                      });
                                      _syncSceneData();
                                    },
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: DropdownButtonFormField<String>(
                              value: widget.scene.size,
                              dropdownColor: const Color(0xff1b2430),
                              decoration: const InputDecoration(
                                filled: true,
                                fillColor: Color(0xff111827),
                                border: OutlineInputBorder(),
                                labelText: '解像度',
                              ),
                              items: widget.scene.model == 'sora-2'
                                  ? const <DropdownMenuItem<String>>[
                                      DropdownMenuItem<String>(value: '1280x720', child: Text('1280x720 (横長)')),
                                      DropdownMenuItem<String>(value: '720x1280', child: Text('720x1280 (縦長)')),
                                    ]
                                  : const <DropdownMenuItem<String>>[
                                      DropdownMenuItem<String>(value: '1792x1024', child: Text('1792x1024 (横長)')),
                                      DropdownMenuItem<String>(value: '1024x1792', child: Text('1024x1792 (縦長)')),
                                    ],
                              onChanged: isRunning
                                  ? null
                                  : (String? value) {
                                      setState(() {
                                        widget.scene.size =
                                            value ?? (widget.scene.model == 'sora-2' ? '1280x720' : '1792x1024');
                                      });
                                      _syncSceneData();
                                      if (widget.scene.i2vImageBytes != null) {
                                        _cropI2vImage();
                                      }
                                    },
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  secondChild: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const Text(
                        'SoraのRemix機能を利用して既存の動画をアレンジします。',
                        style: TextStyle(color: Colors.white60),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _manualRemixVideoIdController,
                        style: const TextStyle(color: Colors.white),
                        enabled: !isRunning,
                        decoration: InputDecoration(
                          filled: true,
                          fillColor: const Color(0xff111827),
                          border: const OutlineInputBorder(),
                          labelText: 'Remix元のVideo ID',
                          hintText: widget.scene.requestId?.isNotEmpty == true
                              ? '空欄の場合は直近のVideo ID (${widget.scene.requestId}) を使用'
                              : '例: sora-video-xxxxxxxx',
                        ),
                        onChanged: (_) => _syncSceneData(),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildVeoSettings(ThemeData theme, bool isRunning) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('Veo3.1 I2V 設定', style: theme.textTheme.titleMedium?.copyWith(color: Colors.white70)),
        const SizedBox(height: 8),
        Row(
          children: <Widget>[
            Expanded(
              child: DropdownButtonFormField<String>(
                value: widget.scene.veoAspectRatio,
                dropdownColor: const Color(0xff1b2430),
                decoration: const InputDecoration(
                  filled: true,
                  fillColor: Color(0xff111827),
                  border: OutlineInputBorder(),
                  labelText: 'アスペクト比',
                ),
                items: const <DropdownMenuItem<String>>[
                  DropdownMenuItem<String>(value: '16:9', child: Text('16:9 (横長)')),
                  DropdownMenuItem<String>(value: '9:16', child: Text('9:16 (縦長)')),
                  DropdownMenuItem<String>(value: '1:1', child: Text('1:1 (正方形)')),
                ],
                onChanged: isRunning
                    ? null
                    : (String? value) {
                        final String resolved = (value ?? '16:9').trim();
                        setState(() {
                          widget.scene.veoAspectRatio = resolved;
                          _applyVeoSize(aspectRatio: resolved);
                        });
                        _syncSceneData();
                        if (widget.scene.i2vImageBytes != null) {
                          _cropI2vImage();
                        }
                      },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: DropdownButtonFormField<String>(
                value: widget.scene.veoResolution,
                dropdownColor: const Color(0xff1b2430),
                decoration: const InputDecoration(
                  filled: true,
                  fillColor: Color(0xff111827),
                  border: OutlineInputBorder(),
                  labelText: '解像度',
                ),
                items: const <DropdownMenuItem<String>>[
                  DropdownMenuItem<String>(value: '720p', child: Text('720p')),
                  DropdownMenuItem<String>(value: '1080p', child: Text('1080p')),
                ],
                onChanged: isRunning
                    ? null
                    : (String? value) {
                        final String resolved = (value ?? '720p').trim();
                        setState(() {
                          widget.scene.veoResolution = resolved;
                          _applyVeoSize(resolution: resolved);
                        });
                        _syncSceneData();
                        if (widget.scene.i2vImageBytes != null) {
                          _cropI2vImage();
                        }
                      },
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          decoration: BoxDecoration(
            color: const Color(0xff111827),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xff253143)),
          ),
          child: const Text(
            '動画長: 8秒（固定）',
            style: TextStyle(color: Colors.white60),
          ),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xff0f141b),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xff253143)),
          ),
          child: Row(
            children: <Widget>[
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('音声を生成', style: TextStyle(color: Colors.white70)),
                    SizedBox(height: 4),
                    Text('オフにするとクレジット使用量が約33%減少します。', style: TextStyle(color: Colors.white54, fontSize: 12)),
                  ],
                ),
              ),
              Switch(
                value: widget.scene.veoGenerateAudio,
                onChanged: isRunning
                    ? null
                    : (bool value) {
                        setState(() {
                          widget.scene.veoGenerateAudio = value;
                        });
                        _syncSceneData();
                      },
                activeColor: const Color(0xff4a9eff),
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  void initState() {
    super.initState();
    _promptController.text = widget.scene.prompt;
    _titleController.text = widget.scene.title;
    _manualRemixVideoIdController.text = widget.scene.manualRemixVideoId;
    final bool updated = widget.scene.videoProvider == StoryVideoProvider.sora
        ? _ensureValidSizeForSoraModel()
        : _ensureVeoDefaults();
    if (updated) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _syncSceneData();
        }
      });
    }
  }

  @override
  void dispose() {
    _promptController.dispose();
    _titleController.dispose();
    _manualRemixVideoIdController.dispose();
    _logScrollController.dispose();
    super.dispose();
  }

  void _syncSceneData() {
    final StoryController controller = context.read<StoryController>();
    widget.scene.prompt = _promptController.text;
    widget.scene.title = _titleController.text;
    widget.scene.manualRemixVideoId = _manualRemixVideoIdController.text;
    controller.updateScene(widget.scene.id, (StoryScene scene) => scene);
  }

  bool _ensureValidSizeForSoraModel() {
    if (widget.scene.videoProvider != StoryVideoProvider.sora) {
      return false;
    }
    final List<String> allowedSizes =
        widget.scene.model == 'sora-2' ? <String>['1280x720', '720x1280'] : <String>['1792x1024', '1024x1792'];
    if (!allowedSizes.contains(widget.scene.size)) {
      widget.scene.size = allowedSizes.first;
      return true;
    }
    return false;
  }

  bool _ensureVeoDefaults() {
    if (widget.scene.videoProvider != StoryVideoProvider.veo31I2v) {
      return false;
    }
    bool updated = false;
    if (widget.scene.veoAspectRatio.trim().isEmpty) {
      widget.scene.veoAspectRatio = '16:9';
      updated = true;
    }
    if (widget.scene.veoResolution.trim().isEmpty) {
      widget.scene.veoResolution = '720p';
      updated = true;
    }
    if (widget.scene.veoDuration.trim().isEmpty || widget.scene.veoDuration != '8s') {
      widget.scene.veoDuration = '8s';
      updated = true;
    }
    if (widget.scene.seconds != 8) {
      widget.scene.seconds = 8;
      updated = true;
    }
    if (widget.scene.isRemixEnabled) {
      widget.scene.isRemixEnabled = false;
      updated = true;
    }
    if (_applyVeoSize()) {
      updated = true;
    }
    return updated;
  }

  bool _applyVeoSize({String? aspectRatio, String? resolution}) {
    final String resolved = _resolveVeoSize(
      aspectRatio: aspectRatio ?? widget.scene.veoAspectRatio,
      resolution: resolution ?? widget.scene.veoResolution,
    );
    if (widget.scene.size != resolved) {
      widget.scene.size = resolved;
      return true;
    }
    return false;
  }

  String _resolveVeoSize({String? aspectRatio, String? resolution}) {
    final String ratio = (aspectRatio ?? widget.scene.veoAspectRatio).trim();
    final String normalizedRatio = <String>{'16:9', '9:16', '1:1'}.contains(ratio) ? ratio : '16:9';
    final String res = (resolution ?? widget.scene.veoResolution).trim();
    final bool is1080 = res == '1080p';
    final int base = is1080 ? 1080 : 720;

    switch (normalizedRatio) {
      case '9:16':
        final int height = (base * 16) ~/ 9;
        return '${base}x$height';
      case '1:1':
        return '${base}x$base';
      case '16:9':
      default:
        final int width = (base * 16) ~/ 9;
        return '${width}x$base';
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final StoryController controller = context.read<StoryController>();
    final bool isRunning = widget.scene.isRunning;

    return Card(
      color: const Color(0xff18212b),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      margin: const EdgeInsets.only(bottom: 16),
      child: Column(
        children: <Widget>[
          // ヘッダー
          InkWell(
            onTap: () {
              setState(() {
                _isExpanded = !_isExpanded;
              });
            },
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: <Widget>[
                  Icon(
                    _isExpanded ? Icons.expand_more : Icons.chevron_right,
                    color: Colors.white70,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _titleController,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                      decoration: const InputDecoration(
                        hintText: 'シーンタイトル',
                        hintStyle: TextStyle(color: Colors.white38),
                        border: InputBorder.none,
                        isDense: true,
                      ),
                      onChanged: (_) => _syncSceneData(),
                    ),
                  ),
                  // ステータスバッジ
                  if (isRunning)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xff4a9eff),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          SizedBox.square(
                            dimension: 12,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          ),
                          SizedBox(width: 6),
                          Text(
                            '生成中',
                            style: TextStyle(color: Colors.white, fontSize: 11),
                          ),
                        ],
                      ),
                    )
                  else if (widget.scene.phase == StoryScenePhase.completed)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xff00d4aa),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Text(
                        '完了',
                        style: TextStyle(color: Colors.white, fontSize: 11),
                      ),
                    )
                  else if (widget.scene.phase == StoryScenePhase.error)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xffff4d5a),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Text(
                        'エラー',
                        style: TextStyle(color: Colors.white, fontSize: 11),
                      ),
                    ),
                  // 削除ボタン
                  if (widget.onDelete != null) ...<Widget>[
                    const SizedBox(width: 8),
                    IconButton(
                      tooltip: 'シーンを削除',
                      icon: const Icon(Icons.delete_outline, color: Color(0xffff4d5a)),
                      onPressed: isRunning ? null : widget.onDelete,
                    ),
                  ],
                ],
              ),
            ),
          ),
          // 展開可能な内容
          if (_isExpanded) ...<Widget>[
            const Divider(color: Color(0xff253143), height: 1),
            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  _buildSceneForm(theme, controller, isRunning),
                  const SizedBox(height: 20),
                  _buildSceneStatus(theme, controller),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSceneForm(ThemeData theme, StoryController controller, bool isRunning) {
    final bool canResume = (widget.scene.requestId ?? '').isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('動画プロンプト', style: theme.textTheme.titleMedium?.copyWith(color: Colors.white70)),
        const SizedBox(height: 8),
        TextField(
          controller: _promptController,
          maxLines: 4,
          minLines: 3,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: '例: A cinematic shot of a neon-lit cityscape with gentle rain',
            hintStyle: TextStyle(color: Colors.white38),
            filled: true,
            fillColor: Color(0xff111827),
            border: OutlineInputBorder(),
          ),
          onChanged: (_) => _syncSceneData(),
        ),
        const SizedBox(height: 16),
        _buildVideoToolSelector(theme, isRunning),
        const SizedBox(height: 16),
        if (widget.scene.videoProvider == StoryVideoProvider.sora)
          _buildSoraSettings(theme, isRunning)
        else
          _buildVeoSettings(theme, isRunning),
        const SizedBox(height: 16),
        Text('i2v 開始フレーム (任意)', style: theme.textTheme.titleMedium?.copyWith(color: Colors.white70)),
        const SizedBox(height: 8),
        Row(
          children: <Widget>[
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                decoration: BoxDecoration(
                  color: const Color(0xff111827),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xff253143)),
                ),
                child: Text(
                  widget.scene.i2vImageName ?? 'ファイル未選択',
                  style: const TextStyle(color: Colors.white60),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            const SizedBox(width: 12),
            ElevatedButton.icon(
              onPressed: isRunning || widget.scene.isRemixEnabled ? null : _pickI2vImage,
              icon: const Icon(Icons.image),
              label: const Text('選択'),
            ),
          ],
        ),
        if (widget.scene.i2vCroppedBytes != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    const Icon(Icons.check_circle, color: Color(0xff00d4aa), size: 16),
                    const SizedBox(width: 6),
                    Text(
                      'クロップ済み（${widget.scene.size}）',
                      style: const TextStyle(color: Color(0xff00d4aa), fontSize: 12),
                    ),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: isRunning || widget.scene.isRemixEnabled ? null : _clearI2vImage,
                      icon: const Icon(Icons.clear, size: 16),
                      label: const Text('クリア'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.memory(
                    widget.scene.i2vCroppedBytes!,
                    fit: BoxFit.contain,
                    height: 120,
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 16),
        Text('参照画像 (任意)', style: theme.textTheme.titleMedium?.copyWith(color: Colors.white70)),
        const SizedBox(height: 8),
        Row(
          children: <Widget>[
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                decoration: BoxDecoration(
                  color: const Color(0xff111827),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xff253143)),
                ),
                child: Text(
                  widget.scene.referenceName ?? 'ファイル未選択',
                  style: const TextStyle(color: Colors.white60),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            const SizedBox(width: 12),
            ElevatedButton.icon(
              onPressed: isRunning || widget.scene.isRemixEnabled ? null : _pickReference,
              icon: const Icon(Icons.upload_file),
              label: const Text('選択'),
            ),
          ],
        ),
        if (widget.scene.referenceBytes != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: isRunning || widget.scene.isRemixEnabled
                    ? null
                    : () {
                        setState(() {
                          widget.scene.referenceBytes = null;
                          widget.scene.referenceName = null;
                          _syncSceneData();
                        });
                      },
                icon: const Icon(Icons.clear, size: 16),
                label: const Text('クリア'),
              ),
            ),
          ),
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: _isEndpointReady ? const Color(0xff4a9eff) : const Color(0xff2a3342),
              foregroundColor: Colors.white,
              disabledForegroundColor: Colors.white70,
              disabledBackgroundColor: const Color(0xff2a3342),
              minimumSize: const Size.fromHeight(52),
            ),
            onPressed: isRunning || !_isEndpointReady ? null : () => _startGeneration(controller),
            icon: isRunning
                ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.play_arrow),
            label: Text(isRunning ? '生成中...' : '動画を生成'),
          ),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
          ),
          onPressed: isRunning || !_isEndpointReady || !canResume ? null : () => _resumeGeneration(controller),
          icon: const Icon(Icons.refresh),
          label: const Text('Resume（生成再開）'),
        ),
        const SizedBox(height: 12),
        TextButton.icon(
          onPressed: widget.scene.phase == StoryScenePhase.idle && widget.scene.logs.isEmpty
              ? null
              : () => controller.resetSceneResult(widget.scene.id),
          icon: const Icon(Icons.restart_alt),
          label: const Text('状態をリセット'),
        ),
        if (!_isEndpointReady)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Row(
              children: <Widget>[
                const Icon(Icons.info_outline, color: Color(0xffffb86c), size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _missingEndpointMessage,
                    style: theme.textTheme.bodySmall?.copyWith(color: const Color(0xffffb86c)),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildSceneStatus(ThemeData theme, StoryController controller) {
    final String statusLabel = _buildPhaseLabel(widget.scene.phase);
    final bool isVeo = widget.scene.videoProvider == StoryVideoProvider.veo31I2v;
    final String remoteLabel = isVeo ? 'Veoステータス' : 'Soraステータス';
    final String requestIdLabel = isVeo ? 'Request ID' : 'Video ID';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            const Icon(Icons.timeline, color: Color(0xff4a9eff)),
            const SizedBox(width: 8),
            Text('進捗', style: theme.textTheme.titleMedium?.copyWith(color: Colors.white70)),
          ],
        ),
        const SizedBox(height: 12),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xff111827),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xff253143)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(statusLabel, style: const TextStyle(color: Colors.white70)),
              if (widget.scene.remoteStatus != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text('$remoteLabel: ${widget.scene.remoteStatus}',
                      style: const TextStyle(color: Colors.white54)),
                ),
              if (widget.scene.progress != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text('進捗: ${widget.scene.progress}%',
                      style: const TextStyle(color: Color(0xff4a9eff), fontWeight: FontWeight.bold)),
                ),
              if (widget.scene.requestId != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: SelectableText(
                    '$requestIdLabel: ${widget.scene.requestId}',
                    style: const TextStyle(color: Colors.white54),
                  ),
                ),
              if (widget.scene.errorMessage != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const Icon(Icons.error_outline, color: Color(0xffffb4ab), size: 18),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          widget.scene.errorMessage!,
                          style: const TextStyle(color: Color(0xffffd9d3), height: 1.3),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (widget.scene.localVideoPath != null) ...<Widget>[
          _VideoPlayerWidget(
            videoPath: widget.scene.localVideoPath!,
            sceneId: widget.scene.id,
          ),
          const SizedBox(height: 16),
        ],
        if (widget.scene.videoUrl != null)
          _buildResultCard(
            title: 'ローカル動画 URL',
            value: widget.scene.videoUrl!,
            icon: Icons.movie,
          ),
        if (widget.scene.curlCommand != null)
          _buildResultCard(
            title: 'curl コマンド',
            value: widget.scene.curlCommand!,
            icon: Icons.code,
          ),
        _buildLogPanel(widget.scene.logs),
      ],
    );
  }

  Widget _buildResultCard({required String title, required String value, required IconData icon}) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: const Color(0xff111827),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xff253143)),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: false,
          tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
          leading: Icon(icon, color: const Color(0xff00d4aa), size: 20),
          title: Text(
            title,
            style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w600, fontSize: 14),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              IconButton(
                tooltip: 'コピー',
                icon: const Icon(Icons.copy, color: Colors.white54, size: 18),
                onPressed: () => Clipboard.setData(ClipboardData(text: value)).then((_) {
                  if (!mounted) {
                    return;
                  }
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('$title をコピーしました')),
                  );
                }),
              ),
              const Icon(Icons.expand_more, color: Colors.white54),
            ],
          ),
          children: <Widget>[
            SelectableText(
              value,
              style: const TextStyle(color: Colors.white60, fontSize: 12, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLogPanel(List<String> logs) {
    final bool hasLogs = logs.isNotEmpty;

    if (hasLogs && logs.length > _lastLogCount && _logPanelExpanded) {
      _lastLogCount = logs.length;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_logScrollController.hasClients) {
          _logScrollController.animateTo(
            _logScrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        }
      });
    } else if (hasLogs) {
      _lastLogCount = logs.length;
    } else {
      _lastLogCount = 0;
    }

    if (!hasLogs && !_logPanelExpanded) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const SizedBox(height: 16),
        AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          height: _logPanelExpanded ? _logPanelHeight : 44,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xff111827),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xff253143)),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Column(
                children: <Widget>[
                  GestureDetector(
                    onVerticalDragUpdate: _logPanelExpanded
                        ? (DragUpdateDetails details) {
                            setState(() {
                              _logPanelHeight = (_logPanelHeight - details.delta.dy).clamp(120.0, 600.0);
                            });
                          }
                        : null,
                    child: Material(
                      color: const Color(0xff1b2430),
                      child: InkWell(
                        onTap: () {
                          setState(() {
                            _logPanelExpanded = !_logPanelExpanded;
                          });
                        },
                        child: SizedBox(
                          height: 44,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Row(
                              children: <Widget>[
                                Icon(
                                  _logPanelExpanded ? Icons.expand_more : Icons.expand_less,
                                  color: Colors.white70,
                                  size: 20,
                                ),
                                const SizedBox(width: 8),
                                if (_logPanelExpanded)
                                  const Icon(
                                    Icons.drag_handle,
                                    color: Colors.white54,
                                    size: 16,
                                  ),
                                if (_logPanelExpanded) const SizedBox(width: 8),
                                const Text(
                                  'ログ',
                                  style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600),
                                ),
                                if (hasLogs) ...<Widget>[
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: const Color(0xff4a9eff),
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Text(
                                      '${logs.length}',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ],
                                const Spacer(),
                                if (hasLogs && _logPanelExpanded)
                                  IconButton(
                                    icon: const Icon(Icons.copy, size: 18),
                                    color: Colors.white70,
                                    tooltip: 'ログをコピー',
                                    onPressed: () => _copyLogs(logs),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (_logPanelExpanded)
                    Expanded(
                      child: Container(
                        color: const Color(0xff0f141b),
                        child: hasLogs
                            ? Scrollbar(
                                controller: _logScrollController,
                                thumbVisibility: true,
                                child: ListView.builder(
                                  controller: _logScrollController,
                                  padding: const EdgeInsets.all(12),
                                  itemCount: logs.length,
                                  itemBuilder: (BuildContext context, int index) {
                                    final String log = logs[index];
                                    Color textColor = Colors.white60;
                                    IconData? iconData;

                                    if (log.contains('エラー') || log.contains('失敗') || log.contains('ERROR')) {
                                      textColor = const Color(0xffff4d5a);
                                      iconData = Icons.error_outline;
                                    } else if (log.contains('成功') || log.contains('完了') || log.contains('DONE')) {
                                      textColor = const Color(0xff00d4aa);
                                      iconData = Icons.check_circle_outline;
                                    } else if (log.contains('===')) {
                                      textColor = const Color(0xff4a9eff);
                                      iconData = Icons.info_outline;
                                    }

                                    return Padding(
                                      padding: const EdgeInsets.only(bottom: 6),
                                      child: Row(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: <Widget>[
                                          if (iconData != null) ...<Widget>[
                                            Icon(iconData, size: 14, color: textColor),
                                            const SizedBox(width: 6),
                                          ],
                                          Expanded(
                                            child: SelectableText(
                                              log,
                                              style: TextStyle(
                                                fontSize: 11,
                                                fontFamily: 'monospace',
                                                color: textColor,
                                                height: 1.4,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    );
                                  },
                                ),
                              )
                            : const Center(
                                child: Text(
                                  'ログはまだありません',
                                  style: TextStyle(color: Colors.white30, fontSize: 12),
                                ),
                              ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  String _buildPhaseLabel(StoryScenePhase phase) {
    switch (phase) {
      case StoryScenePhase.uploadingReference:
        return '参照画像をアップロード中...';
      case StoryScenePhase.submitting:
        return '生成リクエスト送信中...';
      case StoryScenePhase.waiting:
        return '応答を待機中...';
      case StoryScenePhase.downloading:
        return '動画をダウンロードしています...';
      case StoryScenePhase.completed:
        return '生成が完了しました！';
      case StoryScenePhase.error:
        return 'エラーが発生しました';
      case StoryScenePhase.idle:
      default:
        return '待機中';
    }
  }

  Future<void> _copyLogs(List<String> logs) async {
    if (logs.isEmpty) {
      return;
    }
    await Clipboard.setData(ClipboardData(text: logs.join('\n')));
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('ログをコピーしました')),
    );
  }

  Future<void> _pickReference() async {
    try {
      final FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
        withData: true,
      );
      if (result == null || result.files.isEmpty) {
        return;
      }
      final PlatformFile file = result.files.first;
      if (file.bytes == null) {
        throw Exception('ファイルの読み込みに失敗しました');
      }
      setState(() {
        widget.scene.referenceBytes = file.bytes;
        widget.scene.referenceName = file.name;
        _syncSceneData();
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('参照画像の選択に失敗しました: $error')),
      );
    }
  }

  Future<void> _pickI2vImage() async {
    try {
      final FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
        withData: true,
      );
      if (result == null || result.files.isEmpty) {
        return;
      }
      final PlatformFile file = result.files.first;
      if (file.bytes == null) {
        throw Exception('ファイルの読み込みに失敗しました');
      }

      setState(() {
        widget.scene.i2vImageBytes = file.bytes;
        widget.scene.i2vImageName = file.name;
        widget.scene.i2vCroppedBytes = null;
        _syncSceneData();
      });

      await _cropI2vImage();
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('i2v画像の選択に失敗しました: $error')),
      );
    }
  }

  Future<void> _cropI2vImage() async {
    if (widget.scene.i2vImageBytes == null) {
      return;
    }

    try {
      final Uint8List? cropped = await ImageCropHelper.cropToAspectRatio(
        widget.scene.i2vImageBytes!,
        widget.scene.size,
      );

      if (cropped == null) {
        throw Exception('画像のクロップに失敗しました');
      }

      setState(() {
        widget.scene.i2vCroppedBytes = cropped;
        _syncSceneData();
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('画像のクロップに失敗しました: $error')),
      );
    }
  }

  void _clearI2vImage() {
    setState(() {
      widget.scene.i2vImageBytes = null;
      widget.scene.i2vImageName = null;
      widget.scene.i2vCroppedBytes = null;
      _syncSceneData();
    });
  }

  Future<void> _startGeneration(StoryController controller) async {
    final String prompt = _promptController.text.trim();

    if (widget.scene.isRemixEnabled) {
      final String manualVideoId = _manualRemixVideoIdController.text.trim();
      final String? remixVideoId = manualVideoId.isNotEmpty ? manualVideoId : widget.scene.requestId;

      if (remixVideoId == null || remixVideoId.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('RemixモードではVideo IDが必要です。手動入力するか、先に動画を生成してください')),
        );
        return;
      }

      widget.scene.prompt = prompt;
      widget.scene.manualRemixVideoId = manualVideoId;
      _syncSceneData();
    } else {
      widget.scene.prompt = prompt;
      final Uint8List? imageToUpload = widget.scene.i2vCroppedBytes ?? widget.scene.referenceBytes;
      final String? imageName = widget.scene.i2vCroppedBytes != null
          ? (widget.scene.i2vImageName != null ? 'i2v_${widget.scene.i2vImageName!}' : 'i2v_image.png')
          : widget.scene.referenceName;
      widget.scene.referenceBytes = imageToUpload;
      widget.scene.referenceName = imageName;
      _syncSceneData();
    }

    final bool needsUploadToken = widget.scene.referenceBytes != null && widget.scene.referenceBytes!.isNotEmpty;
    if (needsUploadToken) {
      final String? authError = await controller.ensureUploadAuthorization(context);
      if (authError != null) {
        if (!mounted) {
          return;
        }
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(authError)));
        return;
      }
    }

    await controller.generateSceneVideo(widget.scene.id);
  }

  Future<void> _resumeGeneration(StoryController controller) async {
    final bool isVeo = widget.scene.videoProvider == StoryVideoProvider.veo31I2v;
    final String requestIdLabel = isVeo ? 'Request ID' : 'Video ID';
    final String? requestId = widget.scene.requestId;

    if (requestId == null || requestId.isEmpty) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存済みの$requestIdLabelがありません。先に動画を生成してください')),
      );
      return;
    }

    await controller.resumeSceneVideo(widget.scene.id);
  }
}

/// 動画プレーヤーウィジェット
class _VideoPlayerWidget extends StatefulWidget {
  const _VideoPlayerWidget({
    required this.videoPath,
    required this.sceneId,
  });

  final String videoPath;
  final String sceneId;

  @override
  State<_VideoPlayerWidget> createState() => _VideoPlayerWidgetState();
}

class _VideoPlayerWidgetState extends State<_VideoPlayerWidget> {
  VideoPlayerController? _controller;
  mk.Player? _windowsPlayer;
  mk_video.VideoController? _windowsVideoController;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration?>? _durationSubscription;
  StreamSubscription<bool>? _playingSubscription;
  StreamSubscription<int?>? _widthSubscription;
  StreamSubscription<int?>? _heightSubscription;
  bool _isInitialized = false;
  String? _errorMessage;
  bool _isWindowsPlaying = false;
  Duration _currentPosition = Duration.zero;
  Duration _totalDuration = Duration.zero;
  int? _videoWidth;
  int? _videoHeight;
  double _windowsAspectRatio = 16 / 9;
  bool _isCreatingNextScene = false;

  bool get _isWindowsPlatform => Platform.isWindows;

  @override
  void initState() {
    super.initState();
    _initializeVideo();
  }

  @override
  void didUpdateWidget(_VideoPlayerWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoPath != widget.videoPath) {
      _disposeVideoResources();
      _isInitialized = false;
      _errorMessage = null;
      _initializeVideo();
    }
  }

  Future<void> _initializeVideo() async {
    final StoryController controller = context.read<StoryController>();

    try {
      controller.logToScene(widget.sceneId, '動画プレイヤーを初期化しています: ${widget.videoPath}');

      if (_isWindowsPlatform) {
        await _initializeVideoForWindows(controller);
      } else {
        await _initializeVideoForOtherPlatforms();
      }

      if (!mounted) {
        return;
      }

      setState(() {
        _isInitialized = true;
      });
      controller.logToScene(widget.sceneId, '動画プレイヤーの初期化が完了しました');
    } catch (error, stackTrace) {
      final String errorMsg = '動画の初期化に失敗しました: $error';
      controller.logToScene(widget.sceneId, 'エラー: $errorMsg');
      controller.logToScene(widget.sceneId, 'StackTrace: $stackTrace');
      debugPrint('Video player initialization error: $error\n$stackTrace');

      if (mounted) {
        setState(() {
          _errorMessage = errorMsg;
        });
      }
      _disposeVideoResources();
    }
  }

  Future<void> _initializeVideoForOtherPlatforms() async {
    _controller = VideoPlayerController.file(File(widget.videoPath));
    await _controller!.initialize();
    _controller!.setLooping(true);
    _controller!.addListener(() {
      if (mounted) {
        setState(() {});
      }
    });
  }

  Future<void> _initializeVideoForWindows(StoryController controller) async {
    controller.logToScene(widget.sceneId, 'Windows環境: media_kitで動画を読み込みます');

    _disposeVideoResources();

    _windowsPlayer = mk.Player();
    _windowsVideoController = mk_video.VideoController(_windowsPlayer!);

    final String fileUri = Uri.file(widget.videoPath).toString();
    controller.logToScene(widget.sceneId, 'Windows環境: URI形式で読み込み: $fileUri');
    await _windowsPlayer!.open(mk.Media(fileUri));
    await _windowsPlayer!.setPlaylistMode(mk.PlaylistMode.loop);
    _updateWindowsAspectRatio(_windowsPlayer!.state.width, _windowsPlayer!.state.height);

    _playingSubscription = _windowsPlayer!.stream.playing.listen((bool playing) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isWindowsPlaying = playing;
      });
    });

    _durationSubscription = _windowsPlayer!.stream.duration.listen((Duration? duration) {
      if (!mounted || duration == null) {
        return;
      }
      setState(() {
        _totalDuration = duration;
      });
    });

    _positionSubscription = _windowsPlayer!.stream.position.listen((Duration position) {
      if (!mounted) {
        return;
      }
      setState(() {
        _currentPosition = position;
      });
    });

    _widthSubscription = _windowsPlayer!.stream.width.listen((int? width) {
      if (!mounted) {
        return;
      }
      _updateWindowsAspectRatio(width, _videoHeight);
    });

    _heightSubscription = _windowsPlayer!.stream.height.listen((int? height) {
      if (!mounted) {
        return;
      }
      _updateWindowsAspectRatio(_videoWidth, height);
    });
  }

  void _updateWindowsAspectRatio(int? width, int? height) {
    _videoWidth = width;
    _videoHeight = height;

    if (_videoWidth != null && _videoWidth! > 0 && _videoHeight != null && _videoHeight! > 0) {
      final double ratio = _videoWidth! / _videoHeight!;
      if (mounted) {
        setState(() {
          _windowsAspectRatio = ratio;
        });
      } else {
        _windowsAspectRatio = ratio;
      }
    }
  }

  void _disposeVideoResources() {
    _controller?.dispose();
    _controller = null;

    _positionSubscription?.cancel();
    _durationSubscription?.cancel();
    _playingSubscription?.cancel();
    _widthSubscription?.cancel();
    _heightSubscription?.cancel();
    _positionSubscription = null;
    _durationSubscription = null;
    _playingSubscription = null;
    _widthSubscription = null;
    _heightSubscription = null;

    _windowsVideoController = null;

    _windowsPlayer?.dispose();
    _windowsPlayer = null;

    _isWindowsPlaying = false;
    _currentPosition = Duration.zero;
    _totalDuration = Duration.zero;
    _videoWidth = null;
    _videoHeight = null;
    _windowsAspectRatio = 16 / 9;
  }

  Future<void> _downloadVideo() async {
    try {
      final File videoFile = File(widget.videoPath);
      if (!await videoFile.exists()) {
        if (!mounted) {
          return;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('動画ファイルが見つかりません')),
        );
        return;
      }

      // share_plusを使って動画を共有（ダウンロード）
      await Share.shareXFiles(
        <XFile>[XFile(widget.videoPath)],
        text: '生成された動画',
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('動画のダウンロードに失敗しました: $error')),
      );
    }
  }

  void _togglePlayback() {
    if (_isWindowsPlatform) {
      final mk.Player? player = _windowsPlayer;
      if (player == null) {
        return;
      }
      if (_isWindowsPlaying) {
        unawaited(player.pause());
      } else {
        unawaited(player.play());
      }
    } else {
      final VideoPlayerController? controller = _controller;
      if (controller == null) {
        return;
      }
      if (controller.value.isPlaying) {
        unawaited(controller.pause());
      } else {
        unawaited(controller.play());
      }
      if (mounted) {
        setState(() {});
      }
    }
  }

  Future<void> _handleNextScene() async {
    if (!_isInitialized || _isCreatingNextScene) {
      return;
    }

    setState(() {
      _isCreatingNextScene = true;
    });

    try {
      final StoryController storyController = context.read<StoryController>();
      final Duration position = _isWindowsPlatform
          ? _currentPosition
          : (_controller?.value.position ?? Duration.zero);
      final Uint8List? frameBytes = await _captureCurrentFrame(position);

      if (frameBytes == null || frameBytes.isEmpty) {
        if (!mounted) {
          return;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('現在のフレームを取得できませんでした')),
        );
        return;
      }

      final String frameName = 'next_scene_${DateTime.now().millisecondsSinceEpoch}.png';
      final StoryScene? createdScene = await storyController.createNextSceneFrom(
        sourceSceneId: widget.sceneId,
        frameBytes: frameBytes,
        framePosition: position,
        frameFileName: frameName,
      );

      if (!mounted) {
        return;
      }

      if (createdScene == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('次のシーンの作成に失敗しました')),
        );
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${createdScene.title} を追加しました')),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Next Sceneの作成に失敗しました: $error')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isCreatingNextScene = false;
        });
      }
    }
  }

  Future<Uint8List?> _captureCurrentFrame(Duration position) async {
    try {
      final int totalMillis;
      if (_isWindowsPlatform) {
        totalMillis = _totalDuration.inMilliseconds;
      } else {
        totalMillis = _controller?.value.duration.inMilliseconds ?? 0;
      }
      final int clampedPosition = totalMillis > 0
          ? position.inMilliseconds.clamp(0, totalMillis)
          : position.inMilliseconds;

      return await VideoThumbnail.thumbnailData(
        video: widget.videoPath,
        imageFormat: ImageFormat.PNG,
        timeMs: clampedPosition,
        quality: 100,
      );
    } catch (error, stackTrace) {
      debugPrint('Failed to capture current frame: $error\n$stackTrace');
      return null;
    }
  }

  Widget _buildWindowsProgressControls() {
    final int totalMillis = _totalDuration.inMilliseconds;
    final int positionMillis = totalMillis > 0
        ? _currentPosition.inMilliseconds.clamp(0, totalMillis)
        : _currentPosition.inMilliseconds;
    final double sliderMax = totalMillis > 0 ? totalMillis.toDouble() : 1;
    final double sliderValue = totalMillis > 0 ? positionMillis.toDouble() : 0;

    return Column(
      children: <Widget>[
        Slider(
          value: sliderValue,
          max: sliderMax,
          onChanged: totalMillis == 0
              ? null
              : (double value) {
                  final mk.Player? player = _windowsPlayer;
                  if (player == null) {
                    return;
                  }
                  unawaited(player.seek(Duration(milliseconds: value.round())));
                },
          activeColor: const Color(0xff4a9eff),
          inactiveColor: const Color(0xff253143),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Text(
              _formatDuration(_currentPosition),
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
            const Text(
              ' / ',
              style: TextStyle(color: Colors.white38, fontSize: 12),
            ),
            Text(
              _formatDuration(_totalDuration),
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildStandardProgressControls(VideoPlayerController controller) {
    final Duration duration = controller.value.duration;
    final Duration position = controller.value.position;
    final int totalMillis = duration.inMilliseconds;
    final int positionMillis = totalMillis > 0
        ? position.inMilliseconds.clamp(0, totalMillis)
        : position.inMilliseconds;
    final double sliderMax = totalMillis > 0 ? totalMillis.toDouble() : 1;
    final double sliderValue = totalMillis > 0 ? positionMillis.toDouble() : 0;

    return Column(
      children: <Widget>[
        Slider(
          value: sliderValue,
          max: sliderMax,
          onChanged: totalMillis == 0
              ? null
              : (double value) {
                  unawaited(controller.seekTo(Duration(milliseconds: value.round())));
                  if (mounted) {
                    setState(() {});
                  }
                },
          activeColor: const Color(0xff4a9eff),
          inactiveColor: const Color(0xff253143),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Text(
              _formatDuration(position),
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
            const Text(
              ' / ',
              style: TextStyle(color: Colors.white38, fontSize: 12),
            ),
            Text(
              _formatDuration(duration),
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ],
        ),
      ],
    );
  }

  @override
  void dispose() {
    _disposeVideoResources();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xff18212b),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Icon(Icons.play_circle, color: Color(0xff4a9eff)),
                const SizedBox(width: 8),
                const Text(
                  '動画プレビュー',
                  style: TextStyle(color: Colors.white70, fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                if (_isInitialized) ...<Widget>[
                  IconButton(
                    tooltip: 'ダウンロード',
                    icon: const Icon(Icons.download, color: Color(0xff00d4aa)),
                    onPressed: _downloadVideo,
                  ),
                  IconButton(
                    icon: Icon(
                      _isWindowsPlatform
                          ? (_isWindowsPlaying ? Icons.pause : Icons.play_arrow)
                          : ((_controller?.value.isPlaying ?? false) ? Icons.pause : Icons.play_arrow),
                      color: Colors.white70,
                    ),
                    onPressed: _togglePlayback,
                  ),
                ],
              ],
            ),
            const SizedBox(height: 16),
            if (_errorMessage != null)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xff3a1f1f),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xffff4d5a)),
                ),
                child: Row(
                  children: <Widget>[
                    const Icon(Icons.error_outline, color: Color(0xffff4d5a)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _errorMessage!,
                        style: const TextStyle(color: Color(0xffffd9d3)),
                      ),
                    ),
                  ],
                ),
              )
            else if (!_isInitialized)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(40),
                  child: CircularProgressIndicator(color: Color(0xff4a9eff)),
                ),
              )
            else if (_isWindowsPlatform && _windowsVideoController != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: AspectRatio(
                  aspectRatio: _windowsAspectRatio,
                  child: mk_video.Video(
                    controller: _windowsVideoController!,
                    controls: (mk_video.VideoState state) => const SizedBox.shrink(),
                  ),
                ),
              )
            else if (_controller != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: AspectRatio(
                  aspectRatio: _controller!.value.aspectRatio,
                  child: VideoPlayer(_controller!),
                ),
              ),
            if (_isInitialized) ...<Widget>[
              const SizedBox(height: 12),
              if (_isWindowsPlatform)
                _buildWindowsProgressControls()
              else if (_controller != null)
                _buildStandardProgressControls(_controller!),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xff4a9eff),
                    foregroundColor: Colors.white,
                    minimumSize: const Size(160, 44),
                  ),
                  onPressed: _isCreatingNextScene ? null : _handleNextScene,
                  icon: _isCreatingNextScene
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.skip_next),
                  label: Text(_isCreatingNextScene ? '準備中...' : 'Next Scene'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final String minutes = twoDigits(duration.inMinutes.remainder(60));
    final String seconds = twoDigits(duration.inSeconds.remainder(60));
    return '$minutes:$seconds';
  }
}
