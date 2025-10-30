import 'package:flutter/foundation.dart';

/// ストーリーの1シーンを表すモデル
class StoryScene {
  StoryScene({
    required this.id,
    this.title = '',
    this.prompt = '',
    this.videoProvider = StoryVideoProvider.sora,
    this.model = 'sora-2',
    this.seconds = 12,
    this.size = '1280x720',
    this.referenceBytes,
    this.referenceName,
    this.i2vImageBytes,
    this.i2vImageName,
    this.i2vCroppedBytes,
    this.veoAspectRatio = '16:9',
    this.veoResolution = '720p',
    this.veoDuration = '8s',
    this.veoGenerateAudio = true,
    this.isRemixEnabled = false,
    this.manualRemixVideoId = '',
    this.phase = StoryScenePhase.idle,
    this.errorMessage,
    this.videoUrl,
    this.localVideoPath,
    this.curlCommand,
    this.requestId,
    this.remoteStatus,
    this.progress,
    this.isRunning = false,
    List<String>? logs,
  }) : logs = logs ?? <String>[];

  final String id;
  String title;
  String prompt;
  StoryVideoProvider videoProvider;
  String model;
  int seconds;
  String size;
  Uint8List? referenceBytes;
  String? referenceName;
  Uint8List? i2vImageBytes;
  String? i2vImageName;
  Uint8List? i2vCroppedBytes;
  String veoAspectRatio;
  String veoResolution;
  String veoDuration;
  bool veoGenerateAudio;
  bool isRemixEnabled;
  String manualRemixVideoId;

  // 生成状態
  StoryScenePhase phase;
  String? errorMessage;
  String? videoUrl;
  String? localVideoPath;
  String? curlCommand;
  String? requestId;
  String? remoteStatus;
  int? progress; // 0-100の進捗率
  bool isRunning;
  List<String> logs;

  StoryScene copyWith({
    String? id,
    String? title,
    String? prompt,
    StoryVideoProvider? videoProvider,
    String? model,
    int? seconds,
    String? size,
    Uint8List? referenceBytes,
    String? referenceName,
    Uint8List? i2vImageBytes,
    String? i2vImageName,
    Uint8List? i2vCroppedBytes,
    String? veoAspectRatio,
    String? veoResolution,
    String? veoDuration,
    bool? veoGenerateAudio,
    bool? isRemixEnabled,
    String? manualRemixVideoId,
    StoryScenePhase? phase,
    String? errorMessage,
    String? videoUrl,
    String? localVideoPath,
    String? curlCommand,
    String? requestId,
    String? remoteStatus,
    int? progress,
    bool? isRunning,
    List<String>? logs,
  }) {
    return StoryScene(
      id: id ?? this.id,
      title: title ?? this.title,
      prompt: prompt ?? this.prompt,
      videoProvider: videoProvider ?? this.videoProvider,
      model: model ?? this.model,
      seconds: seconds ?? this.seconds,
      size: size ?? this.size,
      referenceBytes: referenceBytes ?? this.referenceBytes,
      referenceName: referenceName ?? this.referenceName,
      i2vImageBytes: i2vImageBytes ?? this.i2vImageBytes,
      i2vImageName: i2vImageName ?? this.i2vImageName,
      i2vCroppedBytes: i2vCroppedBytes ?? this.i2vCroppedBytes,
      veoAspectRatio: veoAspectRatio ?? this.veoAspectRatio,
      veoResolution: veoResolution ?? this.veoResolution,
      veoDuration: veoDuration ?? this.veoDuration,
      veoGenerateAudio: veoGenerateAudio ?? this.veoGenerateAudio,
      isRemixEnabled: isRemixEnabled ?? this.isRemixEnabled,
      manualRemixVideoId: manualRemixVideoId ?? this.manualRemixVideoId,
      phase: phase ?? this.phase,
      errorMessage: errorMessage ?? this.errorMessage,
      videoUrl: videoUrl ?? this.videoUrl,
      localVideoPath: localVideoPath ?? this.localVideoPath,
      curlCommand: curlCommand ?? this.curlCommand,
      requestId: requestId ?? this.requestId,
      remoteStatus: remoteStatus ?? this.remoteStatus,
      progress: progress ?? this.progress,
      isRunning: isRunning ?? this.isRunning,
      logs: logs ?? this.logs,
    );
  }

  void resetResult() {
    phase = StoryScenePhase.idle;
    errorMessage = null;
    videoUrl = null;
    localVideoPath = null;
    curlCommand = null;
    requestId = null;
    remoteStatus = null;
    progress = null;
    logs.clear();
    isRunning = false;
  }

  /// JSON形式に変換（永続化用）
  /// 注意: 画像データ（referenceBytes, i2vImageBytes, i2vCroppedBytes）は保存しない
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'title': title,
      'prompt': prompt,
      'videoProvider': videoProvider.storageValue,
      'model': model,
      'seconds': seconds,
      'size': size,
      'referenceName': referenceName,
      'i2vImageName': i2vImageName,
      'veoAspectRatio': veoAspectRatio,
      'veoResolution': veoResolution,
      'veoDuration': veoDuration,
      'veoGenerateAudio': veoGenerateAudio,
      'isRemixEnabled': isRemixEnabled,
      'manualRemixVideoId': manualRemixVideoId,
      'phase': phase.index,
      'errorMessage': errorMessage,
      'videoUrl': videoUrl,
      'localVideoPath': localVideoPath,
      'curlCommand': curlCommand,
      'requestId': requestId,
      'remoteStatus': remoteStatus,
      'progress': progress,
      'logs': logs,
    };
  }

  /// JSONから復元
  factory StoryScene.fromJson(Map<String, dynamic> json) {
    return StoryScene(
      id: json['id'] as String,
      title: json['title'] as String? ?? '',
      prompt: json['prompt'] as String? ?? '',
      videoProvider: StoryVideoProviderX.fromStorage(json['videoProvider'] as String?),
      model: json['model'] as String? ?? 'sora-2',
      seconds: json['seconds'] as int? ?? 12,
      size: json['size'] as String? ?? '1280x720',
      referenceName: json['referenceName'] as String?,
      i2vImageName: json['i2vImageName'] as String?,
      veoAspectRatio: (json['veoAspectRatio'] as String?)?.trim().isNotEmpty == true
          ? (json['veoAspectRatio'] as String).trim()
          : '16:9',
      veoResolution: (json['veoResolution'] as String?)?.trim().isNotEmpty == true
          ? (json['veoResolution'] as String).trim()
          : '720p',
      veoDuration: (json['veoDuration'] as String?)?.trim().isNotEmpty == true
          ? (json['veoDuration'] as String).trim()
          : '8s',
      veoGenerateAudio: json['veoGenerateAudio'] as bool? ?? true,
      isRemixEnabled: json['isRemixEnabled'] as bool? ?? false,
      manualRemixVideoId: json['manualRemixVideoId'] as String? ?? '',
      phase: StoryScenePhase.values[json['phase'] as int? ?? 0],
      errorMessage: json['errorMessage'] as String?,
      videoUrl: json['videoUrl'] as String?,
      localVideoPath: json['localVideoPath'] as String?,
      curlCommand: json['curlCommand'] as String?,
      requestId: json['requestId'] as String?,
      remoteStatus: json['remoteStatus'] as String?,
      progress: json['progress'] as int?,
      isRunning: false,
      logs: (json['logs'] as List<dynamic>?)?.map((dynamic e) => e as String).toList(),
    );
  }
}

/// シーンの生成フェーズ
enum StoryScenePhase {
  idle,
  uploadingReference,
  submitting,
  waiting,
  downloading,
  completed,
  error,
}

enum StoryVideoProvider {
  sora,
  veo31I2v,
}

extension StoryVideoProviderX on StoryVideoProvider {
  String get storageValue {
    switch (this) {
      case StoryVideoProvider.sora:
        return 'sora';
      case StoryVideoProvider.veo31I2v:
        return 'veo31_i2v';
    }
  }

  static StoryVideoProvider fromStorage(String? value) {
    switch (value) {
      case 'veo31_i2v':
        return StoryVideoProvider.veo31I2v;
      case 'sora':
      default:
        return StoryVideoProvider.sora;
    }
  }
}
