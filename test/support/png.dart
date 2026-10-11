import 'dart:typed_data';

/// The 8-byte PNG file signature.
const List<int> kPngSignature = [
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
];

List<int> _buildCrcTable() {
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

final List<int> _crcTable = _buildCrcTable();

/// Standard CRC-32 (IEEE) over [bytes].
int crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final byte in bytes) {
    crc = _crcTable[(crc ^ byte) & 0xFF] ^ (crc >> 8);
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

void _writeChunk(List<int> out, String type, List<int> data) {
  final length = data.length;
  out.addAll([
    (length >> 24) & 0xFF,
    (length >> 16) & 0xFF,
    (length >> 8) & 0xFF,
    length & 0xFF,
  ]);
  final typeBytes = type.codeUnits;
  out.addAll(typeBytes);
  out.addAll(data);
  final crc = crc32([...typeBytes, ...data]);
  out.addAll([
    (crc >> 24) & 0xFF,
    (crc >> 16) & 0xFF,
    (crc >> 8) & 0xFF,
    crc & 0xFF,
  ]);
}

/// Builds a structurally valid PNG with correct chunk CRCs.
///
/// The IDAT payload is intentionally arbitrary: the validator checks structure
/// and CRCs, not the deflate stream, which lets tests exercise boundaries
/// (size, dimensions, chunk corruption) without shipping binary fixtures.
Uint8List buildPng({
  int width = 2,
  int height = 2,
  int bitDepth = 8,
  int colorType = 6,
  int interlace = 0,
  List<int>? idat,
}) {
  final out = <int>[...kPngSignature];
  final ihdr = <int>[
    (width >> 24) & 0xFF,
    (width >> 16) & 0xFF,
    (width >> 8) & 0xFF,
    width & 0xFF,
    (height >> 24) & 0xFF,
    (height >> 16) & 0xFF,
    (height >> 8) & 0xFF,
    height & 0xFF,
    bitDepth,
    colorType,
    0, // compression
    0, // filter
    interlace,
  ];
  _writeChunk(out, 'IHDR', ihdr);
  _writeChunk(out, 'IDAT', idat ?? List<int>.filled(width * height * 4, 0));
  _writeChunk(out, 'IEND', const []);
  return Uint8List.fromList(out);
}

/// Returns a copy of [png] with the byte at [index] incremented.
Uint8List flipByte(Uint8List png, int index) {
  final copy = Uint8List.fromList(png);
  copy[index] = (copy[index] + 1) & 0xFF;
  return copy;
}

/// Returns a copy of [png] with [count] extra bytes appended after IEND.
Uint8List withTrailingData(Uint8List png, [int count = 4]) {
  return Uint8List.fromList([...png, ...List<int>.filled(count, 0x00)]);
}

/// Returns a copy of [png] truncated to [length] bytes.
Uint8List truncated(Uint8List png, int length) =>
    Uint8List.sublistView(png, 0, length);
