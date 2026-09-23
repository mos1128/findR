/// 备份打包 / 解包 —— 逐字对应 `packages/core/src/backup/pack.ts`（167 行）。
///
/// 层次从里到外：
///   `manifest.json` + `files/*`  →  ZIP（STORE）  →  容器头  →  `.findrpack`
///
/// **中间没有加密**：`.findrpack` 就是一个前面挂了 7 字节头的 ZIP（决策见 `format.dart`）。
///
/// ⚠️ **顺序很重要：先写媒体、再合并 DB**。媒体写失败时 DB 一个字都没动，
/// 不会留下「卡片在、图片没了」的半吊子状态；反过来则会出现指向空文件的卡片。
library;

import 'dart:convert' show jsonDecode, jsonEncode;
import 'dart:typed_data';

import '../db/driver.dart';
import '../db/migrate.dart';
import '../util/utf8.dart';
import 'crc32.dart';
import 'format.dart';
import 'manifest.dart';
import 'types.dart';
import 'zip.dart';

/// 包内清单文件名 —— **这就是格式的一部分**，改不得（RN 版写出的包按这个名字找）。
const String manifestName = 'manifest.json';

final class BackupDeps {
  const BackupDeps({
    required this.db,
    required this.media,
    this.schemaVersion,
    this.appVersion,
  });

  final SqliteDriver db;
  final MediaStorePort media;

  /// 不传则读库里的 `schema_version`。
  final int? schemaVersion;

  final String? appVersion;
}

final class ExportResult {
  const ExportResult({required this.bytes, required this.report});

  final Uint8List bytes;
  final ExportReport report;
}

/// [secrets] = 要随包带走的 API Key（键名用 `ApiKeySlot.storageKey`）。
///
/// ⚠️ core **不自己读 Key** —— 它在 Keystore 里，只有平台层够得着。这里只负责搬运，
/// 所以「带不带」这个决定必须由调用方显式做出（传 null = 不带）。
/// 别在这里加默认值去读什么，那会让「备份含 Key」这件事变成隐式行为。
Future<ExportResult> exportBackup(
  BackupDeps deps, {
  DateTime? now,
  Map<String, String>? secrets,
}) async {
  final at = now ?? DateTime.now();
  final schemaVer = deps.schemaVersion ?? currentSchemaVersion(deps.db);
  final built = buildManifest(deps.db, schemaVer, at, deps.appVersion);
  final manifest = built.manifest.withApiKeys(secrets);
  final mediaPaths = built.mediaPaths;

  // 第一趟：只读一遍媒体算 size/crc，**读完就丢** ——
  // buildZip 需要精确长度来一次性分配输出缓冲，所以长度必须先知道。
  final mediaPlans = <ZipEntryPlan>[];
  final mediaMeta = <MediaEntryMeta>[];
  final mediaMissing = <String>[];
  for (final path in mediaPaths) {
    final data = await deps.media.read(path);
    if (data == null) {
      // 引用存在但文件没了：**不阻断导出**（否则一张坏卡会让整个备份做不出来），
      // 但要如实报给用户，别让他以为备份是全的
      mediaMissing.add(path);
      continue;
    }
    final entry = ZipEntryPlan(path: path, size: data.length, crc32: crc32(data));
    mediaPlans.add(entry);
    mediaMeta.add(MediaEntryMeta(path: path, size: entry.size, crc32: entry.crc32));
  }

  final fullManifest = manifest.withMediaList(mediaMeta);
  final manifestBytes = utf8Encode(jsonEncode(fullManifest.toJson()));
  final manifestPlan = ZipEntryPlan(
    path: manifestName,
    size: manifestBytes.length,
    crc32: crc32(manifestBytes),
  );

  // 第二趟：真正组装，逐个文件读入并直接落进输出缓冲
  final zip = await buildZip(<ZipEntryPlan>[manifestPlan, ...mediaPlans], (path) async {
    if (path == manifestName) return manifestBytes;
    final data = await deps.media.read(path);
    if (data == null) throw StateError('媒体文件在备份过程中消失了：$path');
    return data;
  }, at);

  final bytes = packContainer(zip);

  return ExportResult(
    bytes: bytes,
    report: ExportReport(
      cards: manifest.cards.length,
      categories: manifest.categories.length,
      locations: manifest.locations.length,
      aliases: manifest.aliases.length,
      mediaTotal: mediaPaths.length,
      mediaWritten: mediaPlans.length,
      mediaMissing: mediaMissing,
      bytes: bytes.length,
    ),
  );
}

/// 包里声明的 schema 版本与导出时间，用于 UI 提示「你正在导入一份 2026-09-18 的备份」。
final class ImportManifestInfo {
  const ImportManifestInfo({
    required this.schemaVersion,
    required this.exportedAt,
    required this.cards,
    required this.media,
  });

  final int schemaVersion;
  final String exportedAt;
  final int cards;
  final int media;
}

final class ImportResult {
  const ImportResult({
    required this.report,
    required this.manifestInfo,
    required this.apiKeys,
  });

  final ImportReport report;
  final ImportManifestInfo manifestInfo;

  /// 包里带回来的 API Key（键名 = `ApiKeySlot.storageKey`）。
  ///
  /// ⚠️ **core 不会自己去写 Keystore** —— 那是平台层的事（core 不该依赖
  /// `flutter_secure_storage`）。这里只是把值交给调用方，写不写由界面决定。
  /// 空 map = 这份包没带 Key。
  final Map<String, String> apiKeys;
}

/// 浅层校验 + 转成强类型清单。
///
/// ⚠️ 相对 TS 的一处必要偏差：TS 的 `validateManifest` 只是**判完再原样返回那个对象**
/// （JS 里 JSON 对象本来就能当 `BackupManifest` 用），Dart 没有这种鸭子类型，
/// 所以这里顺便完成 `fromJson` 转换。**校验规则与报错文案逐条对齐 TS**。
BackupManifest validateManifest(Object? value) {
  if (value is! Map) throw const FormatException('备份清单不是对象');
  final m = value.cast<String, Object?>();
  if (m['format'] != 'findrpack') {
    throw FormatException('备份清单标识不符：${m['format']}');
  }
  for (final key in const <String>['cards', 'categories', 'locations', 'aliases']) {
    if (m[key] is! List) throw FormatException('备份清单缺少数组字段 $key');
  }
  final rawSchema = m['schemaVersion'];
  if (rawSchema is! num) throw const FormatException('备份清单缺少 schemaVersion');
  if (rawSchema.toInt() > schemaVersion) {
    throw FormatException(
      '这份备份来自更新的版本（schema ${rawSchema.toInt()} > 本机 $schemaVersion），请先升级 App 再导入',
    );
  }
  return BackupManifest.fromJson(m);
}

Future<ImportResult> importBackup(BackupDeps deps, Uint8List bytes) async {
  // 标识不符 / 版本不认 / 文件被截断 / 成员 CRC 不符，都会在这里就炸掉，
  // **绝不会走到写库那一步**（先 readZip 全量读出并逐个验 CRC，再动任何数据）
  final zipBytes = unpackContainer(bytes);
  final entries = readZip(zipBytes);

  final manifestEntry = _firstOrNull(entries, (e) => e.path == manifestName);
  if (manifestEntry == null) throw const FormatException('备份包内缺少 manifest.json');
  final manifest = validateManifest(jsonDecode(utf8Decode(manifestEntry.data)));

  var mediaWritten = 0;
  var mediaOverwritten = 0;
  final mediaEntries = entries.where((e) => e.path != manifestName).toList();
  for (final e in mediaEntries) {
    final existsFn = deps.media.exists;
    final existed = existsFn != null
        ? await existsFn(e.path)
        : (await deps.media.read(e.path)) != null;
    await deps.media.write(e.path, e.data);
    mediaWritten++;
    if (existed) mediaOverwritten++;
  }

  final merged = mergeManifest(deps.db, manifest);

  return ImportResult(
    report: merged.withMedia(mediaWritten: mediaWritten, mediaOverwritten: mediaOverwritten),
    manifestInfo: ImportManifestInfo(
      schemaVersion: manifest.schemaVersion,
      exportedAt: manifest.exportedAt,
      cards: manifest.cards.length,
      // ⚠️ `media` 缺失（老包）才退回「按实际成员数」；**空数组不退回** ——
      // 这正是 `media` 在 [BackupManifest] 里是 `List?` 而不是 `List` 的原因。
      media: manifest.media?.length ?? mediaEntries.length,
    ),
    apiKeys: manifest.apiKeys ?? const <String, String>{},
  );
}

T? _firstOrNull<T>(Iterable<T> items, bool Function(T) test) {
  for (final item in items) {
    if (test(item)) return item;
  }
  return null;
}
