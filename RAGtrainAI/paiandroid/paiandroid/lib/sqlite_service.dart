import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'openai_service.dart';

class SQLiteService {
  late Database _db;
  final OpenAIService openAI;

  SQLiteService({required this.openAI});

  /// Initialize the database
  Future<void> init() async {
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
  }

  /// Insert a chunk with its embedding
  Future<void> insertChunk(String file, String content, List<double> embedding) async {
    final embeddingStr = openAI.serializeEmbedding(embedding);
    await _db.insert('chunks', {
      'file': file,
      'content': content,
      'embedding': embeddingStr,
    });
  }

  /// Retrieve all chunks with embeddings
  Future<List<Map<String, dynamic>>> getAllChunksWithEmbeddings() async {
    final result = await _db.query('chunks');
    return result.map((row) {
      final embStr = row['embedding'] as String?;
      final embedding = embStr != null
          ? openAI.deserializeEmbedding(embStr)
          : <double>[];
      return {
        "text": row['content'] as String,
        "embedding": embedding,
      };
    }).toList();
  }

  /// Clear all chunks
  Future<void> clear() async {
    await _db.delete('chunks');
  }
}
