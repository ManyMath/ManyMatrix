import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/manymatrix_providers.dart';
import '../widgets/message_bubble.dart';

/// Chat timeline screen showing messages for a room with a send bar.
///
/// Displays room name in the app bar with a lock icon for encrypted
/// rooms. Message list scrolls newest-at-bottom. The send bar allows
/// typing and sending text messages.
class ChatScreen extends ConsumerStatefulWidget {
  final String roomId;

  const ChatScreen({super.key, required this.roomId});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _messageController = TextEditingController();
  bool _sending = false;
  Timer? _typingTimer;

  @override
  void initState() {
    super.initState();
    // Trigger a sync to get latest messages.
    Future.microtask(() => ref.read(syncProvider));
  }

  @override
  void dispose() {
    _messageController.dispose();
    _typingTimer?.cancel();
    super.dispose();
  }

  void _onTextChanged(String text) {
    final client = ref.read(matrixClientProvider);
    if (client == null) return;

    // Send typing indicator.
    client.sendTyping(widget.roomId, true);

    // Reset the idle timer.
    _typingTimer?.cancel();
    _typingTimer = Timer(const Duration(seconds: 3), () {
      client.sendTyping(widget.roomId, false);
    });
  }

  Future<void> _sendMessage() async {
    final body = _messageController.text.trim();
    if (body.isEmpty) return;

    setState(() => _sending = true);
    try {
      await performSendText(
        ref,
        roomId: widget.roomId,
        body: body,
      );
      _messageController.clear();
      // Stop typing indicator after send.
      _typingTimer?.cancel();
      final client = ref.read(matrixClientProvider);
      client?.sendTyping(widget.roomId, false);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Send failed: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _sending = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final roomName = ref.watch(roomNameProvider(widget.roomId));
    final messagesAsync = ref.watch(messagesProvider(widget.roomId));

    final currentUserId = ref.watch(currentUserIdProvider).value;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                roomName.value ?? 'Chat',
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 4),
            // Encryption indicator -- shown as a visual cue.
            // A full implementation would query room encryption state.
            const Icon(Icons.lock, size: 16),
          ],
        ),
      ),
      body: Column(
        children: [
          // Message list
          Expanded(
            child: messagesAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, stack) => Center(
                child: Text('Error loading messages:\n$error',
                    textAlign: TextAlign.center),
              ),
              data: (paginated) {
                final messages = paginated.messages;
                if (messages.isEmpty) {
                  return const Center(
                    child: Text('No messages yet'),
                  );
                }

                // Reverse the list so newest is at bottom.
                final reversed = messages.reversed.toList();

                return ListView.builder(
                  reverse: true,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: reversed.length,
                  itemBuilder: (context, index) {
                    final msg = reversed[index];
                    final isMe =
                        currentUserId != null && msg.sender == currentUserId;
                    return MessageBubble(
                      message: msg,
                      isMe: isMe,
                    );
                  },
                );
              },
            ),
          ),
          // Send bar
          Container(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              border: Border(
                top: BorderSide(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: SafeArea(
              top: false,
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _messageController,
                      onChanged: _onTextChanged,
                      decoration: InputDecoration(
                        hintText: 'Type a message...',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                      ),
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _sendMessage(),
                      enabled: !_sending,
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _sending ? null : _sendMessage,
                    icon: _sending
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                            ),
                          )
                        : const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
