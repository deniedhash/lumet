import 'package:flutter/material.dart';

/// One-time setup for the YouTube stream key.
///
/// A full-screen route rather than a dialog: the HUD is locked to landscape, and
/// in landscape the keyboard takes most of the screen — an AlertDialog ends up
/// with its own text field hidden behind the IME. Everything here is laid out
/// across the top so the keyboard covers only empty space.
///
/// Pops the entered key, or null when cancelled. An empty string means clear.
class StreamKeyEditor extends StatefulWidget {
  const StreamKeyEditor({super.key, this.initial});

  final String? initial;

  @override
  State<StreamKeyEditor> createState() => _StreamKeyEditorState();
}

class _StreamKeyEditorState extends State<StreamKeyEditor> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial ?? '');

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save(String value) => Navigator.of(context).pop(value);

  @override
  Widget build(BuildContext context) {
    final insets = MediaQuery.paddingOf(context);
    final side = insets.left > insets.right ? insets.left : insets.right;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        left: false,
        right: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(side + 28, 18, side + 28, 8),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'YOUTUBE STREAM KEY',
                  style: TextStyle(
                    color: Colors.white38,
                    fontSize: 12,
                    letterSpacing: 3,
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _controller,
                  autofocus: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  // Shown in plain text on purpose: the key arrives by paste, and
                  // seeing that the paste landed is worth more than masking a
                  // value from someone already holding the phone.
                  style: const TextStyle(color: Colors.white, fontSize: 22),
                  cursorColor: Colors.white54,
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: 'xxxx-xxxx-xxxx-xxxx-xxxx',
                    hintStyle: TextStyle(color: Colors.white12, fontSize: 22),
                    enabledBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: Colors.white24),
                    ),
                    focusedBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: Colors.white54),
                    ),
                  ),
                  onSubmitted: _save,
                ),
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Expanded(
                      child: Text(
                        'Studio → Go Live → Stream. Set the default visibility to '
                        'Unlisted there — the app never sends one, so that setting '
                        'is all that keeps drives off the public internet.',
                        style: TextStyle(
                          fontFamily: 'Roboto',
                          color: Colors.white38,
                          fontSize: 13,
                          height: 1.35,
                        ),
                      ),
                    ),
                    const SizedBox(width: 24),
                    if ((widget.initial ?? '').isNotEmpty)
                      TextButton(
                        onPressed: () => _save(''),
                        child: const Text(
                          'Clear',
                          style: TextStyle(color: Colors.white38),
                        ),
                      ),
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text(
                        'Cancel',
                        style: TextStyle(color: Colors.white38),
                      ),
                    ),
                    TextButton(
                      onPressed: () => _save(_controller.text),
                      child: const Text(
                        'Save',
                        style: TextStyle(color: Colors.white),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
