import 'dart:async';
import 'dart:convert';
import 'package:universal_io/io.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../drawing/models/app_settings.dart';
import '../drawing/models/mcp_config.dart';
import '../drawing/services/image_upload_service.dart';
import '../drawing/services/mcp_client.dart';
import '../../shared/app_settings_controller.dart';
import '../../shared/upload_auth_manager.dart';
import 'image_crop_helper.dart';
import 'models/story_scene.dart';

class StoryController extends ChangeNotifier {
  StoryController({required AppSettingsController settingsController})
      : _settingsController = settingsController {
    _settingsController.addListener(_handleSettingsChanged);
    _refreshUploadService(notify: false);
  }

  static const int _maxStatusPolls = 24;
  static const Duration _pollInterval = Duration(seconds: 10);
  static const Uuid _uuid = Uuid();
  static const String _storageKey = 'story_scenes';

  final AppSettingsController _settingsController;
  bool _isInitialized = false;
  ImageUploadService? _uploadService;
  String? _lastSettingsSignature;
  final UploadAuthManager _uploadAuthManager = UploadAuthManager();
  final List<StoryScene> _scenes = <StoryScene>[];

  AppSettings get settings => _settingsController.settings;
  List<StoryScene> get scenes => List<StoryScene>.unmodifiable(_scenes);
  bool get hasRunningScene => _scenes.any((StoryScene scene) => scene.isRunning);

  Future<void> init() async {
    if (_isInitialized) {
      return;
    }
    if (!_settingsController.isInitialized) {
      await _settingsController.init();
    }
    _refreshUploadService(notify: false);

    // 永続化されたシーンを読み込む
    await _loadScenes();

    _isInitialized = true;
  }

  /// シーンを永続化ストレージから読み込む
  Future<void> _loadScenes() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? scenesJson = prefs.getString(_storageKey);

      if (scenesJson != null && scenesJson.isNotEmpty) {
        final List<dynamic> scenesList = jsonDecode(scenesJson) as List<dynamic>;
        _scenes.clear();
        for (final dynamic sceneJson in scenesList) {
          _scenes.add(StoryScene.fromJson(sceneJson as Map<String, dynamic>));
        }
        debugPrint('Loaded ${_scenes.length} scenes from storage');
      }

      // シーンが空の場合は初期シーンを作成
      if (_scenes.isEmpty) {
        _scenes.add(_createNewScene(title: 'シーン 1'));
        debugPrint('Created initial scene');
      }
    } catch (error) {
      debugPrint('Failed to load scenes: $error');
      // エラーが発生した場合は初期シーンを作成
      if (_scenes.isEmpty) {
        _scenes.add(_createNewScene(title: 'シーン 1'));
      }
    }
    // シーンが読み込まれたことをUIに通知
    notifyListeners();
  }

  /// シーンを永続化ストレージに保存
  Future<void> _saveScenes() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final List<Map<String, dynamic>> scenesJson = _scenes.map((StoryScene scene) => scene.toJson()).toList();
      final String encoded = jsonEncode(scenesJson);
      await prefs.setString(_storageKey, encoded);
      debugPrint('Saved ${_scenes.length} scenes to storage');
    } catch (error) {
      debugPrint('Failed to save scenes: $error');
    }
  }

  /// 新しいシーンを作成
  StoryScene _createNewScene({String title = ''}) {
    return StoryScene(
      id: _uuid.v4(),
      title: title,
    );
  }

  /// シーンを追加
  void addScene() {
    final int sceneNumber = _scenes.length + 1;
    _scenes.add(_createNewScene(title: 'シーン $sceneNumber'));
    _saveScenes();
    notifyListeners();
  }

  /// シーンを削除
  void removeScene(String sceneId) {
    _scenes.removeWhere((StoryScene scene) => scene.id == sceneId);
    // シーンが0個になったら、新しいシーンを追加
    if (_scenes.isEmpty) {
      _scenes.add(_createNewScene(title: 'シーン 1'));
    }
    _saveScenes();
    notifyListeners();
  }

  /// プレビュー中のフレームから次のシーンを生成
  Future<StoryScene?> createNextSceneFrom({
    required String sourceSceneId,
    required Uint8List frameBytes,
    Duration? framePosition,
    String? frameFileName,
  }) async {
    if (frameBytes.isEmpty) {
      return null;
    }

    final StoryScene? source = getScene(sourceSceneId);
    if (source == null) {
      return null;
    }

    final int sourceIndex = getSceneIndex(sourceSceneId);
    if (sourceIndex < 0) {
      return null;
    }

    final Uint8List? cropped = await ImageCropHelper.cropToAspectRatio(frameBytes, source.size);

    final StoryScene newScene = StoryScene(
      id: _uuid.v4(),
      title: _suggestNextSceneTitle(source),
      prompt: source.prompt,
      model: source.model,
      seconds: source.seconds,
      size: source.size,
      isRemixEnabled: source.isRemixEnabled,
      manualRemixVideoId: source.requestId?.isNotEmpty == true ? source.requestId! : source.manualRemixVideoId,
      i2vImageBytes: frameBytes,
      i2vImageName: frameFileName ?? 'next_scene_frame.png',
      i2vCroppedBytes: cropped ?? frameBytes,
    );

    _scenes.insert(sourceIndex + 1, newScene);
    await _saveScenes();
    notifyListeners();

    final String positionLabel =
        framePosition != null ? '（位置: ${framePosition.inMilliseconds}ms）' : '';
    final String sourceMessage = positionLabel.isEmpty
        ? 'Next Sceneを作成しました -> ${newScene.title}'
        : 'Next Sceneを作成しました $positionLabel -> ${newScene.title}';
    logToScene(sourceSceneId, sourceMessage);
    final String nextMessage = positionLabel.isEmpty
        ? '前のシーンから開始フレームをコピーしました'
        : '前のシーンから開始フレームをコピーしました $positionLabel';
    logToScene(newScene.id, nextMessage);
    return newScene;
  }

  String _suggestNextSceneTitle(StoryScene source) {
    final String trimmed = source.title.trim();
    if (trimmed.isEmpty) {
      return 'シーン ${_scenes.length + 1}';
    }
    final String baseTitle = trimmed.replaceFirst(RegExp(r'（続き.*）$'), '');
    final int relatedCount =
        _scenes.where((StoryScene scene) => scene.title.startsWith(baseTitle)).length;
    if (relatedCount <= 1) {
      return '$baseTitle（続き）';
    }
    return '$baseTitle（続き$relatedCount）';
  }

  /// シーンを取得
  StoryScene? getScene(String sceneId) {
    try {
      return _scenes.firstWhere((StoryScene scene) => scene.id == sceneId);
    } catch (_) {
      return null;
    }
  }

  /// シーンのインデックスを取得
  int getSceneIndex(String sceneId) {
    return _scenes.indexWhere((StoryScene scene) => scene.id == sceneId);
  }

  /// シーンの結果をリセット
  void resetSceneResult(String sceneId) {
    final StoryScene? scene = getScene(sceneId);
    if (scene != null) {
      scene.resetResult();
      _saveScenes();
      notifyListeners();
    }
  }

  /// シーンのプロパティを更新
  void updateScene(String sceneId, StoryScene Function(StoryScene) updater) {
    final int index = getSceneIndex(sceneId);
    if (index >= 0) {
      _scenes[index] = updater(_scenes[index]);
      _saveScenes();
      notifyListeners();
    }
  }

  Future<String?> ensureUploadAuthorization(BuildContext context, {bool forceRefresh = false}) async {
    if (_uploadService == null) {
      return 'アップロードエンドポイントが未設定です。設定タブで設定してください。';
    }

    final AppSettings currentSettings = _settingsController.settings;
    final String? manualAuth = currentSettings.uploadAuthorization;
    if (manualAuth != null && manualAuth.trim().isNotEmpty) {
      _uploadService!.authorization = manualAuth;
      return null;
    }

    final String vendingEndpoint = currentSettings.uploadAuthEndpoint.trim();
    if (vendingEndpoint.isEmpty) {
      return 'Token Vending Endpoint が未設定です。設定タブで設定してください。';
    }

    try {
      final UploadAuthToken token = await _uploadAuthManager.ensureJwt(
        context: context,
        vendingEndpoint: vendingEndpoint,
        turnstileUrl: currentSettings.uploadTurnstileUrl,
        forceRefresh: forceRefresh,
      );
      _uploadService!.authorization = token.token;
      _uploadService!.deviceId = token.deviceId;
      debugPrint('Story upload JWT acquired (expires ${token.expiresAt.toIso8601String()})');
      return null;
    } on UploadAuthException catch (error) {
      return error.message;
    } catch (error, stack) {
      debugPrint('Story upload JWT unexpected error: $error');
      debugPrint('$stack');
      return 'アップロード用トークンの取得に失敗しました。';
    }
  }

  Future<String?> refreshUploadAuthorization(BuildContext context) {
    return ensureUploadAuthorization(context, forceRefresh: true);
  }

  /// シーンの動画生成を開始
  Future<void> generateSceneVideo(String sceneId) async {
    final StoryScene? scene = getScene(sceneId);
    if (scene == null || scene.isRunning) {
      return;
    }

    final String trimmedPrompt = scene.prompt.trim();
    if (trimmedPrompt.isEmpty) {
      _logToScene(sceneId, 'エラー: プロンプトが空のため生成を開始できません。');
      _setSceneError(sceneId, 'プロンプトを入力してください。');
      return;
    }

    await init();

    final StoryVideoProvider provider = scene.videoProvider;
    final AppSettings currentSettings = settings;
    final String endpoint = _resolveEndpointForProvider(currentSettings, provider).trim();
    final String providerLabel = _providerLabel(provider);

    if (endpoint.isEmpty) {
      _logToScene(sceneId, 'エラー: $providerLabel MCPエンドポイントが未設定です。');
      _setSceneError(sceneId, '$providerLabel のMCPエンドポイントが設定されていません。設定タブで入力してください。');
      return;
    }

    scene.isRunning = true;
    scene.phase = StoryScenePhase.submitting;
    scene.errorMessage = null;
    scene.videoUrl = null;
    scene.curlCommand = null;
    scene.requestId = null;
    scene.remoteStatus = null;
    scene.progress = null;
    scene.logs.clear();
    notifyListeners();

    _logToScene(sceneId, '=== $providerLabel 動画生成を開始 ===');
    _logToScene(sceneId, 'プロンプト: $trimmedPrompt');
    if (provider == StoryVideoProvider.sora) {
      _logToScene(sceneId, 'モデル: ${scene.model}');
      _logToScene(sceneId, '動画長: ${scene.seconds}秒');
      _logToScene(sceneId, '解像度: ${scene.size}');
    } else {
      _logToScene(sceneId, 'アスペクト比: ${scene.veoAspectRatio}');
      _logToScene(sceneId, '解像度: ${scene.veoResolution}');
      _logToScene(sceneId, '音声生成: ${scene.veoGenerateAudio ? 'オン' : 'オフ'}');
    }
    _logToScene(sceneId, '$providerLabel MCPエンドポイント: $endpoint');

    try {
      switch (provider) {
        case StoryVideoProvider.sora:
          await _startSoraGeneration(
            sceneId: sceneId,
            scene: scene,
            prompt: trimmedPrompt,
            endpoint: endpoint,
            settings: currentSettings,
          );
          break;
        case StoryVideoProvider.veo31I2v:
          await _startVeoGeneration(
            sceneId: sceneId,
            scene: scene,
            prompt: trimmedPrompt,
            endpoint: endpoint,
            settings: currentSettings,
          );
          break;
      }
    } catch (error, stackTrace) {
      _logToScene(sceneId, '=== エラーが発生しました ===');
      _logToScene(sceneId, 'エラー内容: $error');
      _logToScene(sceneId, 'StackTrace: $stackTrace');
      debugPrint('StoryController error: $error\n$stackTrace');
      _setSceneError(sceneId, error is Exception ? error.toString() : '$error');
    } finally {
      final StoryScene? finalScene = getScene(sceneId);
      if (finalScene != null) {
        finalScene.isRunning = false;
      }
      _saveScenes();
      notifyListeners();
    }
  }

  /// 保存済みのリクエストIDを使って生成処理を再開
  Future<void> resumeSceneVideo(String sceneId) async {
    final StoryScene? scene = getScene(sceneId);
    if (scene == null || scene.isRunning) {
      return;
    }

    final String? storedRequestId = scene.requestId?.trim();
    if (storedRequestId == null || storedRequestId.isEmpty) {
      _logToScene(sceneId, '保存済みのRequest IDが見つからないため再開できません。先に生成を開始してください。');
      return;
    }

    await init();

    final StoryVideoProvider provider = scene.videoProvider;
    final AppSettings currentSettings = settings;
    final String endpoint = _resolveEndpointForProvider(currentSettings, provider).trim();
    final String providerLabel = _providerLabel(provider);

    if (endpoint.isEmpty) {
      _logToScene(sceneId, 'エラー: $providerLabel MCPエンドポイントが未設定です。');
      _setSceneError(sceneId, '$providerLabel のMCPエンドポイントが設定されていません。設定タブで入力してください。');
      return;
    }

    scene.isRunning = true;
    scene.errorMessage = null;
    notifyListeners();

    _logToScene(sceneId, '=== 保存済み$providerLabelリクエストでステータス確認を再開します ===');
    _logToScene(sceneId, 'Request ID: $storedRequestId');
    _logToScene(sceneId, '$providerLabel MCPエンドポイント: $endpoint');

    try {
      final McpConfig config = _buildConfigForProvider(
        provider: provider,
        endpoint: endpoint,
        settings: currentSettings,
      );
      final McpClient client = McpClient(config, logger: (String message) => _logToScene(sceneId, message));

      await _continueSceneWorkflow(
        sceneId: sceneId,
        scene: scene,
        client: client,
        config: config,
        requestId: storedRequestId,
        provider: provider,
        providerLabel: providerLabel,
        statusIdKeys: provider == StoryVideoProvider.sora
            ? const <String>['video_id', 'request_id']
            : const <String>['request_id'],
        resultIdKeys: provider == StoryVideoProvider.sora
            ? const <String>['video_id', 'request_id']
            : const <String>['request_id'],
        enableStoryGenApi: provider == StoryVideoProvider.sora,
      );
    } catch (error, stackTrace) {
      _logToScene(sceneId, '=== エラーが発生しました ===');
      _logToScene(sceneId, 'エラー内容: $error');
      _logToScene(sceneId, 'StackTrace: $stackTrace');
      debugPrint('StoryController error: $error\n$stackTrace');
      _setSceneError(sceneId, error is Exception ? error.toString() : '$error');
    } finally {
      final StoryScene? finalScene = getScene(sceneId);
      if (finalScene != null) {
        finalScene.isRunning = false;
      }
      _saveScenes();
      notifyListeners();
    }
  }

  Future<void> _startSoraGeneration({
    required String sceneId,
    required StoryScene scene,
    required String prompt,
    required String endpoint,
    required AppSettings settings,
  }) async {
    String? referenceUrl;
    if (scene.referenceBytes != null && scene.referenceBytes!.isNotEmpty) {
      if (_uploadService == null) {
        throw Exception('参照画像をアップロードするためのエンドポイントが設定されていません。');
      }
      _logToScene(sceneId, '参照画像のアップロードを開始 (${scene.referenceBytes!.length} bytes)');
      scene.phase = StoryScenePhase.uploadingReference;
      notifyListeners();
      try {
        referenceUrl = await _uploadService!.uploadImage(
          scene.referenceBytes!,
          filename: scene.referenceName,
        );
        _logToScene(sceneId, '参照画像のアップロードが完了しました: $referenceUrl');
      } catch (uploadError, uploadStack) {
        _logToScene(sceneId, '参照画像のアップロードに失敗しました: $uploadError');
        _logToScene(sceneId, 'StackTrace: $uploadStack');
        rethrow;
      }
    } else {
      _logToScene(sceneId, '参照画像なし（プロンプトのみで生成）');
    }

    scene.phase = StoryScenePhase.submitting;
    notifyListeners();

    final McpConfig config = _buildConfigForProvider(
      provider: StoryVideoProvider.sora,
      endpoint: endpoint,
      settings: settings,
    );

    _logToScene(sceneId, 'MCPクライアントを初期化しました');
    final McpClient client = McpClient(config, logger: (String message) => _logToScene(sceneId, message));

    Map<String, dynamic> submitEnvelope;

    final bool isRemixMode = scene.isRemixEnabled && scene.manualRemixVideoId.trim().isNotEmpty;

    if (isRemixMode) {
      if (config.remixTool == null || config.remixTool!.isEmpty) {
        throw Exception('Remix機能が設定されていません。');
      }

      _logToScene(sceneId, 'Remixリクエストを送信します (ツール: ${config.remixTool})');
      final Map<String, dynamic> remixArgs = <String, dynamic>{
        'prompt': prompt,
        'video_id': scene.manualRemixVideoId.trim(),
      };
      _logToScene(sceneId, 'Remixパラメータ: $remixArgs');

      try {
        submitEnvelope = await client.callTool(
          toolName: config.remixTool!,
          arguments: remixArgs,
        );
        _logToScene(sceneId, 'Remixリクエストの送信が完了しました');
        _logToScene(sceneId, 'レスポンス: $submitEnvelope');
      } catch (remixError, remixStack) {
        _logToScene(sceneId, 'Remixリクエストの送信に失敗しました: $remixError');
        _logToScene(sceneId, 'StackTrace: $remixStack');
        rethrow;
      }
    } else {
      _logToScene(sceneId, '生成リクエストを送信します (ツール: ${config.submitTool})');
      final Map<String, dynamic> submitArgs = <String, dynamic>{
        'prompt': prompt,
        'model': scene.model,
        'seconds': scene.seconds.toString(),
        'size': scene.size,
        if (referenceUrl != null) 'input_reference': referenceUrl,
      };
      _logToScene(sceneId, 'リクエストパラメータ: $submitArgs');

      try {
        submitEnvelope = await client.callTool(
          toolName: config.submitTool,
          arguments: submitArgs,
        );
        _logToScene(sceneId, '生成リクエストの送信が完了しました');
        _logToScene(sceneId, 'レスポンス: $submitEnvelope');
      } catch (submitError, submitStack) {
        _logToScene(sceneId, '生成リクエストの送信に失敗しました: $submitError');
        _logToScene(sceneId, 'StackTrace: $submitStack');
        rethrow;
      }
    }

    final String? videoId = _extractVideoId(submitEnvelope);
    if (videoId == null || videoId.isEmpty) {
      _logToScene(sceneId, '動画IDの抽出に失敗しました。レスポンス内容: $submitEnvelope');
      throw Exception('動画IDの抽出に失敗しました。');
    }
    scene.requestId = videoId;
    _logToScene(sceneId, 'Video IDを取得しました: $videoId');

    await _continueSceneWorkflow(
      sceneId: sceneId,
      scene: scene,
      client: client,
      config: config,
      requestId: videoId,
      provider: StoryVideoProvider.sora,
      providerLabel: _providerLabel(StoryVideoProvider.sora),
      statusIdKeys: const <String>['video_id', 'request_id'],
      resultIdKeys: const <String>['video_id', 'request_id'],
      enableStoryGenApi: true,
    );
  }

  Future<void> _startVeoGeneration({
    required String sceneId,
    required StoryScene scene,
    required String prompt,
    required String endpoint,
    required AppSettings settings,
  }) async {
    final Uint8List? uploadBytes = scene.i2vCroppedBytes ?? scene.i2vImageBytes ?? scene.referenceBytes;
    if (uploadBytes == null || uploadBytes.isEmpty) {
      throw Exception('i2v画像が未設定です。先に画像を選択してください。');
    }
    if (_uploadService == null) {
      throw Exception('参照画像をアップロードするためのエンドポイントが設定されていません。');
    }

    final String filename = scene.i2vImageName ??
        scene.referenceName ??
        'i2v_image.png';

    _logToScene(sceneId, 'i2v画像のアップロードを開始 (${uploadBytes.length} bytes)');
    scene.phase = StoryScenePhase.uploadingReference;
    notifyListeners();

    String imageUrl;
    try {
      imageUrl = await _uploadService!.uploadImage(uploadBytes, filename: filename);
      _logToScene(sceneId, 'i2v画像のアップロードが完了しました: $imageUrl');
    } catch (uploadError, uploadStack) {
      _logToScene(sceneId, 'i2v画像のアップロードに失敗しました: $uploadError');
      _logToScene(sceneId, 'StackTrace: $uploadStack');
      rethrow;
    }

    scene.phase = StoryScenePhase.submitting;
    notifyListeners();

    final McpConfig config = _buildConfigForProvider(
      provider: StoryVideoProvider.veo31I2v,
      endpoint: endpoint,
      settings: settings,
    );

    _logToScene(sceneId, 'MCPクライアントを初期化しました');
    final McpClient client = McpClient(config, logger: (String message) => _logToScene(sceneId, message));

    final Map<String, dynamic> submitArgs = <String, dynamic>{
      'prompt': prompt,
      'image_url': imageUrl,
      'duration': scene.veoDuration,
      'aspect_ratio': scene.veoAspectRatio,
      'resolution': scene.veoResolution,
      'generate_audio': scene.veoGenerateAudio,
    };
    _logToScene(sceneId, '生成リクエストを送信します (ツール: ${config.submitTool})');
    _logToScene(sceneId, 'リクエストパラメータ: $submitArgs');

    Map<String, dynamic> submitEnvelope;
    try {
      submitEnvelope = await client.callTool(
        toolName: config.submitTool,
        arguments: submitArgs,
      );
      _logToScene(sceneId, '生成リクエストの送信が完了しました');
      _logToScene(sceneId, 'レスポンス: $submitEnvelope');
    } catch (submitError, submitStack) {
      _logToScene(sceneId, '生成リクエストの送信に失敗しました: $submitError');
      _logToScene(sceneId, 'StackTrace: $submitStack');
      rethrow;
    }

    final String? requestId = _extractVideoId(submitEnvelope);
    if (requestId == null || requestId.isEmpty) {
      _logToScene(sceneId, 'リクエストIDの抽出に失敗しました。レスポンス内容: $submitEnvelope');
      throw Exception('リクエストIDの抽出に失敗しました。');
    }
    scene.requestId = requestId;
    _logToScene(sceneId, 'Request IDを取得しました: $requestId');

    await _continueSceneWorkflow(
      sceneId: sceneId,
      scene: scene,
      client: client,
      config: config,
      requestId: requestId,
      provider: StoryVideoProvider.veo31I2v,
      providerLabel: _providerLabel(StoryVideoProvider.veo31I2v),
      statusIdKeys: const <String>['request_id'],
      resultIdKeys: const <String>['request_id'],
      enableStoryGenApi: false,
    );
  }

  String _resolveEndpointForProvider(AppSettings settings, StoryVideoProvider provider) {
    switch (provider) {
      case StoryVideoProvider.sora:
        return settings.soraEndpoint;
      case StoryVideoProvider.veo31I2v:
        return settings.veoEndpoint;
    }
  }

  String _providerLabel(StoryVideoProvider provider) {
    switch (provider) {
      case StoryVideoProvider.sora:
        return 'Sora';
      case StoryVideoProvider.veo31I2v:
        return 'Veo3.1 I2V';
    }
  }

  McpConfig _buildConfigForProvider({
    required StoryVideoProvider provider,
    required String endpoint,
    required AppSettings settings,
  }) {
    switch (provider) {
      case StoryVideoProvider.sora:
        return McpConfig(
          name: 'OpenAI Sora',
          url: endpoint,
          authorization: settings.mcpAuthorization,
          submitTool: 'openai_sora_submit',
          statusTool: 'openai_sora_status',
          resultTool: 'openai_sora_result',
          remixTool: 'openai_sora_remix',
        );
      case StoryVideoProvider.veo31I2v:
        return McpConfig(
          name: 'Veo3.1 I2V',
          url: endpoint,
          authorization: settings.mcpAuthorization,
          submitTool: 'veo31_i2v_submit',
          statusTool: 'veo31_i2v_status',
          resultTool: 'veo31_i2v_result',
        );
    }
  }

  Future<void> _continueSceneWorkflow({
    required String sceneId,
    required StoryScene scene,
    required McpClient client,
    required McpConfig config,
    required String requestId,
    required StoryVideoProvider provider,
    required String providerLabel,
    required List<String> statusIdKeys,
    required List<String> resultIdKeys,
    required bool enableStoryGenApi,
  }) async {
    scene.remoteStatus = null;
    scene.progress = null;
    scene.phase = StoryScenePhase.waiting;
    notifyListeners();
    _logToScene(sceneId, '$providerLabel の処理完了を待機します（最大$_maxStatusPolls回、${_pollInterval.inSeconds}秒間隔でポーリング）');

    bool isDone = false;
    for (int attempt = 0; attempt < _maxStatusPolls; attempt++) {
      await Future<void>.delayed(_pollInterval);
      _logToScene(sceneId, 'ステータス確認 (${attempt + 1}/$_maxStatusPolls)...');
      Map<String, dynamic> statusEnvelope;
      try {
        statusEnvelope = await client.callTool(
          toolName: config.statusTool,
          arguments: <String, dynamic>{
            for (final String key in statusIdKeys) key: requestId,
          },
        );
      } catch (statusError, statusStack) {
        _logToScene(sceneId, 'ステータス確認中にエラーが発生しました: $statusError');
        _logToScene(sceneId, 'StackTrace: $statusStack');
        continue;
      }

      final String? status = _extractStatus(statusEnvelope);
      final int? progress = _extractProgress(statusEnvelope);

      if (status != null) {
        scene.remoteStatus = status;
        scene.progress = progress;

        final String progressStr = progress != null ? ' (進捗: $progress%)' : '';
        _logToScene(sceneId, 'ステータス(${attempt + 1}/$_maxStatusPolls): $status$progressStr');
        notifyListeners();

        if (status == 'DONE') {
          isDone = true;
          _logToScene(sceneId, '生成が完了しました！');
          _logToScene(sceneId, '完了時のフルレスポンス: ${jsonEncode(statusEnvelope)}');
          break;
        }
        if (status == 'ERROR') {
          _logToScene(sceneId, '$providerLabel が生成エラーを報告しました。レスポンス: $statusEnvelope');
          throw Exception('$providerLabel の生成が失敗しました。');
        }
      } else {
        _logToScene(sceneId, 'ステータス(${attempt + 1}/$_maxStatusPolls): 取得できませんでした。レスポンス: $statusEnvelope');
      }
    }

    if (!isDone) {
      _logToScene(sceneId, '最大ポーリング回数に到達しましたが、生成は完了していません。');
      throw Exception('$providerLabel の生成がタイムアウトしました。');
    }

    scene.phase = StoryScenePhase.downloading;
    notifyListeners();
    _logToScene(sceneId, '動画URLを取得します (ツール: ${config.resultTool})');

    Map<String, dynamic> resultEnvelope;
    try {
      resultEnvelope = await client.callTool(
        toolName: config.resultTool,
        arguments: <String, dynamic>{
          for (final String key in resultIdKeys) key: requestId,
        },
      );
      _logToScene(sceneId, '動画URL取得リクエストが完了しました');
      _logToScene(sceneId, 'レスポンス: $resultEnvelope');
    } catch (resultError, resultStack) {
      _logToScene(sceneId, '動画URL取得リクエストに失敗しました: $resultError');
      _logToScene(sceneId, 'StackTrace: $resultStack');
      rethrow;
    }

    final dynamic payload = resultEnvelope['result'] ?? resultEnvelope;
    String? videoUrl = _extractAnyUrl(payload);
    final String? curlCommand = _extractCurlCommand(payload);
    scene.curlCommand = curlCommand;

    if (enableStoryGenApi && curlCommand != null) {
      final String preview = curlCommand.length > 160 ? '${curlCommand.substring(0, 160)}…' : curlCommand;
      _logToScene(sceneId, 'curlコマンドを検出しました: $preview');
      final String? downloadedUrl = await _tryDownloadViaStoryGenApi(
        sceneId: sceneId,
        curlCommand: curlCommand,
        videoId: requestId,
      );
      if (downloadedUrl != null && downloadedUrl.isNotEmpty) {
        videoUrl = downloadedUrl;
        _logToScene(sceneId, 'Story Gen APIから動画を取得しました: $downloadedUrl');
      }
    }

    if (videoUrl == null || videoUrl.isEmpty) {
      if (curlCommand != null) {
        _logToScene(sceneId, '動画URLを抽出できませんでした。curlコマンドを利用してダウンロードしてください。');
      } else {
        _logToScene(sceneId, '動画URLとcurlコマンドのどちらも取得できませんでした。');
      }
      throw Exception('動画URLが取得できませんでした。');
    }

    scene.videoUrl = videoUrl;
    _logToScene(sceneId, '動画URLを取得しました: $videoUrl');

    scene.phase = StoryScenePhase.downloading;
    _logToScene(sceneId, '動画のダウンロードを開始します...');
    notifyListeners();

    final String? localPath = await _downloadVideo(sceneId, videoUrl, requestId, provider);
    if (localPath != null && localPath.isNotEmpty) {
      scene.localVideoPath = localPath;
      _logToScene(sceneId, '動画をローカルに保存しました: $localPath');
    } else {
      _logToScene(sceneId, '動画のダウンロードに失敗しました。URLから直接再生してください。');
    }

    scene.phase = StoryScenePhase.completed;
    _logToScene(sceneId, '=== $providerLabel 動画生成が完了しました ===');
    notifyListeners();
  }

  Future<String?> _tryDownloadViaStoryGenApi({
    required String sceneId,
    required String curlCommand,
    required String videoId,
  }) async {
    final String base = settings.storyGenApiBase.trim();
    if (base.isEmpty) {
      _logToScene(sceneId, 'Story Gen APIベースURLが未設定のため自動ダウンロードをスキップします。');
      return null;
    }
    try {
      final String normalized = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
      final Uri endpoint = Uri.parse('$normalized/api/story-gen/sora/download');
      _logToScene(sceneId, 'Story Gen APIへダウンロード要求: $endpoint');
      final http.Response response = await http
          .post(
            endpoint,
            headers: <String, String>{'Content-Type': 'application/json'},
            body: jsonEncode(<String, String>{
              'curl_command': curlCommand,
              'video_id': videoId,
            }),
          )
          .timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) {
        _logToScene(sceneId, 'Story Gen APIの応答: ${response.statusCode} ${response.body}');
        return null;
      }

      final Map<String, dynamic> data = jsonDecode(response.body) as Map<String, dynamic>;
      final String? localUrl = (data['local_url'] as String?)?.trim();
      if (localUrl != null && localUrl.isNotEmpty) {
        return localUrl;
      }
      final String? remoteUrl = (data['remote_url'] as String?)?.trim();
      if (remoteUrl != null && remoteUrl.isNotEmpty) {
        return remoteUrl;
      }
      final String? relative = (data['relative_path'] as String?)?.trim();
      if (relative != null && relative.isNotEmpty) {
        return '$normalized/saves/$relative';
      }
      _logToScene(sceneId, 'Story Gen APIの応答に有効なURLが含まれていません。');
      return null;
    } catch (error) {
      _logToScene(sceneId, 'Story Gen APIでのダウンロードに失敗: $error');
      return null;
    }
  }

  void _setSceneError(String sceneId, String message) {
    final StoryScene? scene = getScene(sceneId);
    if (scene != null) {
      scene.phase = StoryScenePhase.error;
      final String normalized = message.startsWith('Exception: ')
          ? message.substring('Exception: '.length)
          : message;
      scene.errorMessage = normalized;
      _logToScene(sceneId, 'エラー: $normalized');
      notifyListeners();
    }
  }

  /// シーンにログメッセージを追加（外部からも呼び出し可能）
  void logToScene(String sceneId, String message) {
    final StoryScene? scene = getScene(sceneId);
    if (scene != null) {
      final String line = '[${DateTime.now().toIso8601String()}] $message';
      scene.logs.add(line);
      debugPrint('[$sceneId] $line');
      notifyListeners();
    }
  }

  // 内部用の旧メソッド名も互換性のために残す
  void _logToScene(String sceneId, String message) {
    logToScene(sceneId, message);
  }

  void _refreshUploadService({bool notify = true}) {
    final AppSettings currentSettings = _settingsController.settings;
    final String signature = currentSettings.toJsonString();
    if (_lastSettingsSignature == signature) {
      if (notify) {
        notifyListeners();
      }
      return;
    }
    _lastSettingsSignature = signature;
    _uploadAuthManager.invalidate();
    if (currentSettings.uploadEndpoint.isNotEmpty) {
      _uploadService = ImageUploadService(
        uploadEndpoint: currentSettings.uploadEndpoint,
        exposeEndpoint: currentSettings.exposeEndpoint,
        authorization: currentSettings.uploadAuthorization,
        logger: (String message) => debugPrint(message),
      );
    } else {
      _uploadService = null;
    }
    if (notify) {
      notifyListeners();
    }
  }

  void _handleSettingsChanged() {
    _refreshUploadService();
  }

  String? _extractVideoId(dynamic value) {
    if (value == null) {
      return null;
    }
    if (value is Map<String, dynamic>) {
      final List<String> keys = <String>['video_id', 'request_id', 'id'];
      for (final String key in keys) {
        final dynamic candidate = value[key];
        if (candidate is String && candidate.trim().isNotEmpty) {
          return candidate.trim();
        }
      }
      if (value.containsKey('result')) {
        final String? fromResult = _extractVideoId(value['result']);
        if (fromResult != null) {
          return fromResult;
        }
      }
      if (value.containsKey('content')) {
        final String? fromContent = _extractVideoId(value['content']);
        if (fromContent != null) {
          return fromContent;
        }
      }
      // textフィールドの中のJSON文字列をパースして処理
      if (value.containsKey('text')) {
        final dynamic textValue = value['text'];
        if (textValue is String) {
          try {
            final dynamic parsed = jsonDecode(textValue);
            final String? fromParsed = _extractVideoId(parsed);
            if (fromParsed != null) {
              return fromParsed;
            }
          } catch (_) {
            // JSON文字列でない場合は通常の文字列として処理
            final String? fromText = _extractVideoId(textValue);
            if (fromText != null) {
              return fromText;
            }
          }
        }
      }
    }
    if (value is Iterable) {
      for (final dynamic item in value) {
        final String? nested = _extractVideoId(item);
        if (nested != null) {
          return nested;
        }
      }
    }
    if (value is String) {
      final RegExpMatch? videoMatch = RegExp(r'video_[0-9a-fA-F\-]{6,}').firstMatch(value);
      if (videoMatch != null) {
        return videoMatch.group(0);
      }
      final RegExpMatch? uuidMatch = RegExp(
        r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}',
      ).firstMatch(value);
      if (uuidMatch != null) {
        return uuidMatch.group(0);
      }
    }
    return null;
  }

  String? _extractStatus(dynamic value) {
    final String? direct = _extractStatusString(value);
    if (direct != null) {
      return direct;
    }
    final Iterable<String> texts = _collectTexts(value);
    for (final String text in texts) {
      final String? normalized = _normalizeStatus(text);
      if (normalized != null) {
        return normalized;
      }
    }
    return null;
  }

  String? _extractStatusString(dynamic value) {
    if (value is Map<String, dynamic>) {
      final List<String> keys = <String>['status', 'state'];
      for (final String key in keys) {
        final dynamic candidate = value[key];
        if (candidate is String) {
          final String? normalized = _normalizeStatus(candidate);
          if (normalized != null) {
            return normalized;
          }
        }
      }
      if (value.containsKey('result')) {
        final String? nested = _extractStatusString(value['result']);
        if (nested != null) {
          return nested;
        }
      }
      if (value.containsKey('content')) {
        final String? nestedContent = _extractStatusString(value['content']);
        if (nestedContent != null) {
          return nestedContent;
        }
      }
      // textフィールドの中のJSON文字列をパースして処理
      if (value.containsKey('text')) {
        final dynamic textValue = value['text'];
        if (textValue is String) {
          try {
            final dynamic parsed = jsonDecode(textValue);
            final String? fromParsed = _extractStatusString(parsed);
            if (fromParsed != null) {
              return fromParsed;
            }
          } catch (_) {
            // JSON文字列でない場合はスキップ
          }
        }
      }
    } else if (value is Iterable) {
      for (final dynamic item in value) {
        final String? nested = _extractStatusString(item);
        if (nested != null) {
          return nested;
        }
      }
    }
    return null;
  }

  Iterable<String> _collectTexts(dynamic value) sync* {
    if (value == null) {
      return;
    }
    if (value is String) {
      yield value;
    } else if (value is Map<String, dynamic>) {
      if (value['text'] is String) {
        final String textValue = value['text'] as String;
        yield textValue;
        // textフィールドの中のJSON文字列をパースして再帰処理
        try {
          final dynamic parsed = jsonDecode(textValue);
          yield* _collectTexts(parsed);
        } catch (_) {
          // JSON文字列でない場合はスキップ
        }
      }
      for (final dynamic v in value.values) {
        yield* _collectTexts(v);
      }
    } else if (value is Iterable) {
      for (final dynamic item in value) {
        yield* _collectTexts(item);
      }
    }
  }

  String? _normalizeStatus(String input) {
    final String trimmed = input.trim().toLowerCase();
    if (trimmed.isEmpty) {
      return null;
    }
    if (trimmed.contains('queue') || trimmed.contains('待機')) {
      return 'IN_QUEUE';
    }
    if (trimmed.contains('progress') || trimmed.contains('processing') || trimmed.contains('処理中')) {
      return 'IN_PROGRESS';
    }
    if (trimmed.contains('done') || trimmed.contains('complete') || trimmed.contains('完了') || trimmed.contains('success')) {
      return 'DONE';
    }
    if (trimmed.contains('error') || trimmed.contains('fail') || trimmed.contains('失敗')) {
      return 'ERROR';
    }
    return null;
  }

  /// レスポンスからprogressフィールド（0-100の数値）を抽出
  int? _extractProgress(dynamic value) {
    if (value == null) {
      return null;
    }
    if (value is int) {
      return value;
    }
    if (value is Map<String, dynamic>) {
      // progressフィールドを直接探す
      if (value.containsKey('progress')) {
        final dynamic progressValue = value['progress'];
        if (progressValue is int) {
          return progressValue;
        }
        if (progressValue is String) {
          return int.tryParse(progressValue);
        }
      }
      // resultフィールド内を再帰的に探す
      if (value.containsKey('result')) {
        final int? nested = _extractProgress(value['result']);
        if (nested != null) {
          return nested;
        }
      }
      // contentフィールド内を再帰的に探す
      if (value.containsKey('content')) {
        final int? nestedContent = _extractProgress(value['content']);
        if (nestedContent != null) {
          return nestedContent;
        }
      }
      // textフィールドの中のJSON文字列をパースして処理
      if (value.containsKey('text')) {
        final dynamic textValue = value['text'];
        if (textValue is String) {
          try {
            final dynamic parsed = jsonDecode(textValue);
            final int? fromParsed = _extractProgress(parsed);
            if (fromParsed != null) {
              return fromParsed;
            }
          } catch (_) {
            // JSON文字列でない場合はスキップ
          }
        }
      }
    } else if (value is Iterable) {
      for (final dynamic item in value) {
        final int? nested = _extractProgress(item);
        if (nested != null) {
          return nested;
        }
      }
    }
    return null;
  }

  String? _extractAnyUrl(dynamic value) {
    if (value == null) {
      return null;
    }
    if (value is String) {
      final RegExpMatch? match = RegExp(r'https?://[^\s"\)<>]+', caseSensitive: false).firstMatch(value);
      if (match != null) {
        return match.group(0);
      }
      return null;
    }
    if (value is Map<String, dynamic>) {
      const List<String> keys = <String>['url', 'download_url', 'result_url', 'video_url', 'local_url', 'remote_url', 'href'];
      for (final String key in keys) {
        final dynamic candidate = value[key];
        final String? url = _extractAnyUrl(candidate);
        if (url != null) {
          return url;
        }
      }
      if (value.containsKey('content')) {
        final String? fromContent = _extractAnyUrl(value['content']);
        if (fromContent != null) {
          return fromContent;
        }
      }
      // textフィールドの中のJSON文字列をパースして処理
      if (value.containsKey('text')) {
        final dynamic textValue = value['text'];
        if (textValue is String) {
          try {
            final dynamic parsed = jsonDecode(textValue);
            final String? fromParsed = _extractAnyUrl(parsed);
            if (fromParsed != null) {
              return fromParsed;
            }
          } catch (_) {
            // JSON文字列でない場合は文字列として処理
            final String? fromText = _extractAnyUrl(textValue);
            if (fromText != null) {
              return fromText;
            }
          }
        }
      }
      for (final dynamic nestedValue in value.values) {
        final String? nestedUrl = _extractAnyUrl(nestedValue);
        if (nestedUrl != null) {
          return nestedUrl;
        }
      }
    }
    if (value is Iterable) {
      for (final dynamic item in value) {
        final String? nested = _extractAnyUrl(item);
        if (nested != null) {
          return nested;
        }
      }
    }
    return null;
  }

  String? _extractCurlCommand(dynamic value) {
    for (final String text in _collectTexts(value)) {
      final RegExp fenced = RegExp(r'```(?:bash|shell)?\s*([\s\S]*?)```', caseSensitive: false);
      final Iterable<RegExpMatch> matches = fenced.allMatches(text);
      for (final RegExpMatch match in matches) {
        final String? snippet = match.group(1);
        if (snippet != null && snippet.trim().toLowerCase().startsWith('curl ')) {
          return snippet.trim();
        }
      }
      final RegExpMatch? inline = RegExp(r'(curl\s+[^\n\r]+)', caseSensitive: false).firstMatch(text);
      if (inline != null) {
        return inline.group(1)!.trim();
      }
    }
    return null;
  }

  /// 動画URLからファイルをダウンロードしてローカルに保存
  Future<String?> _downloadVideo(
    String sceneId,
    String videoUrl,
    String requestId,
    StoryVideoProvider provider,
  ) async {
    try {
      _logToScene(sceneId, '動画URLからダウンロード中: $videoUrl');

      // HTTPリクエストで動画データを取得
      final http.Response response = await http.get(Uri.parse(videoUrl)).timeout(
        const Duration(minutes: 5),
        onTimeout: () {
          throw Exception('動画ダウンロードがタイムアウトしました');
        },
      );

      if (response.statusCode != 200) {
        _logToScene(sceneId, '動画ダウンロード失敗: HTTP ${response.statusCode}');
        return null;
      }

      final Uint8List videoBytes = response.bodyBytes;
      _logToScene(sceneId, '動画データを取得しました (${videoBytes.length} bytes)');

      // ローカルストレージのパスを取得
      final Directory appDir = await getApplicationDocumentsDirectory();
      final String videosDir = '${appDir.path}/videos';

      // videosディレクトリが存在しない場合は作成
      final Directory dir = Directory(videosDir);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }

      // ファイル名を生成（リクエストID + タイムスタンプ）
      final String timestamp = DateTime.now().millisecondsSinceEpoch.toString();
      final String prefix = provider == StoryVideoProvider.sora ? 'sora' : 'veo';
      final String filename = '${prefix}_${requestId}_$timestamp.mp4';
      final String filePath = '$videosDir/$filename';

      // ファイルに保存
      final File file = File(filePath);
      await file.writeAsBytes(videoBytes);

      _logToScene(sceneId, '動画ファイルを保存しました: $filePath');
      return filePath;
    } catch (error, stackTrace) {
      _logToScene(sceneId, '動画ダウンロード中にエラーが発生しました: $error');
      _logToScene(sceneId, 'StackTrace: $stackTrace');
      return null;
    }
  }

  @override
  void dispose() {
    _settingsController.removeListener(_handleSettingsChanged);
    super.dispose();
  }
}
