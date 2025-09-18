import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'openai_service.dart';
import 'logging_service.dart';

class SQLiteService {
  late Database _db;
  final OpenAIService openAI;

  SQLiteService({required this.openAI});

  /// Initialize the database
  Future<void> init() async {
    loggingService.log("Initializing SQLite database...");
    final path = join(await getDatabasesPath(), 'pai.db');
    _db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS chunks(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            file TEXT,
            content TEXT,
            embedding TEXT
          )
        ''');
      },
    );
    loggingService.log("SQLite database initialized at $path");
  }

  /// Insert a chunk with its embedding
  Future<void> insertChunk(String file, String content, List<double> embedding) async {
    loggingService.log("Inserting chunk for file: $file");
    final embeddingStr = openAI.serializeEmbedding(embedding);
    await _db.insert('chunks', {
      'file': file,
      'content': content,
      'embedding': embeddingStr,
    });
    loggingService.log("Chunk inserted.");
  }

  /// Retrieve all chunks with embeddings
  Future<List<Map<String, dynamic>>> getAllChunksWithEmbeddings() async {
    loggingService.log("Retrieving all chunks with embeddings...");
    final result = await _db.query('chunks');
    final mapped = result.map((row) {
      final embStr = row['embedding'] as String?;
      final embedding = embStr != null
          ? openAI.deserializeEmbedding(embStr)
          : <double>[];
      return {
        "text": row['content'] as String,
        "embedding": embedding,
      };
    }).toList();
    loggingService.log("Retrieved ${result.length} chunks.");
    return mapped;
  }

  /// Clear all chunks
  Future<void> clear() async {
    loggingService.log("Clearing database...");
    await _db.delete('chunks');
  }
}
