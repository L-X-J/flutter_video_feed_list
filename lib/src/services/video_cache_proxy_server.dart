// 本地视频缓存代理：按 Range 读取同一下载文件，预热与播放共享数据及失败语义。
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import '../utils/logging.dart';

String _shortUrl(String url) => Uri.parse(url).pathSegments.last;

/// MP4 下载只建立一条上游连接；完成文件与临时文件分开，避免重启后误用半文件。
class VideoCacheProxyServer {
  VideoCacheProxyServer._();
  static final VideoCacheProxyServer instance = VideoCacheProxyServer._();
  static const int _maxCacheBytes = 512 * 1024 * 1024;

  HttpServer? _server;
  Directory? _cacheDir;
  Future<void>? _starting;
  final Map<String, _ActiveDownload> _active = {};
  final Map<String, int> _readers = {};
  final Map<Object, Set<String>> _windows = {};

  /// 并发启动共用一个 Future。
  Future<void> ensureStarted() => _starting ??= _start();

  Future<void> _start() async {
    try {
      _cacheDir = Directory('${Directory.systemTemp.path}/vp_cache');
      await _cacheDir!.create(recursive: true);
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _server!.listen(_onRequest);
      logging('VideoCacheProxy :${_server!.port}');
    } catch (_) {
      _starting = null;
      rethrow;
    }
  }

  int get port => _server?.port ?? 0;

  String proxiedUrl(String originalUrl) =>
      'http://127.0.0.1:$port/proxy?url=${Uri.encodeComponent(originalUrl)}';

  /// 预热与播放器使用相同任务，后来接入的请求可立即读取已经到达的字节。
  void prefetch(String url) {
    if (_server == null ||
        !_isCacheable(url) ||
        _completeFile(url).existsSync()) {
      return;
    }
    _getOrStart(url);
  }

  /// 只有当前文件完整到达后才允许初始化邻居，避免高码率首播被后台下载抢带宽。
  /// HLS、本地文件和未走本代理的资源没有下载任务，不阻塞其控制器窗口。
  Future<bool> waitUntilCached(String url) async {
    if (_server == null) return true;
    if (_completeFile(url).existsSync()) return true;
    final download = _active[url];
    return download == null ? true : await download.finished.future;
  }

  /// 取消本宿主已经离开窗口的下载；其他宿主仍持有的 URL 保持有效。
  void retainDownloads(Object owner, Iterable<String> urls) {
    final previous = _windows[owner] ?? const <String>{};
    final next = urls.where(_isCacheable).toSet();
    _windows[owner] = next;
    final retained = _windows.values.expand((urls) => urls).toSet();
    for (final url in previous.difference(retained)) {
      _active[url]?.cancel();
    }
  }

  void releaseDownloads(Object owner) {
    retainDownloads(owner, const []);
    _windows.remove(owner);
  }

  bool _isCacheable(String url) {
    final uri = Uri.parse(url);
    return (uri.scheme == 'http' || uri.scheme == 'https') &&
        !uri.path.toLowerCase().endsWith('.m3u8');
  }

  Future<void> _onRequest(HttpRequest req) async {
    final res = req.response;
    // 首字节到来前客户端也可能取消，提前消费 done 的错误，避免未处理的异步异常。
    unawaited(res.done.then<void>((_) {}, onError: (Object _) {}));
    try {
      final url = req.uri.queryParameters['url'];
      if (req.uri.path != '/proxy' || url == null || !_isCacheable(url)) {
        res.statusCode = HttpStatus.notFound;
        await res.close();
        return;
      }
      if (req.method != 'GET' && req.method != 'HEAD') {
        res.statusCode = HttpStatus.methodNotAllowed;
        res.headers.set(HttpHeaders.allowHeader, 'GET, HEAD');
        await res.close();
        return;
      }
      final range = _Range.parse(req.headers.value(HttpHeaders.rangeHeader));
      logging(
          '[proxy] ← ${req.method} range=${range.header ?? "none"} ${_shortUrl(url)}');
      final complete = _completeFile(url);
      if (await complete.exists()) {
        await _serveFile(complete, range, res, headOnly: req.method == 'HEAD');
      } else {
        var download = _getOrStart(url);
        // 旧窗口取消的任务必须先释放文件句柄，不能与新任务同时写同一临时文件。
        if (download.cancelled) {
          await download.finished.future;
          download = _getOrStart(url);
        }
        await download.serve(range, res, headOnly: req.method == 'HEAD');
      }
    } catch (e) {
      logging('[proxy] request ended: $e');
      try {
        res.statusCode = HttpStatus.badGateway;
        await res.close();
      } catch (_) {
        // 响应头已经发送时无法改状态码；立即销毁连接，读者才能收到截断错误。
        res.deadline = Duration.zero;
      }
    }
  }

  _ActiveDownload _getOrStart(String url) => _active.putIfAbsent(url, () {
        final download = _ActiveDownload(url, _completeFile(url));
        // 延迟到 Map 登记之后启动，保证并发 Range 与 prefetch 只有一个 writer。
        unawaited(Future<void>(() => _run(download)));
        return download;
      });

  Future<void> _run(_ActiveDownload download) async {
    try {
      await download.start();
      if (download.isDone) {
        try {
          await _evictIfNeeded();
        } on FileSystemException catch (e) {
          logging('[proxy] cache eviction skipped: $e');
        }
      }
    } finally {
      if (identical(_active[download.url], download)) {
        _active.remove(download.url);
      }
      download.finished.complete(download.isDone);
    }
  }

  Future<void> _serveFile(File file, _Range range, HttpResponse res,
      {required bool headOnly}) async {
    _readers.update(file.path, (count) => count + 1, ifAbsent: () => 1);
    try {
      final total = await file.length();
      final bounds = range.resolve(total);
      if (!_prepareResponse(res, range, bounds, total)) return;
      if (headOnly) {
        await res.close();
        return;
      }
      await file.setLastModified(DateTime.now());
      await res.addStream(file.openRead(bounds!.$1, bounds.$2 + 1));
      await res.close();
    } finally {
      final remaining = _readers[file.path]! - 1;
      if (remaining == 0) {
        _readers.remove(file.path);
      } else {
        _readers[file.path] = remaining;
      }
    }
  }

  File _completeFile(String url) =>
      File('${_cacheDir!.path}/${_fnv1a64(url)}.mp4');

  Future<void> _evictIfNeeded() async {
    final files = await _cacheDir!
        .list()
        .where((entry) => entry is File && entry.path.endsWith('.mp4'))
        .cast<File>()
        .toList();
    final stats = <File, FileStat>{};
    var total = 0;
    for (final file in files) {
      final stat = await file.stat();
      stats[file] = stat;
      total += stat.size;
    }
    files.sort((a, b) => stats[a]!.modified.compareTo(stats[b]!.modified));
    final protected = {
      ..._readers.keys,
      ..._active.values.map((d) => d.completeFile.path),
      ..._windows.values
          .expand((urls) => urls)
          .map((url) => _completeFile(url).path),
    };
    for (final file in files) {
      if (total <= _maxCacheBytes) break;
      if (protected.contains(file.path)) continue;
      try {
        await file.delete();
        total -= stats[file]!.size;
      } on FileSystemException catch (_) {}
    }
  }

  String _fnv1a64(String input) {
    var hash = 0xcbf29ce484222325;
    for (final code in input.codeUnits) {
      hash ^= code;
      hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }

  /// 等待所有 writer 结束后再关闭，避免迟到回调污染新代理实例。
  Future<void> shutdown() async {
    await _starting;
    final server = _server;
    _server = null;
    await server?.close(force: true);
    final downloads = _active.values.toList();
    for (final download in downloads) {
      download.cancel();
    }
    await Future.wait(downloads.map((d) => d.finished.future));
    _windows.clear();
    _starting = null;
  }
}

/// 预热和播放共用的顺序下载；读者从临时文件按需读取，避免保存/扫描整文件内存块。
class _ActiveDownload {
  _ActiveDownload(this.url, this.completeFile)
      : partialFile = File('${completeFile.path}.part');

  final String url;
  final File completeFile;
  final File partialFile;
  final finished = Completer<bool>();
  final _headersReady = Completer<void>();
  Completer<void> _changed = Completer<void>();
  HttpClient? _client;
  int _contentLength = -1;
  int _writtenBytes = 0;
  bool isDone = false;
  bool _failed = false;
  bool cancelled = false;

  void _notify() {
    final previous = _changed;
    _changed = Completer<void>();
    previous.complete();
  }

  void cancel() {
    if (isDone || cancelled) return;
    cancelled = true;
    _failed = true;
    _client?.close(force: true);
    if (!_headersReady.isCompleted) _headersReady.complete();
    _notify();
  }

  Future<void> start() async {
    final watch = Stopwatch()..start();
    RandomAccessFile? writer;
    final client = HttpClient()..autoUncompress = false;
    _client = client;
    try {
      if (cancelled) return;
      client.connectionTimeout = const Duration(seconds: 15);
      logging('[proxy] → GET ${_shortUrl(url)}');
      final request = await client
          .getUrl(Uri.parse(url))
          .timeout(const Duration(seconds: 15));
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      final response =
          await request.close().timeout(const Duration(seconds: 15));
      if (response.statusCode != HttpStatus.ok ||
          (response.headers.value(HttpHeaders.contentEncodingHeader) ??
                  'identity') !=
              'identity') {
        throw HttpException(
            'Unexpected upstream status/encoding: ${response.statusCode}');
      }
      _contentLength = response.contentLength;
      writer = await partialFile.open(mode: FileMode.write);
      if (!_headersReady.isCompleted) _headersReady.complete();
      logging(
          '[proxy] headers ${watch.elapsedMilliseconds}ms length=$_contentLength ${_shortUrl(url)}');
      await for (final chunk in response.timeout(const Duration(seconds: 15))) {
        if (cancelled) throw const HttpException('Download cancelled');
        // writeFrom 完成后才发布字节数，读者不会读到尚未写入的空洞。
        await writer.writeFrom(chunk);
        final first = _writtenBytes == 0;
        _writtenBytes += chunk.length;
        _notify();
        if (first) {
          logging(
              '[proxy] firstByte ${watch.elapsedMilliseconds}ms ${_shortUrl(url)}');
        }
      }
      if (cancelled ||
          _writtenBytes == 0 ||
          (_contentLength >= 0 && _writtenBytes != _contentLength)) {
        throw const HttpException('Incomplete video download');
      }
      await writer.close();
      writer = null;
      await partialFile.rename(completeFile.path);
      if (cancelled) {
        await completeFile.delete();
        throw const HttpException('Download cancelled before cache commit');
      }
      isDone = true;
      logging(
          '[proxy] DONE ${watch.elapsedMilliseconds}ms $_writtenBytes B ${_shortUrl(url)}');
    } catch (e) {
      _failed = true;
      logging(
          '[proxy] ${cancelled ? "cancelled" : "failed"} ${watch.elapsedMilliseconds}ms ${_shortUrl(url)}: $e');
    } finally {
      client.close(force: true);
      try {
        await writer?.close();
        if (!isDone && await partialFile.exists()) {
          await partialFile.delete();
        }
      } on FileSystemException catch (e) {
        logging('[proxy] partial cleanup failed: $e');
      } finally {
        if (!_headersReady.isCompleted) _headersReady.complete();
        _notify();
      }
    }
  }

  Future<void> serve(_Range range, HttpResponse res,
      {required bool headOnly}) async {
    await _headersReady.future;
    // 没有长度时等完整文件后再回应 Range，避免发出错误的 Content-Range/Content-Length。
    while (_contentLength < 0 && !isDone && !_failed) {
      await _changed.future;
    }
    if (_failed) throw const HttpException('Video download unavailable');
    final total = _contentLength >= 0 ? _contentLength : _writtenBytes;
    final bounds = range.resolve(total);
    if (!_prepareResponse(res, range, bounds, total)) return;
    if (headOnly) {
      await res.close();
      return;
    }
    var disconnected = false;
    final closed = Completer<void>();
    // Range 探测请求经常被播放器取消；取消一个读者不能终止整条共享下载。
    unawaited(res.done.then<void>((_) {
      disconnected = true;
      closed.complete();
    }, onError: (Object _) {
      disconnected = true;
      closed.complete();
    }));
    RandomAccessFile? reader;
    try {
      try {
        reader = await partialFile.open();
      } on FileSystemException catch (_) {
        reader = await completeFile.open();
      }
      var cursor = bounds!.$1;
      while (cursor <= bounds.$2 && !disconnected) {
        final changed = _changed.future;
        if (_failed) throw const HttpException('Video download interrupted');
        final available = math.min(_writtenBytes, bounds.$2 + 1) - cursor;
        if (available <= 0) {
          if (isDone) throw const HttpException('Unexpected video EOF');
          await Future.any([changed, closed.future]);
          continue;
        }
        await reader.setPosition(cursor);
        final data = await reader.read(math.min(65536, available));
        if (data.isEmpty) throw const HttpException('Unexpected cache EOF');
        res.add(data);
        await res.flush();
        cursor += data.length;
      }
    } finally {
      await reader?.close();
    }
    await res.close();
  }
}

bool _prepareResponse(
    HttpResponse res, _Range range, (int, int)? bounds, int total) {
  res.bufferOutput = false;
  res.headers.contentType = ContentType('video', 'mp4');
  res.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
  if (bounds == null) {
    res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
    res.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$total');
    res.contentLength = 0;
    unawaited(res.close().catchError((Object _) {}));
    return false;
  }
  res.statusCode =
      range.header == null ? HttpStatus.ok : HttpStatus.partialContent;
  res.contentLength = bounds.$2 - bounds.$1 + 1;
  if (range.header != null) {
    res.headers.set(HttpHeaders.contentRangeHeader,
        'bytes ${bounds.$1}-${bounds.$2}/$total');
  }
  return true;
}

/// 单区间、开放尾部和后缀 Range；越界请求返回 416，不夹取成错误的有效字节。
class _Range {
  const _Range(this.header, this.start, this.end, this.suffix, this.valid);
  factory _Range.parse(String? header) {
    if (header == null) return const _Range(null, 0, null, null, true);
    final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(header.trim());
    final first = match?.group(1) ?? '';
    final last = match?.group(2) ?? '';
    final start = int.tryParse(first);
    final end = int.tryParse(last);
    final isSuffix = first.isEmpty;
    final valid = match != null &&
        (isSuffix
            ? (end ?? 0) > 0
            : start != null && (last.isEmpty || end != null));
    return _Range(header, start ?? 0, isSuffix ? null : end,
        isSuffix ? end : null, valid);
  }
  final String? header;
  final int start;
  final int? end;
  final int? suffix;
  final bool valid;
  (int, int)? resolve(int total) {
    if (!valid || total <= 0) return null;
    if (suffix != null) return (math.max(0, total - suffix!), total - 1);
    if (start >= total || (end != null && end! < start)) return null;
    return (start, math.min(end ?? total - 1, total - 1));
  }
}

/// 保留旧类型以兼容直接引用本服务的宿主。
class RangeReady {
  const RangeReady.available()
      : available = true,
        failed = false;
  const RangeReady.failed()
      : available = false,
        failed = true;
  final bool available;
  final bool failed;
}
