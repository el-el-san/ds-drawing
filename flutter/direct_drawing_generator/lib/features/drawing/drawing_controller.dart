import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'models/app_settings.dart';
import 'models/drawing_state.dart';
import 'models/drawn_stroke.dart';
import 'models/drawn_text.dart';
import 'models/drawing_mode.dart';
import 'models/generation_result.dart';
import 'models/generation_state.dart';
import 'models/mcp_config.dart';
import 'services/image_upload_service.dart';
import 'services/mcp_client.dart';
import '../../shared/app_settings_controller.dart';
import '../../shared/upload_auth_manager.dart';

enum GenerationEngine {
  nanoBanana,
  seedream,
}

extension GenerationEngineLabel on GenerationEngine {
  String get label {
    switch (this) {
      case GenerationEngine.nanoBanana:
        return 'Nano Banana';
      case GenerationEngine.seedream:
        return 'Seedream';
    }
  }
}

class _GenerationRunContext {
  _GenerationRunContext({required this.engine, required this.logBuffer});

  final GenerationEngine engine;
  final List<String> logBuffer;
}

class GenerationRunResult {
  GenerationRunResult({
    required this.engine,
    required this.success,
    required this.logs,
    this.errorMessage,
  });

  final GenerationEngine engine;
  final bool success;
  final List<String> logs;
  final String? errorMessage;
}

class DrawingController extends ChangeNotifier {
  DrawingController({required AppSettingsController settingsController})
      : _settingsController = settingsController {
    _settingsController.addListener(_handleSettingsUpdated);
    _applySettings(_settingsController.settings, notify: false);
  }

  bool _isInitialized = false;
  bool get isInitialized => _isInitialized;

  final AppSettingsController _settingsController;
  final List<DrawnStroke> _strokes = <DrawnStroke>[];
  final List<DrawnText> _texts = <DrawnText>[];
  final List<_CanvasAction> _history = <_CanvasAction>[];
  final List<_CanvasAction> _redoHistory = <_CanvasAction>[];

  DrawnStroke? _activeStroke;
  DrawingMode _mode = DrawingMode.pen;
  Color _penColor = const Color(0xffff4d5a);
  double _penSize = 6;
  double _eraserSize = 42;
  double _textSize = 28;
  Size? _lastCanvasSize;
  ui.Image? _referenceImage;
  Uint8List? _referenceImageBytes;

  // AI画像生成関連
  static final Object _logZoneKey = Object();
  static const int _maxEngineLogs = 400;
  static const int _maxCombinedLogs = 800;
  static const int _maxLogSessionsPerEngine = 6;
  final Map<GenerationEngine, GenerationState> _generationStates = <GenerationEngine, GenerationState>{
    for (final GenerationEngine engine in GenerationEngine.values) engine: GenerationState.idle,
  };
  final Map<GenerationEngine, String?> _generationErrors = <GenerationEngine, String?>{
    for (final GenerationEngine engine in GenerationEngine.values) engine: null,
  };
  final Map<GenerationEngine, List<List<String>>> _generationLogs = <GenerationEngine, List<List<String>>>{
    for (final GenerationEngine engine in GenerationEngine.values) engine: <List<String>>[],
  };
  final Map<GenerationEngine, int> _activeGenerations = <GenerationEngine, int>{
    for (final GenerationEngine engine in GenerationEngine.values) engine: 0,
  };
  final Map<GenerationEngine, List<String>> _pendingEngineLogs = <GenerationEngine, List<String>>{
    for (final GenerationEngine engine in GenerationEngine.values) engine: <String>[],
  };
  final List<String> _combinedLogs = <String>[];
  GenerationEngine? _lastLogEngine;
  final List<GenerationResult> _generationResults = <GenerationResult>[];
  late ImageUploadService _uploadService;
  late AppSettings _settings;
  late McpConfig _nanoBananaConfig;
  late McpConfig _seedreamConfig;
  final UploadAuthManager _uploadAuthManager = UploadAuthManager();

  DrawingMode get mode => _mode;
  Color get penColor => _penColor;
  double get penSize => _penSize;
  double get eraserSize => _eraserSize;
  double get textSize => _textSize;
  ui.Image? get referenceImage => _referenceImage;
  Uint8List? get referenceImageBytes => _referenceImageBytes;
  List<DrawnStroke> get strokes => List<DrawnStroke>.unmodifiable(_strokes);
  List<DrawnText> get texts => List<DrawnText>.unmodifiable(_texts);
  bool get hasReferenceImage => _referenceImage != null;
  bool get hasUndo => _history.isNotEmpty;
  bool get hasRedo => _redoHistory.isNotEmpty;

  bool get isPenActive => _mode == DrawingMode.pen;
  bool get isEraserActive => _mode == DrawingMode.eraser;
  bool get isTextActive => _mode == DrawingMode.text;

  // AI画像生成のゲッター
  GenerationState get generationState {
    for (final GenerationState state in <GenerationState>[
      GenerationState.generating,
      GenerationState.submitting,
      GenerationState.uploading,
      GenerationState.error,
      GenerationState.completed,
    ]) {
      if (_generationStates.values.contains(state)) {
        return state;
      }
    }
    return GenerationState.idle;
  }

  GenerationState generationStateFor(GenerationEngine engine) =>
      _generationStates[engine] ?? GenerationState.idle;

  bool isGenerationInProgress(GenerationEngine engine) {
    return activeGenerationCountFor(engine) > 0;
  }

  int activeGenerationCountFor(GenerationEngine engine) => _activeGenerations[engine] ?? 0;

  String? get generationError {
    if (_lastLogEngine != null) {
      final String? error = _generationErrors[_lastLogEngine];
      if (error != null) {
        return error;
      }
    }
    for (final GenerationEngine engine in GenerationEngine.values) {
      final String? error = _generationErrors[engine];
      if (error != null) {
        return error;
      }
    }
    return null;
  }

  String? generationErrorFor(GenerationEngine engine) => _generationErrors[engine];

  List<GenerationResult> get generationResults => List<GenerationResult>.unmodifiable(_generationResults);

  List<String> get latestGenerationLogs => _lastLogEngine != null
      ? List<String>.unmodifiable(_latestLogBufferForEngine(_lastLogEngine!))
      : const <String>[];

  List<String> latestGenerationLogsFor(GenerationEngine engine) =>
      List<String>.unmodifiable(_latestLogBufferForEngine(engine));

  List<String> get logs => List<String>.unmodifiable(_combinedLogs);
  AppSettings get settings => _settings;
  McpConfig get nanoBananaConfig => _nanoBananaConfig;
  McpConfig get seedreamConfig => _seedreamConfig;

  Future<void> init() async {
    if (_isInitialized) {
      return;
    }
    if (!_settingsController.isInitialized) {
      await _settingsController.init();
    }
    _applySettings(_settingsController.settings);
    await loadState(); // 保存された状態を復元
    _isInitialized = true;
    notifyListeners();
  }

  Future<void> updateSettings(AppSettings newSettings) async {
    await _settingsController.update(newSettings);
  }

  void _applySettings(AppSettings settings, {bool notify = true}) {
    _settings = settings;
    _uploadService = ImageUploadService(
      uploadEndpoint: settings.uploadEndpoint,
      exposeEndpoint: settings.exposeEndpoint,
      authorization: settings.uploadAuthorization,
      logger: _log,
    );
    _uploadAuthManager.invalidate();
    _nanoBananaConfig = McpConfig.nanoBanana(
      url: settings.nanoBananaEndpoint,
      authorization: settings.mcpAuthorization,
    );
    _seedreamConfig = McpConfig.seedream(
      url: settings.seedreamEndpoint,
      authorization: settings.mcpAuthorization,
    );
    if (notify) {
      notifyListeners();
    }
  }

  Future<String?> ensureUploadAuthorization(
    BuildContext context, {
    bool forceRefresh = false,
    GenerationEngine? engine,
  }) async {
    Future<String?> execute() async {
      if (_settings.uploadAuthorization != null && _settings.uploadAuthorization!.trim().isNotEmpty) {
        _uploadService.authorization = _settings.uploadAuthorization;
        return null;
      }

      final String vendingEndpoint = _settings.uploadAuthEndpoint.trim();
      if (vendingEndpoint.isEmpty) {
        return 'Token Vending Endpoint が未設定です。設定タブで設定してください。';
      }

      try {
        final UploadAuthToken token = await _uploadAuthManager.ensureJwt(
          context: context,
          vendingEndpoint: vendingEndpoint,
          turnstileUrl: _settings.uploadTurnstileUrl,
          forceRefresh: forceRefresh,
        );
        _uploadService.authorization = token.token;
        _uploadService.deviceId = token.deviceId;
        _log('Upload JWT を取得 (expires ${token.expiresAt.toIso8601String()})');
        _log('Upload token device: ${token.deviceId}');
        if (token.userId != null) {
          _log('Upload token user: ${token.userId}');
        }
        return null;
      } on UploadAuthException catch (error) {
        _log('Upload JWT エラー: ${error.message}');
        return error.message;
      } catch (error, stack) {
        _log('Upload JWT 取得中に予期しないエラー: $error');
        debugPrint('$stack');
        return 'アップロード用トークンの取得に失敗しました。';
      }
    }

    if (engine == null) {
      return execute();
    }

    return runZoned<Future<String?>>(
      () => execute(),
      zoneValues: <Object?, Object?>{_logZoneKey: engine},
    );
  }

  Future<String?> refreshUploadAuthorization(
    BuildContext context, {
    GenerationEngine? engine,
  }) {
    return ensureUploadAuthorization(context, forceRefresh: true, engine: engine);
  }

  void _handleSettingsUpdated() {
    _applySettings(_settingsController.settings);
  }

  void setMode(DrawingMode mode) {
    if (_mode == mode) {
      _mode = DrawingMode.idle;
    } else {
      _mode = mode;
    }
    notifyListeners();
  }

  void setPenColor(Color color) {
    _penColor = color;
    notifyListeners();
  }

  void setPenSize(double size) {
    _penSize = size.clamp(1, 120);
    notifyListeners();
  }

  void setEraserSize(double size) {
    _eraserSize = size.clamp(8, 240);
    notifyListeners();
  }

  void setTextSize(double size) {
    _textSize = size.clamp(8, 200);
    notifyListeners();
  }

  void updateCanvasSize(Size size) {
    if (!size.isFinite || size.width <= 0 || size.height <= 0) {
      return;
    }
    if (_lastCanvasSize == null || _lastCanvasSize != size) {
      _lastCanvasSize = size;
    }
  }

  void startStroke(Offset position) {
    if (!isPenActive && !isEraserActive) {
      return;
    }
    _redoHistory.clear();
    final DrawnStroke stroke = DrawnStroke(
      points: <Offset>[position],
      color: isEraserActive ? Colors.transparent : _penColor,
      strokeWidth: isEraserActive ? _eraserSize : _penSize,
      blendMode: isEraserActive ? BlendMode.clear : BlendMode.srcOver,
    );
    _strokes.add(stroke);
    _activeStroke = stroke;
    notifyListeners();
  }

  void appendPoint(Offset position) {
    if (_activeStroke == null || _strokes.isEmpty) {
      return;
    }
    final List<Offset> updatedPoints = List<Offset>.from(_activeStroke!.points)..add(position);
    final DrawnStroke updatedStroke = _activeStroke!.copyWith(points: updatedPoints);

    _strokes.last = updatedStroke;
    _activeStroke = updatedStroke;
    notifyListeners();
  }

  void endStroke() {
    if (_activeStroke == null) {
      return;
    }
    if (!_activeStroke!.isDrawable) {
      _strokes.remove(_activeStroke);
    } else {
      _history.add(_CanvasAction.stroke(_activeStroke!));
    }
    _activeStroke = null;
    notifyListeners();
    saveState(); // 状態を保存
  }

  void placeText({required String text, required Offset at}) {
    final String trimmed = text.trim();
    if (trimmed.isEmpty) {
      return;
    }
    final DrawnText entry = DrawnText(
      text: trimmed,
      position: at,
      color: _penColor,
      fontSize: _textSize,
    );
    _texts.add(entry);
    _redoHistory.clear();
    _history.add(_CanvasAction.text(entry));
    notifyListeners();
    saveState(); // 状態を保存
  }

  void undo() {
    if (_history.isEmpty) {
      return;
    }
    final _CanvasAction action = _history.removeLast();
    if (action.stroke != null) {
      _strokes.remove(action.stroke);
    } else if (action.text != null) {
      _texts.remove(action.text);
    }
    _redoHistory.add(action);
    notifyListeners();
    saveState(); // 状態を保存
  }

  void redo() {
    if (_redoHistory.isEmpty) {
      return;
    }
    final _CanvasAction action = _redoHistory.removeLast();
    if (action.stroke != null) {
      _strokes.add(action.stroke!);
    } else if (action.text != null) {
      _texts.add(action.text!);
    }
    _history.add(action);
    notifyListeners();
    saveState(); // 状態を保存
  }

  void clear() {
    _strokes.clear();
    _texts.clear();
    _history.clear();
    _redoHistory.clear();
    _activeStroke = null;
    notifyListeners();
    saveState(); // 状態を保存
  }

  Future<void> loadReferenceImage(Uint8List bytes) async {
    try {
      // 古い画像を破棄
      _referenceImage?.dispose();

      final ui.Codec codec = await ui.instantiateImageCodec(bytes);
      final ui.FrameInfo frameInfo = await codec.getNextFrame();
      _referenceImage = frameInfo.image;
      _referenceImageBytes = bytes;

      debugPrint('リファレンス画像を読み込みました: ${_referenceImage?.width} x ${_referenceImage?.height}');
      notifyListeners();
      await saveState(); // 状態を保存
    } catch (e) {
      debugPrint('リファレンス画像の読み込みに失敗しました: $e');
      rethrow;
    }
  }

  void removeReferenceImage() {
    _referenceImage?.dispose();
    _referenceImage = null;
    _referenceImageBytes = null;
    notifyListeners();
    saveState(); // 状態を保存
  }

  /// キャンバスを画像としてキャプチャ
  Future<Uint8List> captureCanvas(GlobalKey repaintKey) async {
    // ダイアログを閉じた直後など、直前のフレーム完了を待ってからキャプチャを開始する
    await _waitForNextFrame();

    ui.Image? image;
    Object? lastError;

    const int maxAttempts = 24;

    for (int attempt = 0; attempt < maxAttempts; attempt++) {
      final RenderRepaintBoundary? boundary = await _obtainStableBoundary(repaintKey);

      if (boundary == null) {
        lastError = 'RenderRepaintBoundary was not found';
        _log('キャンバスがまだ初期化されていません (attempt ${attempt + 1}/$maxAttempts)');
        await _waitForNextFrame();
        continue;
      }

      if (!boundary.attached) {
        lastError = 'RenderRepaintBoundary is detached from render tree';
        _log('キャンバスがレンダーツリーから外れています (attempt ${attempt + 1}/$maxAttempts)');
        await _waitForNextFrame(boundary: boundary);
        continue;
      }

      if (!boundary.hasSize) {
        lastError = 'RenderRepaintBoundary has no size';
        _log('キャンバスのレイアウト待機中 (attempt ${attempt + 1}/$maxAttempts)');
        await _waitForNextFrame(boundary: boundary);
        continue;
      }

      if (!_hasLayerAttached(boundary)) {
        lastError = 'RenderRepaintBoundary has no composited layer yet';
        _log('キャンバスのlayer初期化待機中 (attempt ${attempt + 1}/$maxAttempts)');
        await _waitForNextFrame(boundary: boundary, forceVisualUpdate: true);
        continue;
      }

      bool boundaryNeedsPaint = false;
      assert(() {
        boundaryNeedsPaint = boundary.debugNeedsPaint;
        return true;
      }());

      final bool schedulerBusy = SchedulerBinding.instance.schedulerPhase != SchedulerPhase.idle;

      if (schedulerBusy || boundaryNeedsPaint) {
        lastError = 'RenderRepaintBoundary is busy or needs paint';
        _log('キャンバスがまだ描画中です (attempt ${attempt + 1}/$maxAttempts, schedulerBusy: $schedulerBusy, needsPaint: $boundaryNeedsPaint)');
        await _waitForNextFrame(boundary: boundary, forceVisualUpdate: true);
        continue;
      }

      try {
        final double pixelRatio = _resolvePixelRatio(repaintKey);
        image = await boundary.toImage(pixelRatio: pixelRatio);
        _log('キャンバスキャプチャ成功 (attempt ${attempt + 1}/$maxAttempts, pixelRatio: $pixelRatio)');
        break;
      } catch (error, stack) {
        lastError = error;
        _log('キャンバスキャプチャ再試行 (${attempt + 1}/$maxAttempts) でエラー: $error');
        if (attempt == 0) {
          _log('StackTrace: $stack');
        }
        await _waitForNextFrame(boundary: boundary, forceVisualUpdate: true);
      }
    }

    if (image == null) {
      final Size? fallbackSize = _lastCanvasSize;
      if (fallbackSize != null && fallbackSize.width > 0 && fallbackSize.height > 0) {
        try {
          _log('Render tree capture failed, falling back to offscreen renderer with size $fallbackSize');
          return await _renderOffscreenImage(fallbackSize);
        } catch (error, stackTrace) {
          _log('オフスクリーン描画に失敗しました: $error');
          _log('StackTrace: $stackTrace');
        }
      }
      throw Exception('キャンバスのキャプチャに失敗しました: $lastError');
    }

    try {
      final ByteData? byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) {
        throw Exception('画像のキャプチャに失敗しました');
      }
      return byteData.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }

  /// Resolves the repaint boundary, giving the layout time to attach if needed.
  Future<RenderRepaintBoundary?> _obtainStableBoundary(GlobalKey repaintKey) async {
    RenderRepaintBoundary? lastBoundary;
    for (int attempt = 0; attempt < 6; attempt++) {
      final RenderObject? renderObject = repaintKey.currentContext?.findRenderObject();
      if (renderObject is RenderRepaintBoundary) {
        lastBoundary = renderObject;
        if (lastBoundary.attached) {
          return lastBoundary;
        }
      }
      await _waitForNextFrame();
    }
    return lastBoundary;
  }

  /// Waits for the next frame to complete and optionally nudges the pipeline.
  Future<void> _waitForNextFrame({RenderRepaintBoundary? boundary, bool forceVisualUpdate = false}) async {
    if (forceVisualUpdate) {
      boundary?.owner?.requestVisualUpdate();
    }
    SchedulerBinding.instance.ensureVisualUpdate();
    await SchedulerBinding.instance.endOfFrame;
    await Future<void>.delayed(const Duration(milliseconds: 16));
  }

  /// Matches the pixel ratio used in the original k-os-ERI direct drawing flow.
  double _resolvePixelRatio(GlobalKey repaintKey) {
    final BuildContext? context = repaintKey.currentContext;
    if (context != null) {
      final MediaQueryData? mediaQuery = MediaQuery.maybeOf(context);
      if (mediaQuery != null) {
        return mediaQuery.devicePixelRatio.clamp(1.0, 4.0).toDouble();
      }
    }

    final ui.FlutterView? implicitView = WidgetsBinding.instance.platformDispatcher.implicitView;
    if (implicitView != null) {
      return implicitView.devicePixelRatio.clamp(1.0, 4.0).toDouble();
    }

    final Iterable<ui.FlutterView> views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isNotEmpty) {
      return views.first.devicePixelRatio.clamp(1.0, 4.0).toDouble();
    }

    return 3.0;
  }

  /// AI画像生成を実行（Nano Banana）
  Future<GenerationRunResult> generateWithNanoBanana({
    required String prompt,
    required GlobalKey canvasKey,
    String? mcpUrl,
  }) async {
    final McpConfig config = mcpUrl != null
        ? _nanoBananaConfig.copyWith(url: mcpUrl)
        : _nanoBananaConfig;
    return _generateImage(
      prompt: prompt,
      canvasKey: canvasKey,
      config: config,
      engine: GenerationEngine.nanoBanana,
      includeReferenceImage: false,
    );
  }

  /// AI画像生成を実行（Seedream）
  Future<GenerationRunResult> generateWithSeedream({
    required String prompt,
    required GlobalKey canvasKey,
    String? mcpUrl,
    Map<String, dynamic>? imageSize,
  }) async {
    final McpConfig config = mcpUrl != null
        ? _seedreamConfig.copyWith(url: mcpUrl)
        : _seedreamConfig;
    return _generateImage(
      prompt: prompt,
      canvasKey: canvasKey,
      config: config,
      engine: GenerationEngine.seedream,
      imageSize: imageSize,
      includeReferenceImage: false,
    );
  }

  /// AI画像生成の共通処理
  Future<GenerationRunResult> _generateImage({
    required String prompt,
    required GlobalKey canvasKey,
    required McpConfig config,
    required GenerationEngine engine,
    Map<String, dynamic>? imageSize,
    bool includeReferenceImage = true,
  }) async {
    if (prompt.trim().isEmpty) {
      const String message = 'プロンプトを入力してください';
      _setGenerationError(engine, message, notify: false);
      _setGenerationState(engine, GenerationState.error, force: true);
      return GenerationRunResult(
        engine: engine,
        success: false,
        logs: const <String>[],
        errorMessage: message,
      );
    }

    final List<String> logBuffer = _prepareGeneration(engine);
    final _GenerationRunContext context = _GenerationRunContext(engine: engine, logBuffer: logBuffer);

    bool success = false;
    String? errorMessage;

    Future<void> execute() async {
      try {
        _log('=== 画像生成開始 (${config.name}) ===');
        _log('プロンプト: ${prompt.trim()}');
        _log('MCPエンドポイント: ${config.url}');

        // キャンバスをキャプチャ
        _log('キャンバスのキャプチャを開始');
        final Uint8List canvasBytes = await captureCanvas(canvasKey);
        _log('キャンバスをキャプチャしました (${canvasBytes.length} bytes)');

        // 状態をアップロード中に設定
        _setGenerationError(engine, null, notify: false);
        _setGenerationState(engine, GenerationState.uploading);

        // 画像をアップロード
        _log('描画画像をアップロードします (${_uploadService.uploadEndpoint})');
        final String imageUrl = await _uploadService.uploadImage(canvasBytes);
        _log('描画画像をアップロードしました: $imageUrl');

        // リファレンス画像も一緒にアップロード（存在する場合）
        final List<String> imageUrls = <String>[imageUrl];
        if (includeReferenceImage && _referenceImageBytes != null) {
          _log('参照画像をアップロードします (${_uploadService.uploadEndpoint})');
          final String refUrl = await _uploadService.uploadImage(_referenceImageBytes!);
          imageUrls.add(refUrl);
          _log('参照画像をアップロードしました: $refUrl');
        }

        // 状態を送信中に設定
        _setGenerationState(engine, GenerationState.submitting);

        // MCPクライアントを作成
        final McpClient client = McpClient(
          config,
          logger: _log,
        );

        // 生成リクエストを送信
        _log('MCP submit を送信します');
        final String requestId = await client.submitGeneration(
          prompt: prompt,
          imageUrls: imageUrls,
          imageSize: imageSize,
        );
        _log('生成リクエストを送信しました: request_id=$requestId');

        // 状態を生成中に設定
        _setGenerationState(engine, GenerationState.generating);

        // 完了までポーリング
        _log('ステータス確認を開始します');
        final String resultUrl = await client.pollUntilComplete(requestId: requestId);
        _log('生成が完了しました: $resultUrl');

        // 結果を保存
        final GenerationResult result = GenerationResult(
          imageUrl: resultUrl,
          prompt: prompt,
          requestId: requestId,
          generatedAt: DateTime.now(),
        );
        _generationResults.insert(0, result);

        _log('=== 画像生成完了 (${config.name}) ===');
        await saveState(); // 状態を保存
        success = true;
      } catch (e, stack) {
        errorMessage = e.toString();
        _log('エラー発生: $e');
        _log('StackTrace: $stack');
        _setGenerationError(engine, errorMessage, notify: false);
        _log('=== 画像生成失敗 (${config.name}) ===');
      }
    }

    try {
      await runZoned<Future<void>>(
        () => execute(),
        zoneValues: <Object?, Object?>{_logZoneKey: context},
      );
    } finally {
      _finalizeGeneration(
        engine,
        success: success,
        errorMessage: errorMessage,
      );
    }

    final List<String> logsSnapshot = List<String>.from(logBuffer);
    return GenerationRunResult(
      engine: engine,
      success: success,
      logs: logsSnapshot,
      errorMessage: errorMessage,
    );
  }

  List<String> _prepareGeneration(GenerationEngine engine) {
    final List<String> buffer = _pendingEngineLogs[engine] ?? <String>[];
    _pendingEngineLogs[engine] = <String>[];
    if (buffer.length > _maxEngineLogs) {
      buffer.removeRange(0, buffer.length - _maxEngineLogs);
    }

    _incrementActiveGeneration(engine);
    final List<List<String>> buckets = _generationLogs[engine] ?? <List<String>>[];
    buckets.add(buffer);
    if (buckets.length > _maxLogSessionsPerEngine) {
      buckets.removeRange(0, buckets.length - _maxLogSessionsPerEngine);
    }
    _generationLogs[engine] = buckets;
    _generationErrors[engine] = null;
    _lastLogEngine = engine;
    return buffer;
  }

  void _setGenerationState(GenerationEngine engine, GenerationState state, {bool force = false}) {
    final GenerationState current = _generationStates[engine] ?? GenerationState.idle;
    if (!force) {
      final int currentPriority = _statePriority(current);
      final int nextPriority = _statePriority(state);
      if (nextPriority < currentPriority) {
        return;
      }
      if (current == state) {
        return;
      }
    }
    _generationStates[engine] = state;
    notifyListeners();
  }

  void _setGenerationError(GenerationEngine engine, String? message, {bool notify = true}) {
    _generationErrors[engine] = message;
    if (notify) {
      notifyListeners();
    }
  }

  void _incrementActiveGeneration(GenerationEngine engine) {
    _activeGenerations[engine] = activeGenerationCountFor(engine) + 1;
    notifyListeners();
  }

  void _finalizeGeneration(
    GenerationEngine engine, {
    required bool success,
    String? errorMessage,
  }) {
    final int remaining = activeGenerationCountFor(engine) > 0 ? activeGenerationCountFor(engine) - 1 : 0;
    _activeGenerations[engine] = remaining;

    if (!success) {
      _generationErrors[engine] = errorMessage;
      _setGenerationState(engine, GenerationState.error, force: true);
      return;
    }

    _generationErrors[engine] = null;
    if (remaining > 0) {
      _setGenerationState(engine, GenerationState.generating, force: true);
    } else {
      _setGenerationState(engine, GenerationState.completed, force: true);
    }
  }

  List<String> _latestLogBufferForEngine(GenerationEngine engine) {
    final List<List<String>> buckets = _generationLogs[engine] ?? <List<String>>[];
    if (buckets.isEmpty) {
      return <String>[];
    }
    return buckets.last;
  }

  int _statePriority(GenerationState state) {
    switch (state) {
      case GenerationState.idle:
        return 0;
      case GenerationState.uploading:
        return 1;
      case GenerationState.submitting:
        return 2;
      case GenerationState.generating:
        return 3;
      case GenerationState.completed:
        return 4;
      case GenerationState.error:
        return 5;
    }
  }

  bool _hasLayerAttached(RenderRepaintBoundary boundary) {
    // RenderObject.layer は protected メンバーのため analyzer 警告を抑制
    // ignore: invalid_use_of_protected_member
    final Layer? layer = boundary.layer;
    return layer != null;
  }

  void _log(String message) {
    final String line = '[${DateTime.now().toIso8601String()}] $message';
    final Object? zoneValue = Zone.current[_logZoneKey];
    _GenerationRunContext? context;
    GenerationEngine? engine;

    if (zoneValue is _GenerationRunContext) {
      context = zoneValue;
      engine = context.engine;
      context.logBuffer.add(line);
      if (context.logBuffer.length > _maxEngineLogs) {
        context.logBuffer.removeRange(0, context.logBuffer.length - _maxEngineLogs);
      }
      _lastLogEngine = context.engine;
    } else if (zoneValue is GenerationEngine) {
      engine = zoneValue;
      final List<String> pending = _pendingEngineLogs[engine] ?? <String>[];
      pending.add(line);
      if (pending.length > _maxEngineLogs) {
        pending.removeRange(0, pending.length - _maxEngineLogs);
      }
      _pendingEngineLogs[engine] = pending;
      _lastLogEngine = engine;
    }

    if (context != null && engine != null) {
      final List<List<String>> buckets = _generationLogs[engine] ?? <List<String>>[];
      if (buckets.isEmpty || !identical(buckets.last, context.logBuffer)) {
        buckets.add(context.logBuffer);
        if (buckets.length > _maxLogSessionsPerEngine) {
          buckets.removeRange(0, buckets.length - _maxLogSessionsPerEngine);
        }
      }
      _generationLogs[engine] = buckets;
    }

    _combinedLogs.add(line);
    if (_combinedLogs.length > _maxCombinedLogs) {
      _combinedLogs.removeRange(0, _combinedLogs.length - _maxCombinedLogs);
    }
    debugPrint(line);
    notifyListeners(); // ログパネルをリアルタイム更新
  }

  void clearLogs({GenerationEngine? engine}) {
    if (engine != null) {
      _generationLogs[engine] = <List<String>>[];
      _pendingEngineLogs[engine] = <String>[];
      if (_lastLogEngine == engine) {
        _lastLogEngine = null;
      }
    } else {
      for (final GenerationEngine target in GenerationEngine.values) {
        _generationLogs[target] = <List<String>>[];
        _pendingEngineLogs[target] = <String>[];
      }
      _combinedLogs.clear();
      _lastLogEngine = null;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _settingsController.removeListener(_handleSettingsUpdated);
    super.dispose();
  }

  Future<Uint8List> _renderOffscreenImage(Size targetSize) async {
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder);
    _paintCanvasContents(canvas, targetSize);
    final ui.Picture picture = recorder.endRecording();
    try {
      final int width = targetSize.width.ceil().clamp(1, 8192);
      final int height = targetSize.height.ceil().clamp(1, 8192);
      final ui.Image offscreenImage = await picture.toImage(width, height);
      try {
        final ByteData? byteData = await offscreenImage.toByteData(format: ui.ImageByteFormat.png);
        if (byteData == null) {
          throw Exception('オフスクリーン画像のエンコードに失敗しました');
        }
        return byteData.buffer.asUint8List();
      } finally {
        offscreenImage.dispose();
      }
    } finally {
      picture.dispose();
    }
  }

  void _paintCanvasContents(Canvas canvas, Size canvasSize) {
    final Rect bounds = Offset.zero & canvasSize;
    final Paint backgroundPaint = Paint()..color = const Color(0xff101010);
    canvas.drawRect(bounds, backgroundPaint);

    if (_referenceImage != null) {
      final Size imageSize = Size(
        _referenceImage!.width.toDouble(),
        _referenceImage!.height.toDouble(),
      );
      final FittedSizes fitted = applyBoxFit(BoxFit.contain, imageSize, canvasSize);
      final Rect inputSubrect = Alignment.center.inscribe(fitted.source, Offset.zero & imageSize);
      final Rect outputSubrect = Alignment.center.inscribe(fitted.destination, bounds);
      canvas.drawImageRect(_referenceImage!, inputSubrect, outputSubrect, Paint());
    }

    for (final DrawnStroke stroke in _strokes) {
      if (!stroke.isDrawable && stroke.blendMode != BlendMode.clear) {
        continue;
      }
      final Paint paint = Paint()
        ..color = stroke.color
        ..strokeWidth = stroke.strokeWidth
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..blendMode = stroke.blendMode
        ..isAntiAlias = true;

      if (stroke.points.length == 1) {
        canvas.drawPoints(ui.PointMode.points, stroke.points, paint);
        continue;
      }

      final Path path = Path();
      path.moveTo(stroke.points.first.dx, stroke.points.first.dy);
      for (final Offset point in stroke.points.skip(1)) {
        path.lineTo(point.dx, point.dy);
      }
      canvas.drawPath(path, paint);
    }

    for (final DrawnText entry in _texts) {
      final TextPainter textPainter = TextPainter(
        text: TextSpan(
          text: entry.text,
          style: TextStyle(
            color: entry.color,
            fontSize: entry.fontSize,
            fontWeight: FontWeight.w600,
          ),
        ),
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: canvasSize.width - 16);

      final Offset anchor = entry.position - Offset(textPainter.width / 2, textPainter.height / 2);
      textPainter.paint(canvas, anchor);
    }
  }

  /// 生成結果をリファレンス画像として読み込む
  Future<void> loadGenerationResultAsReference(GenerationResult result) async {
    if (result.imageBytes != null) {
      await loadReferenceImage(result.imageBytes!);
    } else {
      // URLから画像をダウンロード
      try {
        final http.Response response = await http.get(Uri.parse(result.imageUrl));
        if (response.statusCode == 200) {
          await loadReferenceImage(response.bodyBytes);
        } else {
          throw Exception('画像のダウンロードに失敗しました: ${response.statusCode}');
        }
      } catch (e) {
        debugPrint('画像のダウンロードエラー: $e');
        rethrow;
      }
    }
  }

  /// 生成状態をリセット
  void resetGenerationState({GenerationEngine? engine}) {
    if (engine != null) {
      _generationStates[engine] = GenerationState.idle;
      _generationErrors[engine] = null;
      _generationLogs[engine] = <List<String>>[];
      _activeGenerations[engine] = 0;
      _pendingEngineLogs[engine] = <String>[];
      if (_lastLogEngine == engine) {
        _lastLogEngine = null;
      }
      notifyListeners();
      return;
    }

    for (final GenerationEngine target in GenerationEngine.values) {
      _generationStates[target] = GenerationState.idle;
      _generationErrors[target] = null;
      _generationLogs[target] = <List<String>>[];
      _activeGenerations[target] = 0;
      _pendingEngineLogs[target] = <String>[];
    }
    _combinedLogs.clear();
    _lastLogEngine = null;
    notifyListeners();
  }

  /// 特定の生成結果を削除
  void removeGenerationResultAt(int index) {
    if (index < 0 || index >= _generationResults.length) {
      return;
    }
    _generationResults.removeAt(index);
    notifyListeners();
    saveState(); // 状態を保存
  }

  /// 生成結果を全て削除
  void clearGenerationResults() {
    if (_generationResults.isEmpty) {
      return;
    }
    _generationResults.clear();
    notifyListeners();
    saveState(); // 状態を保存
  }

  /// ドローイング状態を保存
  Future<void> saveState() async {
    try {
      final DrawingState state = DrawingState(
        strokes: _strokes,
        texts: _texts,
        referenceImageBytes: _referenceImageBytes,
        generationResults: _generationResults,
      );

      final String jsonString = state.toJsonString();
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString('drawing_state', jsonString);
      _log('[状態保存] ドローイング状態を保存しました');
    } catch (e, st) {
      _log('[状態保存エラー] $e');
      debugPrint('DrawingController.saveState error: $e\n$st');
    }
  }

  /// ドローイング状態を復元
  Future<void> loadState() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? jsonString = prefs.getString('drawing_state');

      if (jsonString == null || jsonString.isEmpty) {
        _log('[状態復元] 保存された状態がありません');
        return;
      }

      final DrawingState state = DrawingState.fromJsonString(jsonString);

      _strokes.clear();
      _strokes.addAll(state.strokes);

      _texts.clear();
      _texts.addAll(state.texts);

      _generationResults.clear();
      _generationResults.addAll(state.generationResults);

      if (state.referenceImageBytes != null) {
        _referenceImageBytes = state.referenceImageBytes;
        final ui.Codec codec = await ui.instantiateImageCodec(state.referenceImageBytes!);
        final ui.FrameInfo frameInfo = await codec.getNextFrame();
        _referenceImage = frameInfo.image;
      }

      _log('[状態復元] ドローイング状態を復元しました (strokes: ${_strokes.length}, texts: ${_texts.length}, results: ${_generationResults.length})');
      notifyListeners();
    } catch (e, st) {
      _log('[状態復元エラー] $e');
      debugPrint('DrawingController.loadState error: $e\n$st');
    }
  }

  /// ドローイング状態をクリア
  Future<void> clearSavedState() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.remove('drawing_state');
      _log('[状態クリア] 保存された状態をクリアしました');
    } catch (e) {
      _log('[状態クリアエラー] $e');
    }
  }
}

class DrawingControllerRegistry {
  DrawingControllerRegistry._();

  static DrawingController? instance;
}

class _CanvasAction {
  const _CanvasAction.stroke(this.stroke) : text = null;

  const _CanvasAction.text(this.text) : stroke = null;

  final DrawnStroke? stroke;
  final DrawnText? text;
}
