import 'dart:collection';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Resolves file identities without changing persisted paths or source hashes.
abstract final class NoteFilePaths {
  /// Builds a platform-aware set for already resolved identities.
  static Set<String> identitySet([Iterable<String> values = const []]) =>
      HashSet<String>(equals: p.equals, hashCode: p.hash)..addAll(values);

  /// Resolves an existing ordinary directory, including ancestor aliases.
  static Future<String> directory(Directory directory) async {
    _absolute(directory.path, 'directory');
    try {
      if (await FileSystemEntity.type(directory.path, followLinks: false) !=
          FileSystemEntityType.directory) {
        throw _failure('directory/type', directory.path);
      }
      return p.normalize(await directory.resolveSymbolicLinks());
    } on FileSystemException {
      throw _failure('directory/resolve', directory.path);
    }
  }

  /// Resolves an ordinary file or the identity of an explicitly allowed absence.
  static Future<String> file(
    String rawPath, {
    bool allowMissing = false,
  }) async {
    _absolute(rawPath, 'file');
    try {
      // The final component must never be followed when deciding its type.
      final FileSystemEntityType type = await FileSystemEntity.type(
        rawPath,
        followLinks: false,
      );
      if (type == FileSystemEntityType.file) {
        return p.normalize(await File(rawPath).resolveSymbolicLinks());
      }
      if (allowMissing && type == FileSystemEntityType.notFound) {
        return p.join(
          await prospectiveDirectory(Directory(p.dirname(rawPath))),
          p.basename(rawPath),
        );
      }
      throw _failure('file/type', rawPath);
    } on FileSystemException {
      throw _failure('file/resolve', rawPath);
    }
  }

  /// Validates ownership using physical identities rather than stored spelling.
  static Future<String> ownedFile(
    String rawPath,
    Iterable<Directory> roots, {
    bool directChild = false,
    bool allowMissing = false,
  }) async {
    // The candidate is validated before any authorization decision.
    final String candidate = await file(rawPath, allowMissing: allowMissing);
    // Every supplied root is resolved before matching the candidate.
    final List<String> directories = [];
    // Each root is an explicitly authorized directory.
    for (final Directory root in roots) {
      // Optional source roots may not have been created on this device yet.
      final FileSystemEntityType type = await FileSystemEntity.type(
        root.path,
        followLinks: false,
      );
      directories.add(
        type == FileSystemEntityType.notFound
            ? await prospectiveDirectory(root)
            : await directory(root),
      );
    }
    if (directories.any(
      (root) => directChild
          ? p.equals(root, p.dirname(candidate))
          : p.isWithin(root, candidate),
    )) {
      return candidate;
    }
    throw _failure('owned-file/boundary', rawPath);
  }

  /// Resolves all protection references; invalid references fail closed.
  static Future<Set<String>> identities(Iterable<String> paths) async {
    // Missing files still retain their identity for idempotent deletion retries.
    final Set<String> result = identitySet();
    // Stored paths remain unchanged in the caller's database and manifests.
    for (final String path in paths) {
      result.add(await file(path, allowMissing: true));
    }
    return result;
  }

  /// Resolves a future directory through its nearest existing ancestor.
  static Future<String> prospectiveDirectory(Directory target) async {
    _absolute(target.path, 'prospective-directory');
    // Missing path components are appended only after resolving a real ancestor.
    final List<String> suffix = [];
    // Walk upward without creating directories, then resolve the existing ancestor.
    String current = p.normalize(target.path);
    try {
      while (true) {
        // Existing directory links are resolved before a caller checks boundaries.
        final FileSystemEntityType type = await FileSystemEntity.type(
          current,
          followLinks: false,
        );
        if (type == FileSystemEntityType.directory ||
            (type == FileSystemEntityType.link &&
                await Directory(current).exists())) {
          return p.normalize(
            p.joinAll([
              await Directory(current).resolveSymbolicLinks(),
              ...suffix.reversed,
            ]),
          );
        }
        if (type != FileSystemEntityType.notFound) {
          throw _failure('prospective-directory/type', target.path);
        }
        // A filesystem root cannot be missing for a valid prospective path.
        final String parent = p.dirname(current);
        if (p.equals(parent, current)) {
          throw _failure('prospective-directory/ancestor', target.path);
        }
        suffix.add(p.basename(current));
        current = parent;
      }
    } on FileSystemException {
      throw _failure('prospective-directory/resolve', target.path);
    }
  }

  /// Rejects ambiguous input before normalization can erase traversal segments.
  static void _absolute(String rawPath, String phase) {
    if (!p.isAbsolute(rawPath) ||
        rawPath.contains('\u0000') ||
        p.split(rawPath).contains('..')) {
      throw _failure('$phase/input', rawPath);
    }
  }

  /// Reports the validation phase and leaf name without disclosing parent paths.
  static FileSystemException _failure(String phase, String rawPath) =>
      FileSystemException(
        'Note path validation failed [$phase]: ${p.basename(rawPath)}',
      );
}
