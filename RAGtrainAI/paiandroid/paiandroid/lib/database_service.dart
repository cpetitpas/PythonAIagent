class DatabaseService {
  static Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'paiassistant.db');
    _db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE vectors (
            id TEXT PRIMARY KEY,
            vector TEXT, -- store JSON string of embedding
            text TEXT,
            filename TEXT
          )
        ''');
      },
    );
    return _db!;
  }

  Future<void> insertVector(String text, List<double> vector, String filename) async {
    final db = await database;
    await db.insert("vectors", {
      "id": const Uuid().v4(),
      "vector": jsonEncode(vector),
      "text": text,
      "filename": filename,
    });
  }

  Future<List<Map<String, dynamic>>> searchSimilar(List<double> queryVector, {int limit = 3}) async {
    final db = await database;
    final rows = await db.query("vectors");
    List<Map<String, dynamic>> scored = [];

    for (var row in rows) {
      final storedVector = List<double>.from(jsonDecode(row["vector"] as String));
      final score = _cosineSimilarity(queryVector, storedVector);
      scored.add({...row, "score": score});
    }

    scored.sort((a, b) => (b["score"] as double).compareTo(a["score"] as double));
    return scored.take(limit).toList();
  }

  double _cosineSimilarity(List<double> a, List<double> b) {
    double dot = 0, normA = 0, normB = 0;
    for (int i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }
    return dot / (sqrt(normA) * sqrt(normB));
  }

  Future<void> clear() async {
    final db = await database;
    await db.delete("vectors");
  }
}
