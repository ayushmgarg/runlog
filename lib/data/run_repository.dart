import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../domain/models/run_record.dart';

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

  Future<List<RunRecord>> loadRuns() async {
    try {
      final file = await _file(_historyFile);
      if (!await file.exists()) return const [];
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! List) return const [];
      final runs =
          decoded
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

  Future<void> _writeAtomically(String name, String contents) async {
    final target = await _file(name);
    final temp = File('${target.path}.tmp');
    await temp.writeAsString(contents, flush: true);
    await temp.rename(target.path);
  }
}
