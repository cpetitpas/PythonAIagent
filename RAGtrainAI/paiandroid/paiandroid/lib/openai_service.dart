import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'logging_service.dart';

class OpenAIService {
  final String? apiKey; // optional direct injection
  final _storage = const FlutterSecureStorage();

  OpenAIService({this.apiKey});

  /// Get API key (prefer constructor-injected, else from secure storage)
  Future<String?> getApiKey() async {
    if (apiKey != null && apiKey!.isNotEmpty) {
      return apiKey;
    }
    return await _storage.read(key: 'OPENAI_API_KEY');
  }

  /// Store API key in secure storage
  Future<void> setApiKey(String key) async {
    await _storage.write(key: 'OPENAI_API_KEY', value: key);
    loggingService.log("OpenAI API key set.");
  }

  /// Create embeddings for a given text
  Future<List<double>> createEmbedding({
    required String text,
    String model = "text-embedding-3-small",
  }) async {
    final key = await getApiKey();
    if (key == null) throw Exception("Missing API key.");

    final response = await http.post(
      Uri.parse("https://api.openai.com/v1/embeddings"),
      headers: {
        "Authorization": "Bearer $key",
        "Content-Type": "application/json",
      },
      body: jsonEncode({"model": model, "input": text}),
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      loggingService.log("Embedding request successful.");
      return (data["data"][0]["embedding"] as List)
          .map((e) => (e as num).toDouble())
          .toList();
    } else {
      loggingService.error("Embedding request failed: ${response.body}");
      throw Exception("Embedding failed: ${response.body}");
    }
  }

  /// Create chat completion with context
  Future<Map<String, dynamic>> createChatCompletion({
    required String model,
    required List<Map<String, String>> messages,
  }) async {
    final key = await getApiKey();
    if (key == null) throw Exception("Missing API key.");

    final response = await http.post(
      Uri.parse("https://api.openai.com/v1/chat/completions"),
      headers: {
        "Authorization": "Bearer $key",
        "Content-Type": "application/json",
      },
      body: jsonEncode({
        "model": model,
        "messages": messages,
      }),
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return data;
    } else {
      throw Exception("Chat failed: ${response.body}");
    }
  }

  /// Serialize embedding to string for storage in SQLite
  String serializeEmbedding(List<double> embedding) {
    return jsonEncode(embedding);
  }

  /// Deserialize embedding string from SQLite to List<double>
  List<double> deserializeEmbedding(String embeddingStr) {
    final List<dynamic> rawList = jsonDecode(embeddingStr);
    return rawList.map((e) => (e as num).toDouble()).toList();
  }
}
