import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:file_picker/file_picker.dart';
import 'dart:convert';
import 'package:path_provider/path_provider.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'dart:typed_data';

class DialogueItem {
  final String speaker;
  final String text;
  
  DialogueItem({required this.speaker, required this.text});

  factory DialogueItem.fromJson(Map<String, dynamic> json) {
    return DialogueItem(
      speaker: json['speaker'] as String? ?? '',
      text: json['text'] as String? ?? '',
    );
  }
}

class Dialogue {
  final String scratchpad;
  final String nameOfGuest;
  final List<DialogueItem> dialogue;

  Dialogue({
    required this.scratchpad, 
    required this.nameOfGuest, 
    required this.dialogue
  });

  factory Dialogue.fromJson(Map<String, dynamic> json) {
    return Dialogue(
      scratchpad: json['scratchpad'] as String? ?? '',
      nameOfGuest: json['name_of_guest'] as String? ?? '',
      dialogue: (json['dialogue'] as List?)
          ?.map((i) => DialogueItem.fromJson(i))
          .toList() ?? [],
    );
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: ".env");
  runApp(const PodcastApp());
}

class PodcastApp extends StatelessWidget {
  const PodcastApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'PDF to Podcast',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const PodcastScreen(),
    );
  }
}

class PodcastScreen extends StatefulWidget {
  const PodcastScreen({super.key});

  @override
  State<PodcastScreen> createState() => _PodcastScreenState();
}

class _PodcastScreenState extends State<PodcastScreen> {
  String _pdfText = '';
  Dialogue? _script;
  bool _isLoading = false;
  bool _isGeneratingAudio = false;
  String? _audioPath;
  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _isPlaying = false;
  WebSocketChannel? _channel;

  Future<void> _pickPDF() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf'],
        withData: true,
      );

      if (result != null && result.files.first.bytes != null) {
        final file = result.files.first;
        final bytes = file.bytes!;
        
        // Extract text from PDF
        final document = PdfDocument(inputBytes: bytes);
        final text = PdfTextExtractor(document).extractText();
        
        if (text.isNotEmpty) {
          setState(() {
            _pdfText = text;
            _script = null;
            _audioPath = null;
          });
        } else {
          throw Exception('Could not extract text from PDF');
        }
        document.dispose();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error reading PDF: $e')),
        );
      }
    }
  }

  Future<void> _generateScript() async {
    if (_pdfText.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a PDF first')),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      final togetherApiKey = dotenv.env['TOGETHER_API_KEY'];
      if (togetherApiKey == null) throw Exception('Together API key not found');

      final response = await http.post(
        Uri.parse('https://api.together.xyz/v1/chat/completions'),
        headers: {
          'Authorization': 'Bearer $togetherApiKey',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'model': 'meta-llama/Meta-Llama-3.1-70B-Instruct-Turbo',
          'messages': [
            {'role': 'system', 'content': systemPrompt},
            {'role': 'user', 'content': _pdfText}
          ],
          'response_format': {'type': 'json_object'}
        }),
      );

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        final content = json['choices']?[0]?['message']?['content'];
        if (content != null) {
          final scriptJson = jsonDecode(content);
          setState(() {
            _script = Dialogue.fromJson(scriptJson);
            _audioPath = null;
          });
        } else {
          throw Exception('Invalid response format from API');
        }
      } else {
        throw Exception('Failed to generate script: ${response.statusCode}');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _generatePodcast() async {
    if (_script == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please generate script first')),
      );
      return;
    }

    setState(() => _isGeneratingAudio = true);

    try {
      final cartesiaApiKey = dotenv.env['CARTESIA_API_KEY'];
      if (cartesiaApiKey == null) throw Exception('Cartesia API key not found');

      final tempDir = await getTemporaryDirectory();
      final outputFile = File('${tempDir.path}/podcast.mp3');

      // BytesBuilder to combine all audio segments
      final audioBuffer = BytesBuilder();

      // Process each line of dialogue
      for (var line in _script!.dialogue) {
        final response = await http.post(
          Uri.parse('https://api.cartesia.ai/tts/bytes'),
          headers: {
            'X-Api-Key': cartesiaApiKey,
            'Cartesia-Version': '2024-06-10',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'model_id': 'sonic-english',
            'transcript': line.text,
            'voice': {
              'mode': 'id',
              'id': line.speaker == 'Guest'
                  ? 'a0e99841-438c-4a64-b679-ae501e7d6091'
                  : '694f9389-aac1-45b6-b726-9d9369183238',
            },
            'output_format': {
              'container': 'mp3',
              'bit_rate': 128000,
              'sample_rate': 44100
            },
            'language': 'en'
          }),
        );

        if (response.statusCode == 200) {
          // Add audio bytes to buffer
          audioBuffer.add(response.bodyBytes);

          // Add a small delay to process the next line
          await Future.delayed(const Duration(milliseconds: 100));
        } else {
          throw Exception(
            'Failed to generate audio: ${response.statusCode}\n${response.body}',
          );
        }
      }

      // Write the complete audio file
      await outputFile.writeAsBytes(audioBuffer.takeBytes());

      setState(() {
        _audioPath = outputFile.path;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error generating audio: $e')),
        );
      }
    } finally {
      setState(() => _isGeneratingAudio = false);
    }
  }

  Future<void> _togglePlayback() async {
    if (_audioPath == null) return;

    try {
      if (_isPlaying) {
        await _audioPlayer.pause();
      } else {
        await _audioPlayer.play(DeviceFileSource(_audioPath!));
      }
      setState(() => _isPlaying = !_isPlaying);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error playing audio: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('PDF to Podcast'),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ElevatedButton.icon(
                onPressed: _isLoading ? null : _pickPDF,
                icon: const Icon(Icons.upload_file),
                label: Text(_pdfText.isEmpty ? 'Select PDF' : 'Change PDF'),
              ),
              if (_pdfText.isNotEmpty) ...[
                const SizedBox(height: 16),
                ElevatedButton.icon(
                  onPressed: _isLoading ? null : _generateScript,
                  icon: _isLoading 
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.description),
                  label: const Text('Generate Script'),
                ),
              ],
              if (_script != null) ...[
                const SizedBox(height: 16),
                ElevatedButton.icon(
                  onPressed: _isGeneratingAudio ? null : _generatePodcast,
                  icon: _isGeneratingAudio
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.record_voice_over),
                  label: const Text('Generate Podcast'),
                ),
              ],
              if (_audioPath != null) ...[
                const SizedBox(height: 16),
                ElevatedButton.icon(
                  onPressed: _togglePlayback,
                  icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
                  label: Text(_isPlaying ? 'Pause' : 'Play'),
                ),
              ],
              const SizedBox(height: 16),
              Expanded(
                child: _script != null
                    ? ListView.builder(
                        itemCount: _script!.dialogue.length,
                        itemBuilder: (context, index) {
                          final line = _script!.dialogue[index];
                          return Card(
                            child: ListTile(
                              leading: Icon(
                                line.speaker == 'Guest' 
                                    ? Icons.person 
                                    : Icons.mic,
                                color: line.speaker == 'Guest'
                                    ? Colors.blue
                                    : Colors.red,
                              ),
                              title: Text(
                                line.speaker,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              subtitle: Text(line.text),
                            ),
                          );
                        },
                      )
                    : const Center(
                        child: Text(
                          'Generate a script to see the dialogue here',
                          style: TextStyle(
                            color: Colors.grey,
                            fontSize: 16,
                          ),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    _channel?.sink.close();
    super.dispose();
  }
}

const String systemPrompt = '''
You are a world-class podcast producer tasked with transforming the provided input text into an engaging and informative podcast script. The input may be unstructured or messy, sourced from PDFs or web pages. Your goal is to extract the most interesting and insightful content for a compelling podcast discussion.

# Steps to Follow:

1. Analyze and identify key topics from the text
2. Create an engaging conversation between host (Jane) and guest
3. Keep responses natural and conversational
4. Include relevant examples and explanations
5. Maintain a balanced flow of information
6. End with key takeaways

Rules:
- Host (Jane) interviews the guest
- Keep responses concise (5-8 seconds)
- Use natural speech patterns
- Stay focused on key points
- Avoid technical jargon
- End with clear takeaways

Format as JSON with:
{
  "scratchpad": "your notes",
  "name_of_guest": "guest name",
  "dialogue": [
    {
      "speaker": "Host (Jane)" or "Guest",
      "text": "dialogue line"
    }
  ]
}
''';