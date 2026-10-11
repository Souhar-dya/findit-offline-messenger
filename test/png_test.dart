import 'dart:typed_data';

import 'package:findit/core/config/app_config.dart';
import 'package:findit/core/errors/app_exception.dart';
import 'package:findit/core/utils/bytes.dart';
import 'package:findit/messaging/png_validator.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/png.dart';

void main() {
  group('PngValidator', () {
    test('accepts a well-formed PNG and reports dimensions and hash', () async {
      final png = buildPng(
        width: 7,
        height: 5,
        idat: List<int>.generate(64, (i) => i),
      );
      final result = await PngValidator.validate(png);
      expect(result.width, 7);
      expect(result.height, 5);
      expect(result.byteLength, png.length);
      expect(result.contentHashHex, bytesToHex(await sha256(png)));
    });

    test('does not modify the input bytes', () async {
      final png = buildPng();
      final copy = Uint8List.fromList(png);
      await PngValidator.validate(png);
      expect(png, copy);
    });

    test('accepts images larger than 50 KB without rejecting them', () async {
      final png = buildPng(
        width: 200,
        height: 200,
        idat: List<int>.filled(100 * 1024, 0),
      );
      expect(png.length, greaterThan(50 * 1024));
      final result = await PngValidator.validate(png);
      expect(result.width, 200);
      expect(result.height, 200);
    });

    test('rejects a bad signature', () {
      final png = Uint8List.fromList(buildPng());
      png[1] = 0x00;
      expect(PngValidator.hasSignature(png), isFalse);
      expect(
        () => PngValidator.validate(png),
        throwsA(isA<ValidationException>()),
      );
    });

    test('rejects a truncated file', () {
      final png = buildPng();
      expect(
        () => PngValidator.validate(truncated(png, 20)),
        throwsA(isA<ValidationException>()),
      );
    });

    test('rejects a corrupted chunk CRC', () {
      final png = buildPng(width: 4, height: 4, idat: List<int>.filled(64, 1));
      // Flip a byte inside the IHDR payload so its CRC no longer matches.
      final corrupted = flipByte(png, 20);
      expect(
        () => PngValidator.validate(corrupted),
        throwsA(isA<ValidationException>()),
      );
    });

    test('rejects trailing data after IEND', () {
      final png = buildPng();
      expect(
        () => PngValidator.validate(withTrailingData(png)),
        throwsA(isA<ValidationException>()),
      );
    });

    test('rejects unsupported bit depth and colour combinations', () {
      final png = buildPng(bitDepth: 3, colorType: 6);
      expect(
        () => PngValidator.validate(png),
        throwsA(isA<ValidationException>()),
      );
    });

    test('rejects dimensions above the configured maximum', () {
      const config = AppConfig(
        maxImageDimension: 100,
        maxImagePixels: 1024 * 1024,
      );
      final png = buildPng(width: 101, height: 1);
      expect(
        () => PngValidator.validate(png, config: config),
        throwsA(isA<ValidationException>()),
      );
    });

    test('rejects a decompression-bomb pixel count', () {
      const config = AppConfig(maxImageDimension: 100000, maxImagePixels: 1000);
      final png = buildPng(width: 100, height: 100);
      expect(
        () => PngValidator.validate(png, config: config),
        throwsA(isA<ValidationException>()),
      );
    });

    test('rejects a file above the configured size limit', () {
      const config = AppConfig(maxImageBytes: 64);
      final png = buildPng(width: 2, height: 2);
      expect(
        () => PngValidator.validate(png, config: config),
        throwsA(isA<ValidationException>()),
      );
    });
  });
}
