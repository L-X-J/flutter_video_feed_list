// 视频缓存本地代理服务器。
//
// 在 127.0.0.1 上启动 HttpServer，监听 player 的 Range 请求。
// 核心设计：单次 HTTP 下载同时 pipe 给 player response 并写盘，
// 真正实现单流边播边缓存。第二次播放直接从磁盘返回。
//
// - 单例，端口由操作系统分配
// - 缓存文件按 URL FNV-1a 哈希命名
// - LRU 驱逐，默认 512 MB 上限
// - HLS（.m3u8）和本地文件跳过代理
import 'dart:async';
import 'dart:io';

import 'package:flutter_video_feed_list/src/utils/logging.dart';

/// 截短 URL 用于日志，只保留最后一段路径。
String _shortUrl(String url) {
  try {
    final path = Uri.parse(url).pathSegments.last;
    return path.length > 24 ? '…${path.substring(path.length - 24)}' : path;
  } catch (_) {
    return url.length > 32 ? '…${url.substring(url.length - 32)}' : url;
  }
}

/// 视频缓存代理服务器单例。
class VideoCacheProxyServer {
  VideoCacheProxyServer._();
  static final VideoCacheProxyServer instance = VideoCacheProxyServer._();

  static const int _maxCacheBytes = 512 * 1024 * 1024; // 512 MB

  HttpServer? _server;
  Directory? _cacheDir;
  Completer<void>? _startCompleter;

  /// 已完成的缓存文件，按 URL 索引。
  final Map<String, File> _cached = {};

  /// 正在进行的下载任务，按 URL 索引。
  final Map<String, _ActiveDownload> _active = {};

  /// 启动代理服务器；并发安全，已启动则直接返回。
  Future<void> ensureStarted() async {
    if (_server != null) return;
    final pending = _startCompleter;
    if (pending != null) return pending.future;

    final c = Completer<void>();
    _startCompleter = c;
    try {
      final base = Directory.systemTemp;
      _cacheDir = Directory('${base.path}/vp_cache');
      if (!_cacheDir!.existsSync()) _cacheDir!.createSync(recursive: true);
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _server!.listen(_onRequest);
      logging('VideoCacheProxy :${_server!.port}');
      c.complete();
    } catch (e) {
      _startCompleter = null;
      c.completeError(e);
      rethrow;
    }
  }

  int get port => _server?.port ?? 0;

  /// 把原始 URL 改写为代理 URL。
  String proxiedUrl(String originalUrl) =>
      'http://127.0.0.1:$port/proxy?url=${Uri.encodeComponent(originalUrl)}';

  /// 后台静默预热：提前开始下载，不阻塞调用方，不关联任何 player response。
  ///
  /// 已缓存或已在下载中的 URL 直接跳过。HLS 和本地文件不应传入此方法。
  void prefetch(String url) {
    if (_server == null) return;          // 代理还未启动，跳过
    if (_cached.containsKey(url)) return; // 已完整缓存
    if (_active.containsKey(url)) return; // 已在下载中
    final file = _cacheFileFor(url);
    logging('[proxy] prefetch start ${_shortUrl(url)}');
    final download = _ActiveDownload(url, file);
    _active[url] = download;
    // fire-and-forget：传入一个 null-like sentinel response 不现实，
    // 改用 _PrefetchSink 作为虚拟响应接收者，只写盘不回传。
    download.startPrefetch().then((_) {
      _active.remove(url);
      if (download.isDone && file.existsSync() && file.lengthSync() > 0) {
        _cached[url] = file;
        logging('[proxy] prefetch cached ${_shortUrl(url)} (${file.lengthSync()} bytes)');
        _evictIfNeeded();
      } else {
        if (file.existsSync()) {
          try { file.deleteSync(); } catch (_) {}
        }
        logging('[proxy] prefetch incomplete ${_shortUrl(url)}');
      }
    }).catchError((Object e) {
      _active.remove(url);
      if (file.existsSync()) {
        try { file.deleteSync(); } catch (_) {}
      }
      logging('[proxy] prefetch error ${_shortUrl(url)}: $e');
    });
  }

  // MARK: - Request handler

  Future<void> _onRequest(HttpRequest req) async {
    try {
      if (req.uri.path != '/proxy') {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
        return;
      }
      final original = req.uri.queryParameters['url'];
      if (original == null || original.isEmpty) {
        req.response.statusCode = HttpStatus.badRequest;
        await req.response.close();
        return;
      }
      final rangeHeader = req.headers.value('range');
      final range = _parseRange(rangeHeader);
      logging('[proxy] ← ${req.method} range=${rangeHeader ?? "none"} ${_shortUrl(original)}');
      await _serve(original, range, req.response);
    } catch (e) {
      logging('[proxy] request error: $e');
      try {
        req.response.statusCode = HttpStatus.internalServerError;
        await req.response.close();
      } catch (_) {}
    }
  }

  Future<void> _serve(
      String url, _Range range, HttpResponse res) async {
    final file = _cacheFileFor(url);

    // 缓存命中：只信任 _cached map 中明确登记的完整文件。
    // 不能用 file.existsSync() 判断，下载进行中文件也存在，会把不完整文件当缓存用。
    if (_cached.containsKey(url)) {
      final cachedFile = _cached[url]!;
      logging('[proxy] HIT disk ${_shortUrl(url)} (${cachedFile.lengthSync()} bytes)');
      return _serveFromFile(cachedFile, range, res);
    }

    // 已有进行中的下载：接入同一流。
    // _getOrCreateActive 保证同 URL 的并发请求拿到同一实例，避免 TOCTOU 竞争。
    final existing = _active[url];
    if (existing != null) {
      logging('[proxy] ATTACH to active download ${_shortUrl(url)}');
      return existing.attach(range, res);
    }

    // 发起新下载。在注册到 _active 之前就创建实例，
    // 后续并发进来的请求会走 attach 分支。
    logging('[proxy] MISS – starting download ${_shortUrl(url)}');
    final download = _ActiveDownload(url, file);
    _active[url] = download;          // 先注册，再 await，避免 await 间隙里再次创建
    bool downloadSucceeded = false;
    try {
      await download.start(range, res);
      downloadSucceeded = download.isDone;
    } finally {
      _active.remove(url);
      if (downloadSucceeded && file.existsSync() && file.lengthSync() > 0) {
        _cached[url] = file;
        logging('[proxy] cached ${_shortUrl(url)} (${file.lengthSync()} bytes)');
        _evictIfNeeded();
      } else if (!downloadSucceeded && file.existsSync()) {
        try { file.deleteSync(); } catch (_) {}
        logging('[proxy] cleaned partial file ${_shortUrl(url)}');
      }
    }
  }

  // MARK: - Disk helpers

  /// 从已缓存文件响应 Range 请求。
  Future<void> _serveFromFile(
      File file, _Range range, HttpResponse res) async {
    final total = file.lengthSync();
    final start = range.start.clamp(0, total > 0 ? total - 1 : 0);
    final end = (range.end ?? total - 1).clamp(start, total > 0 ? total - 1 : 0);
    final length = end - start + 1;

    res.statusCode =
        range.isFullRequest ? HttpStatus.ok : HttpStatus.partialContent;
    res.headers.contentType = ContentType('video', 'mp4');
    res.headers.set(HttpHeaders.contentLengthHeader, length);
    res.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    if (!range.isFullRequest) {
      res.headers.set(
          HttpHeaders.contentRangeHeader, 'bytes $start-$end/$total');
    }

    final raf = await file.open();
    try {
      await raf.setPosition(start);
      var remaining = length;
      const chunkSize = 65536;
      while (remaining > 0) {
        final toRead = remaining < chunkSize ? remaining : chunkSize;
        final data = await raf.read(toRead);
        if (data.isEmpty) break;
        res.add(data);
        remaining -= data.length;
      }
      await res.flush();
    } finally {
      await raf.close();
      await res.close();
    }
  }

  File _cacheFileFor(String url) {
    final hash = _fnv1a64(url);
    return File('${_cacheDir!.path}/$hash');
  }

  void _evictIfNeeded() {
    try {
      if (!_cacheDir!.existsSync()) return;
      final files = _cacheDir!.listSync().whereType<File>().toList();
      var total = 0;
      for (final f in files) {
        try {
          total += f.lengthSync();
        } catch (_) {}
      }
      if (total <= _maxCacheBytes) return;
      files.sort(
          (a, b) => a.statSync().modified.compareTo(b.statSync().modified));
      for (final f in files) {
        if (total <= _maxCacheBytes) break;
        try {
          total -= f.lengthSync();
          f.deleteSync();
          _cached.removeWhere((_, v) => v.path == f.path);
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// FNV-1a 64 位哈希，用于生成缓存文件名。
  String _fnv1a64(String input) {
    var hash = 0xcbf29ce484222325;
    for (var i = 0; i < input.length; i++) {
      hash ^= input.codeUnitAt(i);
      hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }

  _Range _parseRange(String? header) {
    if (header == null || !header.startsWith('bytes=')) {
      return const _Range(0, null);
    }
    final spec = header.substring(6);
    final dash = spec.indexOf('-');
    if (dash < 0) return const _Range(0, null);
    final start = int.tryParse(spec.substring(0, dash)) ?? 0;
    final endStr = spec.substring(dash + 1);
    final end = endStr.isEmpty ? null : int.tryParse(endStr);
    return _Range(start, end);
  }

  Future<void> shutdown() async {
    await _server?.close(force: true);
    _server = null;
    _active.clear();
    _cached.clear();
  }
}

/// 进行中的单次下载任务。
///
/// 第一个 player 请求触发下载；字节到来时同时：
///   1. 写入缓存文件（持久化）
///   2. pipe 给所有挂载的 HttpResponse（实时播放）
///
/// 后续请求通过 [attach] 接入同一流，无需额外 HTTP 请求。
class _ActiveDownload {
  _ActiveDownload(this.url, this.file);

  final String url;
  final File file;

  int _contentLength = 0;
  int _writtenBytes = 0;
  bool _done = false;
  bool _failed = false;
  // 下载是否正在进行中（不依赖第一个 waiter 的生命周期）。
  final Completer<void> _downloadCompleter = Completer<void>();

  /// 下载是否完整完成（供外部判断是否进缓存）。
  bool get isDone => _done;

  /// 所有挂载的等待者：每个等待者持有其 Range 请求和 response。
  final List<_Waiter> _waiters = [];

  /// 已下载的字节分块及其起始偏移，用于让后来 attach 的请求回放已下载部分。
  /// 必须记录偏移，因为 _writtenBytes 在下载过程中持续增长，
  /// 重放时用 _writtenBytes - chunk.length 计算偏移会得到错误的值。
  final List<_ChunkRecord> _chunks = [];

  /// 接入已有下载流；若请求的 range 已就绪则立刻喂数据。
  Future<void> attach(_Range range, HttpResponse res) {
    final completer = Completer<void>();
    final waiter = _Waiter(range, res, completer);
    _waiters.add(waiter);

    // 如果响应头已就绪，先初始化新 waiter 的响应头并回放已下载部分。
    if (_contentLength > 0) {
      _initResponse(waiter, _contentLength);
      for (final record in _chunks) {
        _feedWaiterWithOffset(waiter, record.data, record.offset);
      }
    }
    if (_done) {
      _finishWaiter(waiter);
    } else if (_failed) {
      _failWaiter(waiter);
    }
    return completer.future;
  }

  /// 纯后台预热下载：不关联任何 player response，只写盘。
  Future<void> startPrefetch() async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 15);
    client.idleTimeout = const Duration(seconds: 30);
    try {
      logging('[proxy] → prefetch GET ${_shortUrl(url)}');
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      logging('[proxy] ← prefetch ${response.statusCode} ${_shortUrl(url)}');
      if (response.statusCode != HttpStatus.ok &&
          response.statusCode != HttpStatus.partialContent) {
        _failed = true;
        if (!_downloadCompleter.isCompleted) _downloadCompleter.complete();
        return;
      }
      _contentLength = response.contentLength > 0
          ? response.contentLength
          : int.tryParse(
                  response.headers.value(HttpHeaders.contentLengthHeader) ?? '') ??
              0;
      final sink = file.openWrite(mode: FileMode.write);
      try {
        await for (final chunk in response) {
          sink.add(chunk);
          _writtenBytes += chunk.length;
        }
        await sink.flush();
        _done = true;
        logging('[proxy] prefetch DONE ${_shortUrl(url)} $_writtenBytes/$_contentLength B');
      } catch (e) {
        _failed = true;
        logging('[proxy] prefetch chunk err ${_shortUrl(url)}: $e');
      } finally {
        await sink.close();
      }
    } catch (e) {
      _failed = true;
      logging('[proxy] prefetch error ${_shortUrl(url)}: $e');
    } finally {
      client.close();
      if (!_downloadCompleter.isCompleted) _downloadCompleter.complete();
    }
  }

  /// 启动 HTTP 下载，同时服务第一个请求。
  Future<void> start(_Range range, HttpResponse res) async {
    // 第一个 waiter 只负责响应这个 player 请求，不控制下载生命周期。
    final waiter = _Waiter(range, res, Completer<void>());
    _waiters.add(waiter);

    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 15);
    client.idleTimeout = const Duration(seconds: 30);
    try {
      logging('[proxy] → GET ${_shortUrl(url)}');
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      logging('[proxy] ← ${response.statusCode} ${_shortUrl(url)}');

      if (response.statusCode != HttpStatus.ok &&
          response.statusCode != HttpStatus.partialContent) {
        _failed = true;
        for (final w in _waiters) {
          _failWaiter(w);
        }
        if (!_downloadCompleter.isCompleted) _downloadCompleter.complete();
        return;
      }

      _contentLength = response.contentLength > 0
          ? response.contentLength
          : int.tryParse(
                  response.headers.value(HttpHeaders.contentLengthHeader) ??
                      '') ??
              0;
      logging('[proxy] contentLength=$_contentLength ${_shortUrl(url)}');

      // 初始化所有已挂载 waiter 的响应头。
      for (final w in _waiters) {
        _initResponse(w, _contentLength);
      }

      // 打开缓存文件写入句柄。
      final sink = file.openWrite(mode: FileMode.write);

      try {
        var chunkIndex = 0;
        await for (final chunk in response) {
          final chunkOffset = _writtenBytes;
          sink.add(chunk);
          _writtenBytes += chunk.length;
          _chunks.add(_ChunkRecord(chunk, chunkOffset));
          final dead = <_Waiter>[];
          for (final w in _waiters) {
            if (!_feedWaiterWithOffset(w, chunk, chunkOffset)) dead.add(w);
          }
          _waiters.removeWhere((w) => dead.contains(w));
          chunkIndex++;
          if (chunkIndex == 1) {
            logging('[proxy] first chunk ${chunk.length}B ${_shortUrl(url)} (waiters=${_waiters.length})');
          }
        }
        await sink.flush();
        _done = true;
        // 下载完成后清空内存中的 chunk 缓冲，释放 RAM。
        _chunks.clear();
        logging('[proxy] DONE ${_shortUrl(url)} $_writtenBytes/$_contentLength B');
      } catch (e) {
        _failed = true;
        _chunks.clear();
        logging('[proxy] download chunk err ${_shortUrl(url)}: $e');
      } finally {
        await sink.close();
      }
    } catch (e) {
      _failed = true;
      logging('[proxy] download error ${_shortUrl(url)}: $e');
    } finally {
      client.close();
    }

    // 通知所有剩余 waiter 下载已结束。
    for (final w in _waiters) {
      if (_done) {
        _finishWaiter(w);
      } else {
        _failWaiter(w);
      }
    }
    _waiters.clear();
    // 标记下载任务本身完成，与各 waiter 的生命周期无关。
    if (!_downloadCompleter.isCompleted) _downloadCompleter.complete();
  }

  // MARK: - Waiter helpers

  void _initResponse(_Waiter w, int totalLength) {
    if (w.headerSent) return;
    w.headerSent = true;
    final range = w.range;
    final start = range.start;
    final end = range.end ?? (totalLength > 0 ? totalLength - 1 : 0);
    final length = totalLength > 0 ? end - start + 1 : 0;

    w.res.statusCode =
        range.isFullRequest ? HttpStatus.ok : HttpStatus.partialContent;
    w.res.headers.contentType = ContentType('video', 'mp4');
    if (length > 0) {
      w.res.headers.set(HttpHeaders.contentLengthHeader, length);
    }
    w.res.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    if (!range.isFullRequest && totalLength > 0) {
      w.res.headers
          .set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$totalLength');
    }
  }

  /// 把 chunk 推给 waiter，只推 waiter 请求 range 内的字节。
  /// [chunkOffset] 是该 chunk 在文件中的起始字节偏移。
  /// 返回 false 表示该 waiter 的 range 已满足，可以移除。
  bool _feedWaiterWithOffset(_Waiter w, List<int> chunk, int chunkOffset) {
    if (w.done) return false;
    final range = w.range;
    final chunkStart = chunkOffset;
    final chunkEnd = chunkOffset + chunk.length - 1;
    final rangeStart = range.start;
    final rangeEnd = range.end; // null = 到文件末尾

    // 计算本 chunk 内需要发送的字节段。
    final sendStart = chunkStart < rangeStart ? rangeStart - chunkStart : 0;
    final sendEnd = rangeEnd != null && chunkEnd > rangeEnd
        ? rangeEnd - chunkStart
        : chunk.length - 1;

    if (sendStart <= sendEnd && sendStart < chunk.length) {
      try {
        w.res.add(chunk.sublist(sendStart, sendEnd + 1));
      } catch (_) {
        w.done = true;
        if (!w.completer.isCompleted) w.completer.complete();
        return false;
      }
    }

    // 如果 range 有明确结束点且已发完，提前关闭。
    if (rangeEnd != null && chunkEnd >= rangeEnd) {
      _finishWaiter(w);
      return false;
    }
    return true;
  }

  void _finishWaiter(_Waiter w) {
    if (w.done) return;
    w.done = true;
    try {
      w.res.close();
    } catch (_) {}
    if (!w.completer.isCompleted) w.completer.complete();
  }

  void _failWaiter(_Waiter w) {
    if (w.done) return;
    w.done = true;
    try {
      w.res.statusCode = HttpStatus.badGateway;
      w.res.close();
    } catch (_) {}
    if (!w.completer.isCompleted) w.completer.complete();
  }
}

/// 单个 player Range 请求的等待者。
class _Waiter {
  _Waiter(this.range, this.res, this.completer);
  final _Range range;
  final HttpResponse res;
  final Completer<void> completer;
  bool headerSent = false;
  bool done = false;
}

/// Range 请求的字节范围。
class _Range {
  const _Range(this.start, this.end);
  final int start;
  final int? end;
  bool get isFullRequest => start == 0 && end == null;
}

/// 已下载的字节分块及其在文件中的起始偏移。
class _ChunkRecord {
  const _ChunkRecord(this.data, this.offset);
  final List<int> data;
  /// 该 chunk 在文件中的字节起始偏移。
  final int offset;
}

/// 下载就绪状态（保留用于外部兼容）。
class RangeReady {
  const RangeReady.available() : available = true, failed = false;
  const RangeReady.failed() : available = false, failed = true;
  final bool available;
  final bool failed;
}
