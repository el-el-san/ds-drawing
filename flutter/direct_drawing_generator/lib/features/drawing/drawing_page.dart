import 'dart:async';
import 'package:universal_io/io.dart';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import 'drawing_controller.dart';
import 'models/app_settings.dart';
import 'models/drawing_mode.dart';
import 'models/generation_state.dart';
import 'services/mcp_health_checker.dart';
import 'widgets/drawing_canvas.dart';
import '../../shared/app_settings_controller.dart';
import '../../shared/web/file_saver.dart' as web_file_saver;
import '../story/story_controller.dart';

class DrawingPage extends StatefulWidget {
  const DrawingPage({super.key, required this.settingsController});

  final AppSettingsController settingsController;

  @override
  State<DrawingPage> createState() => _DrawingPageState();
}

class _DrawingPageState extends State<DrawingPage> {
  late final DrawingController _controller;
  final TextEditingController _textController = TextEditingController();
  final TextEditingController _promptController = TextEditingController();
  final GlobalKey _repaintBoundaryKey = GlobalKey();
  final ScrollController _logScrollController = ScrollController();
  bool _isSaving = false;
  bool _logPanelExpanded = false;
  double _resolutionScale = 1.0; // Seedream解像度倍率
  double _logPanelHeight = 250.0; // ログパネルの高さ（ドラッグ可能）
  int _lastLogCount = 0; // ログの数を追跡してオートスクロール

  static const List<Color> _presetPalette = <Color>[
    Color(0xffff4d5a),
    Color(0xff4a9eff),
    Color(0xff2dd4bf),
    Color(0xfffacc15),
    Color(0xffffffff),
    Color(0xffd946ef),
    Color(0xfff97316),
    Color(0xff111827),
  ];

  @override
  void initState() {
    super.initState();
    _controller = DrawingController(settingsController: widget.settingsController);
    DrawingControllerRegistry.instance = _controller;
    _controller.init();
  }

  @override
  void dispose() {
    DrawingControllerRegistry.instance = null;
    _controller.dispose();
    _textController.dispose();
    _promptController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<DrawingController>.value(
      value: _controller,
      child: Consumer<DrawingController>(
        builder: (BuildContext context, DrawingController controller, _) {
          if (!controller.isInitialized) {
            return const Scaffold(
              backgroundColor: Color(0xff0f141b),
              body: Center(
                child: CircularProgressIndicator(),
              ),
            );
          }
          return LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final bool isWide = constraints.maxWidth >= 960;
              return Scaffold(
                backgroundColor: const Color(0xff0f141b),
                appBar: AppBar(
                  title: const Text('Direct Drawing Generator'),
                  backgroundColor: const Color(0xff1b2430),
                  actions: <Widget>[
                    IconButton(
                      tooltip: 'Undo',
                      onPressed: controller.hasUndo ? controller.undo : null,
                      icon: const Icon(Icons.undo),
                    ),
                    IconButton(
                      tooltip: 'Redo',
                      onPressed: controller.hasRedo ? controller.redo : null,
                      icon: const Icon(Icons.redo),
                    ),
                    IconButton(
                      tooltip: 'Clear',
                      onPressed: controller.strokes.isEmpty && controller.texts.isEmpty
                          ? null
                          : controller.clear,
                      icon: const Icon(Icons.layers_clear),
                    ),
                    const SizedBox(width: 8),
                  ],
                ),
                body: Column(
                  children: <Widget>[
                    Expanded(
                      child: SafeArea(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: isWide
                              ? Row(
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: <Widget>[
                                    SizedBox(
                                      width: 320,
                                      child: SingleChildScrollView(
                                        child: _buildControlPanel(context, controller),
                                      ),
                                    ),
                                    const SizedBox(width: 16),
                                    Expanded(child: _buildCanvasArea(context, controller)),
                                  ],
                                )
                              : SingleChildScrollView(
                                  child: Column(
                                    children: <Widget>[
                                      // キャンバスエリア（ヘッダー、キャンバス、コントロールを直接配置）
                                      // 画像のアスペクト比に完全に従ってキャンバス高さを計算
                                      // BoxFit.contain使用時、キャンバスと画像のアスペクト比が一致するため
                                      // 空白なく横幅いっぱいに表示される
                                      LayoutBuilder(
                                        builder: (BuildContext context, BoxConstraints constraints) {
                                          final double availableWidth = constraints.maxWidth;

                                          // リファレンス画像のアスペクト比を取得
                                          final double aspectRatio = _calculateAspectRatio(controller);

                                          // 純粋なキャンバスの高さを計算（画像のアスペクト比に100%従う）
                                          final double pureCanvasHeight = availableWidth / aspectRatio;

                                          return Container(
                                            decoration: BoxDecoration(
                                              color: const Color(0xff151d24),
                                              borderRadius: BorderRadius.circular(16),
                                              boxShadow: const <BoxShadow>[
                                                BoxShadow(
                                                  color: Colors.black38,
                                                  offset: Offset(0, 18),
                                                  blurRadius: 36,
                                                ),
                                              ],
                                            ),
                                            clipBehavior: Clip.antiAlias,
                                            child: Column(
                                              children: <Widget>[
                                                _CanvasHeader(controller: controller),
                                                const Divider(height: 1, color: Color(0xff252f3b)),
                                                SizedBox(
                                                  height: pureCanvasHeight,
                                                  child: Stack(
                                                    children: <Widget>[
                                                      Positioned.fill(
                                                        child: DrawingCanvas(
                                                          controller: controller,
                                                          repaintKey: _repaintBoundaryKey,
                                                          onTextPlacement: (Offset offset) {
                                                            _controller.placeText(
                                                              text: _textController.text,
                                                              at: offset,
                                                            );
                                                            if (_controller.mode == DrawingMode.text) {
                                                              FocusScope.of(context).unfocus();
                                                            }
                                                          },
                                                        ),
                                                      ),
                                                      if (_isSaving)
                                                        const Positioned.fill(
                                                          child: ColoredBox(
                                                            color: Color(0xaa000000),
                                                            child: Center(
                                                              child: CircularProgressIndicator(),
                                                            ),
                                                          ),
                                                        ),
                                                    ],
                                                  ),
                                                ),
                                                const Divider(height: 1, color: Color(0xff252f3b)),
                                                _buildSizeControls(context, controller),
                                              ],
                                            ),
                                          );
                                        },
                                      ),
                                      const SizedBox(height: 16),
                                      _buildControlPanel(context, controller),
                                    ],
                                  ),
                                ),
                        ),
                      ),
                    ),
                    _buildLogPanel(controller),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  double _calculateAspectRatio(DrawingController controller) {
    // リファレンス画像が読み込まれている場合は、その画像のアスペクト比を使用
    if (controller.referenceImage != null) {
      final ui.Image image = controller.referenceImage!;
      // 高さ0の画像など、不正な値によるゼロ除算を避ける
      if (image.height > 0) {
        final double aspectRatio = image.width / image.height;
        debugPrint('リファレンス画像のアスペクト比を使用: $aspectRatio (${image.width} x ${image.height})');
        return aspectRatio;
      }
    }

    // リファレンス画像がない場合は16:9（約1.78）のアスペクト比をデフォルトとする
    // これにより、画像がなくても適切なキャンバスサイズで表示される
    return 16.0 / 9.0;
  }

  Widget _buildCanvasArea(BuildContext context, DrawingController controller) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xff151d24),
        borderRadius: BorderRadius.circular(16),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Colors.black38,
            offset: Offset(0, 18),
            blurRadius: 36,
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: <Widget>[
          _CanvasHeader(controller: controller),
          const Divider(height: 1, color: Color(0xff252f3b)),
          Expanded(
            child: Stack(
              children: <Widget>[
                Positioned.fill(
                  child: DrawingCanvas(
                    controller: controller,
                    repaintKey: _repaintBoundaryKey,
                    onTextPlacement: (Offset offset) {
                      _controller.placeText(
                        text: _textController.text,
                        at: offset,
                      );
                      if (_controller.mode == DrawingMode.text) {
                        FocusScope.of(context).unfocus();
                      }
                    },
                  ),
                ),
                if (_isSaving)
                  const Positioned.fill(
                    child: ColoredBox(
                      color: Color(0xaa000000),
                      child: Center(
                        child: CircularProgressIndicator(),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1, color: Color(0xff252f3b)),
          _buildSizeControls(context, controller),
        ],
      ),
    );
  }

  Widget _buildControlPanel(BuildContext context, DrawingController controller) {
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('Reference Assets', style: theme.textTheme.titleMedium?.copyWith(color: Colors.white70)),
        const SizedBox(height: 12),
        Row(
            children: <Widget>[
              Expanded(
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xff3b82f6),
                    foregroundColor: Colors.white,
                  ),
                  onPressed: _pickReferenceImage,
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Import Reference'),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Remove reference image',
                onPressed: controller.hasReferenceImage ? controller.removeReferenceImage : null,
                icon: const Icon(Icons.delete_forever),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (controller.referenceImageBytes != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.memory(
                controller.referenceImageBytes!,
                fit: BoxFit.cover,
                height: 160,
                width: double.infinity,
                errorBuilder: (BuildContext context, Object error, StackTrace? stackTrace) {
                  debugPrint('❌ 画像表示エラー: $error');
                  return Container(
                    height: 160,
                    width: double.infinity,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xffff4d5a)),
                      color: const Color(0xff121821),
                    ),
                    alignment: Alignment.center,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: <Widget>[
                        const Icon(Icons.error, color: Color(0xffff4d5a)),
                        const SizedBox(height: 8),
                        Text(
                          'Error: ${error.toString()}',
                          style: const TextStyle(color: Color(0xffff4d5a), fontSize: 11),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  );
                },
              ),
            )
          else
            Container(
              height: 160,
              width: double.infinity,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xff2b3645)),
                color: const Color(0xff121821),
              ),
              alignment: Alignment.center,
              child: const Text(
                'No reference image',
                style: TextStyle(color: Colors.white38),
              ),
            ),
          const SizedBox(height: 24),
          Text('Brush Colors', style: theme.textTheme.titleMedium?.copyWith(color: Colors.white70)),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: <Widget>[
              for (final Color color in _presetPalette)
                _ColorSwatch(
                  color: color,
                  isSelected: controller.penColor.value == color.value,
                  onSelected: () => controller.setPenColor(color),
                ),
              _ColorSwatch(
                color: controller.penColor,
                isSelected: false,
                onSelected: _openColorPicker,
                child: const Icon(Icons.palette, color: Colors.white, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Text('Tools', style: theme.textTheme.titleMedium?.copyWith(color: Colors.white70)),
          const SizedBox(height: 12),
          ToggleButtons(
            isSelected: <bool>[
              controller.isPenActive,
              controller.isEraserActive,
              controller.isTextActive,
            ],
            onPressed: (int index) {
              switch (index) {
                case 0:
                  controller.setMode(DrawingMode.pen);
                  break;
                case 1:
                  controller.setMode(DrawingMode.eraser);
                  break;
                case 2:
                  controller.setMode(DrawingMode.text);
                  break;
              }
            },
            borderRadius: BorderRadius.circular(12),
            selectedBorderColor: const Color(0xff4a9eff),
            fillColor: const Color(0xff223b57),
            color: Colors.white60,
            selectedColor: Colors.white,
            constraints: const BoxConstraints(minHeight: 48, minWidth: 88),
            children: const <Widget>[
              Row(mainAxisAlignment: MainAxisAlignment.center, children: <Widget>[Icon(Icons.edit), SizedBox(width: 6), Text('Draw')]),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: <Widget>[Icon(Icons.auto_fix_high), SizedBox(width: 6), Text('Erase')]),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: <Widget>[Icon(Icons.text_fields), SizedBox(width: 6), Text('Text')]),
            ],
          ),
          const SizedBox(height: 24),
          Text('Text Prompt', style: theme.textTheme.titleMedium?.copyWith(color: Colors.white70)),
          const SizedBox(height: 8),
          TextField(
            controller: _textController,
            maxLines: 2,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: 'Enter text to stamp on canvas',
              hintStyle: const TextStyle(color: Colors.white38),
              filled: true,
              fillColor: const Color(0xff18212b),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Color(0xff253143)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Color(0xff3b82f6)),
              ),
            ),
          ),
          const SizedBox(height: 24),
          Text('AI Image Generation', style: theme.textTheme.titleMedium?.copyWith(color: Colors.white70)),
          const SizedBox(height: 12),
          TextField(
            controller: _promptController,
            maxLines: 3,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: '編集したい内容（例: 色味を暖色に、肌をなめらかに、背景を夕景に など）',
              hintStyle: const TextStyle(color: Colors.white38),
              filled: true,
              fillColor: const Color(0xff18212b),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Color(0xff253143)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Color(0xff3b82f6)),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xff18212b),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xff253143)),
            ),
            child: Row(
              children: <Widget>[
                const Icon(Icons.photo_size_select_large, color: Colors.white70, size: 20),
                const SizedBox(width: 12),
                const Text('解像度:', style: TextStyle(color: Colors.white70, fontSize: 14)),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButton<double>(
                    value: _resolutionScale,
                    isExpanded: true,
                    dropdownColor: const Color(0xff1b2430),
                    style: const TextStyle(color: Colors.white),
                    underline: Container(),
                    items: const <DropdownMenuItem<double>>[
                      DropdownMenuItem<double>(
                        value: 1.0,
                        child: Text('x1 (入力画像と同じ)'),
                      ),
                      DropdownMenuItem<double>(
                        value: 1.5,
                        child: Text('x1.5 (1.5倍)'),
                      ),
                      DropdownMenuItem<double>(
                        value: 2.0,
                        child: Text('x2 (2倍)'),
                      ),
                    ],
                    onChanged: (double? newValue) {
                      if (newValue != null) {
                        setState(() {
                          _resolutionScale = newValue;
                        });
                      }
                    },
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xffa855f7),
                    foregroundColor: Colors.white,
                    minimumSize: const Size.fromHeight(48),
                  ),
                  onPressed: () => _generateWithNanoBanana(controller),
                  icon: const Icon(Icons.auto_awesome),
                  label: const Text('Nano Banana'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xff4a9eff),
                    foregroundColor: Colors.white,
                    minimumSize: const Size.fromHeight(48),
                  ),
                  onPressed: () => _generateWithSeedream(controller),
                  icon: const Icon(Icons.auto_fix_high),
                  label: const Text('Seedream'),
                ),
              ),
            ],
          ),
          ..._buildGenerationStatusWidgets(controller),
          if (controller.generationResults.isNotEmpty) ...<Widget>[
            const SizedBox(height: 16),
            Row(
              children: <Widget>[
                Text('Generated Results', style: theme.textTheme.titleMedium?.copyWith(color: Colors.white70)),
                const Spacer(),
                TextButton.icon(
                  onPressed: () => _confirmClearAllResults(controller),
                  icon: const Icon(Icons.delete_sweep, size: 18),
                  label: const Text('全消去'),
                  style: TextButton.styleFrom(foregroundColor: Colors.white70),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 120,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: controller.generationResults.length,
                itemBuilder: (BuildContext context, int index) {
                  final result = controller.generationResults[index];
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Stack(
                      children: <Widget>[
                        GestureDetector(
                          onTap: () => _loadResultAsReference(result),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.network(
                              result.imageUrl,
                              width: 120,
                              height: 120,
                              fit: BoxFit.cover,
                              errorBuilder: (BuildContext context, Object error, StackTrace? stackTrace) {
                                return Container(
                                  width: 120,
                                  height: 120,
                                  color: const Color(0xff2b3645),
                                  child: const Icon(Icons.error, color: Colors.white38),
                                );
                              },
                            ),
                          ),
                        ),
                        Positioned(
                          top: 4,
                          right: 4,
                          child: IconButton(
                            icon: const Icon(Icons.close, color: Colors.white, size: 18),
                            tooltip: 'この結果を削除',
                            style: IconButton.styleFrom(
                              backgroundColor: const Color(0xaa000000),
                              padding: const EdgeInsets.all(4),
                              minimumSize: const Size(28, 28),
                            ),
                            onPressed: () => _removeGenerationResultAt(controller, index),
                          ),
                        ),
                        Positioned(
                          bottom: 4,
                          right: 4,
                          child: IconButton(
                            icon: const Icon(Icons.download, color: Colors.white, size: 20),
                            style: IconButton.styleFrom(
                              backgroundColor: const Color(0xaa000000),
                              padding: const EdgeInsets.all(4),
                              minimumSize: const Size(28, 28),
                            ),
                            onPressed: () => _downloadResultImage(result),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
          const SizedBox(height: 24),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xff00d4aa),
              foregroundColor: Colors.white,
              minimumSize: const Size.fromHeight(50),
            ),
            onPressed: _isSaving ? null : _exportDrawing,
            icon: const Icon(Icons.download),
            label: Text(_isSaving ? 'Preparing image...' : 'Save & Share'),
          ),
        ],
      );
  }

  List<Widget> _buildGenerationStatusWidgets(DrawingController controller) {
    final GenerationState nanoState = controller.generationStateFor(GenerationEngine.nanoBanana);
    final GenerationState seedState = controller.generationStateFor(GenerationEngine.seedream);
    final bool showNano = nanoState != GenerationState.idle || controller.activeGenerationCountFor(GenerationEngine.nanoBanana) > 0;
    final bool showSeed = seedState != GenerationState.idle || controller.activeGenerationCountFor(GenerationEngine.seedream) > 0;

    if (!showNano && !showSeed) {
      return const <Widget>[];
    }

    return <Widget>[
      const SizedBox(height: 12),
      if (showNano) _buildGenerationStatus(controller, GenerationEngine.nanoBanana, nanoState),
      if (showNano && showSeed) const SizedBox(height: 8),
      if (showSeed) _buildGenerationStatus(controller, GenerationEngine.seedream, seedState),
    ];
  }

  Widget _buildGenerationStatus(
    DrawingController controller,
    GenerationEngine engine,
    GenerationState state,
  ) {
    String statusText;
    Color statusColor;
    IconData statusIcon;
    bool showSpinner;
    final int activeCount = controller.activeGenerationCountFor(engine);

    switch (state) {
      case GenerationState.uploading:
        statusText = 'アップロード中...';
        statusColor = const Color(0xff4a9eff);
        statusIcon = Icons.cloud_upload;
        showSpinner = true;
        break;
      case GenerationState.submitting:
        statusText = '生成リクエスト送信中...';
        statusColor = const Color(0xff4a9eff);
        statusIcon = Icons.send;
        showSpinner = true;
        break;
      case GenerationState.generating:
        statusText = 'AI画像生成中...';
        statusColor = const Color(0xffa855f7);
        statusIcon = Icons.auto_awesome;
        showSpinner = true;
        break;
      case GenerationState.completed:
        statusText = '生成完了！';
        statusColor = const Color(0xff00d4aa);
        statusIcon = Icons.check_circle;
        showSpinner = false;
        break;
      case GenerationState.error:
        statusText = 'エラー: ${controller.generationErrorFor(engine) ?? "不明なエラー"}';
        statusColor = const Color(0xffff4d5a);
        statusIcon = Icons.error;
        showSpinner = false;
        break;
      default:
        statusText = '';
        statusColor = Colors.white60;
        statusIcon = Icons.info;
        showSpinner = false;
    }

    final String label = engine.label;
    String countSuffix = '';
    if (activeCount > 0) {
      if (showSpinner) {
        countSuffix = ' (実行中: $activeCount件)';
      } else if (state == GenerationState.error) {
        countSuffix = ' (他に$activeCount件実行中)';
      }
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xff18212b),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: statusColor.withOpacity(0.3)),
      ),
      child: Row(
        children: <Widget>[
          if (showSpinner)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70),
            )
          else
            Icon(statusIcon, color: statusColor, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '$label: $statusText$countSuffix',
              style: TextStyle(color: statusColor, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _generateWithNanoBanana(DrawingController controller) async {
    final String prompt = _promptController.text.trim();
    if (prompt.isEmpty) {
      _showSnackBar('プロンプトを入力してください');
      return;
    }
    final AppSettings settings = _controller.settings;
    if (settings.uploadEndpoint.isEmpty || settings.nanoBananaEndpoint.isEmpty) {
      _showSnackBar('必須のサーバー設定が未入力です。設定タブで設定してください。');
      return;
    }
    final String? authError = await controller.ensureUploadAuthorization(
      context,
      engine: GenerationEngine.nanoBanana,
    );
    if (authError != null) {
      _showSnackBar(authError);
      return;
    }
    final GenerationRunResult result = await controller.generateWithNanoBanana(
      prompt: prompt,
      canvasKey: _repaintBoundaryKey,
    );

    if (!mounted) {
      return;
    }

    if (result.success) {
      _showSnackBar('画像生成が完了しました！');
    } else {
      final String message = result.errorMessage ?? controller.generationErrorFor(GenerationEngine.nanoBanana) ?? '不明なエラー';
      _showSnackBar('画像生成に失敗しました: $message');
    }

    await _showGenerationLogDialog(
      title: 'Nano Banana Edit',
      logs: result.logs,
      success: result.success,
    );
  }

  Future<void> _generateWithSeedream(DrawingController controller) async {
    final String prompt = _promptController.text.trim();
    if (prompt.isEmpty) {
      _showSnackBar('プロンプトを入力してください');
      return;
    }
    final AppSettings settings = _controller.settings;
    if (settings.uploadEndpoint.isEmpty || settings.seedreamEndpoint.isEmpty) {
      _showSnackBar('必須のサーバー設定が未入力です。設定タブで設定してください。');
      return;
    }
    final String? authError = await controller.ensureUploadAuthorization(
      context,
      engine: GenerationEngine.seedream,
    );
    if (authError != null) {
      _showSnackBar(authError);
      return;
    }
    // リファレンス画像のサイズを取得して解像度を計算
    Map<String, dynamic>? imageSize;
    if (controller.hasReferenceImage && controller.referenceImage != null) {
      final int baseWidth = controller.referenceImage!.width;
      final int baseHeight = controller.referenceImage!.height;
      final int scaledWidth = (baseWidth * _resolutionScale).round().clamp(256, 4096);
      final int scaledHeight = (baseHeight * _resolutionScale).round().clamp(256, 4096);
      imageSize = <String, dynamic>{
        'width': scaledWidth,
        'height': scaledHeight,
      };
      debugPrint('[解像度] 基準: ${baseWidth}x$baseHeight, 倍率: x$_resolutionScale, 出力: ${scaledWidth}x$scaledHeight');
    }

    final GenerationRunResult result = await controller.generateWithSeedream(
      prompt: prompt,
      canvasKey: _repaintBoundaryKey,
      imageSize: imageSize,
    );

    if (!mounted) {
      return;
    }

    if (result.success) {
      _showSnackBar('画像生成が完了しました！');
    } else {
      final String message = result.errorMessage ?? controller.generationErrorFor(GenerationEngine.seedream) ?? '不明なエラー';
      _showSnackBar('画像生成に失敗しました: $message');
    }

    await _showGenerationLogDialog(
      title: 'Seedream Edit',
      logs: result.logs,
      success: result.success,
    );
  }

  Future<void> _showGenerationLogDialog({
    required String title,
    required List<String> logs,
    required bool success,
  }) async {
    if (!mounted || logs.isEmpty) {
      return;
    }

    final String logText = logs.join('\n');
    final Color iconColor = success ? const Color(0xff00d4aa) : const Color(0xffff4d5a);
    final IconData iconData = success ? Icons.check_circle : Icons.error;

    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          backgroundColor: const Color(0xff1b2430),
          title: Row(
            children: <Widget>[
              Icon(iconData, color: iconColor),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '$title ログ',
                  style: const TextStyle(color: Colors.white),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                tooltip: 'ログをコピー',
                color: Colors.white70,
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: logText));
                  if (mounted) {
                    _showSnackBar('ログをコピーしました');
                  }
                },
                icon: const Icon(Icons.copy),
              ),
            ],
          ),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 320, maxWidth: 520),
            child: Scrollbar(
              thumbVisibility: true,
              child: SingleChildScrollView(
                child: SelectableText(
                  logText,
                  style: const TextStyle(
                    fontSize: 12,
                    fontFamily: 'monospace',
                    color: Colors.white70,
                  ),
                ),
              ),
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: logText));
                if (mounted) {
                  _showSnackBar('ログをコピーしました');
                }
              },
              child: const Text('ログをコピー'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: const Color(0xff4a9eff)),
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('閉じる'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _loadResultAsReference(dynamic result) async {
    try {
      await _controller.loadGenerationResultAsReference(result);
      _showSnackBar('生成結果をリファレンスとして読み込みました');
    } catch (e) {
      _showSnackBar('画像の読み込みに失敗しました: $e');
    }
  }

  Future<void> _downloadResultImage(dynamic result) async {
    try {
      setState(() {
        _isSaving = true;
      });

      final String imageUrl = result.imageUrl as String;
      final http.Response response = await http.get(Uri.parse(imageUrl));

      if (response.statusCode != 200) {
        throw Exception('画像のダウンロードに失敗しました: ${response.statusCode}');
      }

      final Uint8List imageBytes = response.bodyBytes;
      final String fileName = 'ai_generated_${DateTime.now().millisecondsSinceEpoch}.png';

      if (kIsWeb) {
        final bool handled = await web_file_saver.triggerDownload(
          fileName: fileName,
          bytes: imageBytes,
          mimeType: 'image/png',
        );
        if (handled) {
          _showSnackBar('Download started in browser');
          return;
        }
      }

      Directory? directory;
      if (Platform.isAndroid) {
        directory = await getExternalStorageDirectory();
      }
      directory ??= await getApplicationDocumentsDirectory();
      Directory targetDirectory = directory;

      if (Platform.isWindows) {
        final Directory videosDir = Directory('${targetDirectory.path}/videos');
        if (!await videosDir.exists()) {
          await videosDir.create(recursive: true);
        }
        targetDirectory = videosDir;
      }

      if (!await targetDirectory.exists()) {
        await targetDirectory.create(recursive: true);
      }

      final String filePath = '${targetDirectory.path}/$fileName';
      final File file = File(filePath);
      await file.writeAsBytes(imageBytes);

      if (!mounted) {
        return;
      }

      _showSnackBar('画像を保存しました: $fileName');

      if (!Platform.isWindows) {
        await Share.shareXFiles(
          <XFile>[XFile(filePath)],
          text: 'AI Generated Image',
        );
      }
    } catch (e, stackTrace) {
      if (kDebugMode) {
        debugPrint('downloadResultImage error: $e\n$stackTrace');
      }
      if (!mounted) {
        return;
      }
      _showSnackBar('画像のダウンロードに失敗しました: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  Future<void> _confirmClearAllResults(DrawingController controller) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          backgroundColor: const Color(0xff1b2430),
          title: const Text('生成結果を全て削除しますか？', style: TextStyle(color: Colors.white)),
          content: const Text(
            'この操作は元に戻せません。続行する場合は「削除」を押してください。',
            style: TextStyle(color: Colors.white70),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('キャンセル'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: const Color(0xffff4d5a)),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('削除'),
            ),
          ],
        );
      },
    );

    if (confirmed == true) {
      controller.clearGenerationResults();
      if (!mounted) {
        return;
      }
      _showSnackBar('生成結果を全て削除しました');
    }
  }

  void _removeGenerationResultAt(DrawingController controller, int index) {
    controller.removeGenerationResultAt(index);
    if (!mounted) {
      return;
    }
    _showSnackBar('生成結果を削除しました');
  }

  Widget _buildSizeControls(BuildContext context, DrawingController controller) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
      decoration: const BoxDecoration(
        color: Color(0xff111a23),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _SliderTile(
            label: 'Brush Size',
            value: controller.penSize,
            min: 1,
            max: 80,
            onChanged: controller.setPenSize,
          ),
          const SizedBox(height: 12),
          _SliderTile(
            label: 'Eraser Size',
            value: controller.eraserSize,
            min: 8,
            max: 200,
            onChanged: controller.setEraserSize,
          ),
          const SizedBox(height: 12),
          _SliderTile(
            label: 'Text Size',
            value: controller.textSize,
            min: 12,
            max: 160,
            onChanged: controller.setTextSize,
          ),
        ],
      ),
    );
  }

  Future<void> _pickReferenceImage() async {
    try {
      debugPrint('🖼️ ファイルピッカーを開始...');
      final FilePickerResult? result = await FilePicker.platform.pickFiles(type: FileType.image);

      if (result == null) {
        debugPrint('❌ ファイルピッカーがキャンセルされました');
        return;
      }

      if (result.files.isEmpty) {
        debugPrint('❌ 選択されたファイルがありません');
        return;
      }

      final PlatformFile pickedFile = result.files.first;

      Uint8List? bytes = pickedFile.bytes;
      if (bytes == null) {
        final String? path = pickedFile.path;
        if (path == null) {
          debugPrint('❌ ファイルのバイトデータとパスが取得できませんでした');
          _showSnackBar('画像データの読み込みに失敗しました');
          return;
        }

        // Android などでは bytes が省略されるため、パスから読み込む
        bytes = await File(path).readAsBytes();
      }

      final int byteLength = bytes.length;
      debugPrint('✅ 画像を選択しました: ${pickedFile.name}, サイズ: $byteLength bytes');

      await _controller.loadReferenceImage(bytes);
      debugPrint('✅ リファレンス画像を読み込みました');
      _showSnackBar('リファレンス画像を読み込みました');
    } catch (error, stackTrace) {
      debugPrint('❌ 画像インポートエラー: $error');
      if (kDebugMode) {
        debugPrint('スタックトレース: $stackTrace');
      }
      _showSnackBar('画像の読み込みに失敗しました: $error');
    }
  }

  Future<void> _openColorPicker() async {
    Color tempColor = _controller.penColor;
    final Color? picked = await showDialog<Color>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: const Color(0xff1b2430),
          title: const Text('Select Color'),
          content: SingleChildScrollView(
            child: BlockPicker(
              pickerColor: tempColor,
              availableColors: _presetPalette,
              onColorChanged: (Color value) {
                tempColor = value;
              },
            ),
          ),
          actions: <Widget>[
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, tempColor), child: const Text('Select')),
          ],
        );
      },
    );

    if (picked != null) {
      _controller.setPenColor(picked);
    }
  }

  Future<void> _exportDrawing() async {
    if (_isSaving) {
      return;
    }
    setState(() => _isSaving = true);
    try {
      final Uint8List bytes = await _capturePng();
      if (bytes.isEmpty) {
        _showSnackBar('Nothing to save yet');
        return;
      }
      final String fileName = _buildFileName();
      if (kIsWeb) {
        final bool handled = await web_file_saver.triggerDownload(
          fileName: fileName,
          bytes: bytes,
          mimeType: 'image/png',
        );
        if (handled) {
          _showSnackBar('Download started in browser');
          return;
        }
      }

      final String? subDirectory = Platform.isWindows ? 'videos' : null;
      final File file = await _persistToFile(bytes, subDirectory: subDirectory);
      if (!Platform.isWindows) {
        await Share.shareXFiles(<XFile>[XFile(file.path)]);
      }
      _showSnackBar('Saved to ${file.path}');
    } catch (error, stackTrace) {
      if (kDebugMode) {
        debugPrint('Failed to save drawing: $error\n$stackTrace');
      }
      _showSnackBar('Save failed. Please try again.');
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  Future<Uint8List> _capturePng() async {
    final RenderRepaintBoundary? boundary =
        _repaintBoundaryKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) {
      return Uint8List(0);
    }
    final double dpr = MediaQuery.of(context).devicePixelRatio;
    final ui.Image image = await boundary.toImage(pixelRatio: dpr);
    final ByteData? byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    return byteData?.buffer.asUint8List() ?? Uint8List(0);
  }

  Future<File> _persistToFile(Uint8List bytes, {String? subDirectory}) async {
    final Directory directory = await getApplicationDocumentsDirectory();
    final String basePath = subDirectory == null ? directory.path : '${directory.path}/$subDirectory';
    if (subDirectory != null) {
      final Directory targetDir = Directory(basePath);
      if (!await targetDir.exists()) {
        await targetDir.create(recursive: true);
      }
    }
    final File file = File('$basePath/${_buildFileName()}');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  String _buildFileName() {
    final DateTime now = DateTime.now();
    return 'direct_drawing_${now.millisecondsSinceEpoch}.png';
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
      ),
    );
  }

  Widget _buildLogPanel(DrawingController controller) {
    final List<String> logs = controller.logs;
    final bool hasLogs = logs.isNotEmpty;

    // ログが増えたら自動的に最下部にスクロール
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
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      height: _logPanelExpanded ? _logPanelHeight : 43,
      decoration: const BoxDecoration(
        color: Color(0xff111827),
        border: Border(top: BorderSide(color: Color(0xff1f2937), width: 1)),
      ),
      child: Column(
        children: <Widget>[
          // ドラッグハンドル付きヘッダー
          GestureDetector(
            onVerticalDragUpdate: _logPanelExpanded
                ? (DragUpdateDetails details) {
                    setState(() {
                      // 上方向にドラッグすると高さが増える（deltaYは負）
                      _logPanelHeight = (_logPanelHeight - details.delta.dy).clamp(100.0, 600.0);
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
                  height: 42,
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
                          'デバッグログ',
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
                              style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ],
                        const Spacer(),
                        if (hasLogs && _logPanelExpanded)
                          IconButton(
                            icon: const Icon(Icons.copy, size: 18),
                            color: Colors.white70,
                            tooltip: 'ログをコピー',
                            onPressed: () async {
                              await Clipboard.setData(ClipboardData(text: logs.join('\n')));
                              if (mounted) {
                                _showSnackBar('ログをコピーしました');
                              }
                            },
                          ),
                        if (hasLogs && _logPanelExpanded)
                          IconButton(
                            icon: const Icon(Icons.clear_all, size: 18),
                            color: Colors.white70,
                            tooltip: 'ログをクリア',
                            onPressed: () {
                              controller.clearLogs();
                              setState(() {
                                _lastLogCount = 0;
                              });
                            },
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

                            if (log.contains('エラー') || log.contains('失敗')) {
                              textColor = const Color(0xffff4d5a);
                              iconData = Icons.error_outline;
                            } else if (log.contains('成功') || log.contains('完了')) {
                              textColor = const Color(0xff00d4aa);
                              iconData = Icons.check_circle_outline;
                            } else if (log.contains('===')) {
                              textColor = const Color(0xff4a9eff);
                              iconData = Icons.info_outline;
                            } else if (log.contains('HTTP') || log.contains('MCP')) {
                              textColor = const Color(0xfffacc15);
                              iconData = Icons.api;
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
    );
  }
}

class _ConnectionTestResult {
  _ConnectionTestResult({
    required this.label,
    required this.success,
    required this.summary,
    List<String>? details,
  }) : details = details ?? <String>[];

  final String label;
  final bool success;
  final String summary;
  final List<String> details;

  void dumpToDebug() {
    debugPrint('[ServerTest][$label] ${success ? 'OK' : 'NG'} — $summary');
    for (final String line in details) {
      debugPrint('[ServerTest][$label] $line');
    }
  }
}

class ServerSettingsDialog extends StatefulWidget {
  const ServerSettingsDialog({
    super.key,
    required this.initial,
  });

  final AppSettings initial;

  @override
  State<ServerSettingsDialog> createState() => _ServerSettingsDialogState();
}

class _ServerSettingsDialogState extends State<ServerSettingsDialog> {
  late final TextEditingController _uploadEndpointController;
  late final TextEditingController _exposeEndpointController;
  late final TextEditingController _uploadAuthEndpointController;
  late final TextEditingController _uploadTurnstileUrlController;
  late final TextEditingController _uploadAuthorizationController;
  late final TextEditingController _nanoBananaController;
  late final TextEditingController _seedreamController;
  late final TextEditingController _soraController;
  late final TextEditingController _veoController;
  final ScrollController _scrollController = ScrollController();

  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  bool _isTesting = false;
  bool _isRefreshingToken = false;

  bool get _requiresUploadConfigInput =>
      !AppSettings.hasEmbeddedUploadConfig ||
      !AppSettings.hasEmbeddedTokenEndpoint ||
      !AppSettings.hasEmbeddedTurnstileUrl;

  @override
  void initState() {
    super.initState();
    _uploadEndpointController = TextEditingController(text: widget.initial.uploadEndpoint);
    _exposeEndpointController = TextEditingController(text: widget.initial.exposeEndpoint);
    _uploadAuthEndpointController = TextEditingController(text: widget.initial.uploadAuthEndpoint);
    _uploadTurnstileUrlController = TextEditingController(text: widget.initial.uploadTurnstileUrl);
    _uploadAuthorizationController =
        TextEditingController(text: widget.initial.uploadAuthorization ?? '');
    _nanoBananaController = TextEditingController(text: widget.initial.nanoBananaEndpoint);
    _seedreamController = TextEditingController(text: widget.initial.seedreamEndpoint);
    _soraController = TextEditingController(text: widget.initial.soraEndpoint);
    _veoController = TextEditingController(text: widget.initial.veoEndpoint);
  }

  @override
  void dispose() {
    _uploadEndpointController.dispose();
    _exposeEndpointController.dispose();
    _uploadAuthEndpointController.dispose();
    _uploadTurnstileUrlController.dispose();
    _uploadAuthorizationController.dispose();
    _nanoBananaController.dispose();
    _seedreamController.dispose();
    _soraController.dispose();
    _veoController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Size screenSize = MediaQuery.of(context).size;
    final double dialogWidth = (screenSize.width - 32).clamp(280.0, 600.0).toDouble();
    final double maxDialogHeight = screenSize.height * 0.7;

    return AlertDialog(
      backgroundColor: const Color(0xff1b2430),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      title: const Row(
        children: <Widget>[
          Icon(Icons.settings, color: Color(0xff4a9eff)),
          SizedBox(width: 8),
          Text('サーバー設定'),
        ],
      ),
      content: SizedBox(
        width: dialogWidth,
        child: Scrollbar(
          controller: _scrollController,
          thumbVisibility: true,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxDialogHeight),
            child: SingleChildScrollView(
              controller: _scrollController,
              padding: const EdgeInsets.only(right: 8),
              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    _buildResetButton(),
                    const SizedBox(height: 20),
                    _buildUploadSection(),
                    const SizedBox(height: 16),
                    _buildMcpSection(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
      actions: <Widget>[
        OutlinedButton.icon(
          onPressed: _isTesting ? null : _testConnection,
          icon: _isTesting
              ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.network_check),
          label: Text(_isTesting ? 'テスト中...' : '接続テスト'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: const Color(0xff4a9eff)),
          onPressed: _handleSave,
          child: const Text('保存'),
        ),
      ],
    );
  }

  Widget _buildResetButton() {
    return OutlinedButton.icon(
      onPressed: _restoreDefaults,
      style: OutlinedButton.styleFrom(
        foregroundColor: Colors.white70,
        side: const BorderSide(color: Color(0xff3b82f6)),
      ),
      icon: const Icon(Icons.refresh, size: 18),
      label: const Text('デフォルト値に戻す'),
    );
  }

  Widget _buildUploadSection() {
    if (!_requiresUploadConfigInput) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xff0f141b),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xff2b3645)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Row(
              children: <Widget>[
                Icon(Icons.cloud_upload, color: Color(0xff4a9eff), size: 18),
                SizedBox(width: 8),
                Text(
                  'アップロードAPI',
                  style: TextStyle(fontWeight: FontWeight.w600, color: Colors.white70, fontSize: 15),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Upload / Expose / Token / Turnstile はアプリに組み込み済みの固定設定です。',
              style: TextStyle(fontSize: 12, color: Colors.white54),
            ),
            const SizedBox(height: 8),
            const Text(
              '公開環境でも値は表示されず、変更の必要はありません。',
              style: TextStyle(fontSize: 12, color: Colors.white54),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: OutlinedButton.icon(
                onPressed: _isRefreshingToken ? null : _refreshUploadToken,
                icon: _isRefreshingToken
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
                label: Text(_isRefreshingToken ? '再取得中...' : 'JWTを再取得'),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xff0f141b),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xff2b3645)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Row(
            children: <Widget>[
              Icon(Icons.cloud_upload, color: Color(0xff4a9eff), size: 18),
              SizedBox(width: 8),
              Text(
                'アップロードAPI (手動設定)',
                style: TextStyle(fontWeight: FontWeight.w600, color: Colors.white70, fontSize: 15),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'GitHub Actions 等でビルドされたバイナリでは自動設定されますが、ローカル開発環境では手動入力が必要です。',
            style: TextStyle(fontSize: 12, color: Colors.white54),
          ),
          const SizedBox(height: 12),
          _buildUrlField(
            controller: _uploadEndpointController,
            label: 'Upload Endpoint',
            hintText: 'https://example.com/upload',
          ),
          const SizedBox(height: 12),
          _buildUrlField(
            controller: _exposeEndpointController,
            label: 'Expose Endpoint (任意)',
            hintText: 'https://example.com/expose',
            requiredField: false,
          ),
          const SizedBox(height: 12),
          _buildUrlField(
            controller: _uploadAuthEndpointController,
            label: 'Upload Auth Endpoint',
            hintText: 'https://auth.example.com/token',
          ),
          const SizedBox(height: 12),
          _buildUrlField(
            controller: _uploadTurnstileUrlController,
            label: 'Turnstile Verify URL (任意)',
            hintText: 'https://verify.example.com',
            requiredField: false,
          ),
          const SizedBox(height: 12),
          _buildTextField(
            controller: _uploadAuthorizationController,
            label: 'Upload Authorization ヘッダー (任意)',
            hintText: '例: Bearer ********',
            validator: (String? _) => null,
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: OutlinedButton.icon(
              onPressed: _isRefreshingToken ? null : _refreshUploadToken,
              icon: _isRefreshingToken
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
              label: Text(_isRefreshingToken ? '再取得中...' : 'JWTを再取得'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMcpSection() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xff0f141b),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xff2b3645)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(Icons.auto_awesome, color: Color(0xffa855f7), size: 18),
              const SizedBox(width: 8),
              const Text(
                'MCP サーバー',
                style: TextStyle(fontWeight: FontWeight.w600, color: Colors.white70, fontSize: 15),
              ),
              const SizedBox(width: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xffff4d5a),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text(
                  '必須',
                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'AI画像生成用のMCP (Model Context Protocol) サーバー',
            style: TextStyle(fontSize: 12, color: Colors.white54),
          ),
          const SizedBox(height: 12),
          _buildUrlField(
            controller: _nanoBananaController,
            label: 'Nano Banana MCP URL',
            hintText: 'Nano BananaサーバーURL (必須)',
          ),
          const SizedBox(height: 12),
          _buildUrlField(
            controller: _seedreamController,
            label: 'Seedream MCP URL',
            hintText: 'SeedreamサーバーURL (必須)',
          ),
          const SizedBox(height: 12),
          _buildUrlField(
            controller: _soraController,
            label: 'Sora MCP URL',
            hintText: 'Soraテキストto動画サーバーURL (任意)',
            requiredField: false,
          ),
          const SizedBox(height: 12),
          _buildUrlField(
            controller: _veoController,
            label: 'Veo MCP URL',
            hintText: 'Veo3.1 I2VサーバーURL (任意)',
            requiredField: false,
          ),
        ],
      ),
    );
  }

  Future<void> _refreshUploadToken() async {
    setState(() => _isRefreshingToken = true);
    String? error;
    final DrawingController? drawingController = DrawingControllerRegistry.instance;
    if (drawingController != null) {
      error = await drawingController.refreshUploadAuthorization(context);
    } else {
      error = 'Drawingタブが初期化されていません。';
    }

    if (!mounted) {
      return;
    }

    final StoryController? storyController = context.read<StoryController?>();
    if (storyController != null) {
      final String? storyError = await storyController.refreshUploadAuthorization(context);
      error ??= storyError;
    }

    if (!mounted) {
      return;
    }
    setState(() => _isRefreshingToken = false);
    final String message =
        error == null ? 'アップロード用トークンを再取得しました。' : 'トークン再取得に失敗しました: $error';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  void _restoreDefaults() {
    final AppSettings defaults = AppSettings.defaults();
    _uploadEndpointController.text = defaults.uploadEndpoint;
    _exposeEndpointController.text = defaults.exposeEndpoint;
    _uploadAuthEndpointController.text = defaults.uploadAuthEndpoint;
    _uploadTurnstileUrlController.text = defaults.uploadTurnstileUrl;
    _uploadAuthorizationController.clear();
    _nanoBananaController.text = defaults.nanoBananaEndpoint;
    _seedreamController.text = defaults.seedreamEndpoint;
    _soraController.text = defaults.soraEndpoint;
    _veoController.text = defaults.veoEndpoint;
  }

  Future<void> _handleSave() async {
    final FormState? formState = _formKey.currentState;
    if (formState == null || !formState.validate()) {
      return;
    }

    Navigator.of(context).pop(_buildSettings());
  }

  Future<void> _testConnection() async {
    setState(() => _isTesting = true);

    final List<_ConnectionTestResult> results = <_ConnectionTestResult>[];
    final String nanoBananaUrl = _nanoBananaController.text.trim();
    final String seedreamUrl = _seedreamController.text.trim();
    final String soraUrl = _soraController.text.trim();
    final String veoUrl = _veoController.text.trim();

    try {
      results.add(
        await _performMcpTest(
          label: 'MCP: Nano Banana',
          url: nanoBananaUrl,
          authorization: null,
        ),
      );

      results.add(
        await _performMcpTest(
          label: 'MCP: Seedream',
          url: seedreamUrl,
          authorization: null,
        ),
      );

      if (soraUrl.isNotEmpty) {
        results.add(
          await _performMcpTest(
            label: 'MCP: Sora',
            url: soraUrl,
            authorization: null,
          ),
        );
      }

      if (veoUrl.isNotEmpty) {
        results.add(
          await _performMcpTest(
            label: 'MCP: Veo3.1 I2V',
            url: veoUrl,
            authorization: null,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isTesting = false);
      }
    }

    if (!mounted) {
      return;
    }

    await _showConnectionResultDialog(results);
  }

  Future<_ConnectionTestResult> _performMcpTest({
    required String label,
    required String url,
    String? authorization,
  }) async {
    final List<String> details = <String>[];
    final String trimmed = url.trim();

    if (trimmed.isEmpty) {
      const String summary = 'URLが未設定のためMCPテストを実行できません';
      details.add('URL: (未設定)');
      details.add('MCP URLを設定するとツール一覧を取得できます。');
      return _ConnectionTestResult(label: label, success: false, summary: summary, details: details);
    }

    final Uri? uri = Uri.tryParse(trimmed);
    if (uri == null || uri.scheme.isEmpty || uri.host.isEmpty) {
      const String summary = 'MCP URLが不正です';
      details.add('URL: $trimmed');
      details.add('https:// から始まる正しいMCPエンドポイントを設定してください。');
      return _ConnectionTestResult(label: label, success: false, summary: summary, details: details);
    }

    details.add('URL: $trimmed');

    final McpHealthChecker checker = McpHealthChecker(
      endpoint: uri,
      authorization: authorization,
      clientName: 'direct-drawing-generator',
      clientVersion: '1.0.0',
      timeout: const Duration(seconds: 15),
    );

    final Stopwatch sw = Stopwatch()..start();
    final McpHealthCheckResult result = await checker.run();
    sw.stop();

    details.add('所要時間: ${sw.elapsedMilliseconds}ms');
    if (result.sessionId != null && result.sessionId!.isNotEmpty) {
      details.add('取得したセッションID: ${result.sessionId}');
    }

    for (final String log in result.logs) {
      details.add('ログ: $log');
    }

    if (result.tools.isNotEmpty) {
      details.add('取得ツール一覧 (${result.tools.length}件):');
      for (final McpToolSummary tool in result.tools) {
        details.add('  • ${tool.display()}');
      }
    }

    if (!result.success && result.error != null) {
      details.add('エラー詳細: ${result.error}');
    }

    final String summary = result.success
        ? 'MCP接続成功 — 利用可能なツール ${result.tools.length} 件'
        : 'MCP接続失敗 — 詳細はログを確認してください';

    return _ConnectionTestResult(
      label: label,
      success: result.success,
      summary: summary,
      details: details,
    );
  }

  Future<void> _showConnectionResultDialog(List<_ConnectionTestResult> results) async {
    final bool overallSuccess =
        results.isNotEmpty && results.every((result) => result.success);
    final String reportText = _buildReportText(results);

    if (reportText.isNotEmpty) {
      debugPrint('===== 接続テストレポート =====');
      for (final _ConnectionTestResult result in results) {
        result.dumpToDebug();
      }
      debugPrint(reportText);
      debugPrint('===== レポート終了 =====');
    }

    if (!mounted) {
      return;
    }

    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          backgroundColor: const Color(0xff1b2430),
          title: Row(
            children: <Widget>[
              Icon(
                overallSuccess ? Icons.check_circle : Icons.error,
                color: overallSuccess ? const Color(0xff00d4aa) : const Color(0xffff4d5a),
              ),
              const SizedBox(width: 12),
              const Text('接続テスト結果'),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (final _ConnectionTestResult result in results)
                  _buildResultSummaryCard(result),
                const SizedBox(height: 12),
                Container(
                  decoration: BoxDecoration(
                    color: const Color(0xff0f141b),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xff2b3645)),
                  ),
                  padding: const EdgeInsets.all(12),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 240),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        reportText.isEmpty ? 'テスト結果がありません。' : reportText,
                        style: const TextStyle(fontSize: 12, height: 1.4),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton.icon(
              onPressed: reportText.isEmpty ? null : () => _copyReport(reportText),
              icon: const Icon(Icons.copy),
              label: const Text('結果をコピー'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('閉じる'),
            ),
          ],
        );
      },
    );
  }

  Widget _buildResultSummaryCard(_ConnectionTestResult result) {
    final Color accent = result.success ? const Color(0xff00d4aa) : const Color(0xffff4d5a);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xff111827),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: result.success ? const Color(0xff1f3b2f) : const Color(0xff452b2f)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(
                result.success ? Icons.check_circle : Icons.error_outline,
                color: accent,
                size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  result.label,
                  style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.white70),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            result.summary,
            style: const TextStyle(fontSize: 12, color: Colors.white60, height: 1.4),
          ),
        ],
      ),
    );
  }

  Future<void> _copyReport(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('接続テスト結果をコピーしました')),
    );
  }

  String _buildReportText(List<_ConnectionTestResult> results) {
    if (results.isEmpty) {
      return '';
    }

    final List<String> lines = <String>[];
    for (final _ConnectionTestResult result in results) {
      lines.add('[${result.success ? 'OK' : 'NG'}] ${result.label}');
      lines.add('  ${result.summary}');
      for (final String detail in result.details) {
        lines.add('  - $detail');
      }
      lines.add('');
    }

    return lines.join('\n').trim();
  }

  AppSettings _buildSettings() {
    final String embeddedUpload = AppSettings.kEmbeddedUploadEndpoint.trim();
    final String embeddedExpose = AppSettings.kEmbeddedExposeEndpoint.trim();
    final String embeddedAuth = AppSettings.kEmbeddedTokenEndpoint.trim();
    final String embeddedTurnstile = AppSettings.kEmbeddedTurnstileVerifyUrl.trim();

    final String resolvedUploadEndpoint = embeddedUpload.isNotEmpty
        ? embeddedUpload
        : _uploadEndpointController.text.trim();
    final String resolvedExposeEndpoint = embeddedExpose.isNotEmpty
        ? embeddedExpose
        : _exposeEndpointController.text.trim();
    final String resolvedAuthEndpoint = embeddedAuth.isNotEmpty
        ? embeddedAuth
        : _uploadAuthEndpointController.text.trim();
    final String resolvedTurnstileUrl = embeddedTurnstile.isNotEmpty
        ? embeddedTurnstile
        : _uploadTurnstileUrlController.text.trim();

    final String authText = _uploadAuthorizationController.text.trim();
    final String? resolvedAuthorization = authText.isEmpty ? null : authText;

    return widget.initial.copyWith(
      uploadEndpoint: resolvedUploadEndpoint,
      exposeEndpoint: resolvedExposeEndpoint,
      uploadAuthEndpoint: resolvedAuthEndpoint,
      uploadTurnstileUrl: resolvedTurnstileUrl,
      uploadAuthorization: resolvedAuthorization,
      nanoBananaEndpoint: _nanoBananaController.text.trim(),
      seedreamEndpoint: _seedreamController.text.trim(),
      soraEndpoint: _soraController.text.trim(),
      veoEndpoint: _veoController.text.trim(),
    );
  }

  Widget _buildUrlField({
    required TextEditingController controller,
    required String label,
    required String hintText,
    bool requiredField = true,
  }) {
    return _buildTextField(
      controller: controller,
      label: label,
      hintText: hintText,
      validator: _urlValidator(requiredField: requiredField),
      keyboardType: TextInputType.url,
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required String hintText,
    TextInputType? keyboardType,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: controller,
      style: const TextStyle(color: Colors.white),
      keyboardType: keyboardType,
      autovalidateMode: AutovalidateMode.disabled,
      decoration: InputDecoration(
        labelText: label,
        hintText: hintText,
        labelStyle: const TextStyle(color: Colors.white70),
        hintStyle: const TextStyle(color: Colors.white38),
        filled: true,
        fillColor: const Color(0xff18212b),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xff253143)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xff4a9eff)),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xffff4d5a)),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xffff4d5a), width: 2),
        ),
      ),
      validator: validator,
    );
  }

  String? Function(String?) _urlValidator({required bool requiredField}) {
    return (String? value) {
      final String trimmed = value?.trim() ?? '';
      if (trimmed.isEmpty) {
        return requiredField ? 'URLを入力してください' : null;
      }
      final Uri? uri = Uri.tryParse(trimmed);
      if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
        return '有効なURLを入力してください';
      }
      return null;
    };
  }
}

class _CanvasHeader extends StatelessWidget {
  const _CanvasHeader({required this.controller});

  final DrawingController controller;

  @override
  Widget build(BuildContext context) {
    final Color activeColor = controller.mode == DrawingMode.pen
        ? const Color(0xff4a9eff)
        : controller.mode == DrawingMode.eraser
            ? const Color(0xfff97316)
            : controller.mode == DrawingMode.text
                ? const Color(0xff2dd4bf)
                : Colors.white60;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      color: const Color(0xff111a23),
      child: Row(
        children: <Widget>[
          const Icon(Icons.brush, color: Colors.white70),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'Canvas',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Colors.white70),
              ),
              Text(
                _modeLabel(controller.mode),
                style: TextStyle(color: activeColor, fontSize: 12, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xff1d2633),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              children: <Widget>[
                const Icon(Icons.palette, size: 18, color: Colors.white60),
                const SizedBox(width: 8),
                Text(controller.penColor.value.toRadixString(16).padLeft(8, '0').toUpperCase()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _modeLabel(DrawingMode mode) {
    switch (mode) {
      case DrawingMode.pen:
        return 'Drawing mode active';
      case DrawingMode.eraser:
        return 'Eraser mode active';
      case DrawingMode.text:
        return 'Text placement active';
      case DrawingMode.idle:
        return 'Select a tool to begin';
    }
  }
}

class _ColorSwatch extends StatelessWidget {
  const _ColorSwatch({
    required this.color,
    required this.isSelected,
    required this.onSelected,
    this.child,
  });

  final Color color;
  final bool isSelected;
  final VoidCallback onSelected;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onSelected,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: child == null ? color : const Color(0xff1d2633),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? const Color(0xff4a9eff) : const Color(0xff2b3645),
            width: isSelected ? 3 : 1,
          ),
        ),
        alignment: Alignment.center,
        child: child,
      ),
    );
  }
}

class _SliderTile extends StatelessWidget {
  const _SliderTile({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: <Widget>[
            Text(label, style: const TextStyle(color: Colors.white70)),
            Text('${value.toStringAsFixed(0)} px', style: const TextStyle(color: Colors.white54)),
          ],
        ),
        Slider(
          value: value,
          min: min,
          max: max,
          activeColor: const Color(0xff3b82f6),
          inactiveColor: const Color(0xff1f2937),
          onChanged: onChanged,
        ),
      ],
    );
  }
}









