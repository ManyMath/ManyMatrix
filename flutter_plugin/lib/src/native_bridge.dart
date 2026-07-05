import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../bridge/bindings.dart';
import 'models/models.dart';

/// Initialization data sent to the worker isolate.
class _WorkerInit {
  final String libraryPath;
  final SendPort sendPort;
  _WorkerInit(this.libraryPath, this.sendPort);
}

/// Request sent to the worker isolate for FFI execution.
class _FfiRequest {
  final String method;
  final Map<String, dynamic> args;
  final SendPort replyPort;
  _FfiRequest(this.method, this.args, this.replyPort);
}

/// Response from the worker isolate.
class _FfiResponse {
  final dynamic data;
  final String? error;
  _FfiResponse.success(this.data) : error = null;
  _FfiResponse.failure(this.error) : data = null;
}

/// Dart wrapper around the Rust FFI layer.
///
/// Worker isolate for blocking FFI calls, NativeCallable.listener for
/// callbacks from Rust threads, NativeFinalizer for memory management.
class ManyMatrixBridge implements ffi.Finalizable {
  // ignore: unused_field
  static late String _libraryPath;
  static late SendPort _workerPort;
  static bool _initialized = false;

  // Main isolate bindings -- used for dispose(), NativeFinalizer, and callbacks
  static late ManyMatrixBindings _mainBindings;
  static late ffi.NativeFinalizer _finalizer;

  final ffi.Pointer<ManyMatrixClient> _handle;
  final int _handleAddress;

  ManyMatrixBridge._(this._handle, this._handleAddress) {
    _finalizer.attach(this, _handle.cast(), detach: this);
  }

  /// Initialize the bridge with the path to the native library.
  ///
  /// This spawns a long-lived worker isolate that handles all blocking FFI calls.
  /// Must be called once before any other operations.
  static Future<void> initialize(String libraryPath) async {
    if (_initialized) return;

    _libraryPath = libraryPath;

    // Open library on main isolate for NativeFinalizer and dispose(). An
    // empty path means the symbols are force-linked into the executable
    // itself (macOS/iOS Runner via -force_load, see platform Podfiles)
    // rather than shipped as a standalone .so/.dylib/.dll.
    final lib = libraryPath.isEmpty
        ? ffi.DynamicLibrary.process()
        : ffi.DynamicLibrary.open(libraryPath);
    _mainBindings = ManyMatrixBindings(lib);

    // Set up NativeFinalizer using the manymatrix_free function pointer
    final freePtr = lib.lookup<
        ffi.NativeFunction<ffi.Void Function(ffi.Pointer<ManyMatrixClient>)>>(
      'manymatrix_free',
    );
    _finalizer = ffi.NativeFinalizer(freePtr.cast());

    // Spawn worker isolate
    final initPort = ReceivePort();
    await Isolate.spawn(
      _workerEntryPoint,
      _WorkerInit(libraryPath, initPort.sendPort),
    );
    _workerPort = await initPort.first as SendPort;
    _initialized = true;
  }

  /// Worker isolate entry point.
  ///
  /// Runs in its own isolate with its own DynamicLibrary and bindings instance.
  /// Listens for _FfiRequest messages and executes the corresponding FFI call.
  static void _workerEntryPoint(_WorkerInit init) {
    final lib = init.libraryPath.isEmpty
        ? ffi.DynamicLibrary.process()
        : ffi.DynamicLibrary.open(init.libraryPath);
    final bindings = ManyMatrixBindings(lib);
    final port = ReceivePort();
    init.sendPort.send(port.sendPort);

    port.listen((message) {
      if (message is _FfiRequest) {
        try {
          final result = _executeFFI(bindings, message.method, message.args);
          message.replyPort.send(_FfiResponse.success(result));
        } catch (e) {
          message.replyPort.send(_FfiResponse.failure(e.toString()));
        }
      }
    });
  }

  /// Dispatch a single FFI call by method name.
  static dynamic _executeFFI(
    ManyMatrixBindings bindings,
    String method,
    Map<String, dynamic> args,
  ) {
    switch (method) {
      case 'client_new':
        return _execClientNew(bindings, args);
      case 'login':
        return _execWithHandleAndStrings(bindings, method, args);
      case 'restore':
        return _execWithHandleAndStrings(bindings, method, args);
      case 'sync_once':
        return _execHandleOnly(bindings, method, args);
      case 'sync_forever':
        return _execHandleOnly(bindings, method, args);
      case 'joined_rooms':
        return _execHandleOnly(bindings, method, args);
      case 'server_capabilities':
        return _execHandleOnly(bindings, method, args);
      case 'logout':
        return _execHandleOnly(bindings, method, args);
      case 'sync_token':
        return _execHandleOnly(bindings, method, args);
      case 'whoami':
        return _execHandleOnly(bindings, method, args);
      case 'is_room_encrypted':
        return _execWithHandleAndOneString(bindings, method, args);
      case 'create_room':
        return _execCreateRoom(bindings, args);
      case 'join_room':
        return _execWithHandleAndOneString(bindings, method, args);
      case 'invite':
        return _execWithHandleAndTwoStrings(bindings, method, args);
      case 'leave_room':
        return _execWithHandleAndOneString(bindings, method, args);
      case 'kick':
        return _execKickBan(bindings, method, args);
      case 'ban':
        return _execKickBan(bindings, method, args);
      case 'room_name':
        return _execWithHandleAndOneString(bindings, method, args);
      case 'room_topic':
        return _execWithHandleAndOneString(bindings, method, args);
      case 'room_avatar_url':
        return _execWithHandleAndOneString(bindings, method, args);
      case 'room_members':
        return _execWithHandleAndOneString(bindings, method, args);
      case 'send_text':
        return _execWithHandleAndTwoStrings(bindings, method, args);
      case 'send_html':
        return _execSendHtml(bindings, args);
      case 'send_notice':
        return _execWithHandleAndTwoStrings(bindings, method, args);
      case 'send_emote':
        return _execWithHandleAndTwoStrings(bindings, method, args);
      case 'edit_message':
        return _execWithHandleAndThreeStrings(bindings, method, args);
      case 'reply_to':
        return _execWithHandleAndThreeStrings(bindings, method, args);
      case 'send_reaction':
        return _execWithHandleAndThreeStrings(bindings, method, args);
      case 'redact':
        return _execRedact(bindings, args);
      case 'send_thread_reply':
        return _execWithHandleAndThreeStrings(bindings, method, args);
      case 'send_custom_event':
        return _execWithHandleAndThreeStrings(bindings, method, args);
      case 'send_read_receipt':
        return _execWithHandleAndTwoStrings(bindings, method, args);
      case 'send_typing':
        return _execSendTyping(bindings, args);
      case 'get_messages':
        return _execGetMessages(bindings, args);
      case 'enable_encryption':
        return _execWithHandleAndOneString(bindings, method, args);
      case 'start_verification':
        return _execWithHandleAndTwoStrings(bindings, method, args);
      case 'accept_verification':
        return _execWithHandleAndTwoStrings(bindings, method, args);
      case 'start_sas':
        return _execWithHandleAndTwoStrings(bindings, method, args);
      case 'accept_sas':
        return _execWithHandleAndTwoStrings(bindings, method, args);
      case 'get_sas_emojis':
        return _execWithHandleAndTwoStrings(bindings, method, args);
      case 'confirm_sas':
        return _execWithHandleAndTwoStrings(bindings, method, args);
      case 'cancel_verification':
        return _execWithHandleAndTwoStrings(bindings, method, args);
      case 'bootstrap_cross_signing':
        return _execHandleOnly(bindings, method, args);
      case 'setup_key_backup':
        return _execHandleOnly(bindings, method, args);
      case 'restore_key_backup':
        return _execWithHandleAndOneString(bindings, method, args);
      case 'enable_recovery':
        return _execHandleOnly(bindings, method, args);
      case 'wait_for_backup_upload':
        return _execHandleOnly(bindings, method, args);
      case 'upload_media':
        return _execUploadMedia(bindings, args);
      case 'download_media':
        return _execDownloadMedia(bindings, args);
      case 'get_thumbnail':
        return _execGetThumbnail(bindings, args);
      case 'register_pusher':
        return _execRegisterPusher(bindings, args);
      default:
        throw Exception('Unknown FFI method: $method');
    }
  }

  // --- FFI dispatch helpers ---

  static int _execClientNew(
      ManyMatrixBindings bindings, Map<String, dynamic> args) {
    final url = (args['homeserver_url'] as String).toNativeUtf8();
    final path = (args['store_path'] as String).toNativeUtf8();
    try {
      final result = bindings.manymatrix_new(url.cast(), path.cast());
      _checkResult(bindings, result);
      final address = result.data.address;
      return address;
    } finally {
      calloc.free(url);
      calloc.free(path);
    }
  }

  static String? _execHandleOnly(
    ManyMatrixBindings bindings,
    String method,
    Map<String, dynamic> args,
  ) {
    final handle =
        ffi.Pointer<ManyMatrixClient>.fromAddress(args['handle'] as int);
    final FfiResult result;
    switch (method) {
      case 'sync_once':
        result = bindings.manymatrix_sync_once(handle);
      case 'sync_forever':
        result = bindings.manymatrix_sync_forever(handle);
      case 'joined_rooms':
        result = bindings.manymatrix_joined_rooms(handle);
      case 'server_capabilities':
        result = bindings.manymatrix_server_capabilities(handle);
      case 'logout':
        result = bindings.manymatrix_logout(handle);
      case 'sync_token':
        result = bindings.manymatrix_sync_token(handle);
      case 'whoami':
        result = bindings.manymatrix_whoami(handle);
      case 'bootstrap_cross_signing':
        result = bindings.manymatrix_bootstrap_cross_signing(handle);
      case 'setup_key_backup':
        result = bindings.manymatrix_setup_key_backup(handle);
      case 'enable_recovery':
        result = bindings.manymatrix_enable_recovery(handle);
      case 'wait_for_backup_upload':
        result = bindings.manymatrix_wait_for_backup_upload(handle);
      default:
        throw Exception('Unknown handle-only method: $method');
    }
    return _extractStringResult(bindings, result);
  }

  static String? _execWithHandleAndStrings(
    ManyMatrixBindings bindings,
    String method,
    Map<String, dynamic> args,
  ) {
    final handle =
        ffi.Pointer<ManyMatrixClient>.fromAddress(args['handle'] as int);
    switch (method) {
      case 'login':
        final username = (args['username'] as String).toNativeUtf8();
        final password = (args['password'] as String).toNativeUtf8();
        try {
          final result = bindings.manymatrix_login(
            handle,
            username.cast(),
            password.cast(),
          );
          return _extractStringResult(bindings, result);
        } finally {
          calloc.free(username);
          calloc.free(password);
        }
      case 'restore':
        final sessionJson = (args['session_json'] as String).toNativeUtf8();
        try {
          final result =
              bindings.manymatrix_restore(handle, sessionJson.cast());
          return _extractStringResult(bindings, result);
        } finally {
          calloc.free(sessionJson);
        }
      default:
        throw Exception('Unknown method: $method');
    }
  }

  static String? _execWithHandleAndOneString(
    ManyMatrixBindings bindings,
    String method,
    Map<String, dynamic> args,
  ) {
    final handle =
        ffi.Pointer<ManyMatrixClient>.fromAddress(args['handle'] as int);
    final s1 = (args['s1'] as String).toNativeUtf8();
    try {
      final FfiResult result;
      switch (method) {
        case 'join_room':
          result = bindings.manymatrix_join_room(handle, s1.cast());
        case 'leave_room':
          result = bindings.manymatrix_leave_room(handle, s1.cast());
        case 'room_name':
          result = bindings.manymatrix_room_name(handle, s1.cast());
        case 'room_topic':
          result = bindings.manymatrix_room_topic(handle, s1.cast());
        case 'room_avatar_url':
          result = bindings.manymatrix_room_avatar_url(handle, s1.cast());
        case 'room_members':
          result = bindings.manymatrix_room_members(handle, s1.cast());
        case 'is_room_encrypted':
          result = bindings.manymatrix_is_room_encrypted(handle, s1.cast());
        case 'enable_encryption':
          result = bindings.manymatrix_enable_encryption(handle, s1.cast());
        case 'restore_key_backup':
          result = bindings.manymatrix_restore_key_backup(handle, s1.cast());
        default:
          throw Exception('Unknown one-string method: $method');
      }
      return _extractStringResult(bindings, result);
    } finally {
      calloc.free(s1);
    }
  }

  static String? _execWithHandleAndTwoStrings(
    ManyMatrixBindings bindings,
    String method,
    Map<String, dynamic> args,
  ) {
    final handle =
        ffi.Pointer<ManyMatrixClient>.fromAddress(args['handle'] as int);
    final s1 = (args['s1'] as String).toNativeUtf8();
    final s2 = (args['s2'] as String).toNativeUtf8();
    try {
      final FfiResult result;
      switch (method) {
        case 'invite':
          result = bindings.manymatrix_invite(handle, s1.cast(), s2.cast());
        case 'send_text':
          result = bindings.manymatrix_send_text(handle, s1.cast(), s2.cast());
        case 'send_notice':
          result =
              bindings.manymatrix_send_notice(handle, s1.cast(), s2.cast());
        case 'send_emote':
          result = bindings.manymatrix_send_emote(handle, s1.cast(), s2.cast());
        case 'send_read_receipt':
          result = bindings.manymatrix_send_read_receipt(
              handle, s1.cast(), s2.cast());
        case 'start_verification':
          result = bindings.manymatrix_start_verification(
              handle, s1.cast(), s2.cast());
        case 'accept_verification':
          result = bindings.manymatrix_accept_verification(
              handle, s1.cast(), s2.cast());
        case 'start_sas':
          result = bindings.manymatrix_start_sas(handle, s1.cast(), s2.cast());
        case 'accept_sas':
          result = bindings.manymatrix_accept_sas(handle, s1.cast(), s2.cast());
        case 'get_sas_emojis':
          result =
              bindings.manymatrix_get_sas_emojis(handle, s1.cast(), s2.cast());
        case 'confirm_sas':
          result =
              bindings.manymatrix_confirm_sas(handle, s1.cast(), s2.cast());
        case 'cancel_verification':
          result = bindings.manymatrix_cancel_verification(
              handle, s1.cast(), s2.cast());
        default:
          throw Exception('Unknown two-string method: $method');
      }
      return _extractStringResult(bindings, result);
    } finally {
      calloc.free(s1);
      calloc.free(s2);
    }
  }

  static String? _execWithHandleAndThreeStrings(
    ManyMatrixBindings bindings,
    String method,
    Map<String, dynamic> args,
  ) {
    final handle =
        ffi.Pointer<ManyMatrixClient>.fromAddress(args['handle'] as int);
    final s1 = (args['s1'] as String).toNativeUtf8();
    final s2 = (args['s2'] as String).toNativeUtf8();
    final s3 = (args['s3'] as String).toNativeUtf8();
    try {
      final FfiResult result;
      switch (method) {
        case 'edit_message':
          result = bindings.manymatrix_edit_message(
            handle,
            s1.cast(),
            s2.cast(),
            s3.cast(),
          );
        case 'reply_to':
          result = bindings.manymatrix_reply_to(
            handle,
            s1.cast(),
            s2.cast(),
            s3.cast(),
          );
        case 'send_reaction':
          result = bindings.manymatrix_send_reaction(
            handle,
            s1.cast(),
            s2.cast(),
            s3.cast(),
          );
        case 'send_thread_reply':
          result = bindings.manymatrix_send_thread_reply(
            handle,
            s1.cast(),
            s2.cast(),
            s3.cast(),
          );
        case 'send_custom_event':
          result = bindings.manymatrix_send_custom_event(
            handle,
            s1.cast(),
            s2.cast(),
            s3.cast(),
          );
        default:
          throw Exception('Unknown three-string method: $method');
      }
      return _extractStringResult(bindings, result);
    } finally {
      calloc.free(s1);
      calloc.free(s2);
      calloc.free(s3);
    }
  }

  static String? _execCreateRoom(
    ManyMatrixBindings bindings,
    Map<String, dynamic> args,
  ) {
    final handle =
        ffi.Pointer<ManyMatrixClient>.fromAddress(args['handle'] as int);
    final name = args['name'] as String?;
    final topic = args['topic'] as String?;
    final namePtr = name?.toNativeUtf8() ?? ffi.nullptr;
    final topicPtr = topic?.toNativeUtf8() ?? ffi.nullptr;
    try {
      final result = bindings.manymatrix_create_room(
        handle,
        namePtr.cast(),
        topicPtr.cast(),
      );
      return _extractStringResult(bindings, result);
    } finally {
      if (name != null) calloc.free(namePtr);
      if (topic != null) calloc.free(topicPtr);
    }
  }

  static String? _execKickBan(
    ManyMatrixBindings bindings,
    String method,
    Map<String, dynamic> args,
  ) {
    final handle =
        ffi.Pointer<ManyMatrixClient>.fromAddress(args['handle'] as int);
    final roomId = (args['s1'] as String).toNativeUtf8();
    final userId = (args['s2'] as String).toNativeUtf8();
    final reason = args['reason'] as String?;
    final reasonPtr = reason?.toNativeUtf8() ?? ffi.nullptr;
    try {
      final FfiResult result;
      if (method == 'kick') {
        result = bindings.manymatrix_kick(
          handle,
          roomId.cast(),
          userId.cast(),
          reasonPtr.cast(),
        );
      } else {
        result = bindings.manymatrix_ban(
          handle,
          roomId.cast(),
          userId.cast(),
          reasonPtr.cast(),
        );
      }
      return _extractStringResult(bindings, result);
    } finally {
      calloc.free(roomId);
      calloc.free(userId);
      if (reason != null) calloc.free(reasonPtr);
    }
  }

  static String? _execSendHtml(
    ManyMatrixBindings bindings,
    Map<String, dynamic> args,
  ) {
    final handle =
        ffi.Pointer<ManyMatrixClient>.fromAddress(args['handle'] as int);
    final roomId = (args['s1'] as String).toNativeUtf8();
    final body = (args['s2'] as String).toNativeUtf8();
    final html = (args['s3'] as String).toNativeUtf8();
    try {
      final result = bindings.manymatrix_send_html(
        handle,
        roomId.cast(),
        body.cast(),
        html.cast(),
      );
      return _extractStringResult(bindings, result);
    } finally {
      calloc.free(roomId);
      calloc.free(body);
      calloc.free(html);
    }
  }

  static String? _execRedact(
    ManyMatrixBindings bindings,
    Map<String, dynamic> args,
  ) {
    final handle =
        ffi.Pointer<ManyMatrixClient>.fromAddress(args['handle'] as int);
    final roomId = (args['s1'] as String).toNativeUtf8();
    final eventId = (args['s2'] as String).toNativeUtf8();
    final reason = args['reason'] as String?;
    final reasonPtr = reason?.toNativeUtf8() ?? ffi.nullptr;
    try {
      final result = bindings.manymatrix_redact(
        handle,
        roomId.cast(),
        eventId.cast(),
        reasonPtr.cast(),
      );
      return _extractStringResult(bindings, result);
    } finally {
      calloc.free(roomId);
      calloc.free(eventId);
      if (reason != null) calloc.free(reasonPtr);
    }
  }

  static String? _execSendTyping(
    ManyMatrixBindings bindings,
    Map<String, dynamic> args,
  ) {
    final handle =
        ffi.Pointer<ManyMatrixClient>.fromAddress(args['handle'] as int);
    final roomId = (args['s1'] as String).toNativeUtf8();
    final typing = args['typing'] as bool;
    try {
      final result = bindings.manymatrix_send_typing(
        handle,
        roomId.cast(),
        typing,
      );
      return _extractStringResult(bindings, result);
    } finally {
      calloc.free(roomId);
    }
  }

  static String? _execGetMessages(
    ManyMatrixBindings bindings,
    Map<String, dynamic> args,
  ) {
    final handle =
        ffi.Pointer<ManyMatrixClient>.fromAddress(args['handle'] as int);
    final roomId = (args['s1'] as String).toNativeUtf8();
    final fromToken = args['from_token'] as String?;
    final fromTokenPtr = fromToken?.toNativeUtf8() ?? ffi.nullptr;
    final limit = args['limit'] as int;
    try {
      final result = bindings.manymatrix_get_messages(
        handle,
        roomId.cast(),
        fromTokenPtr.cast(),
        limit,
      );
      return _extractStringResult(bindings, result);
    } finally {
      calloc.free(roomId);
      if (fromToken != null) calloc.free(fromTokenPtr);
    }
  }

  static String? _execUploadMedia(
    ManyMatrixBindings bindings,
    Map<String, dynamic> args,
  ) {
    final handle =
        ffi.Pointer<ManyMatrixClient>.fromAddress(args['handle'] as int);
    final roomId = (args['room_id'] as String).toNativeUtf8();
    final filename = (args['filename'] as String).toNativeUtf8();
    final mimeType = (args['mime_type'] as String).toNativeUtf8();
    final dataBytes = args['data'] as List<int>;
    final dataPtr = calloc<ffi.Uint8>(dataBytes.length);
    for (var i = 0; i < dataBytes.length; i++) {
      dataPtr[i] = dataBytes[i];
    }
    try {
      final result = bindings.manymatrix_upload_media(
        handle,
        roomId.cast(),
        filename.cast(),
        mimeType.cast(),
        dataPtr,
        dataBytes.length,
      );
      return _extractStringResult(bindings, result);
    } finally {
      calloc.free(roomId);
      calloc.free(filename);
      calloc.free(mimeType);
      calloc.free(dataPtr);
    }
  }

  static List<int>? _execDownloadMedia(
    ManyMatrixBindings bindings,
    Map<String, dynamic> args,
  ) {
    final handle =
        ffi.Pointer<ManyMatrixClient>.fromAddress(args['handle'] as int);
    final mxcUri = (args['mxc_uri'] as String).toNativeUtf8();
    try {
      final result = bindings.manymatrix_download_media(handle, mxcUri.cast());
      _checkResult(bindings, result);
      if (result.data == ffi.nullptr) return null;
      final bufPtr = result.data.cast<FfiBuffer>();
      final buf = bufPtr.ref;
      final bytes = buf.data.cast<ffi.Uint8>().asTypedList(buf.len);
      final copy = Uint8List.fromList(bytes);
      bindings.ffi_free_buffer(buf);
      return copy;
    } finally {
      calloc.free(mxcUri);
    }
  }

  static List<int>? _execGetThumbnail(
    ManyMatrixBindings bindings,
    Map<String, dynamic> args,
  ) {
    final handle =
        ffi.Pointer<ManyMatrixClient>.fromAddress(args['handle'] as int);
    final mxcUri = (args['mxc_uri'] as String).toNativeUtf8();
    final width = args['width'] as int;
    final height = args['height'] as int;
    try {
      final result = bindings.manymatrix_get_thumbnail(
        handle,
        mxcUri.cast(),
        width,
        height,
      );
      _checkResult(bindings, result);
      if (result.data == ffi.nullptr) return null;
      final bufPtr = result.data.cast<FfiBuffer>();
      final buf = bufPtr.ref;
      final bytes = buf.data.cast<ffi.Uint8>().asTypedList(buf.len);
      final copy = Uint8List.fromList(bytes);
      bindings.ffi_free_buffer(buf);
      return copy;
    } finally {
      calloc.free(mxcUri);
    }
  }

  static String? _execRegisterPusher(
    ManyMatrixBindings bindings,
    Map<String, dynamic> args,
  ) {
    final handle =
        ffi.Pointer<ManyMatrixClient>.fromAddress(args['handle'] as int);
    final appId = (args['app_id'] as String).toNativeUtf8();
    final pushKey = (args['push_key'] as String).toNativeUtf8();
    final appDisplayName = (args['app_display_name'] as String).toNativeUtf8();
    final deviceDisplayName =
        (args['device_display_name'] as String).toNativeUtf8();
    final pushUrl = (args['push_url'] as String).toNativeUtf8();
    final lang = (args['lang'] as String).toNativeUtf8();
    try {
      final result = bindings.manymatrix_register_pusher(
        handle,
        appId.cast(),
        pushKey.cast(),
        appDisplayName.cast(),
        deviceDisplayName.cast(),
        pushUrl.cast(),
        lang.cast(),
      );
      return _extractStringResult(bindings, result);
    } finally {
      calloc.free(appId);
      calloc.free(pushKey);
      calloc.free(appDisplayName);
      calloc.free(deviceDisplayName);
      calloc.free(pushUrl);
      calloc.free(lang);
    }
  }

  // --- Result helpers ---

  static void _checkResult(ManyMatrixBindings bindings, FfiResult result) {
    if (!result.ok) {
      final errorMsg = result.error_msg == ffi.nullptr
          ? 'Unknown FFI error'
          : result.error_msg.cast<Utf8>().toDartString();
      bindings.ffi_free_result(result);
      throw Exception(errorMsg);
    }
  }

  static String? _extractStringResult(
    ManyMatrixBindings bindings,
    FfiResult result,
  ) {
    _checkResult(bindings, result);
    if (result.data == ffi.nullptr) return null;
    final str = result.data.cast<Utf8>().toDartString();
    bindings.ffi_free_string(result.data.cast());
    return str;
  }

  // --- Worker isolate communication ---

  Future<dynamic> _call(String method, Map<String, dynamic> args) async {
    assert(_initialized, 'ManyMatrixBridge.initialize() must be called first');
    final replyPort = ReceivePort();
    _workerPort.send(_FfiRequest(
      method,
      {...args, 'handle': _handleAddress},
      replyPort.sendPort,
    ));
    final response = await replyPort.first as _FfiResponse;
    replyPort.close();
    if (response.error != null) throw Exception(response.error);
    return response.data;
  }

  // === Public API ===

  /// Create a new ManyMatrixClient connected to the given homeserver.
  static Future<ManyMatrixBridge> create(
    String homeserverUrl,
    String storePath,
  ) async {
    assert(_initialized, 'ManyMatrixBridge.initialize() must be called first');
    final replyPort = ReceivePort();
    _workerPort.send(_FfiRequest(
      'client_new',
      {'homeserver_url': homeserverUrl, 'store_path': storePath},
      replyPort.sendPort,
    ));
    final response = await replyPort.first as _FfiResponse;
    replyPort.close();
    if (response.error != null) throw Exception(response.error);
    final address = response.data as int;
    return ManyMatrixBridge._(
      ffi.Pointer<ManyMatrixClient>.fromAddress(address),
      address,
    );
  }

  /// Login with username and password. Returns JSON session string.
  Future<String> login(String username, String password) async {
    final result = await _call('login', {
      'username': username,
      'password': password,
    });
    return result as String;
  }

  /// Restore a previously saved session from JSON.
  Future<void> restore(String sessionJson) async {
    await _call('restore', {'session_json': sessionJson});
  }

  /// Perform a single sync round.
  Future<void> syncOnce() async {
    await _call('sync_once', {});
  }

  /// Start the continuous sync loop in a background thread.
  Future<void> syncForever() async {
    final syncStatusCallable = _syncStatusCallable;
    if (syncStatusCallable == null) {
      await _call('sync_forever', {});
      return;
    }
    final result = _mainBindings.manymatrix_sync_forever_with_status(
      _handle,
      syncStatusCallable.nativeFunction,
    );
    _checkResult(_mainBindings, result);
  }

  /// Get the list of joined rooms as parsed RoomSummary objects.
  Future<List<RoomSummary>> joinedRooms() async {
    final json = await _call('joined_rooms', {}) as String?;
    if (json == null) return [];
    final list = jsonDecode(json) as List<dynamic>;
    return list
        .map((e) => RoomSummary.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Get Matrix server version and capability data as JSON.
  Future<String> serverCapabilities() async {
    final result = await _call('server_capabilities', {});
    return result as String;
  }

  /// Logout and invalidate the server token.
  Future<void> logout() async {
    await _call('logout', {});
  }

  /// Get the current sync token, if any.
  Future<String?> syncToken() async {
    return await _call('sync_token', {}) as String?;
  }

  /// Get the currently logged-in user's Matrix ID.
  Future<String?> whoami() async {
    return await _call('whoami', {}) as String?;
  }

  /// Create a new room with optional name and topic.
  Future<String> createRoom({String? name, String? topic}) async {
    final result = await _call('create_room', {
      'name': name,
      'topic': topic,
    });
    return result as String;
  }

  /// Join a room by ID or alias.
  Future<String> joinRoom(String roomIdOrAlias) async {
    final result = await _call('join_room', {'s1': roomIdOrAlias});
    return result as String;
  }

  /// Invite a user to a room.
  Future<void> invite(String roomId, String userId) async {
    await _call('invite', {'s1': roomId, 's2': userId});
  }

  /// Leave a room.
  Future<void> leaveRoom(String roomId) async {
    await _call('leave_room', {'s1': roomId});
  }

  /// Kick a user from a room with optional reason.
  Future<void> kick(String roomId, String userId, {String? reason}) async {
    await _call('kick', {'s1': roomId, 's2': userId, 'reason': reason});
  }

  /// Ban a user from a room with optional reason.
  Future<void> ban(String roomId, String userId, {String? reason}) async {
    await _call('ban', {'s1': roomId, 's2': userId, 'reason': reason});
  }

  /// Get a room's display name.
  Future<String?> roomName(String roomId) async {
    return await _call('room_name', {'s1': roomId}) as String?;
  }

  /// Get a room's topic.
  Future<String?> roomTopic(String roomId) async {
    return await _call('room_topic', {'s1': roomId}) as String?;
  }

  /// Get a room's avatar URL (mxc:// URI).
  Future<String?> roomAvatarUrl(String roomId) async {
    return await _call('room_avatar_url', {'s1': roomId}) as String?;
  }

  /// Get the list of joined member user IDs for a room (JSON array string).
  Future<String?> roomMembers(String roomId) async {
    return await _call('room_members', {'s1': roomId}) as String?;
  }

  /// Check whether a room has encryption enabled.
  Future<bool> isRoomEncrypted(String roomId) async {
    final result = await _call('is_room_encrypted', {'s1': roomId}) as String?;
    return result == 'true';
  }

  /// Send a plain-text message. Returns event ID.
  Future<String> sendText(String roomId, String body) async {
    final result = await _call('send_text', {'s1': roomId, 's2': body});
    return result as String;
  }

  /// Send a message-like event of an arbitrary [eventType] with arbitrary JSON
  /// [content] to a room. Returns the event ID.
  ///
  /// Unlike [sendText]/[sendReaction]/etc, this is not limited to this plugin's fixed
  /// message shapes: use it for an app-specific event type (e.g. `io.example.foo`)
  /// with its own content schema. Pair with [onCustomEvent] to receive it.
  Future<String> sendCustomEvent(
    String roomId,
    String eventType,
    Map<String, dynamic> content,
  ) async {
    final result = await _call('send_custom_event', {
      's1': roomId,
      's2': eventType,
      's3': jsonEncode(content),
    });
    return result as String;
  }

  /// Send a formatted HTML message. Returns event ID.
  Future<String> sendHtml(String roomId, String body, String html) async {
    final result = await _call('send_html', {
      's1': roomId,
      's2': body,
      's3': html,
    });
    return result as String;
  }

  /// Send a notice message. Returns event ID.
  Future<String> sendNotice(String roomId, String body) async {
    final result = await _call('send_notice', {'s1': roomId, 's2': body});
    return result as String;
  }

  /// Send an emote message (/me action). Returns event ID.
  Future<String> sendEmote(String roomId, String body) async {
    final result = await _call('send_emote', {'s1': roomId, 's2': body});
    return result as String;
  }

  /// Edit a previously sent message.
  Future<void> editMessage(
      String roomId, String eventId, String newBody) async {
    await _call('edit_message', {'s1': roomId, 's2': eventId, 's3': newBody});
  }

  /// Reply to a message. Returns event ID.
  Future<String> replyTo(String roomId, String eventId, String body) async {
    final result = await _call('reply_to', {
      's1': roomId,
      's2': eventId,
      's3': body,
    });
    return result as String;
  }

  /// Send a reaction emoji to an event. Returns event ID.
  Future<String> sendReaction(String roomId, String eventId, String key) async {
    final result = await _call('send_reaction', {
      's1': roomId,
      's2': eventId,
      's3': key,
    });
    return result as String;
  }

  /// Redact (delete) an event with optional reason.
  Future<void> redact(String roomId, String eventId, {String? reason}) async {
    await _call('redact', {'s1': roomId, 's2': eventId, 'reason': reason});
  }

  /// Send a threaded reply. Returns event ID.
  Future<String> sendThreadReply(
    String roomId,
    String threadRootId,
    String body,
  ) async {
    final result = await _call('send_thread_reply', {
      's1': roomId,
      's2': threadRootId,
      's3': body,
    });
    return result as String;
  }

  /// Send a read receipt for an event.
  Future<void> sendReadReceipt(String roomId, String eventId) async {
    await _call('send_read_receipt', {'s1': roomId, 's2': eventId});
  }

  /// Send a typing indicator.
  Future<void> sendTyping(String roomId, bool typing) async {
    await _call('send_typing', {'s1': roomId, 'typing': typing});
  }

  /// Load messages from a room with backward pagination.
  Future<PaginatedMessages> getMessages(
    String roomId, {
    String? fromToken,
    int limit = 20,
  }) async {
    final json = await _call('get_messages', {
      's1': roomId,
      'from_token': fromToken,
      'limit': limit,
    }) as String?;
    if (json == null) {
      return PaginatedMessages(messages: []);
    }
    return PaginatedMessages.fromJson(
      jsonDecode(json) as Map<String, dynamic>,
    );
  }

  /// Enable end-to-end encryption on a room.
  Future<void> enableEncryption(String roomId) async {
    await _call('enable_encryption', {'s1': roomId});
  }

  /// Start SAS device verification. Returns flow ID.
  Future<String> startVerification(String userId, String deviceId) async {
    final result = await _call('start_verification', {
      's1': userId,
      's2': deviceId,
    });
    return result as String;
  }

  /// Accept an incoming SAS verification request.
  Future<void> acceptVerification(String userId, String flowId) async {
    await _call('accept_verification', {'s1': userId, 's2': flowId});
  }

  /// Transition an accepted verification request into a SAS flow.
  /// Called by the party that initiated verification.
  Future<void> startSas(String userId, String flowId) async {
    await _call('start_sas', {'s1': userId, 's2': flowId});
  }

  /// Accept an in-progress SAS flow so short auth strings can be shown.
  /// Called by the other party, after `startSas`.
  Future<void> acceptSas(String userId, String flowId) async {
    await _call('accept_sas', {'s1': userId, 's2': flowId});
  }

  /// Get SAS emojis for visual comparison. Returns JSON string.
  Future<String> getSasEmojis(String userId, String flowId) async {
    final result = await _call('get_sas_emojis', {
      's1': userId,
      's2': flowId,
    });
    return result as String;
  }

  /// Confirm SAS verification after comparing emojis.
  Future<void> confirmSas(String userId, String flowId) async {
    await _call('confirm_sas', {'s1': userId, 's2': flowId});
  }

  /// Cancel an ongoing verification flow.
  Future<void> cancelVerification(String userId, String flowId) async {
    await _call('cancel_verification', {'s1': userId, 's2': flowId});
  }

  /// Bootstrap cross-signing keys.
  Future<void> bootstrapCrossSigning() async {
    await _call('bootstrap_cross_signing', {});
  }

  /// Set up server-side key backup.
  Future<void> setupKeyBackup() async {
    await _call('setup_key_backup', {});
  }

  /// Restore room keys from backup using recovery key.
  Future<void> restoreKeyBackup(String recoveryKey) async {
    await _call('restore_key_backup', {'s1': recoveryKey});
  }

  /// Enable secret storage and key backup recovery. Returns the recovery key.
  Future<String> enableRecovery() async {
    final result = await _call('enable_recovery', {});
    return result as String;
  }

  /// Block until locally-created room keys finish uploading to backup.
  Future<void> waitForBackupUpload() async {
    await _call('wait_for_backup_upload', {});
  }

  /// Upload media to a room. Returns event ID.
  Future<String> uploadMedia(
    String roomId,
    String filename,
    String mimeType,
    Uint8List data,
  ) async {
    final result = await _call('upload_media', {
      'room_id': roomId,
      'filename': filename,
      'mime_type': mimeType,
      'data': data.toList(),
    });
    return result as String;
  }

  /// Download media by mxc:// URI. Returns raw bytes.
  Future<Uint8List?> downloadMedia(String mxcUri) async {
    final result = await _call('download_media', {'mxc_uri': mxcUri});
    if (result == null) return null;
    return Uint8List.fromList(result as List<int>);
  }

  /// Get a thumbnail of media. Returns raw bytes.
  Future<Uint8List?> getThumbnail(
    String mxcUri, {
    int width = 128,
    int height = 128,
  }) async {
    final result = await _call('get_thumbnail', {
      'mxc_uri': mxcUri,
      'width': width,
      'height': height,
    });
    if (result == null) return null;
    return Uint8List.fromList(result as List<int>);
  }

  /// Register a pusher for push notifications.
  Future<void> registerPusher({
    required String appId,
    required String pushKey,
    required String appDisplayName,
    required String deviceDisplayName,
    required String pushUrl,
    required String lang,
  }) async {
    await _call('register_pusher', {
      'app_id': appId,
      'push_key': pushKey,
      'app_display_name': appDisplayName,
      'device_display_name': deviceDisplayName,
      'push_url': pushUrl,
      'lang': lang,
    });
  }

  // === Callback registration (main isolate) ===
  //
  // These use NativeCallable.listener which is designed for cross-thread
  // callback invocation. The callbacks fire on Rust's sync thread and post
  // to the main isolate's event loop.

  /// Register a callback for incoming message events.
  ///
  /// The callback receives a JSON-serialized MessageEvent string.
  void onMessage(void Function(String json) callback) {
    final nativeCallable =
        ffi.NativeCallable<ffi.Void Function(ffi.Pointer<ffi.Char>)>.listener(
      (ffi.Pointer<ffi.Char> ptr) {
        // Rust hands over ownership of this heap-allocated string (see
        // MessageCallback's doc comment) precisely because NativeCallable.listener
        // posts across isolates and returns before this closure runs: a pointer
        // valid only for the native call's duration would already be dangling here.
        final json = ptr.cast<Utf8>().toDartString();
        _mainBindings.ffi_free_string(ptr.cast());
        callback(json);
      },
    );
    _mainBindings.manymatrix_on_message(_handle, nativeCallable.nativeFunction);
    // Keep reference to prevent GC
    _messageCallable = nativeCallable;
  }

  ffi.NativeCallable<ffi.Void Function(ffi.Pointer<ffi.Char>)>?
      _messageCallable;

  /// Register a callback for incoming reaction events.
  ///
  /// The callback receives a JSON-serialized ReactionEvent string.
  void onReaction(void Function(String json) callback) {
    final nativeCallable =
        ffi.NativeCallable<ffi.Void Function(ffi.Pointer<ffi.Char>)>.listener(
      (ffi.Pointer<ffi.Char> ptr) {
        final json = ptr.cast<Utf8>().toDartString();
        _mainBindings.ffi_free_string(ptr.cast());
        callback(json);
      },
    );
    _mainBindings.manymatrix_on_reaction(
        _handle, nativeCallable.nativeFunction);
    _reactionCallable = nativeCallable;
  }

  ffi.NativeCallable<ffi.Void Function(ffi.Pointer<ffi.Char>)>?
      _reactionCallable;

  /// Register a callback for incoming read receipt events.
  ///
  /// The callback receives a JSON-serialized ReceiptEvent string.
  void onReceipt(void Function(String json) callback) {
    final nativeCallable =
        ffi.NativeCallable<ffi.Void Function(ffi.Pointer<ffi.Char>)>.listener(
      (ffi.Pointer<ffi.Char> ptr) {
        final json = ptr.cast<Utf8>().toDartString();
        _mainBindings.ffi_free_string(ptr.cast());
        callback(json);
      },
    );
    _mainBindings.manymatrix_on_receipt(_handle, nativeCallable.nativeFunction);
    _receiptCallable = nativeCallable;
  }

  ffi.NativeCallable<ffi.Void Function(ffi.Pointer<ffi.Char>)>?
      _receiptCallable;

  /// Register a callback for incoming custom (non-standard) message-like events whose
  /// event type matches [eventType] exactly. Pairs with [sendCustomEvent].
  ///
  /// The callback receives a JSON-serialized CustomEvent string (`event_id`, `room_id`,
  /// `sender`, `event_type`, `content`, `timestamp`). Unlike [onMessage]/[onReaction]/
  /// [onReceipt], multiple event types can each have their own registration: every call
  /// to this method adds a new native handler rather than replacing a single one, so keep
  /// the returned callables alive in [_customEventCallables] for the client's lifetime.
  void onCustomEvent(String eventType, void Function(String json) callback) {
    final nativeCallable =
        ffi.NativeCallable<ffi.Void Function(ffi.Pointer<ffi.Char>)>.listener(
      (ffi.Pointer<ffi.Char> ptr) {
        final json = ptr.cast<Utf8>().toDartString();
        _mainBindings.ffi_free_string(ptr.cast());
        callback(json);
      },
    );
    final eventTypePtr = eventType.toNativeUtf8();
    try {
      _mainBindings.manymatrix_on_custom_event(
        _handle,
        eventTypePtr.cast(),
        nativeCallable.nativeFunction,
      );
    } finally {
      calloc.free(eventTypePtr);
    }
    _customEventCallables.add(nativeCallable);
  }

  final List<ffi.NativeCallable<ffi.Void Function(ffi.Pointer<ffi.Char>)>>
      _customEventCallables = [];

  /// Register a callback for background sync-loop status events.
  ///
  /// The callback receives a JSON string such as
  /// `{"state":"exited","ok":false,"error":"..."}` when a native sync loop
  /// exits after being started with [syncForever].
  void onSyncStatus(void Function(String json) callback) {
    _syncStatusCallable?.close();
    final nativeCallable =
        ffi.NativeCallable<ffi.Void Function(ffi.Pointer<ffi.Char>)>.listener(
      (ffi.Pointer<ffi.Char> ptr) {
        final json = ptr.cast<Utf8>().toDartString();
        _mainBindings.ffi_free_string(ptr.cast());
        callback(json);
      },
    );
    _syncStatusCallable = nativeCallable;
  }

  ffi.NativeCallable<ffi.Void Function(ffi.Pointer<ffi.Char>)>?
      _syncStatusCallable;

  /// Dispose the client, freeing native resources.
  ///
  /// After calling dispose, this instance must not be used again.
  void dispose() {
    _finalizer.detach(this);
    _messageCallable?.close();
    _reactionCallable?.close();
    _receiptCallable?.close();
    _syncStatusCallable?.close();
    for (final callable in _customEventCallables) {
      callable.close();
    }
    _mainBindings.manymatrix_free(_handle);
  }
}
