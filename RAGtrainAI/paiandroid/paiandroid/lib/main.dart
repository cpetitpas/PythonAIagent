import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:file_picker/file_picker.dart';
import 'sqlite_service.dart';
import 'pdf_service.dart';
import 'openai_service.dart';
import 'ask_service.dart';

void main() {
  runApp(const PAIApp());
}

class PAIApp extends StatelessWidget {
  const PAIApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: "PAI Workflow",
      theme: ThemeData(
        primarySwatch: Colors.blue,
        textTheme: GoogleFonts.interTextTheme(),
      ),
      home: const WorkflowScreen(),
    );
  }
}

class WorkflowScreen extends StatefulWidget {
  const WorkflowScreen({super.key});

  @override
  State<WorkflowScreen> createState() => _WorkflowScreenState();
}

class _WorkflowScreenState extends State<WorkflowScreen> {
  int currentStep = 0;
  String apiKey = "";
  final TextEditingController queryController = TextEditingController();
  final List<Map<String, String>> chatHistory = [];
  List<String> pdfPaths = [];

  late OpenAIService openAIService;
  late SQLiteService dbService;
  late PdfService pdfService;
  late AskService askService;

  @override
  void initState() {
    super.initState();

    openAIService = OpenAIService();
    dbService = SQLiteService(openAI: openAIService);
    pdfService = PdfService(dbService, openAIService);
    dbService.init();
    askService = AskService(openAI: openAIService, dbService: dbService);
  }

  void configureServices(String key) async {
    await openAIService.setApiKey(key);
    setState(() {
      apiKey = key;
    });
  }

  void nextStep() {
    setState(() {
      currentStep++;
    });
  }

  void prevStep() {
    setState(() {
      currentStep--;
    });
  }

  Future<void> pickPdfs() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
      allowMultiple: true,
    );

    if (result != null && result.files.isNotEmpty) {
      setState(() {
        pdfPaths = result.paths.whereType<String>().toList();
      });

      // Process PDFs immediately
      for (var path in pdfPaths) {
        await pdfService.processPdf(path);
      }
    }
  }

  void sendMessage() async {
  final query = queryController.text.trim();
  if (query.isEmpty) return;

  setState(() {
    chatHistory.add({"role": "user", "text": query});
    chatHistory.add({"role": "pai", "text": "Thinking..."});
  });

  queryController.clear();

  try {
    // askService.ask now returns a String
    final answer = await askService.ask(query: query);

    setState(() {
      chatHistory.removeLast(); // remove "Thinking..."
      chatHistory.add({"role": "pai", "text": answer});
    });
  } catch (e) {
    setState(() {
      chatHistory.removeLast(); // remove "Thinking..."
      chatHistory.add({"role": "pai", "text": "Error: $e"});
    });
  }
}


  @override
  Widget build(BuildContext context) {
    final steps = [
      _buildStepCard(
        step: 1,
        title: "Enter OpenAI API Key",
        content: Column(
          children: [
            TextField(
              onChanged: (v) => apiKey = v,
              decoration: const InputDecoration(
                labelText: "OPENAI_API_KEY",
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: () {
                if (apiKey.isNotEmpty) {
                  configureServices(apiKey);
                  nextStep();
                }
              },
              child: const Text("Next"),
            ),
          ],
        ),
      ),
      _buildStepCard(
        step: 2,
        title: "Select PDFs",
        content: Column(
          children: [
            ElevatedButton.icon(
              onPressed: pickPdfs,
              icon: const Icon(Icons.upload_file),
              label: const Text("Pick PDF files"),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: pdfPaths.isEmpty
                  ? const Center(child: Text("No PDFs selected"))
                  : ListView.builder(
                      itemCount: pdfPaths.length,
                      itemBuilder: (context, i) {
                        return ListTile(
                          leading:
                              const Icon(Icons.picture_as_pdf, color: Colors.red),
                          title: Text(pdfPaths[i].split('/').last),
                          subtitle: Text(pdfPaths[i]),
                        );
                      },
                    ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                OutlinedButton(onPressed: prevStep, child: const Text("Back")),
                ElevatedButton(
                  onPressed: pdfPaths.isNotEmpty ? nextStep : null,
                  child: const Text("Next"),
                ),
              ],
            )
          ],
        ),
      ),
      _buildStepCard(
        step: 3,
        title: "Ask Questions",
        content: Column(
          children: [
            Expanded(
              child: ListView.builder(
                itemCount: chatHistory.length,
                itemBuilder: (context, i) {
                  final msg = chatHistory[i];
                  final isUser = msg["role"] == "user";
                  return Align(
                    alignment:
                        isUser ? Alignment.centerRight : Alignment.centerLeft,
                    child: Container(
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      padding: const EdgeInsets.symmetric(
                          vertical: 8, horizontal: 12),
                      decoration: BoxDecoration(
                        color: isUser ? Colors.blue : Colors.green,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Text(
                        msg["text"]!,
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                  );
                },
              ),
            ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: queryController,
                    decoration: const InputDecoration(
                      hintText: "Ask something...",
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: sendMessage,
                  child: const Text("Ask"),
                ),
              ],
            )
          ],
        ),
      ),
    ];

    return Scaffold(
      backgroundColor: Colors.blue,
      appBar: AppBar(
        title: const Text("PAI Workflow - Guided Workflow"),
        backgroundColor: Colors.blue.shade700,
      ),
      body: Container(
        margin: const EdgeInsets.all(16),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          boxShadow: const [BoxShadow(blurRadius: 6, color: Colors.black26)],
        ),
        child: steps[currentStep],
      ),
    );
  }

  Widget _buildStepCard({
    required int step,
    required String title,
    required Widget content,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text("Step $step",
            style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: Colors.blue)),
        const SizedBox(height: 8),
        Text(title,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
        const SizedBox(height: 16),
        Expanded(child: content),
      ],
    );
  }
}
