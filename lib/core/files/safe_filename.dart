import 'package:path/path.dart' as p;

const int orexSafeFilenameMaxLength = 120;

/// Returns a single filesystem-safe filename.
///
/// Directory components are always discarded, control characters and the
/// Windows-reserved punctuation are replaced, and reserved device names are
/// prefixed so the same value is safe on every native platform.
String orexSafeFilename(
  String filename, {
  String fallback = 'download.bin',
  int maxLength = orexSafeFilenameMaxLength,
}) {
  if (maxLength < 1) {
    throw ArgumentError.value(maxLength, 'maxLength', 'Must be positive');
  }

  var safeFallback = _cleanFilename(fallback);
  if (_isEmptyFilename(safeFallback)) safeFallback = 'download.bin';
  safeFallback = _fitSafeFilename(safeFallback, maxLength);

  var name = _cleanFilename(filename);
  if (_isEmptyFilename(name)) name = safeFallback;
  name = _fitSafeFilename(name, maxLength);

  return _isEmptyFilename(name) ? safeFallback : name;
}

String _cleanFilename(String value) => value
    .trim()
    .replaceAll('\\', '/')
    .split('/')
    .last
    .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
    .replaceAll(RegExp(r'\s+'), ' ')
    .replaceAll(RegExp(r'[. ]+$'), '')
    .trim();

bool _isEmptyFilename(String value) =>
    value.isEmpty || value == '.' || value == '..';

String _fitSafeFilename(String value, int maxLength) {
  var result = _protectWindowsReservedName(value);
  result = _truncateFilename(result, maxLength);
  if (!_windowsReservedNames.contains(_windowsBasename(result))) {
    return result;
  }

  final prefixed = '_$result';
  if (prefixed.length <= maxLength) return prefixed;
  return _truncateFilename('file', maxLength);
}

String _protectWindowsReservedName(String value) {
  final basename = _windowsBasename(value);
  return _windowsReservedNames.contains(basename) ? '_$value' : value;
}

String _windowsBasename(String value) => p
    .basenameWithoutExtension(value)
    .replaceAll(RegExp(r'[. ]+$'), '')
    .toUpperCase();

String _truncateFilename(String value, int maxLength) {
  if (value.length <= maxLength) return value;

  var extension = p.extension(value);
  if (extension.length >= maxLength) extension = '';

  var base = p.basenameWithoutExtension(value);
  if (base.isEmpty) base = 'file';
  final maxBaseLength = maxLength - extension.length;
  if (base.length > maxBaseLength) {
    base = base.substring(0, maxBaseLength);
  }

  final result = '$base$extension'.replaceAll(RegExp(r'[. ]+$'), '');
  return result.isEmpty ? 'f'.substring(0, maxLength) : result;
}

const Set<String> _windowsReservedNames = <String>{
  'CON',
  'PRN',
  'AUX',
  'NUL',
  'COM1',
  'COM2',
  'COM3',
  'COM4',
  'COM5',
  'COM6',
  'COM7',
  'COM8',
  'COM9',
  'LPT1',
  'LPT2',
  'LPT3',
  'LPT4',
  'LPT5',
  'LPT6',
  'LPT7',
  'LPT8',
  'LPT9',
};
