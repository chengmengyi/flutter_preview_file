import 'dart:async';

class FileToolsTaskControl {
  bool _paused = false;
  bool _canceled = false;
  Completer<void>? _resumeCompleter;

  bool get isPaused => _paused;

  bool get isCanceled => _canceled;

  void pause() {
    if (_canceled) {
      return;
    }
    _paused = true;
    _resumeCompleter ??= Completer<void>();
  }

  void resume() {
    _paused = false;
    if (_resumeCompleter != null && !_resumeCompleter!.isCompleted) {
      _resumeCompleter!.complete();
    }
    _resumeCompleter = null;
  }

  void cancel() {
    _canceled = true;
    resume();
  }

  Future<void> checkpoint() async {
    if (_canceled) {
      throw const FileToolsCanceledException();
    }
    if (_paused) {
      _resumeCompleter ??= Completer<void>();
      await _resumeCompleter!.future;
    }
    if (_canceled) {
      throw const FileToolsCanceledException();
    }
    await Future<void>.delayed(Duration.zero);
    if (_canceled) {
      throw const FileToolsCanceledException();
    }
  }
}

class FileToolsCanceledException implements Exception {
  const FileToolsCanceledException();

  @override
  String toString() => "Task canceled";
}
