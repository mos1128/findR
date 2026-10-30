/// 检查更新 —— 去发布接口读「最新一次发布」，版本号取它的 tag
/// （解析与比较在 core 的 `update/update_info.dart`，这里只管出网与结果归拢）。
///
/// **为什么是接口而不是一份静态文件**：发布约定就是「一版一 tag」（tag = `v` + pubspec 版本号），
/// 版本号本来就在发布里，接口一次问清 —— 与 ccg-gateway 的做法一致，也不用再维护第二份文件。
///
/// **顺序：先 Gitee，失败再 GitHub**（不是并行）。理由：
/// - 国内用户直连 Gitee 就够了，绝大多数请求只打到 Gitee 一家，少打扰 GitHub；
/// - 接口有按 IP 的次数限额（GitHub 未登录是 60 次/小时/IP），**能少发一次就少发一次**；
/// - 不做加速镜像：Gitee 是给国内的主路，GitHub 是给国外的兜底，再加一层代理只会多一个会坏的东西。
///
/// ⚠️ 代价说清楚：Gitee 那一路**通了就不再问 GitHub** —— 万一 CI 同步 Gitee 那步挂了
/// （那一步会报红），国内用户会看到偏旧的结果。CI 的红就是唯一信号。
///
/// **安装包的下载也在这里**（见文件下半部）：流式写盘、可取消、可断点续传（Range）、
/// 装前按魔数验一次真身。「下完为什么不当场装」不是这一层的事 —— 安装走
/// `update_install.dart` 的平台通道，这里只管把文件拿到手并保证它是完整的。
///
/// 这一层与 `media.dart` 同一套路：HTTP 走 `package:http`，可注入 `Client`
/// （测试用 `package:http/testing.dart` 的 MockClient 换成假网络）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:findr_core/findr_core.dart';
import 'package:http/http.dart' as http;

import 'app_paths.dart';

/// 发布接口，**按顺序尝试**（先 Gitee 后 GitHub，见文件头）。
///
/// 两家都是「最新一次发布」：GitHub 的 `/releases/latest` 会跳过草稿与预发布，
/// 所以 CI 发的是**正式 release**（不再打 prerelease 标记）。
const List<String> updateApiSources = <String>[
  'https://gitee.com/api/v5/repos/ms6/findR/releases/latest',
  'https://api.github.com/repos/mos1128/findR/releases/latest',
];

/// 单个源的超时。顺序尝试 ⇒ 最坏情况是「两个都超时」（≈ 两个相加），
/// 所以这里给得比并行时紧一点。
const Duration updateSourceTimeout = Duration(seconds: 6);

/// APK 的文件名。**这是 App 与 CI 的约定**：发布里那份附件必须叫这个名字，
/// 下载地址就按 `<仓库>/releases/download/<tag>/<这个名字>` 拼（CI 有断言挡着）。
const String apkAssetName = 'app-release.apk';

/// 两个仓库与发布页。Gitee 在国内直连最稳，所以「查不到」时的兜底去处也放它。
const String giteeRepoUrl = 'https://gitee.com/ms6/findR';
const String githubRepoUrl = 'https://github.com/mos1128/findR';
const String releasePageUrl = '$giteeRepoUrl/releases';

/// 一个下载渠道（弹窗里一个按钮）。
final class UpdateChannel {
  const UpdateChannel({
    required this.name,
    required this.url,
    this.fallbackUrls = const <String>[],
  });

  final String name;
  final String url;

  /// 主地址失败后依次再试的地址。目前只有 GitHub 用它：
  /// 先走国内加速镜像，失败自动回 GitHub 原站（用户不用再点一次）。
  final List<String> fallbackUrls;

  /// 本次下载依次尝试的完整地址列表。
  List<String> get urls => <String>[url, ...fallbackUrls];
}

/// 检查结果 —— **三态，不许压成布尔**。
///
/// 「有新版本 / 已是最新 / 查不到」对用户的代价完全不同：把第三态压进前两态的任何一个，
/// 都是在替用户做错误决定（压成「已是最新」会让人错过更新；压成「有新版本」会让人白跑）。
sealed class UpdateCheckResult {
  const UpdateCheckResult();
}

/// 有更新。[info] 里带着版本与发布说明。
final class UpdateAvailable extends UpdateCheckResult {
  const UpdateAvailable(this.info);

  final UpdateInfo info;
}

/// 已是最新。[latest] 是读到的那份（版本不高于本机）——「查不到」不会伪装成它。
final class UpToDate extends UpdateCheckResult {
  const UpToDate(this.latest);

  final UpdateInfo latest;
}

/// 所有源都没读到（断网、限流、还没发过版……）。**不代表没有新版本**。
final class UpdateCheckFailed extends UpdateCheckResult {
  const UpdateCheckFailed();
}

/// 按顺序读各源，返回三态结果：**先成功的那个说了算**。
///
/// [client] 传了就用它（调用方负责关）；不传则内部新建一个用完即关。
Future<UpdateCheckResult> checkForUpdate({
  required String currentVersion,
  required int currentBuild,
  List<String> sources = updateApiSources,
  http.Client? client,
  Duration timeout = updateSourceTimeout,
}) async {
  final own = client == null ? http.Client() : null;
  final c = client ?? own!;
  try {
    for (final url in sources) {
      final info = await fetchReleaseInfo(c, url, timeout);
      // 这一路不通（网断 / 404 / 内容不认识）就换下一路；
      // 通了就直接下结论 —— 不为「再多问一家」多花一次请求
      if (info == null) continue;
      if (isNewerThan(info, currentVersion: currentVersion, currentBuild: currentBuild)) {
        return UpdateAvailable(info);
      }
      return UpToDate(info);
    }
    return const UpdateCheckFailed();
  } finally {
    own?.close();
  }
}

/// 读一个源。**任何异常都吞掉、返回 null** —— 坏源不许拖垮整轮检查。
Future<UpdateInfo?> fetchReleaseInfo(http.Client client, String url, Duration timeout) async {
  try {
    final res = await client.get(
      Uri.parse(url),
      headers: const <String, String>{
        // 两家都要求带上 UA；顺带让服务端看得见是谁在问（出问题好查）
        'User-Agent': 'findr-app',
        'Accept': 'application/json',
      },
    ).timeout(timeout);
    if (res.statusCode != 200) return null;
    // 按字节自己解 UTF-8：`res.body` 在响应头没带 charset 时按 latin-1 解，
    // 中文发布说明到手就是乱码
    return parseReleaseInfo(utf8.decode(res.bodyBytes, allowMalformed: true));
  } catch (_) {
    return null;
  }
}

/// 弹窗里的下载渠道：Gitee 在前（国内直连稳），GitHub 在后（国外用户）。
///
/// 地址优先用发布里挂的**附件地址**（那是服务端自己给的，最不容易拼错）；
/// 附件里找不到（或不属于这个域名）就按固定文件名拼。
///
/// [accelPrefix] 非空时 GitHub 这一路先走加速镜像（前缀 + 原始地址），
/// 失败自动回原站 —— 界面仍是一个按钮。前缀由设置提供（默认 `gh-proxy.com`），
/// 用户也可以填自己搭的。
List<UpdateChannel> downloadChannels(UpdateInfo info, {String? accelPrefix}) {
  final github = _downloadUrl(info, githubRepoUrl, 'github.com');
  final accel = accelPrefix != null &&
      accelPrefix.isNotEmpty &&
      github.startsWith('https://github.com/');
  return <UpdateChannel>[
    UpdateChannel(name: 'Gitee', url: _downloadUrl(info, giteeRepoUrl, 'gitee.com')),
    UpdateChannel(
      name: 'GitHub',
      url: accel ? '$accelPrefix$github' : github,
      fallbackUrls: accel ? <String>[github] : const <String>[],
    ),
  ];
}

String _downloadUrl(UpdateInfo info, String repoUrl, String host) {
  for (final asset in info.assets) {
    if (asset.name == apkAssetName && asset.url.contains(host)) return asset.url;
  }
  return '$repoUrl/releases/download/${Uri.encodeComponent(info.tag)}/$apkAssetName';
}

/// 某个下载渠道对应的**发布页**（长按下载按钮时在浏览器打开）。
/// 是列出所有版本的页面，不是某个 APK 的直链。
String releasePageFor(UpdateChannel channel) =>
    channel.name == 'Gitee' ? '$giteeRepoUrl/releases' : '$githubRepoUrl/releases';

/// 另一个下载渠道 —— 「换源重试」用：两个里挑不是 [current] 的那个。
/// 只有一个渠道时返回 `null`（界面据此少给一个按钮）。
UpdateChannel? otherChannel(UpdateInfo info, UpdateChannel current, {String? accelPrefix}) {
  for (final c in downloadChannels(info, accelPrefix: accelPrefix)) {
    if (c.name != current.name) return c;
  }
  return null;
}

// ─────────────────────────────────────────────────────────────
// 应用内下载安装包
// ─────────────────────────────────────────────────────────────

/// 下载目录：临时目录下的 `updates/`。
///
/// **为什么是临时目录**：APK 是「用完即弃」的中转文件，装完就没价值了 ——
/// 放 documents（会随备份搬走的那份用户数据目录）不合适。放 cache 还有一个直接好处：
/// Android 的 FileProvider 用 `<cache-path>` 正好能把它授权给系统安装器
/// （见 `android/app/src/main/res/xml/file_paths.xml`），装完由系统或我们清掉都不心疼。
Directory updateDownloadDir() {
  final dir = Directory('${AppPaths.temp.path}/updates');
  if (!dir.existsSync()) dir.createSync(recursive: true);
  return dir;
}

/// 安装包文件名。tag 里的 `+` 在文件名里合法，直接带进去。
String apkFileName(String tag) => 'findr-$tag.apk';

File apkFileFor(String tag) => File('${updateDownloadDir().path}/${apkFileName(tag)}');

/// 下载中间态（`.part`）。**校验通过才改名成 `.apk`** ——
/// 于是「`.apk` 存在」本身就等于「这是一份完整的包」，界面可以直接跳过重下。
File apkPartFileFor(String tag) => File('${apkFileFor(tag).path}.part');

/// 只留 [keepTag] 的成品与半成品，其它 tag 的一律删掉。
/// 反复检查更新不该把临时目录越堆越大（同 `backup.dart` 的 `purgeOldBackups`）。
void purgeOtherDownloads(String keepTag) {
  try {
    final dir = updateDownloadDir();
    final keep = <String>{apkFileName(keepTag), '${apkFileName(keepTag)}.part'};
    for (final f in dir.listSync().whereType<File>()) {
      if (!keep.contains(f.uri.pathSegments.last)) f.deleteSync();
    }
  } catch (_) {
    // 清理失败不该让下载失败
  }
}

/// 是不是一个完整的 APK：存在、长度 ≥ 4、且以 ZIP 魔数 `PK\x03\x04` 开头。
///
/// 这一条专挡「下到一个 HTML 错误页 / 登录页」这种**假成功**：那种响应状态码是 200、
/// 长度也可能对得上，改个扩展名就想骗过安装器。真实 APK 必然是 ZIP。
bool isCompleteApk(File f) {
  if (!f.existsSync() || f.lengthSync() < 4) return false;
  RandomAccessFile? raf;
  try {
    raf = f.openSync();
    final head = raf.readSync(4);
    return head.length == 4 && head[0] == 0x50 && head[1] == 0x4B && head[2] == 0x03 && head[3] == 0x04;
  } catch (_) {
    return false;
  } finally {
    try {
      raf?.closeSync();
    } catch (_) {
      // 关不上也不影响判断结果
    }
  }
}

/// 取消牌。调用方拿一个实例就能中途叫停：
/// - 下载循环每次收到数据都会看 [isCancelled]；
/// - [whenCancelled] 让「连接正卡着」时也能**立刻**停 —— 不然点了取消要等下一块数据
///   或者等卡死超时才有反应（实测体感就是「点了没反应」）。
final class DownloadCancelToken {
  bool _cancelled = false;
  final Completer<void> _cancelledSignal = Completer<void>();

  bool get isCancelled => _cancelled;

  /// 取消时完成的信号（没取消就永远不完成）。
  Future<void> get whenCancelled => _cancelledSignal.future;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    if (!_cancelledSignal.isCompleted) _cancelledSignal.complete();
  }
}

/// 下载进度。[total] 可空 —— 服务器没给长度时界面只能显示「已下载 xx MB」。
typedef UpdateDownloadProgress = void Function(int received, int? total);

/// 下载结果 —— 三态，与检查那边同一口径：**「取消」与「失败」不许混成一种**。
/// 失败保留 `.part` 好续传，取消删除 `.part`（取消就是不要了）。
sealed class DownloadOutcome {
  const DownloadOutcome();
}

final class DownloadDone extends DownloadOutcome {
  const DownloadDone(this.file, this.bytes);

  final File file;
  final int bytes;
}

final class DownloadCancelled extends DownloadOutcome {
  const DownloadCancelled();
}

final class DownloadFailed extends DownloadOutcome {
  const DownloadFailed(this.reason);

  final String reason;
}

/// 只卡「响应头到手」的时间。**整包不设总超时** —— 几十兆的文件没有合理的总时长，
/// 卡死由 [updateStallTimeout]（多久没有新字节）来判。
const Duration updateResponseTimeout = Duration(seconds: 20);

/// 流「卡死」的判定：这么久没有新字节就当中断（留着 `.part` 下次续传）。
const Duration updateStallTimeout = Duration(seconds: 30);

/// 把安装包下到 [apkFileFor] 的位置，成功时返回那份文件。
///
/// 断点续传：`.part` 存在且非空就给请求带 `Range`；服务器回 `206` 就接着写，
/// 回 `200`（不支持 Range）就截断重来 —— **服务器给什么就是什么，不赌**。
///
/// [client] 传了就用它（调用方负责关）；不传则内部新建一个用完即关。
Future<DownloadOutcome> downloadApkToFile({
  required String url,
  required String tag,
  http.Client? client,
  Duration responseTimeout = updateResponseTimeout,
  Duration stallTimeout = updateStallTimeout,
  UpdateDownloadProgress? onProgress,
  DownloadCancelToken? cancel,
}) async {
  final own = client == null ? http.Client() : null;
  final c = client ?? own!;
  final apk = apkFileFor(tag);
  final part = apkPartFileFor(tag);
  try {
    purgeOtherDownloads(tag);
    final resumeFrom = part.existsSync() ? part.lengthSync() : 0;

    final req = http.Request('GET', Uri.parse(url))
      ..headers['User-Agent'] = 'findr-app'
      ..headers['Accept'] = '*/*';
    if (resumeFrom > 0) req.headers['Range'] = 'bytes=$resumeFrom-';

    final http.StreamedResponse res;
    try {
      // 🚨 `send()` 在**拿到响应头之前**是取消不掉的（`package:http` 没有 abort）。
      //    所以这里必须和取消牌**赛跑**：谁先到算谁的。否则用户在"已下载 0 B"那一刻点
      //    「取消下载」会毫无反应 —— GitHub 那条跳转链慢，真机上就是这么撞上的。
      final send = c.send(req);
      if (cancel == null) {
        res = await send.timeout(responseTimeout);
      } else {
        final first = await Future.any<Object?>(<Future<Object?>>[
          send,
          cancel.whenCancelled.then<Object?>((_) => null),
        ]).timeout(responseTimeout);
        if (first is! http.StreamedResponse) {
          // 取消先到：把还在路上的响应接住再倒掉，别让它变成未捕获异常或悬挂的连接
          unawaited(
            send.then<void>(
              (late) => late.stream.drain<void>().catchError((Object _) {}),
              onError: (Object _) {},
            ),
          );
          if (part.existsSync()) part.deleteSync();
          return const DownloadCancelled();
        }
        res = first;
      }
    } on TimeoutException {
      return const DownloadFailed('连接发布服务器超时');
    }

    if (res.statusCode == 416) {
      // 服务器说「这个范围不存在」—— 本地那份 `.part` 已经不可信了（多半比目标还大），
      // 删掉重来；留着它每次续传都会被拒。
      if (part.existsSync()) part.deleteSync();
      return const DownloadFailed('服务器拒绝了续传请求，请重试');
    }
    if (res.statusCode != 200 && res.statusCode != 206) {
      return DownloadFailed('下载失败（HTTP ${res.statusCode}）');
    }

    final appending = res.statusCode == 206 && resumeFrom > 0;
    final start = appending ? resumeFrom : 0;
    final total = res.contentLength == null ? null : start + res.contentLength!;

    var received = start;
    onProgress?.call(received, total);

    if (!appending && part.existsSync()) part.deleteSync();
    final sink = part.openWrite(mode: appending ? FileMode.append : FileMode.writeOnly);
    var cancelled = false;
    Object? streamError;
    final done = Completer<void>();
    // ⚠️ 用 listen + Completer 而不是 `await for`：取消要能**立刻**打断一个卡住的连接
    // （`await for` 只有在下一块数据或超时到达时才会看到取消牌）。
    final sub = res.stream.timeout(stallTimeout).listen(
      (chunk) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      },
      onError: (Object e, StackTrace st) {
        if (!done.isCompleted) done.completeError(e, st);
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      cancelOnError: true,
    );
    try {
      if (cancel == null) {
        await done.future;
      } else {
        await Future.any(<Future<void>>[done.future, cancel.whenCancelled]);
        if (cancel.isCancelled && !done.isCompleted) {
          cancelled = true;
          await sub.cancel();
          done.complete();
        } else {
          await done.future;
        }
      }
    } catch (e) {
      streamError = e;
    } finally {
      await sink.flush();
      await sink.close();
    }

    if (cancelled) {
      if (part.existsSync()) part.deleteSync();
      return const DownloadCancelled();
    }
    if (streamError != null) {
      return DownloadFailed(
        streamError is TimeoutException ? '下载中断（网络长时间没有动静）' : '$streamError',
      );
    }

    final written = part.lengthSync();
    if (total != null && written != total) {
      // 少收了就留着 `.part` 等下次续传 —— 别把「传了一半」当成功
      return DownloadFailed('下载不完整（$written / $total 字节）');
    }
    if (!isCompleteApk(part)) {
      // 拿到的东西根本不是安装包（多半是个 HTML 错误页）—— 这份 `.part` 没有续传价值
      if (part.existsSync()) part.deleteSync();
      return const DownloadFailed('下载到的不是安装包（内容不完整）');
    }

    if (apk.existsSync()) apk.deleteSync();
    part.renameSync(apk.path);
    return DownloadDone(apk, written);
  } catch (e) {
    // 网络层的任何异常（连接被重置、DNS、证书……）都收成一句人话，`.part` 留着续传
    return DownloadFailed('$e');
  } finally {
    own?.close();
  }
}
