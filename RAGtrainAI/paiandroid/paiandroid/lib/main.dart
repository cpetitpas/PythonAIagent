import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:io';
import 'sqlite_service.dart';
import 'pdf_service.dart';
import 'openai_service.dart';
import 'logging_service.dart';
import 'ask_service.dart';
import 'purchase_service.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart' as perm;
import 'package:share_plus/share_plus.dart';
import 'dart:async';

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
  bool limitContext = true; // default: limit ON
  int? currentStep = 0; // Tracks current step in the steps list
  int trialDaysRemaining = 0;
  Timer? _trialTimer; 
  String apiKey = "";
  final ScrollController chatScrollController = ScrollController();
  final TextEditingController queryController = TextEditingController();
  final List<Map<String, String>> chatHistory = [];
  final InAppPurchase _iap = InAppPurchase.instance;
  final Map<String, ProductDetails> _productDetails = {};
  
  List<String> pdfPaths = [];
  List<String> previousQuestions = [];
  bool termsExpanded = false;
  bool showLimitContextInfo = false;
  bool showPreviousQuestions = false;

  late OpenAIService openAIService;
  late SQLiteService dbService;
  late PdfService pdfService;
  late AskService askService;
  late StreamSubscription<List<PurchaseDetails>> _subscription;
  final FlutterSecureStorage storage = const FlutterSecureStorage();

  @override
  void initState() {
    super.initState();
    openAIService = OpenAIService();
    dbService = SQLiteService(openAI: openAIService);
    pdfService = PdfService(dbService, openAIService);
    dbService.init();
    askService = AskService(openAI: openAIService, dbService: dbService);
    _checkAccess();
    _subscription = _iap.purchaseStream.listen(
      (purchases) async {
        for (var purchase in purchases) {
          if (purchase.status == PurchaseStatus.purchased ||
              purchase.status == PurchaseStatus.restored) {
            await _handlePurchase(purchase);
          } else if (purchase.status == PurchaseStatus.error) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text("Purchase Error: ${purchase.error?.message}")),
            );
          }
        }
      },
      onDone: () => _subscription.cancel(),
      onError: (error) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Purchase Stream Error: $error")),
        );
      },
    );
    _loadProducts();
    _loadApiKey();
  }

  Future<void> _loadApiKey() async {
    String? storedKey = await storage.read(key: "OPENAI_API_KEY");
    if (storedKey != null && storedKey.isNotEmpty) {
      await openAIService.setApiKey(storedKey);
      setState(() {
        apiKey = storedKey;
        currentStep = 0;
      });
    }
  }

  Future<void> _purchase(String productId) async {
    if (!_productDetails.containsKey(productId)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Product not loaded")),
      );
      return;
    }

  final purchaseParam = PurchaseParam(productDetails: _productDetails[productId]!);

    if (productId == 'lifetime_plan_id') {
      await _iap.buyNonConsumable(purchaseParam: purchaseParam);
    } else {
      await _iap.buyConsumable(purchaseParam: purchaseParam, autoConsume: false);
    }
  }


  Future<void> _loadProducts() async {
  const ids = {'monthly_plan_id', 'yearly_plan_id', 'lifetime_plan_id'};
  final response = await _iap.queryProductDetails(ids);
    if (response.notFoundIDs.isNotEmpty) {
      debugPrint("Products not found: ${response.notFoundIDs}");
    }
    for (var pd in response.productDetails) {
      _productDetails[pd.id] = pd;
    }
  }

  Future<void> _handlePurchase(PurchaseDetails purchase) async {
    if (purchase.productID == 'lifetime_plan_id') {
      await purchaseService.setLifetime(true);
    } else if (purchase.productID == 'monthly_plan_id') {
      await purchaseService.extendSubscription(days: 30);
    } else if (purchase.productID == 'yearly_plan_id') {
      await purchaseService.extendSubscription(days: 365);
    }

    if (purchase.pendingCompletePurchase) {
      await _iap.completePurchase(purchase);
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Purchase successful! App unlocked.")),
    );

    setState(() {
      currentStep = 4; // unlock main app
    });
  }


  Future<bool> _checkAccess() async {
    // Ensure trial is started if none exists
    final daysLeft = await purchaseService.remainingTrialDays();
    if (daysLeft == 0) {
      await purchaseService.startTrial();
    }

    // Now check entitlement (trial or purchase)
    return await purchaseService.isEntitled();
  }


    
final PurchaseService purchaseService = PurchaseService();


  void configureServices(String key) async {
    await openAIService.setApiKey(key);
    await storage.write(key: "OPENAI_API_KEY", value: key);
    setState(() {
      apiKey = key;
      currentStep = 4;
    });
  }

  void clearApiKey() async {
    await storage.delete(key: "OPENAI_API_KEY");
    setState(() {
      apiKey = "";
      currentStep = 2;
    });
  }

  void nextStep() {
    setState(() {
      if (currentStep != null) {
        currentStep = currentStep! + 1;
      }
    });
  }

  void prevStep() {
    setState(() {
      if (currentStep != null) {
        currentStep = currentStep! - 1;
      }
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

      for (var path in pdfPaths) {
        await pdfService.processPdf(path);
      }
    }
  }

  // Save log file to Downloads folder
Future<File?> saveLogToDownloads() async {
  try {
    final logFile = await loggingService.saveToFile();

    if (Platform.isAndroid) {
      // Request storage permission on Android
      if (!await perm.Permission.storage.request().isGranted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Storage permission denied")),
        );
        return null;
      }
      final downloadsDir = Directory('/storage/emulated/0/Download');
      final targetPath = '${downloadsDir.path}/pai_logs.txt';
      final targetFile = await logFile.copy(targetPath);
      return targetFile;
    } else if (Platform.isIOS) {
      final dir = await getApplicationDocumentsDirectory();
      final targetPath = '${dir.path}/pai_logs.txt';
      final targetFile = await logFile.copy(targetPath);
      return targetFile;
    }
  } catch (e) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("Error saving log: $e")),
    );
    return null;
  }
  return null;
}

// Send log via email with pre-filled "to" field
Future<void> sendLogByEmail() async {
  final file = await saveLogToDownloads();
  if (file == null) return;

  final Uri emailUri = Uri(
    scheme: 'mailto',
    path: 'admin@paidocassistant.com', // <-- replace with your support email
    queryParameters: {
      'subject': 'PAI App Logs',
      'body': 'Attached are my logs for troubleshooting.',
    },
  );

  if (await canLaunchUrl(emailUri)) {
    await launchUrl(emailUri);
  } else {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Could not launch email app')),
    );
  }
}

  void sendMessage() async {
    final query = queryController.text.trim();
    if (query.isEmpty) return;

    setState(() {
      chatHistory.add({"role": "user", "text": query});
      chatHistory.add({"role": "pai", "text": "Thinking..."});

      if (!previousQuestions.contains(query)) {
        previousQuestions.add(query);
      }

      queryController.clear();
    });

    await Future.delayed(const Duration(milliseconds: 100));
    chatScrollController.jumpTo(chatScrollController.position.maxScrollExtent);

    try {
      final answer = await askService.ask(
        query: query,
        limitContext: limitContext,
      );

      setState(() {
        chatHistory.removeLast();
        chatHistory.add({"role": "pai", "text": answer});
      });

      await Future.delayed(const Duration(milliseconds: 100));
      chatScrollController.jumpTo(chatScrollController.position.maxScrollExtent);
    } catch (e) {
      setState(() {
        chatHistory.removeLast();
        chatHistory.add({"role": "pai", "text": "Error: $e"});
      });
      await Future.delayed(const Duration(milliseconds: 100));
      chatScrollController.jumpTo(chatScrollController.position.maxScrollExtent);
    }
  }

  void exitApp() async {
    await dbService.clear();
    if (Platform.isAndroid || Platform.isIOS) {
      exit(0);
    }
  }

  @override
  void dispose() {
    _trialTimer?.cancel();
    dbService.clear();
    queryController.dispose();
    super.dispose();
  }

  Widget _buildUpgradeScreen(int daysLeft) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          daysLeft > 0
              ? "Your free trial has $daysLeft day${daysLeft > 1 ? 's' : ''} remaining.\n\nUpgrade to continue using the app:"
              : "Your free trial has ended.\n\nUpgrade to continue using the app:",
          style: const TextStyle(fontSize: 16),
        ),
        const SizedBox(height: 20),
        ElevatedButton(
          onPressed: () => _purchase("monthly_plan_id"),
          child: const Text("\$2 / month"),
        ),
        ElevatedButton(
          onPressed: () => _purchase("yearly_plan_id"),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.blueAccent,
          ),
          child: const Text("\$20 / year  ⭐ Most Popular"),
        ),
        ElevatedButton(
          onPressed: () => _purchase("lifetime_plan_id"),
          child: const Text("\$49 Lifetime"),
        ),
      ],
    );
  }



  @override
  Widget build(BuildContext context) {
    final steps = [
      _buildStepCard(
          step: 0,
          title: "Disclaimer",
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "This software is for informational purposes only.\n\n"
                  "• It does NOT provide medical advice, diagnosis, or treatment.\n"
                  "• It does NOT provide legal advice about Medicare, Medicaid, disability, or other benefits.\n"
                  "• Always consult a qualified professional before making decisions.\n"
                  "• All processing happens locally on your device. No data is sent to us.",
                  style: TextStyle(fontSize: 16),
                ),
                const SizedBox(height: 20),

                // Expandable Terms of Use
                ExpansionTile(
                  title: const Text(
                    "View Terms of Use",
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.blue,
                    ),
                  ),
                  onExpansionChanged: (expanded) {
                    setState(() {
                      termsExpanded = expanded;
                    });
                  },
                  children: const [
                    Padding(
                      padding: EdgeInsets.all(12),
                      child: Text(
                        "Terms of Use (Effective Sept 18, 2025)\n\n"
                        "1. License: You are granted a limited, non-exclusive license to use this app. "
                        "You may not redistribute, resell, or reverse engineer it.\n\n"
                        "2. No Advice: This app is informational only and does not provide medical, legal, "
                        "or financial advice. Always consult a professional.\n\n"
                        "3. Privacy: Documents are processed locally on your device. No data is sent to us.\n\n"
                        "4. Purchases: Ads, subscriptions, or in-app purchases may apply. All sales final "
                        "unless required by law.\n\n"
                        "5. Disclaimer: The app is provided 'as-is' without warranties. We are not liable "
                        "for damages or losses from its use.\n\n"
                        "6. Governing Law: These terms are governed by U.S. law.\n\n"
                        "© 2025 Christopher Petitpas. All rights reserved.",
                        style: TextStyle(fontSize: 14),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 20),

                Center(
                  child: ElevatedButton(
                    onPressed: termsExpanded
                        ? () {
                            if (apiKey.isNotEmpty) {
                              setState(() => currentStep = 4);
                            } else {
                              nextStep();
                            }
                          }
                        : null, // disabled until expanded
                    child: const Text("I Understand"),
                  ),
                ),
              ],
            ),
          ),
        ),
      _buildStepCard(
        step: 1,
        title: "Welcome to PAI Assistant - Document Clarity AI",
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Text(
                "Welcome to PAI your Personal AI Document Assistant!\n\n"
                "With this application you can upload PDF documents and ask questions about their content.\n\n"
                "This is very helpful with documents which come from Social Security, Medicare, Insurance, Legal, Medical, wherein the language is complex and difficult to understand.\n\n"
                "It is also helpful when you have many documents and one seems to conflict with another.",
                style: TextStyle(fontSize: 16),
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: nextStep,
                child: const Text("Next"),
              ),
            ],
          ),
        ),
      ),
      _buildStepCard(
        step: 2,
        title: "Getting Started: OpenAI API Key",
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Text(
                "This application leverages the power of OpenAI's GPT models to provide accurate and context-aware answers based on your documents.\n\n"
                "You will need an OpenAI API key to use this application.\n\n"
                "You can sign up or log in to your OpenAI account, then create a secret key and copy it to your clipboard.\n\n"
                "⚠️ Note: You will have only one opportunity to copy the key, so save it somewhere safe.\n\n"
                "The key will be stored securely on your device and never shared.\n\n"
                "Once set, this step will be skipped on future app launches.\n\n"
                "If you need to change or remove the key, you can do so later from the top-right key icon.",
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16),
              ),
              const SizedBox(height: 16),

              // Button to open OpenAI API key page
              ElevatedButton.icon(
                icon: const Icon(Icons.open_in_browser),
                label: const Text("Open OpenAI API Key Page"),
                onPressed: () async {
                  final Uri url = Uri.parse("https://platform.openai.com/account/api-keys");

                  if (await canLaunchUrl(url)) {
                    try {
                      await launchUrl(url, mode: LaunchMode.externalApplication);
                    } catch (e) {
                      // fallback to default mode
                      await launchUrl(url, mode: LaunchMode.platformDefault);
                    }
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text("Cannot launch URL")),
                    );
                  }
                },
              ),

              const SizedBox(height: 8),

              // Plain selectable URL for copy/paste
              SelectableText(
                "https://platform.openai.com/account/api-keys",
                style: const TextStyle(
                  color: Colors.blue,
                  decoration: TextDecoration.underline,
                  fontSize: 14,
                ),
              ),

              const SizedBox(height: 20),

              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  OutlinedButton(onPressed: prevStep, child: const Text("Back")),
                  ElevatedButton(onPressed: nextStep, child: const Text("Continue")),
                ],
              ),
            ],
          ),
        ),
      ),
      _buildStepCard(
        step: 3,
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
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                OutlinedButton(
                    onPressed: prevStep, child: const Text("Back")),
                ElevatedButton(
                  onPressed: () {
                    if (apiKey.isNotEmpty) {
                      configureServices(apiKey);
                    }
                  },
                  child: const Text("Next"),
                ),
              ],
            ),
          ],
        ),
      ),
      _buildStepCard(
        step: 4,
        title: "Select PDFs",
        content: Column(
          children: [
            ElevatedButton.icon(
              onPressed: pickPdfs,
              icon: const Icon(Icons.upload_file),
              label: const Text("Pick PDF files"),
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: () async {
                await dbService.clear();
                setState(() {
                  pdfPaths.clear();
                });
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text("Database cleared")),
                );
              },
              icon: const Icon(Icons.delete_forever, color: Colors.red),
              label: const Text("Clear Database"),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: pdfPaths.isEmpty
                  ? const Center(child: Text("No PDFs selected"))
                  : ListView.builder(
                      itemCount: pdfPaths.length,
                      itemBuilder: (context, i) {
                        return ListTile(
                          leading: const Icon(Icons.picture_as_pdf, color: Colors.red),
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
      // Step 5: Ask Questions
      _buildStepCard(
        step: 5,
        title: "Ask Questions",
        content: Column(
          children: [
            // Explanation section for Limit Context
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                GestureDetector(
                  onTap: () {
                    setState(() {
                      showLimitContextInfo = !showLimitContextInfo;
                    });
                  },
                  child: Row(
                    children: [
                      Text(
                        "Limit Context Info",
                        style: TextStyle(
                          color: Colors.blue,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Icon(
                        showLimitContextInfo
                            ? Icons.keyboard_arrow_up
                            : Icons.keyboard_arrow_down,
                        color: Colors.blue,
                      )
                    ],
                  ),
                ),
                if (showLimitContextInfo)
                  Container(
                    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                    margin: const EdgeInsets.only(bottom: 8, top: 4),
                    decoration: BoxDecoration(
                      color: Colors.blue.shade50,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text(
                      "Limit Context controls how much of your documents are used to answer your question.\n\n"
                      "• ON (recommended): Only the most relevant parts of your PDFs are used, making answers faster and more focused.\n"
                      "• OFF: The AI considers all content from your PDFs, which may be slower but can provide broader answers.\n\n"
                      "You can toggle this setting at any time.",
                      style: TextStyle(fontSize: 15, color: Colors.black87),
                    ),
                  ),
              ],
            ),

            // Chat History
            Expanded(
              child: ListView.builder(
                controller: chatScrollController,
                itemCount: chatHistory.length,
                itemBuilder: (context, i) {
                  final msg = chatHistory[i];
                  final isUser = msg["role"] == "user";
                  return Align(
                    alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
                    child: Container(
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
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

            const SizedBox(height: 8),

            // Ask Input & Previous Questions (inside your Column)
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey.shade400),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                          children: [
                            // TextField for new / selected question
                            TextField(
                              controller: queryController,
                              decoration: const InputDecoration(
                                hintText: "Ask something...",
                                border: InputBorder.none,
                              ),
                              textInputAction: TextInputAction.send,
                              onChanged: (value) {
                                setState(() {
                                  showPreviousQuestions = value.isEmpty; // only show when empty
                                });
                              },
                              onTap: () {
                                setState(() {
                                  showPreviousQuestions = queryController.text.isEmpty;
                                });
                              },
                              onSubmitted: (_) => sendMessage(),
                            ),

                            // Expanded previous questions list (only when box is focused & empty)
                            if (showPreviousQuestions && previousQuestions.isNotEmpty)
                              Container(
                                constraints: const BoxConstraints(maxHeight: 150), // scrollable area
                                margin: const EdgeInsets.only(top: 6),
                                child: ListView.builder(
                                  shrinkWrap: true,
                                  itemCount: previousQuestions.length,
                                  itemBuilder: (context, i) {
                                    final q = previousQuestions[i];
                                    return ListTile(
                                      dense: true,
                                      title: Text(
                                        q,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      onTap: () {
                                        setState(() {
                                          queryController.text = q;
                                          showPreviousQuestions = false;
                                        });
                                        sendMessage();
                                      },
                                    );
                                  },
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: sendMessage,
                  child: const Text("Ask"),
                ),
              ],
            ),


            const SizedBox(height: 12),

            // Limit Context Toggle
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                OutlinedButton(onPressed: prevStep, child: const Text("Back")),
                Row(
                  children: [
                    Text(
                      "Limit Context",
                      style: TextStyle(
                        color: limitContext ? Colors.blue : Colors.grey,
                        fontWeight: limitContext ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: () {
                        setState(() => limitContext = !limitContext);
                        loggingService.log(
                          "User toggled context mode: ${limitContext ? "Limited" : "Flexible"}",
                        );
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: limitContext ? Colors.blue : Colors.grey,
                      ),
                      child: Text(limitContext ? "ON" : "OFF"),
                    ),
                  ],
                ),
              ],
            )
          ],
        ),
      ),
    ];

    Widget content = FutureBuilder<bool>(
      future: _checkAccess(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        final entitled = snapshot.data ?? false;

        if (!entitled) {
          // Fetch trial days separately here
          return FutureBuilder<int>(
            future: purchaseService.remainingTrialDays(),
            builder: (context, trialSnap) {
              if (!trialSnap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              return _buildUpgradeScreen(trialSnap.data ?? 0);
            },
          );
        } else {
          // Defensive: clamp step to safe range
          final safeStep = (currentStep ?? 0).clamp(0, steps.length - 1);
          return steps[safeStep];
        }
      },
    );


    return Scaffold(
      backgroundColor: Colors.blue,
      appBar: AppBar(
        title: const Text("PAI Assistant - Document Clarity AI"),
        backgroundColor: Colors.blue.shade700,
        actions: [
          if (currentStep != null && currentStep! > 0) ...[
            Tooltip(
              message: "Clear saved OpenAI API Key",
              child: IconButton(
                icon: const Icon(Icons.key_off),
                onPressed: clearApiKey,
              ),
            ),
            Tooltip(
              message: "Exit App",
              child: IconButton(
                icon: const Icon(Icons.exit_to_app),
                onPressed: exitApp,
              ),
            ),
          ],
          Tooltip(
            message: "Download log file",
            child: IconButton(
              icon: const Icon(Icons.download),
              onPressed: () async {
                try {
                  final logFile = await loggingService.saveToFile();
                  await Share.shareXFiles(
                    [XFile(logFile.path)],
                    text: "PAI App Logs",
                    subject: "PAI Logs",
                  );

                  // Show instruction after sharing
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        "Select 'Save to Files' or your preferred app to store the log."
                      ),
                      duration: Duration(seconds: 4),
                    ),
                  );
                } catch (e) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text("Failed to save log: $e")),
                  );
                }
              },
            ),
          ),
          Tooltip(
          message: "Send logs via email",
          child: IconButton(
            icon: const Icon(Icons.email),
            onPressed: () async {
              try {
                final logFile = await loggingService.saveToFile();
                await Share.shareXFiles(
                  [XFile(logFile.path)],
                  text: "Here are my logs for troubleshooting.\n\nPlease send to admin@paidocassistant.com",
                  subject: "PAI App Logs",
                );

                // Show instruction after sharing
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      "Select your email app and verify the recipient before sending."
                    ),
                    duration: Duration(seconds: 4),
                  ),
                );
              } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text("Failed to send logs: $e")),
                );
              }
            },
          ),
        ),
        ],
      ),
      body: Container(
      margin: const EdgeInsets.all(16),
      child: Column(
        children: [
          if (currentStep != null && currentStep! > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                children: [
                  Image.asset(
                    "assets/images/robot.png",
                    width: 40,
                    height: 40,
                  ),
                  const SizedBox(width: 12),
                  const Text(
                    "PAI Assistant - Document Clarity AI",
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: Center(
              child: Container(
                constraints: const BoxConstraints(maxWidth: 600),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: const [BoxShadow(blurRadius: 6, color: Colors.black26)],
                ),
                child: content,
              ),
            ),
          ),
        ],
      ),
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
        if (step > 0)
          Text(
            "Step $step",
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: Colors.blue,
            ),
          ),
        if (step > 0) const SizedBox(height: 8),
        Text(
          title,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 16),
        Expanded(child: content),
      ],
    );
  }
}
