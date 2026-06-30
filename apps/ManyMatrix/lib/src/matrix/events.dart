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
