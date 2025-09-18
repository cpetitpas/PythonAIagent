import 'dart:math';
import 'sqlite_service.dart';
import 'openai_service.dart';
import 'logging_service.dart';

class AskService {
  final OpenAIService openAI;
  final SQLiteService dbService;

  AskService({required this.openAI, required this.dbService});

  /// Ask a question, returning a clean answer string
  Future<String> ask({
    required String query,
    String answerModel = "gpt-4o-mini",
    String embeddingModel = "text-embedding-3-small",
    int maxChunks = 3, // number of chunks to use as context
    bool limitContext = true, // user toggle
  }) async {
    loggingService.log("Received query: $query (limitContext=$limitContext)");
    try {
      // 1️⃣ Embed the query
      final queryEmbedding =
          await openAI.createEmbedding(text: query, model: embeddingModel);

      // 2️⃣ Get all stored chunks
      final allChunks = await dbService.getAllChunksWithEmbeddings();

      if (allChunks.isEmpty) {
        return "No documents found. Please upload some PDFs first.";
      }

      // 3️⃣ Compute cosine similarity between query embedding and each chunk
      List<Map<String, dynamic>> scoredChunks = allChunks.map((chunk) {
        final chunkVector = chunk["embedding"] as List<double>;
        final score = cosineSimilarity(queryEmbedding, chunkVector);
        return {"text": chunk["text"], "score": score};
      }).toList();

      // 4️⃣ Select chunks depending on context limit
      List<Map<String, dynamic>> selectedChunks;
      if (limitContext) {
        scoredChunks.sort((a, b) => b["score"].compareTo(a["score"]));
        selectedChunks = scoredChunks.take(maxChunks).toList();
        loggingService.log("Top $maxChunks chunks selected for context.");
      } else {
        selectedChunks = scoredChunks;
        loggingService.log("All chunks used for context (no limit).");
      }

      final combinedContext =
          selectedChunks.map((c) => c["text"] as String).join(" ");

      if (combinedContext.trim().isEmpty) {
        loggingService.log("No relevant chunks found.");
        return "No relevant information found in your documents.";
      }

      // 5️⃣ System prompt depends on toggle
      String systemPrompt;
      if (limitContext) {
        systemPrompt =
            "You are PAI, a helpful assistant. You must only answer using the provided context. "
            "If the answer is not in the context, say: "
            "'I don’t know. Please upload a document that contains this information or try a different answer model. Did you type names correctly?'";
      } else {
        systemPrompt =
            "You are PAI, a helpful assistant. Use the provided context if it is relevant, "
            "but you may also rely on your own knowledge to provide the best possible answer.";
      }

      // 6️⃣ Call OpenAI chat completion
      loggingService.log("Calling chat completion with model: $answerModel");
      final completion = await openAI.createChatCompletion(
        model: answerModel,
        messages: [
          {"role": "system", "content": systemPrompt},
          {
            "role": "user",
            "content": "Context: $combinedContext\n\nQuestion: $query"
          },
        ],
      );
      loggingService.log("Chat completion received.");

      final answer = completion["choices"][0]["message"]["content"] as String;

      // Return clean string directly
      return answer.trim();
    } catch (e) {
      return "Error: ${e.toString()}";
    }
  }

  /// Cosine similarity between two vectors
  double cosineSimilarity(List<double> a, List<double> b) {
    assert(a.length == b.length);
    double dot = 0.0;
    double magA = 0.0;
    double magB = 0.0;
    for (int i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      magA += a[i] * a[i];
      magB += b[i] * b[i];
    }
    return dot / (sqrt(magA) * sqrt(magB) + 1e-8);
  }
}
