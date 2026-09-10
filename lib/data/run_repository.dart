import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../domain/models/run_record.dart';

/// Local storage for finished runs and for the in-progress snapshot.
///
/// A JSON file rather than a database: the whole dataset is a handful of runs
/// that are only ever read as a list and written whole. `sqflite` would add a
/// native dependency and a schema-migration story to solve a problem this app
/// does not have, and `shared_preferences` is the wrong shape for a growing
/// list of route points.
///
/// Writes go to a temp file and are then renamed, so a crash mid-write cannot
/// leave a truncated history behind.
class RunRepository {
  RunRepository({Directory? directory}) : _directoryOverride = directory;

  final Directory? _directoryOverride;
  Directory? _resolved;

  static const String _historyFile = 'runs.json';
  static const String _activeRunFile = 'active_run.json';

  Future<Directory> _dir() async {
    final override = _directoryOverride;
    if (override != null) return override;
    return _resolved ??= await getApplicationDocumentsDirectory();
  }

  Future<File> _file(String name) async => File('${(await _dir()).path}/$name');

  // ------------------------------------------------------------- history

  /// All saved runs, newest first. Returns an empty list rather than throwing
  /// if the file is missing or corrupt: a damaged history must not make the app
  /// unusable, and the runs it holds are not worth a crash.
  Future<List<RunRecord>> loadRuns() async {
    try {
      final file = await _file(_historyFile);
      if (!await file.exists()) return const [];
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! List) return const [];
      final runs = decoded
          .whereType<Map>()
          .map((e) => RunRecord.fromJson(Map<String, dynamic>.from(e)))
          .toList()
        ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
      return runs;
    } catch (_) {
      return const [];
    }
  }

  Future<void> saveRun(RunRecord run) async {
    // Copied: loadRuns returns an immutable empty list on the empty/corrupt
    // paths, and a fresh install would otherwise throw on the first save.
    final runs = List<RunRecord>.of(await loadRuns());
    runs.removeWhere((r) => r.id == run.id);
    runs.insert(0, run);
    await _writeRuns(runs);
  }

  Future<void> deleteRun(String id) async {
    final runs = List<RunRecord>.of(await loadRuns())
      ..removeWhere((r) => r.id == id);
    await _writeRuns(runs);
  }

  Future<void> _writeRuns(List<RunRecord> runs) async {
    final payload = jsonEncode(runs.map((r) => r.toJson()).toList());
    await _writeAtomically(_historyFile, payload);
  }

  // ----------------------------------------------------- active run snapshot

  /// Persists an in-progress run so a crash, a battery pull or an
  /// out-of-memory kill does not lose it.
  Future<void> saveActiveRun(Map<String, dynamic> snapshot) =>
      _writeAtomically(_activeRunFile, jsonEncode(snapshot));

  Future<Map<String, dynamic>?> loadActiveRun() async {
    try {
      final file = await _file(_activeRunFile);
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return null;
      return Map<String, dynamic>.from(decoded);
    } catch (_) {
      return null;
    }
  }

  Future<void> clearActiveRun() async {
    try {
      final file = await _file(_activeRunFile);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Nothing useful to do: the next snapshot overwrites it anyway.
    }
  }

  /// Write-then-rename. A half-written file is the one failure mode that would
  /// cost the user their history, and rename is atomic on both platforms.
  Future<void> _writeAtomically(String name, String contents) async {
    final target = await _file(name);
    final temp = File('${target.path}.tmp');
    await temp.writeAsString(contents, flush: true);
    await temp.rename(target.path);
  }
}
