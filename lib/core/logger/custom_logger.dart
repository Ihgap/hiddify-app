// ignore_for_file: avoid_print

import 'dart:io';

import 'package:loggy/loggy.dart';

class ConsolePrinter extends LoggyPrinter {
  const ConsolePrinter({this.showColors = false});

  final bool showColors;

  static final _levelColors = {
    LogLevel.debug: AnsiColor(foregroundColor: AnsiColor.grey(0.5), italic: true),
    LogLevel.info: AnsiColor(foregroundColor: 35),
    LogLevel.warning: AnsiColor(foregroundColor: 214),
    LogLevel.error: AnsiColor(foregroundColor: 196),
  };

  @override
  void onLog(LogRecord record) {
    final colorize = showColors && stdout.supportsAnsiEscapes;
    final time = record.time.toIso8601String().split('T')[1];
    final callerFrame = record.callerFrame == null ? ' ' : ' (${record.callerFrame?.location}) ';

    final String logLevel;
    if (colorize) {
      logLevel = record.level.name.toUpperCase().padRight(8);
    } else {
      logLevel = "[${record.level.name.toUpperCase()}]".padRight(10);
    }

    final color = showColors ? levelColor(record.level) ?? AnsiColor() : AnsiColor();

    print(color('$time $logLevel [${record.loggerName}]$callerFrame${record.message}'));

    if (record.stackTrace != null) {
      print(record.stackTrace);
    }
  }

  AnsiColor? levelColor(LogLevel level) {
    return _levelColors[level];
  }
}

class FileLogPrinter extends LoggyPrinter {
  FileLogPrinter(String filePath, {this.minLevel = LogLevel.debug, this.maxSizeBytes = 10 * 1024 * 1024})
      : _logFile = File(filePath) {
    _truncateIfNeeded();
  }

  final File _logFile;
  final LogLevel minLevel;
  final int maxSizeBytes;
  int _lineCount = 0;

  late IOSink _sink = _logFile.openWrite(mode: FileMode.writeOnly);

  void _truncateIfNeeded() {
    try {
      if (_logFile.existsSync() && _logFile.lengthSync() > maxSizeBytes) {
        _logFile.writeAsStringSync('');
      }
    } catch (_) {}
  }

  @override
  void onLog(LogRecord record) {
    final time = record.time.toIso8601String().split('T')[1];
    _sink.writeln("$time - $record");
    if (record.error != null) {
      _sink.writeln(record.error);
    }
    if (record.stackTrace != null) {
      _sink.writeln(record.stackTrace);
    }
    _lineCount++;
    if (_lineCount % 1000 == 0) {
      _checkSize();
    }
  }

  void _checkSize() {
    try {
      if (_logFile.existsSync() && _logFile.lengthSync() > maxSizeBytes) {
        _sink.close();
        _logFile.writeAsStringSync('--- log rotated ---\n');
        _sink = _logFile.openWrite(mode: FileMode.append);
      }
    } catch (_) {}
  }

  void dispose() {
    _sink.close();
  }
}
