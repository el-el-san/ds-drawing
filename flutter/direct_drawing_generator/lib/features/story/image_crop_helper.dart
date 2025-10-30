import 'dart:typed_data';
import 'package:image/image.dart' as img;

/// 画像クロップヘルパークラス
class ImageCropHelper {
  /// 指定されたアスペクト比（解像度文字列）に基づいて画像を中央クロップ
  ///
  /// [imageBytes]: 元画像のバイトデータ
  /// [targetSize]: ターゲット解像度（例: "1280x720", "1920x1080"）
  ///
  /// 返り値: クロップされた画像のPNGバイトデータ
  static Future<Uint8List?> cropToAspectRatio(
    Uint8List imageBytes,
    String targetSize,
  ) async {
    try {
      // 画像をデコード
      final img.Image? image = img.decodeImage(imageBytes);
      if (image == null) {
        return null;
      }

      // ターゲットアスペクト比を解析
      final List<String> parts = targetSize.split('x');
      if (parts.length != 2) {
        return null;
      }

      final int targetWidth = int.tryParse(parts[0]) ?? 1280;
      final int targetHeight = int.tryParse(parts[1]) ?? 720;
      final double targetAspectRatio = targetWidth / targetHeight;

      final int srcWidth = image.width;
      final int srcHeight = image.height;
      final double srcAspectRatio = srcWidth / srcHeight;

      int cropWidth;
      int cropHeight;
      int cropX;
      int cropY;

      // アスペクト比に基づいてクロップ領域を計算
      if (srcAspectRatio > targetAspectRatio) {
        // 元画像が横長 → 高さを基準に幅をクロップ
        cropHeight = srcHeight;
        cropWidth = (srcHeight * targetAspectRatio).round();
        cropX = ((srcWidth - cropWidth) / 2).round();
        cropY = 0;
      } else {
        // 元画像が縦長 → 幅を基準に高さをクロップ
        cropWidth = srcWidth;
        cropHeight = (srcWidth / targetAspectRatio).round();
        cropX = 0;
        cropY = ((srcHeight - cropHeight) / 2).round();
      }

      // クロップを実行
      final img.Image cropped = img.copyCrop(
        image,
        x: cropX,
        y: cropY,
        width: cropWidth,
        height: cropHeight,
      );

      // ターゲット解像度にリサイズ
      final img.Image resized = img.copyResize(
        cropped,
        width: targetWidth,
        height: targetHeight,
      );

      // PNGとしてエンコード
      final List<int> pngBytes = img.encodePng(resized);
      return Uint8List.fromList(pngBytes);
    } catch (error) {
      // エラー時はnullを返す
      return null;
    }
  }

  /// 解像度文字列をパース
  static ({int width, int height})? parseSize(String size) {
    final List<String> parts = size.split('x');
    if (parts.length != 2) {
      return null;
    }

    final int? width = int.tryParse(parts[0]);
    final int? height = int.tryParse(parts[1]);

    if (width == null || height == null) {
      return null;
    }

    return (width: width, height: height);
  }

  /// アスペクト比を計算
  static double getAspectRatio(String size) {
    final parsed = parseSize(size);
    if (parsed == null) {
      return 16 / 9; // デフォルト
    }
    return parsed.width / parsed.height;
  }
}
