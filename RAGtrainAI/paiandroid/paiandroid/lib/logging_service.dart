import 'dart:io';
import 'package:logger/logger.dart';
import 'package:path_provider/path_provider.dart';

class LoggingService {
  final Logger _logger = Logger(
    printer: PrettyPrinter(),
  );

  final List<String> _logs = [];

  void log(String message) {
    _logger.i(message);
    _logs.add("[INFO] $message");
  }

  void error(String message) {
    _logger.e(message);
    _logs.add("[ERROR] $message");
  }

  Future<File> saveToFile() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File("${dir.path}/pai_log.txt");
    return file.writeAsString(_logs.join("\n"));
  }

  String getLogs() {
    return _logs.join("\n");
  }

  void clearLogs() {
    _logs.clear();
  }
}

final loggingService = LoggingService();
