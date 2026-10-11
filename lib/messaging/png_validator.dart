import 'dart:typed_data';

import '../core/config/app_config.dart';
import '../core/errors/app_exception.dart';
import '../core/utils/bytes.dart';

/// Result of validating a PNG attachment.
class PngValidationResult {
  const PngValidationResult({
    required this.width,
    required this.height,
    required this.byteLength,
    required this.contentHashHex,
    required this.bitDepth,
    required this.colorType,
  });

  final int width;
  final int height;
  final int byteLength;

  /// SHA-256 of the complete PNG bytes. Kept deliberately separate from the
  /// message id.
  final String contentHashHex;
  final int bitDepth;
  final int colorType;
}

/// Validates that a byte blob is structurally a valid PNG and is safe to store
/// and forward.
///
/// This does not re-encode, resize, convert or otherwise alter the image: the
/// original bytes are preserved losslessly. It only verifies structure, chunk
/// CRCs, dimensions, and resource bounds.
class PngValidator {
  PngValidator._();

  static const List<int> signature = [
    0x89,
    0x50,
    0x4E,
    0x47,
    0x0D,
    0x0A,
    0x1A,
    0x0A,
  ];

  /// True if [bytes] begins with the PNG signature.
  static bool hasSignature(List<int> bytes) {
    if (bytes.length < signature.length) return false;
    for (var i = 0; i < signature.length; i++) {
      if (bytes[i] != signature[i]) return false;
    }
    return true;
  }

  /// Fully validates [bytes]. Throws [ValidationException] on any problem.
  static Future<PngValidationResult> validate(
    Uint8List bytes, {
    AppConfig config = AppConfig.production,
  }) async {
    if (!hasSignature(bytes)) {
      throw const ValidationException('Not a PNG file (bad signature)');
    }
    if (bytes.length > config.maxImageBytes) {
      throw ValidationException(
        'PNG exceeds the maximum allowed size of ${config.maxImageBytes} bytes',
      );
    }
    if (bytes.length < signature.length + 12 + 13 + 12) {
      throw const ValidationException('PNG file is truncated');
    }

    var offset = signature.length;
    int? width;
    int? height;
    int? bitDepth;
    int? colorType;
    var sawIhdr = false;
    var sawIend = false;

    while (offset < bytes.length) {
      if (offset + 8 > bytes.length) {
        throw const ValidationException('PNG chunk header is truncated');
      }
      final length = _readUint32(bytes, offset);
      final type = String.fromCharCodes(bytes.sublist(offset + 4, offset + 8));
      final dataStart = offset + 8;
      final dataEnd = dataStart + length;
      if (length < 0 || dataEnd + 4 > bytes.length) {
        throw const ValidationException('PNG chunk length is out of range');
      }
      final crc = _readUint32(bytes, dataEnd);
      final computed = _crc32(bytes, offset + 4, dataEnd);
      if (crc != computed) {
        throw ValidationException('PNG chunk "$type" failed its CRC check');
      }

      if (!sawIhdr && type != 'IHDR') {
        throw const ValidationException('PNG must begin with an IHDR chunk');
      }

      switch (type) {
        case 'IHDR':
          if (sawIhdr) {
            throw const ValidationException(
              'PNG contains multiple IHDR chunks',
            );
          }
          if (length != 13) {
            throw const ValidationException(
              'PNG IHDR chunk has an invalid length',
            );
          }
          width = _readUint32(bytes, dataStart);
          height = _readUint32(bytes, dataStart + 4);
          bitDepth = bytes[dataStart + 8];
          colorType = bytes[dataStart + 9];
          final compression = bytes[dataStart + 10];
          final filter = bytes[dataStart + 11];
          final interlace = bytes[dataStart + 12];
          if (compression != 0) {
            throw const ValidationException(
              'Unsupported PNG compression method',
            );
          }
          if (filter != 0) {
            throw const ValidationException('Unsupported PNG filter method');
          }
          if (interlace != 0 && interlace != 1) {
            throw const ValidationException('Unsupported PNG interlace method');
          }
          _validateBitDepthAndColor(bitDepth, colorType);
          sawIhdr = true;
          break;
        case 'IEND':
          sawIend = true;
          break;
      }

      offset = dataEnd + 4;
      if (sawIend) break;
    }

    if (!sawIhdr || width == null || height == null) {
      throw const ValidationException('PNG is missing a valid IHDR chunk');
    }
    if (!sawIend) {
      throw const ValidationException('PNG is missing its IEND chunk');
    }
    if (offset != bytes.length) {
      throw const ValidationException('PNG has trailing data after IEND');
    }
    if (width <= 0 || height <= 0) {
      throw const ValidationException('PNG has invalid dimensions');
    }
    if (width > config.maxImageDimension || height > config.maxImageDimension) {
      throw ValidationException(
        'PNG dimensions exceed ${config.maxImageDimension}px',
      );
    }
    if (width * height > config.maxImagePixels) {
      throw ValidationException(
        'PNG exceeds the maximum pixel count of ${config.maxImagePixels}',
      );
    }

    final hash = await sha256(bytes);
    return PngValidationResult(
      width: width,
      height: height,
      byteLength: bytes.length,
      contentHashHex: bytesToHex(hash),
      bitDepth: bitDepth!,
      colorType: colorType!,
    );
  }

  static void _validateBitDepthAndColor(int bitDepth, int colorType) {
    const allowed = <int, Set<int>>{
      0: {1, 2, 4, 8, 16}, // grayscale
      2: {8, 16}, // truecolor
      3: {1, 2, 4, 8}, // indexed
      4: {8, 16}, // grayscale + alpha
      6: {8, 16}, // truecolor + alpha
    };
    final depths = allowed[colorType];
    if (depths == null || !depths.contains(bitDepth)) {
      throw ValidationException(
        'Unsupported PNG bit depth $bitDepth for color type $colorType',
      );
    }
  }

  static int _readUint32(List<int> bytes, int offset) =>
      (bytes[offset] << 24) |
      (bytes[offset + 1] << 16) |
      (bytes[offset + 2] << 8) |
      bytes[offset + 3];

  static final List<int> _crcTable = _buildCrcTable();

  static List<int> _buildCrcTable() {
    final table = List<int>.filled(256, 0);
    for (var n = 0; n < 256; n++) {
      var c = n;
      for (var k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
      }
      table[n] = c;
    }
    return table;
  }

  /// CRC-32 over bytes [start, end).
  static int _crc32(List<int> bytes, int start, int end) {
    var crc = 0xFFFFFFFF;
    for (var i = start; i < end; i++) {
      crc = _crcTable[(crc ^ bytes[i]) & 0xFF] ^ (crc >> 8);
    }
    return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }
}
