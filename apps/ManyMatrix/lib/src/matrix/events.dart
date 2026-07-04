import 'dart:async';
import 'dart:convert';

import 'package:manymatrix/manymatrix.dart';

/// Parses one raw `onMessage` JSON payload into a [MessageEvent].
///
/// The callbacks fire from the Rust sync thread with whatever the server
/// delivered, so malformed or unexpected payloads are answered with null
/// rather than an exception.
MessageEvent? tryParseMessageEvent(String json) {
  try {
    final decoded = jsonDecode(json);
    if (decoded is! Map<String, dynamic>) return null;
    return MessageEvent.fromJson(decoded);
  } on Object {
    return null;
  }
}

/// Maps a stream of raw `onMessage` JSON strings to typed [MessageEvent]s,
/// silently dropping payloads that fail to parse.
Stream<MessageEvent> messageEventStream(Stream<String> raw) => raw
    .map(tryParseMessageEvent)
    .where((event) => event != null)
    .cast<MessageEvent>();

/// Parses one raw `onReaction` JSON payload into a [ReactionEvent].
ReactionEvent? tryParseReactionEvent(String json) {
  try {
    final decoded = jsonDecode(json);
    if (decoded is! Map<String, dynamic>) return null;
    return ReactionEvent.fromJson(decoded);
  } on Object {
    return null;
  }
}

/// Maps raw `onReaction` payloads to typed [ReactionEvent]s.
Stream<ReactionEvent> reactionEventStream(Stream<String> raw) => raw
    .map(tryParseReactionEvent)
    .where((event) => event != null)
    .cast<ReactionEvent>();

/// Parses one raw `onReceipt` JSON payload into a [ReceiptEvent].
ReceiptEvent? tryParseReceiptEvent(String json) {
  try {
    final decoded = jsonDecode(json);
    if (decoded is! Map<String, dynamic>) return null;
    return ReceiptEvent.fromJson(decoded);
  } on Object {
    return null;
  }
}

/// Maps raw `onReceipt` payloads to typed [ReceiptEvent]s.
Stream<ReceiptEvent> receiptEventStream(Stream<String> raw) => raw
    .map(tryParseReceiptEvent)
    .where((event) => event != null)
    .cast<ReceiptEvent>();
