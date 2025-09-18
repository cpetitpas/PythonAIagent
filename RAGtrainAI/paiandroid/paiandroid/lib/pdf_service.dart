import 'dart:io';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'sqlite_service.dart';
import 'openai_service.dart';
import 'logging_service.dart';

class PdfService {
  final SQLiteService db;
  final OpenAIService openAI;

  PdfService(this.db, this.openAI);

  /// Process a PDF: extract text, chunk, embed, store
  Future<void> processPdf(String filePath, {int chunkSize = 500}) async {
    loggingService.log("Processing PDF: $filePath");
    final file = File(filePath);
    if (!await file.exists()) return;

    final bytes = await file.readAsBytes();
    final document = PdfDocument(inputBytes: bytes);

    // Use PdfTextExtractor to extract all text
    final text = PdfTextExtractor(document).extractText();

    final words = text.split(RegExp(r'\s+'));
    List<String> chunks = [];

    for (var i = 0; i < words.length; i += chunkSize) {
      final chunkWords = words.sublist(i, (i + chunkSize).clamp(0, words.length));
      chunks.add(chunkWords.join(' '));
    }

    // Embed each chunk and store
    for (var chunk in chunks) {
      final embedding = await openAI.createEmbedding(text: chunk);
      await db.insertChunk(filePath, chunk, embedding);
    }
    loggingService.log("PDF processing complete: $filePath");
  }
}
