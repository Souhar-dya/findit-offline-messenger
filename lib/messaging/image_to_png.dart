import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../core/config/app_config.dart';
import '../core/errors/app_exception.dart';
import 'png_validator.dart';

/// Normalizes picked images to the PNG format used by the message protocol.
class ImageToPng {
  ImageToPng._();

  static Future<Uint8List> convert(
    Uint8List bytes, {
    AppConfig config = AppConfig.production,
  }) async {
    if (PngValidator.hasSignature(bytes)) return bytes;
    if (bytes.isEmpty || bytes.length > config.maxImageBytes) {
      throw const ValidationException('Image is empty or exceeds the size limit');
    }

    ui.Codec? codec;
    ui.Image? image;
    try {
      final pixelLimitSide = math.sqrt(config.maxImagePixels).floor();
      final maxSide = config.maxImageDimension < pixelLimitSide
          ? config.maxImageDimension
          : pixelLimitSide;
      codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: maxSide,
        targetHeight: maxSide,
        allowUpscaling: false,
      );
      final frame = await codec.getNextFrame();
      image = frame.image;

      final width = image.width;
      final height = image.height;
      if (width <= 0 || height <= 0 ||
          width > config.maxImageDimension ||
          height > config.maxImageDimension ||
          width * height > config.maxImagePixels) {
        throw const ValidationException('Image dimensions exceed the supported limit');
      }

      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null || data.lengthInBytes > config.maxImageBytes) {
        throw const ValidationException('Converted PNG exceeds the size limit');
      }
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } on ValidationException {
      rethrow;
    } catch (_) {
      throw const ValidationException(
        'This image format could not be opened. Choose a JPG, PNG, or WebP image.',
      );
    } finally {
      image?.dispose();
      codec?.dispose();
    }
  }

  static String pngFilename(String filename) {
    final stem = filename.replaceFirst(RegExp(r'\.[^.]*$'), '');
    return '${stem.isEmpty ? 'image' : stem}.png';
  }
}
