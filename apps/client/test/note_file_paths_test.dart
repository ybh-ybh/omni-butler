import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/features/notes/audio/note_file_paths.dart';
import 'package:path/path.dart' as p;

import 'support/note_path_test_support.dart';

/// Exercises physical identities and ownership boundaries in an isolated tree.
void main() {
  // The test owns this temporary directory and everything created inside it.
  late Directory root;
  // The authorized recording directory is separate from its neighbor.
  late Directory audio;
  // The neighbor intentionally shares an authorization-root prefix.
  late Directory neighbor;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('note-path-regression-long-');
    audio = await Directory(p.join(root.path, 'audio')).create();
    neighbor = await Directory(p.join(root.path, 'audio-neighbor')).create();
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('ordinary and nested files obey direct and recursive ownership', () async {
    // The ordinary file is a direct child of the authorized directory.
    final File direct = await File(p.join(audio.path, 'direct.wav'))
        .writeAsString('a');
    // The nested file is authorized only for recursive ownership.
    final Directory nested = await Directory(p.join(audio.path, 'nested'))
        .create();
    // The nested fixture is a regular file.
    final File child = await File(p.join(nested.path, 'child.wav'))
        .writeAsString('b');
    // The neighboring file shares a textual prefix but is not inside the root.
    final File outside = await File(p.join(neighbor.path, 'outside.wav'))
        .writeAsString('c');
    // Physical identity is shared by the general and authorized resolvers.
    final String identity = await NoteFilePaths.file(direct.path);
    expect(
      p.equals(
        identity,
        await NoteFilePaths.ownedFile(direct.path, [audio], directChild: true),
      ),
      isTrue,
    );
    // An optional source root may be absent without invalidating another root.
    final Directory missingRoot = Directory(
      p.join(root.path, 'optional-source'),
    );
    expect(
      p.equals(
        identity,
        await NoteFilePaths.ownedFile(direct.path, [audio, missingRoot]),
      ),
      isTrue,
    );
    expect(await missingRoot.exists(), isFalse);
    expect(
      p.equals(
        await NoteFilePaths.file(child.path),
        await NoteFilePaths.ownedFile(child.path, [audio]),
      ),
      isTrue,
    );
    await expectLater(
      NoteFilePaths.ownedFile(child.path, [audio], directChild: true),
      throwsA(isA<FileSystemException>()),
    );
    await expectLater(
      NoteFilePaths.ownedFile(outside.path, [audio]),
      throwsA(isA<FileSystemException>()),
    );
    expect(await outside.readAsString(), 'c');
  });

  test('relative and traversal paths fail before normalization', () async {
    // Traversal is rejected even when normalization would return to the root.
    final String traversal = p.join(audio.path, '..', 'audio', 'voice.wav');
    await expectLater(
      NoteFilePaths.file(p.join('audio', 'voice.wav'), allowMissing: true),
      throwsA(isA<FileSystemException>()),
    );
    await expectLater(
      NoteFilePaths.file(traversal, allowMissing: true),
      throwsA(isA<FileSystemException>()),
    );
    await expectLater(
      NoteFilePaths.directory(Directory(p.join('audio'))),
      throwsA(isA<FileSystemException>()),
    );
    await expectLater(
      NoteFilePaths.prospectiveDirectory(
        Directory(p.join(audio.path, '..', 'audio')),
      ),
      throwsA(isA<FileSystemException>()),
    );
  });

  test(
    'missing files require opt-in and retain prospective identity',
    () async {
      // The missing child remains absent during all identity checks.
      final String missing = p.join(audio.path, 'missing.wav');
      await expectLater(
        NoteFilePaths.file(missing),
        throwsA(isA<FileSystemException>()),
      );
      // A missing identity is derived from its resolved existing parent.
      final String identity = await NoteFilePaths.file(
        missing,
        allowMissing: true,
      );
      expect(
        p.equals(
          identity,
          p.join(await NoteFilePaths.directory(audio), 'missing.wav'),
        ),
        isTrue,
      );
      expect(
        p.equals(
          identity,
          await NoteFilePaths.ownedFile(
            missing,
            [audio],
            directChild: true,
            allowMissing: true,
          ),
        ),
        isTrue,
      );
      expect(await File(missing).exists(), isFalse);
    },
  );

  test('prospective directory resolves the nearest existing ancestor without creation', () async {
    // Two missing descendants exercise the full upward walk.
    final Directory future = Directory(p.join(audio.path, 'future', 'backups'));
    // The expected identity extends the physically resolved existing ancestor.
    final String expected = p.join(
      await NoteFilePaths.directory(audio),
      'future',
      'backups',
    );
    expect(
      p.equals(await NoteFilePaths.prospectiveDirectory(future), expected),
      isTrue,
    );
    expect(await Directory(p.join(audio.path, 'future')).exists(), isFalse);
    // A regular file cannot act as a directory ancestor.
    final File blocker = await File(p.join(audio.path, 'blocker'))
        .writeAsString('x');
    await expectLater(
      NoteFilePaths.prospectiveDirectory(
        Directory(p.join(blocker.path, 'child')),
      ),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('real Windows 8.3 aliases share file and set identities', () async {
    if (!Platform.isWindows) return;
    // A short TEMP can make the original fixture path an alias already.
    final String longRoot = await root.resolveSymbolicLinks();
    // The helper fails rather than substituting a guessed or identical path.
    final String shortRoot = await shortPathOf(root);
    expect(p.equals(longRoot, shortRoot), isFalse);
    // The fixture is addressed through both spellings of the same parent.
    final File original = await File(p.join(longRoot, 'audio', 'voice.wav'))
        .writeAsString('voice');
    // The alias uses the native short root and the same descendants.
    final String alias = p.join(shortRoot, 'audio', 'voice.wav');
    // Physical identity must be identical across long and short spellings.
    final String longIdentity = await NoteFilePaths.file(original.path);
    // The authorized root may use a different spelling than the file.
    final String shortIdentity = await NoteFilePaths.ownedFile(alias, [
      audio,
    ], directChild: true);
    expect(p.equals(longIdentity, shortIdentity), isTrue);
    expect(
      NoteFilePaths.identitySet([longIdentity]).contains(shortIdentity),
      isTrue,
    );
    expect((await NoteFilePaths.identities([original.path, alias])).length, 1);
    // Missing leaf identity also resolves through the existing alias parent.
    final String missingLong = await NoteFilePaths.file(
      p.join(longRoot, 'audio', 'absent.wav'),
      allowMissing: true,
    );
    final String missingShort = await NoteFilePaths.file(
      p.join(shortRoot, 'audio', 'absent.wav'),
      allowMissing: true,
    );
    expect(p.equals(missingLong, missingShort), isTrue);
  });

  test('directory links resolve prospective paths while ownership rejects escapes', () async {
    // The outside file must remain unchanged after every rejected path.
    final File outside = await File(p.join(neighbor.path, 'outside.wav'))
        .writeAsString('safe');
    // A directory link inside the authorized root points to the neighbor.
    final Link linkedDirectory = Link(p.join(audio.path, 'linked'));
    if (Platform.isWindows) {
      // Environment variables pass paths without embedding them in shell code.
      final ProcessResult result = await Process.run(
        'powershell.exe',
        [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          r'New-Item -ItemType Junction -Path $env:OMNI_TEST_LINK -Target $env:OMNI_TEST_TARGET -ErrorAction Stop | Out-Null',
        ],
        environment: {
          'OMNI_TEST_LINK': linkedDirectory.path,
          'OMNI_TEST_TARGET': neighbor.path,
        },
      );
      if (result.exitCode != 0) {
        throw StateError('Junction creation failed: ${result.stderr}');
      }
    } else {
      await linkedDirectory.create(neighbor.path);
    }
    try {
      await expectLater(
        NoteFilePaths.directory(Directory(linkedDirectory.path)),
        throwsA(isA<FileSystemException>()),
      );
      // A prospective directory resolves a link to its physical target.
      final String neighborIdentity = await NoteFilePaths.directory(neighbor);
      expect(
        p.equals(
          await NoteFilePaths.prospectiveDirectory(
            Directory(linkedDirectory.path),
          ),
          neighborIdentity,
        ),
        isTrue,
      );
      // Missing descendants must remain absent after resolution through the link.
      final Directory prospective = Directory(
        p.join(linkedDirectory.path, 'future', 'backup'),
      );
      expect(
        p.equals(
          await NoteFilePaths.prospectiveDirectory(prospective),
          p.join(neighborIdentity, 'future', 'backup'),
        ),
        isTrue,
      );
      expect(
        await Directory(p.join(neighbor.path, 'future')).exists(),
        isFalse,
      );
      // Missing file identities use the same physical parent without creating it.
      expect(
        p.equals(
          await NoteFilePaths.file(
            p.join(prospective.path, 'absent.wav'),
            allowMissing: true,
          ),
          p.join(neighborIdentity, 'future', 'backup', 'absent.wav'),
        ),
        isTrue,
      );
      expect(
        await Directory(p.join(neighbor.path, 'future')).exists(),
        isFalse,
      );
      await expectLater(
        NoteFilePaths.ownedFile(p.join(linkedDirectory.path, 'outside.wav'), [
          audio,
        ]),
        throwsA(isA<FileSystemException>()),
      );
      if (!Platform.isWindows) {
        // A final file symlink is never treated as an ordinary recording.
        final Link linkedFile = await Link(p.join(audio.path, 'linked.wav'))
            .create(outside.path);
        await expectLater(
          NoteFilePaths.file(linkedFile.path),
          throwsA(isA<FileSystemException>()),
        );
        await expectLater(
          NoteFilePaths.file(linkedFile.path, allowMissing: true),
          throwsA(isA<FileSystemException>()),
        );
        await linkedFile.delete();
      }
      expect(await outside.readAsString(), 'safe');
    } finally {
      await linkedDirectory.delete();
    }
  });
}
