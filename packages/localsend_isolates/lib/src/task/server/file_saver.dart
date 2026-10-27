import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:gal/gal.dart';
import 'package:localsend_isolates/rust/api/filename.dart' as rust_filename;
import 'package:localsend_isolates/util/android_channel.dart' as android_channel;
import 'package:localsend_isolates/util/content_uri_helper.dart';
import 'package:localsend_isolates/util/file_path_helper.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

final _logger = Logger('FileSaver');

/// Where an incoming file should be written to.
/// The actual writing is done by the Rust server which receives either a
/// plain file [path] or a writable [fileDescriptor] (Android SAF).
class FileSaveTarget {
  /// The path to write the file to. `null` when [fileDescriptor] is used.
  final String? path;

  /// A writable file descriptor (Android SAF). `null` when [path] is used.
  final int? fileDescriptor;

  /// The path or content URI of the destination, used for the history
  /// and to locate the file after it has been written.
  final String displayPath;

  FileSaveTarget({
    required this.path,
    required this.fileDescriptor,
    required this.displayPath,
  });
}

/// Prepares the destination for an incoming file with [fileName].
///
/// When [saveToGallery] is true, the file is first written to the
/// [cacheDirectory]; call [saveCachedFileToGallery] after the file has been
/// written.
///
/// On Android, destinations that cannot be written directly (SAF content URIs
/// and SD cards) are created via the Storage Access Framework and a writable
/// file descriptor is returned instead of a path.
Future<FileSaveTarget> prepareFileSaveTarget({
  required String destinationDirectory,
  required String cacheDirectory,
  required String fileName,
  required bool saveToGallery,
  required Set<String> createdDirectories,
  int? androidSdkInt,
}) async {
  final parentDirectory = saveToGallery ? cacheDirectory : destinationDirectory;

  final (destinationPath, documentUri, finalName) = await digestFilePathAndPrepareDirectory(
    parentDirectory: parentDirectory,
    fileName: fileName,
    createdDirectories: createdDirectories,
  );

  // When saveToGallery is enabled, the cache directory is used so SAF is not needed
  if (!saveToGallery && androidSdkInt != null) {
    String? parentUri;
    if (documentUri != null || destinationPath.startsWith('content://')) {
      parentUri = documentUri ?? destinationPath;
    } else {
      final sdCardPath = getSdCardPath(destinationPath);
      if (sdCardPath != null) {
        final uriString = ContentUriHelper.encodeTreeUri(sdCardPath.path.parentPath());
        parentUri = 'content://com.android.externalstorage.documents/tree/${sdCardPath.sdCardId}:$uriString';
      }
    }

    if (parentUri != null) {
      _logger.info('Using SAF to save file to $parentUri as $finalName');
      final createdFile = await android_channel.createFileAndroid(
        parentUri: parentUri,
        fileName: finalName,
      );
      return FileSaveTarget(
        path: null,
        fileDescriptor: createdFile.fileDescriptor,
        displayPath: createdFile.uri,
      );
    }
  }

  return FileSaveTarget(
    path: destinationPath,
    fileDescriptor: null,
    displayPath: destinationPath,
  );
}

/// Prepares [target] for another attempt at the same file, e.g. after the
/// previous attempt was rejected because of a checksum mismatch.
///
/// The destination is kept, so the file is overwritten instead of being
/// created a second time under a numbered name.
Future<FileSaveTarget> reopenFileSaveTarget(FileSaveTarget target) async {
  final path = target.path;
  if (path != null) {
    // The server opens (and truncates) the path itself.
    return target;
  }

  // The descriptor of the previous attempt was consumed by it, so the SAF
  // document has to be opened again.
  _logger.info('Reopening ${target.displayPath}');
  return FileSaveTarget(
    path: null,
    fileDescriptor: await android_channel.openFileForWritingAndroid(uri: target.displayPath),
    displayPath: target.displayPath,
  );
}

/// Moves a file that has been written to the cache directory into the
/// OS gallery (Photos/Videos).
///
/// If the gallery rejects the file (unsupported format, missing permission,
/// not enough space, ...), the cached file is moved to [destinationDirectory]
/// as fallback. At this point the file is already fully received and the
/// sender was already told success, so failing the transfer would lose it.
///
/// Returns (savedToGallery, filePath):
/// - savedToGallery: true if saved to gallery, false if saved to directory
/// - filePath: absolute path to file (null when saved to gallery)
Future<(bool, String?)> saveCachedFileToGallery({
  required String cachedPath,
  required String destinationDirectory,
  required String fileName,
  required bool isImage,
  required Set<String> createdDirectories,
}) async {
  try {
    isImage ? await Gal.putImage(cachedPath) : await Gal.putVideo(cachedPath);
  } on GalException catch (e) {
    _logger.warning('Could not save to gallery (${e.type.name}), moving to destination directory', e);

    final (fallbackPath, _, _) = await digestFilePathAndPrepareDirectory(
      parentDirectory: destinationDirectory,
      fileName: fileName,
      createdDirectories: createdDirectories,
    );

    _logger.info('Moving file from $cachedPath to $fallbackPath');
    await File(cachedPath).rename(fallbackPath);
    return (false, fallbackPath);
  }

  try {
    await File(cachedPath).delete();
  } catch (e) {
    _logger.warning('Could not delete cached file after saving to gallery', e);
  }
  return (true, null);
}

/// Turns the peer-supplied [fileName] into a relative name that stays inside
/// the destination directory.
///
/// Protocol v2 lets a name carry directory components, for folder transfers.
/// The peer chooses them, so they get the same treatment as the base name:
/// `..` and absolute names are refused outright rather than rewritten, since a
/// name that tries to leave the destination is not a name to guess at, and
/// every remaining component is sanitized. Without that, only the base name
/// was checked and a directory could still be named `con`, end in a dot or
/// carry control characters.
///
/// Throws `'Path traversal detected'` when the name tries to leave the
/// destination.
List<String> sanitizeRelativeName(String fileName) {
  final parts = p.split(fileName);

  final components = <String>[];
  for (final part in parts) {
    // `p.split` keeps the root of an absolute name ('/', 'C:\\', ...) as the
    // first component, so this catches absolute names as well.
    if (part == '..' || p.rootPrefix(part).isNotEmpty) {
      throw 'Path traversal detected';
    }
    // A '.' component (and the empty ones `p.split` can produce) addresses the
    // directory it is in, so it simply drops out.
    if (part == '.' || part.isEmpty) {
      continue;
    }
    components.add(rust_filename.sanitizeFileName(name: part));
  }

  // Everything collapsed, e.g. the name was empty or just '.'.
  if (components.isEmpty) {
    components.add(rust_filename.sanitizeFileName(name: ''));
  }

  return components;
}

/// If the name is already occupied, appends a number to the file name.
Future<(String, String?, String)> digestFilePathAndPrepareDirectory({
  required String parentDirectory,
  required String fileName,
  required Set<String> createdDirectories,
}) async {
  final components = sanitizeRelativeName(fileName);
  fileName = components.join('/');

  if (parentDirectory.startsWith('content://')) {
    final String documentUri;
    if (fileName.contains('/')) {
      try {
        await android_channel.createMissingDirectoriesAndroid(parentUri: parentDirectory, fileName: fileName, createdDirectories: createdDirectories);
      } catch (e) {
        _logger.warning('Could not create missing directories', e);
      }
      documentUri = ContentUriHelper.convertTreeUriToDocumentUri(treeUri: parentDirectory, suffix: fileName.parentPath());
    } else {
      // root directory
      documentUri = ContentUriHelper.convertTreeUriToDocumentUri(treeUri: parentDirectory, suffix: null);
    }

    // destinationUri is for the history
    // documentUri is for SAF to save the file, it should point to the parent directory
    final destinationUri = ContentUriHelper.convertTreeUriToDocumentUri(treeUri: parentDirectory, suffix: fileName);
    return (destinationUri, documentUri, p.basename(fileName));
  }

  final actualFileName = components.last;
  final dir = p.joinAll([parentDirectory, ...components.take(components.length - 1)]);

  if (components.length > 1) {
    // Second gate: the components above cannot escape on their own, but the
    // resulting directory is what is about to be created.
    if (!p.isWithin(parentDirectory, dir)) {
      throw 'Path traversal detected';
    }
  }

  // The destination directory may not exist anymore, e.g. because it was deleted
  // or is on a drive that is no longer mounted. This also creates the
  // sub-directories of a folder transfer. Errors are propagated so that the
  // caller fails the upload instead of writing to a path that cannot be opened.
  Directory(dir).createSync(recursive: true);

  String destinationPath;
  int counter = 1;
  do {
    destinationPath = counter == 1 ? p.join(dir, actualFileName) : p.join(dir, actualFileName.withCount(counter));
    counter++;
  } while (await FileSystemEntity.type(destinationPath, followLinks: false) != FileSystemEntityType.notFound);
  return (destinationPath, null, p.basename(destinationPath));
}

final _sdCardPathRegex = RegExp(r'^/storage/([A-Fa-f0-9]{4}-[A-Fa-f0-9]{4})/(.*)$');

class SdCardPath {
  final String sdCardId;
  final String path;

  SdCardPath(this.sdCardId, this.path);
}

/// Checks if the [path] is on the SD card and returns the SD card path.
/// Returns `null` if the [path] is not on the SD card.
/// Only works on Android.
SdCardPath? getSdCardPath(String path) {
  final match = _sdCardPathRegex.firstMatch(path);
  if (match == null) {
    return null;
  }
  return SdCardPath(match.group(1)!, match.group(2)!);
}

/// A partial file that an interrupted transfer can be continued from.
class ResumeOffer {
  /// Absolute path of the partial file.
  final String path;

  /// Bytes already on disk, i.e. the offset the sender has to continue at.
  final int offset;

  /// Opaque identifier of the partial file, echoed by the sender and checked
  /// by the server before a single byte is appended.
  final String partialId;

  ResumeOffer({
    required this.path,
    required this.offset,
    required this.partialId,
  });

  /// The bridge representation used for a resume offer:
  /// `<fileId>\u{1f}<offset>\u{1f}<partialId>`.
  ///
  /// The unit separator cannot occur in a file ID, a file name, or a number,
  /// so the payload needs no escaping.
  String toWire(String fileId) => '$fileId\u{1f}$offset\u{1f}$partialId';
}

/// Remembers partial files so that an interrupted transfer can continue at the
/// byte it stopped at instead of starting over.
///
/// Entries are keyed by the identity of the incoming file (name, size,
/// checksum) and not by session or file ID: a sender that retries after a
/// reconnect opens a new session and may even use a new file ID for the same
/// content, while the bytes on disk are still the same prefix.
///
/// The index is a JSON file in the cache directory, so it survives an app
/// restart and never litters the user's destination directory.
class ResumeIndex {
  static const _fileName = 'localsend_resume.json';

  /// Entries older than this are dropped on load, so a partial file that is
  /// never continued does not stay indexed forever.
  static const _maxAge = Duration(days: 7);

  /// The directory the index belongs to.
  final String cacheDirectory;

  final File _file;
  final Map<String, _PartialEntry> _entries;

  ResumeIndex._(this.cacheDirectory, this._file, this._entries);

  /// Identity of an incoming file, independent of the session it arrives in.
  static String keyOf({
    required String fileName,
    required int size,
    String? sha256,
  }) =>
      '$fileName\u{1f}$size\u{1f}${sha256 ?? ''}';

  static Future<ResumeIndex> load(String cacheDirectory) async {
    final file = File(p.join(cacheDirectory, _fileName));
    final entries = <String, _PartialEntry>{};

    try {
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map) {
          final raw = decoded['entries'];
          if (raw is Map) {
            final cutoff = DateTime.now().subtract(_maxAge).millisecondsSinceEpoch;
            raw.forEach((key, value) {
              if (key is! String || value is! Map) {
                return;
              }
              final entry = _PartialEntry.fromJson(value);
              if (entry == null || entry.updatedAtMs < cutoff) {
                return;
              }
              entries[key] = entry;
            });
          }
        }
      }
    } catch (e) {
      // A broken index only loses the ability to continue; it must never
      // prevent receiving a file from the beginning.
      _logger.warning('Discarding unreadable resume index', e);
    }

    return ResumeIndex._(cacheDirectory, file, entries);
  }

  /// Returns the offer for the file identified by [key], or `null` when
  /// nothing can be continued.
  ///
  /// An entry is only offered when the partial file still exists and is
  /// neither empty nor complete. The offset is read from disk instead of from
  /// the index, so bytes written after the last update are not announced as
  /// missing.
  Future<ResumeOffer?> offerFor({
    required String key,
    required int expectedSize,
  }) async {
    final entry = _entries[key];
    if (entry == null) {
      return null;
    }

    final int length;
    try {
      if (await FileSystemEntity.type(entry.path, followLinks: false) != FileSystemEntityType.file) {
        _entries.remove(key);
        return null;
      }
      length = await File(entry.path).length();
    } catch (e) {
      _logger.warning('Could not inspect the partial file at ${entry.path}', e);
      _entries.remove(key);
      return null;
    }

    if (length <= 0 || length >= expectedSize) {
      // Either nothing arrived, or the file is already complete.
      _entries.remove(key);
      return null;
    }

    entry
      ..offset = length
      ..updatedAtMs = DateTime.now().millisecondsSinceEpoch;

    return ResumeOffer(
      path: entry.path,
      offset: length,
      partialId: entry.partialId,
    );
  }

  /// Records how much of the file at [path] has been received.
  ///
  /// A missing, empty, or complete file drops the entry: there is nothing left
  /// to continue. A new partial file gets a new [ResumeOffer.partialId], so an
  /// offer from an earlier attempt cannot be reused against different bytes.
  Future<void> record({
    required String key,
    required String path,
    required int expectedSize,
  }) async {
    final int length;
    try {
      if (await FileSystemEntity.type(path, followLinks: false) != FileSystemEntityType.file) {
        await remove(key);
        return;
      }
      length = await File(path).length();
    } catch (e) {
      _logger.warning('Could not inspect the partial file at $path', e);
      await remove(key);
      return;
    }

    if (length <= 0 || length >= expectedSize) {
      await remove(key);
      return;
    }

    final previous = _entries[key];
    _entries[key] = _PartialEntry(
      path: path,
      offset: length,
      partialId: previous != null && previous.path == path ? previous.partialId : _newPartialId(),
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    await flush();
  }

  /// Forgets the entry of the file identified by [key].
  Future<void> remove(String key) async {
    if (_entries.remove(key) != null) {
      await flush();
    }
  }

  /// Writes the index back to disk.
  ///
  /// The new content is written to a temporary file and renamed over the old
  /// one, so a process that dies halfway cannot leave a half-written index.
  Future<void> flush() async {
    try {
      final json = jsonEncode({
        'entries': {
          for (final entry in _entries.entries) entry.key: entry.value.toJson(),
        },
      });

      await _file.parent.create(recursive: true);
      final temp = File('${_file.path}.tmp');
      await temp.writeAsString(json, flush: true);
      await temp.rename(_file.path);
    } catch (e) {
      _logger.warning('Could not persist the resume index', e);
    }
  }

  static String _newPartialId() {
    final random = Random.secure();
    return List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }
}

/// One entry of a [ResumeIndex].
class _PartialEntry {
  final String path;
  int offset;
  final String partialId;
  int updatedAtMs;

  _PartialEntry({
    required this.path,
    required this.offset,
    required this.partialId,
    required this.updatedAtMs,
  });

  static _PartialEntry? fromJson(Map<dynamic, dynamic> json) {
    final path = json['path'];
    final offset = json['offset'];
    final partialId = json['partialId'];
    final updatedAtMs = json['updatedAt'];
    if (path is! String || path.isEmpty || offset is! int || partialId is! String || partialId.isEmpty || updatedAtMs is! int) {
      return null;
    }
    return _PartialEntry(
      path: path,
      offset: offset,
      partialId: partialId,
      updatedAtMs: updatedAtMs,
    );
  }

  Map<String, Object?> toJson() => {
        'path': path,
        'offset': offset,
        'partialId': partialId,
        'updatedAt': updatedAtMs,
      };
}
