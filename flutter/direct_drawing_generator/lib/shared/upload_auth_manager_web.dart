import 'package:flutter/material.dart';

class UploadAuthToken {
  const UploadAuthToken({
    required this.token,
    required this.expiresIn,
    required this.expiresAt,
    required this.deviceId,
    this.userId,
  });

  final String token;
  final int expiresIn;
  final DateTime expiresAt;
  final String deviceId;
  final String? userId;

  bool get isExpired => true;
}

class UploadAuthException implements Exception {
  UploadAuthException(this.message);
  final String message;

  @override
  String toString() => 'UploadAuthException: $message';
}

class UploadAuthManager {
  void invalidate() {}

  Future<UploadAuthToken> ensureJwt({
    required BuildContext context,
    required String vendingEndpoint,
    String? turnstileUrl,
    bool forceRefresh = false,
  }) async {
    throw UploadAuthException('Upload vending is not supported on the web build.');
  }
}
