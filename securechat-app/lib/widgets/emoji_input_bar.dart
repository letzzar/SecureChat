import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/foundation.dart' as foundation;
import 'package:flutter/material.dart';

/// Input bar shared by DM chat and room chat.
/// Shows an emoji picker panel when the emoji button is toggled.
class EmojiInputBar extends StatefulWidget {
  final TextEditingController controller;
  final VoidCallback onSend;
  final VoidCallback? onAttach;
  final bool sending;
  final String hintText;

  const EmojiInputBar({
    super.key,
    required this.controller,
    required this.onSend,
    this.onAttach,
    this.sending = false,
    this.hintText = 'Message',
  });

  @override
  State<EmojiInputBar> createState() => _EmojiInputBarState();
}

class _EmojiInputBarState extends State<EmojiInputBar> {
  bool _emojiOpen = false;
  final _focusNode = FocusNode();

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  void _toggleEmoji() {
    if (_emojiOpen) {
      setState(() => _emojiOpen = false);
      _focusNode.requestFocus();
    } else {
      _focusNode.unfocus();
      setState(() => _emojiOpen = true);
    }
  }

  void _onFieldTap() {
    if (_emojiOpen) setState(() => _emojiOpen = false);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SafeArea(
          bottom: !_emojiOpen,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              children: [
                IconButton(
                  icon: Icon(
                    _emojiOpen
                        ? Icons.keyboard_alt_outlined
                        : Icons.emoji_emotions_outlined,
                  ),
                  tooltip: _emojiOpen ? 'Keyboard' : 'Emoji',
                  onPressed: _toggleEmoji,
                ),
                if (widget.onAttach != null)
                  IconButton(
                    icon: const Icon(Icons.attach_file),
                    tooltip: 'Send file',
                    onPressed: widget.onAttach,
                  ),
                Expanded(
                  child: TextField(
                    controller: widget.controller,
                    focusNode: _focusNode,
                    minLines: 1,
                    maxLines: 5,
                    textInputAction: TextInputAction.newline,
                    onTap: _onFieldTap,
                    decoration: InputDecoration(
                      hintText: widget.hintText,
                      filled: true,
                      fillColor: cs.surfaceContainerHighest,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 10),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: widget.sending ? null : widget.onSend,
                  icon: widget.sending
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.send),
                ),
              ],
            ),
          ),
        ),
        if (_emojiOpen)
          SizedBox(
            height: 256,
            child: EmojiPicker(
              textEditingController: widget.controller,
              config: Config(
                height: 256,
                checkPlatformCompatibility: true,
                emojiViewConfig: EmojiViewConfig(
                  emojiSizeMax: 28 *
                      (foundation.defaultTargetPlatform ==
                              TargetPlatform.iOS
                          ? 1.2
                          : 1.0),
                ),
                skinToneConfig: const SkinToneConfig(),
                categoryViewConfig: CategoryViewConfig(
                  backgroundColor: cs.surface,
                  iconColor: cs.onSurfaceVariant,
                  iconColorSelected: cs.primary,
                  indicatorColor: cs.primary,
                ),
                bottomActionBarConfig: BottomActionBarConfig(
                  backgroundColor: cs.surface,
                  buttonColor: cs.primary,
                  buttonIconColor: cs.onPrimary,
                ),
                searchViewConfig: SearchViewConfig(
                  backgroundColor: cs.surface,
                  buttonIconColor: cs.primary,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
