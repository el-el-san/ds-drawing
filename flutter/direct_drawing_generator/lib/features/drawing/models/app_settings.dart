import 'dart:convert';

/// アプリ全体で利用するサーバー設定
class AppSettings {
  // ビルド時に --dart-define で注入される値
  static const String kEmbeddedUploadEndpoint = String.fromEnvironment(
    'UPLOAD_ENDPOINT',
    defaultValue: '',
  );
  static const String kEmbeddedExposeEndpoint = String.fromEnvironment(
    'UPLOAD_ENDPOINT',
    defaultValue: '',
  );
  static const String kEmbeddedTokenEndpoint = String.fromEnvironment(
    'UPLOAD_AUTH_ENDPOINT',
    defaultValue: '',
  );
  static const String kEmbeddedTurnstileVerifyUrl = String.fromEnvironment(
    'UPLOAD_TURNSTILE_URL',
    defaultValue: '',
  );

  static bool get hasEmbeddedUploadConfig => kEmbeddedUploadEndpoint.trim().isNotEmpty;
  static bool get hasEmbeddedTokenEndpoint => kEmbeddedTokenEndpoint.trim().isNotEmpty;
  static bool get hasEmbeddedTurnstileUrl => kEmbeddedTurnstileVerifyUrl.trim().isNotEmpty;

  AppSettings({
    required this.uploadEndpoint,
    required this.exposeEndpoint,
    required this.nanoBananaEndpoint,
    required this.seedreamEndpoint,
    required this.soraEndpoint,
    required this.veoEndpoint,
    required this.storyGenApiBase,
    required this.uploadAuthEndpoint,
    required this.uploadTurnstileUrl,
    this.uploadAuthorization,
    this.mcpAuthorization,
  });

  factory AppSettings.defaults() {
    return AppSettings(
      uploadEndpoint: kEmbeddedUploadEndpoint.trim(),
      exposeEndpoint: kEmbeddedExposeEndpoint.trim(),
      nanoBananaEndpoint: '',
      seedreamEndpoint: '',
      soraEndpoint: '',
      veoEndpoint: '',
      storyGenApiBase: '',
      uploadAuthEndpoint: kEmbeddedTokenEndpoint.trim(),
      uploadTurnstileUrl: kEmbeddedTurnstileVerifyUrl.trim(),
    );
  }

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    String extractAndTrim(String key) {
      final String? value = json[key] as String?;
      return value == null ? '' : value.trim();
    }

    final AppSettings defaults = AppSettings.defaults();
    final String embeddedUploadEndpoint = kEmbeddedUploadEndpoint.trim();
    final String embeddedExposeEndpoint = kEmbeddedExposeEndpoint.trim();
    final String embeddedTokenEndpoint = kEmbeddedTokenEndpoint.trim();
    final String embeddedTurnstileUrl = kEmbeddedTurnstileVerifyUrl.trim();

    return AppSettings(
      uploadEndpoint: embeddedUploadEndpoint.isNotEmpty
          ? embeddedUploadEndpoint
          : extractAndTrim('uploadEndpoint'),
      exposeEndpoint: embeddedExposeEndpoint.isNotEmpty
          ? embeddedExposeEndpoint
          : extractAndTrim('exposeEndpoint'),
      nanoBananaEndpoint: (json['nanoBananaEndpoint'] as String?)?.trim().isNotEmpty == true
          ? (json['nanoBananaEndpoint'] as String).trim()
          : defaults.nanoBananaEndpoint,
      seedreamEndpoint: (json['seedreamEndpoint'] as String?)?.trim().isNotEmpty == true
          ? (json['seedreamEndpoint'] as String).trim()
          : defaults.seedreamEndpoint,
      soraEndpoint: (json['soraEndpoint'] as String?)?.trim().isNotEmpty == true
          ? (json['soraEndpoint'] as String).trim()
          : defaults.soraEndpoint,
      veoEndpoint: (json['veoEndpoint'] as String?)?.trim().isNotEmpty == true
          ? (json['veoEndpoint'] as String).trim()
          : defaults.veoEndpoint,
      storyGenApiBase: (json['storyGenApiBase'] as String?)?.trim().isNotEmpty == true
          ? (json['storyGenApiBase'] as String).trim()
          : defaults.storyGenApiBase,
      uploadAuthEndpoint: embeddedTokenEndpoint.isNotEmpty
          ? embeddedTokenEndpoint
          : extractAndTrim('uploadAuthEndpoint'),
      uploadTurnstileUrl: embeddedTurnstileUrl.isNotEmpty
          ? embeddedTurnstileUrl
          : extractAndTrim('uploadTurnstileUrl'),
      uploadAuthorization: (json['uploadAuthorization'] as String?)?.trim().isNotEmpty == true
          ? (json['uploadAuthorization'] as String).trim()
          : null,
      mcpAuthorization: (json['mcpAuthorization'] as String?)?.trim().isNotEmpty == true
          ? (json['mcpAuthorization'] as String).trim()
          : null,
    );
  }

  factory AppSettings.fromJsonString(String data) {
    return AppSettings.fromJson(jsonDecode(data) as Map<String, dynamic>);
  }

  final String uploadEndpoint;
  final String exposeEndpoint;
  final String nanoBananaEndpoint;
  final String seedreamEndpoint;
  final String soraEndpoint;
  final String veoEndpoint;
  final String storyGenApiBase;
  final String uploadAuthEndpoint;
  final String uploadTurnstileUrl;
  final String? uploadAuthorization;
  final String? mcpAuthorization;

  AppSettings copyWith({
    String? uploadEndpoint,
    String? exposeEndpoint,
    String? nanoBananaEndpoint,
    String? seedreamEndpoint,
    String? soraEndpoint,
    String? veoEndpoint,
    String? storyGenApiBase,
    String? uploadAuthEndpoint,
    String? uploadTurnstileUrl,
    String? uploadAuthorization,
    String? mcpAuthorization,
  }) {
    return AppSettings(
      uploadEndpoint: uploadEndpoint ?? this.uploadEndpoint,
      exposeEndpoint: exposeEndpoint ?? this.exposeEndpoint,
      nanoBananaEndpoint: nanoBananaEndpoint ?? this.nanoBananaEndpoint,
      seedreamEndpoint: seedreamEndpoint ?? this.seedreamEndpoint,
      soraEndpoint: soraEndpoint ?? this.soraEndpoint,
      veoEndpoint: veoEndpoint ?? this.veoEndpoint,
      storyGenApiBase: storyGenApiBase ?? this.storyGenApiBase,
      uploadAuthEndpoint: uploadAuthEndpoint ?? this.uploadAuthEndpoint,
      uploadTurnstileUrl: uploadTurnstileUrl ?? this.uploadTurnstileUrl,
      uploadAuthorization: uploadAuthorization ?? this.uploadAuthorization,
      mcpAuthorization: mcpAuthorization ?? this.mcpAuthorization,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'uploadEndpoint': uploadEndpoint,
      'exposeEndpoint': exposeEndpoint,
      'nanoBananaEndpoint': nanoBananaEndpoint,
      'seedreamEndpoint': seedreamEndpoint,
      'soraEndpoint': soraEndpoint,
      'veoEndpoint': veoEndpoint,
      'storyGenApiBase': storyGenApiBase,
      'uploadAuthEndpoint': uploadAuthEndpoint,
      'uploadTurnstileUrl': uploadTurnstileUrl,
      if (uploadAuthorization != null) 'uploadAuthorization': uploadAuthorization,
      if (mcpAuthorization != null) 'mcpAuthorization': mcpAuthorization,
    };
  }

  String toJsonString() => jsonEncode(toJson());
}
