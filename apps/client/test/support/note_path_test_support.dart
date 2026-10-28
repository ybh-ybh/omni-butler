import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

/// Returns an existing Windows directory's distinct 8.3 alias or fails.
Future<String> shortPathOf(Directory directory) async {
  if (!Platform.isWindows) {
    throw UnsupportedError('Windows short paths are only available on Windows');
  }
  if (!await directory.exists()) {
    throw FileSystemException(
      'Short-path directory does not exist',
      directory.path,
    );
  }
  // The Windows API returns the required UTF-16 buffer size when called first.
  final getShortPath = DynamicLibrary.open('kernel32.dll')
      .lookupFunction<
        Uint32 Function(Pointer<Utf16>, Pointer<Utf16>, Uint32),
        int Function(Pointer<Utf16>, Pointer<Utf16>, int)
      >('GetShortPathNameW');
  // Resolve an already-short TEMP path before asking Windows for its alias.
  final canonicalPath = await directory.resolveSymbolicLinks();
  // The canonical input remains allocated until both native calls have finished.
  final input = canonicalPath.toNativeUtf16();
  try {
    // A zero result indicates a native failure rather than an absent alias.
    final length = getShortPath(input, nullptr, 0);
    if (length == 0) {
      throw FileSystemException('GetShortPathNameW failed', directory.path);
    }
    // The first call includes space for the terminating UTF-16 character.
    final output = calloc<Uint16>(length).cast<Utf16>();
    try {
      // The second call reports the characters written without the terminator.
      final written = getShortPath(input, output, length);
      if (written == 0 || written >= length) {
        throw FileSystemException('GetShortPathNameW failed', directory.path);
      }
      // Equal paths do not exercise the alias regression.
      final shortPath = output.toDartString();
      if (p.equals(shortPath, canonicalPath)) {
        throw FileSystemException(
          'No distinct 8.3 directory alias',
          directory.path,
        );
      }
      return shortPath;
    } finally {
      calloc.free(output);
    }
  } finally {
    calloc.free(input);
  }
}
