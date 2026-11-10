/// 备份打包 / 解包。
///
/// 层次从里到外：
///   `manifest.json` + `files/*`  →  ZIP（STORE）  →  容器头  →  `.findrpack`
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

/// 包内清单文件名 —— **这就是格式的一部分**，改不得（读取侧按这个名字找）。
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

/// [secrets] = 随包带走的 API Key（键名用 `ApiKeySlot.storageKey`）。
///
/// ⚠️ core **不自己读 Key** —— 它在 Keystore 里，只有平台层够得着。这里只负责搬运，
/// 平台层总是传入本机全部 Key（空 map = 本机没配）。
Future<ExportResult> exportBackup(
  BackupDeps deps, {
  DateTime? now,
  Map<String, String>? secrets,
  List<String>? extraMediaPaths,
}) async {
  final builder = BytesBuilder(copy: false);
  final report = await exportBackupStream(
    deps,
    now: now,
    secrets: secrets,
    extraMediaPaths: extraMediaPaths,
    write: builder.add,
  );
  return ExportResult(bytes: builder.takeBytes(), report: report);
}

/// 流式导出：ZIP 数据按块交给 [write]，峰值内存不再随媒体总量增长。
///
/// 两遍流式读每个媒体：
/// 1. 第一遍只算 size / crc（ZIP 成员头必须先写这两个值）；
/// 2. 第二遍边读边写，顺便校验文件在两次读取之间没有变化。
///
/// 仍然是「manifest 第一个成员」的顺序 —— 格式与 [exportBackup] 的产物一致。
Future<ExportReport> exportBackupStream(
  BackupDeps deps, {
  DateTime? now,
  Map<String, String>? secrets,
  List<String>? extraMediaPaths,
  required ZipChunkWriter write,
}) async {
  final at = now ?? DateTime.now();
  final schemaVer = deps.schemaVersion ?? currentSchemaVersion(deps.db);
  final built = buildManifest(deps.db, schemaVer, at, deps.appVersion);
  final manifest = built.manifest.withApiKeys(secrets);
  final mediaPaths = <String>{
    ...built.mediaPaths,
    ...?extraMediaPaths,
  }.toList();

  final mediaPlans = <({String path, int size, int crc})>[];
  final mediaMeta = <MediaEntryMeta>[];
  final mediaMissing = <String>[];
  for (final path in mediaPaths) {
    final measured = await _measureMedia(deps.media, path);
    if (measured == null) {
      // 引用存在但文件没了：**不阻断导出**（否则一张坏卡会让整个备份做不出来），
      // 但要如实报给用户，别让他以为备份是全的
      mediaMissing.add(path);
      continue;
    }
    mediaPlans.add((path: path, size: measured.size, crc: measured.crc));
    mediaMeta.add(
      MediaEntryMeta(path: path, size: measured.size, crc32: measured.crc),
    );
  }

  final fullManifest = manifest.withMediaList(mediaMeta);
  final manifestBytes = utf8Encode(jsonEncode(fullManifest.toJson()));

  final header = encodeHeader();
  await write(header);
  final zip = ZipStreamWriter(write: write, mtime: at);
  await zip.addBytes(manifestName, manifestBytes);
  for (final plan in mediaPlans) {
    await zip.addFile(
      plan.path,
      size: plan.size,
      crc: plan.crc,
      data: _openMedia(deps.media, plan.path),
    );
  }
  await zip.finish();

  return ExportReport(
    cards: manifest.cards.length,
    categories: manifest.categories.length,
    locations: manifest.locations.length,
    aliases: manifest.aliases.length,
    mediaTotal: mediaPaths.length,
    mediaWritten: mediaPlans.length,
    mediaMissing: mediaMissing,
    bytes: header.length + zip.bytesWritten,
  );
}

/// 第一遍：流式算 size / crc，不保留文件内容。
Future<({int size, int crc})?> _measureMedia(
  MediaStorePort media,
  String path,
) async {
  final streamer = _streamerOf(media);
  if (streamer == null) {
    final data = await media.read(path);
    if (data == null) return null;
    return (size: data.length, crc: crc32(data));
  }
  final exists = media.exists;
  if (exists != null && !await exists(path)) return null;
  final crc = Crc32();
  var size = 0;
  try {
    await for (final chunk in streamer.openRead(path)) {
      final bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
      size += bytes.length;
      crc.add(bytes);
    }
  } catch (_) {
    // 读不出来就当「文件不在」：导出不该被一张坏卡挡住
    return null;
  }
  return (size: size, crc: crc.value);
}

/// 第二遍：重新打开同一个文件，按块交给 ZIP 写入器。
Stream<List<int>> _openMedia(MediaStorePort media, String path) {
  final streamer = _streamerOf(media);
  if (streamer != null) return streamer.openRead(path);
  return _readAsStream(media, path);
}

/// 两个接口没有继承关系，Dart 不会自动类型提升 —— 显式收窄。
StreamingMediaStore? _streamerOf(MediaStorePort media) =>
    media is StreamingMediaStore ? media as StreamingMediaStore : null;

Stream<List<int>> _readAsStream(MediaStorePort media, String path) async* {
  final data = await media.read(path);
  if (data == null) throw StateError('媒体文件在备份过程中消失了：$path');
  yield data;
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
  ///
  /// `null` = 老包没有 `apiKeys` 字段；空 map = 包带了这个字段但本机一把都没配。
  final Map<String, String>? apiKeys;
}

/// 浅层校验 + 转成强类型清单。
///
/// ⚠️ 这里**顺便完成 `fromJson` 转换**：判完就返回强类型对象，而不是把入参原样退回。
/// **校验规则与报错文案是既定契约** —— 老备份包要能导入、坏包的报错要能被用户看懂。
BackupManifest validateManifest(Object? value) {
  if (value is! Map) throw const FormatException('备份清单不是对象');
  final m = value.cast<String, Object?>();
  if (m['format'] != 'findrpack') {
    throw FormatException('备份清单标识不符：${m['format']}');
  }
  for (final key in const <String>[
    'cards',
    'categories',
    'locations',
    'aliases',
  ]) {
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

Future<ImportResult> importBackup(
  BackupDeps deps,
  Uint8List bytes, {
  bool fullReplace = false,
}) async {
  // 标识不符 / 版本不认 / 文件被截断 / 成员 CRC 不符，都会在这里就炸掉，
  // **绝不会走到写库那一步**（先 readZip 全量读出并逐个验 CRC，再动任何数据）
  final zipBytes = unpackContainer(bytes);
  final entries = readZip(zipBytes);

  final manifestEntry = _firstOrNull(entries, (e) => e.path == manifestName);
  if (manifestEntry == null) {
    throw const FormatException('备份包内缺少 manifest.json');
  }
  final manifest = validateManifest(jsonDecode(utf8Decode(manifestEntry.data)));

  final mediaEntries = entries.where((e) => e.path != manifestName).toList();
  for (final e in mediaEntries) {
    // 白名单：包内成员只能是媒体目录下的相对路径。
    // 我们自己导出的包永远满足这条；挡的是「别人传过来的、被改过的、或损坏的」包 ——
    // 没有这行，一个叫 `findr.sqlite` 的成员会覆盖正在使用的数据库。
    if (!e.path.startsWith('files/')) {
      throw FormatException('备份包里有非法成员路径：${e.path}');
    }
  }

  // 全量导入：所有成员已校验完，现在才允许清空本机。
  if (fullReplace) await _resetBeforeFullImport(deps);

  var mediaWritten = 0;
  var mediaOverwritten = 0;
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

  return _importResult(
    manifest: manifest,
    merged: merged,
    mediaWritten: mediaWritten,
    mediaOverwritten: mediaOverwritten,
    mediaEntryCount: mediaEntries.length,
  );
}

/// 流式导入：从 [source] 按需读取，不把整个 `.findrpack` 读进内存。
///
/// **两遍**，与导出一样先校验后写：
/// 1. 读中央目录与 manifest，逐个校验媒体成员的 CRC（不保留数据）；
/// 2. 全部校验通过后，再逐个读出并写入媒体。
/// 这样坏包不会写一半；峰值内存 = 单个成员（通常是最大的一张图/一段录音）。
Future<ImportResult> importBackupStream(
  BackupDeps deps,
  BackupByteSource source, {
  bool fullReplace = false,
}) async {
  final total = await source.length();
  if (total < backupHeaderLen) {
    throw const FormatException('备份文件过短，不是有效的 .findrpack');
  }
  final header = await source.read(0, backupHeaderLen);
  validateBackupHeader(header);
  final entries = await readZipDirectory(source, baseOffset: backupHeaderLen);

  final manifestEntry = _firstOrNull(entries, (e) => e.path == manifestName);
  if (manifestEntry == null) {
    throw const FormatException('备份包内缺少 manifest.json');
  }
  final manifestBytes = await readZipEntry(
    source,
    manifestEntry,
    totalLength: total,
  );
  final manifest = validateManifest(jsonDecode(utf8Decode(manifestBytes)));

  final mediaEntries = entries.where((e) => e.path != manifestName).toList();
  for (final e in mediaEntries) {
    // 白名单：包内成员只能是媒体目录下的相对路径。
    if (!e.path.startsWith('files/')) {
      throw FormatException('备份包里有非法成员路径：${e.path}');
    }
  }
  // 第一遍：只验 CRC，不写任何文件。
  for (final e in mediaEntries) {
    await verifyZipEntry(source, e, totalLength: total);
  }

  // 全量导入：所有成员已校验完，现在才允许清空本机。
  if (fullReplace) await _resetBeforeFullImport(deps);

  // 第二遍：全部成员都验过了，再落盘。
  var mediaWritten = 0;
  var mediaOverwritten = 0;
  for (final e in mediaEntries) {
    final data = await readZipEntry(source, e, totalLength: total);
    final existsFn = deps.media.exists;
    final existed = existsFn != null
        ? await existsFn(e.path)
        : (await deps.media.read(e.path)) != null;
    await deps.media.write(e.path, data);
    mediaWritten++;
    if (existed) mediaOverwritten++;
  }

  final merged = mergeManifest(deps.db, manifest);
  return _importResult(
    manifest: manifest,
    merged: merged,
    mediaWritten: mediaWritten,
    mediaOverwritten: mediaOverwritten,
    mediaEntryCount: mediaEntries.length,
  );
}

ImportResult _importResult({
  required BackupManifest manifest,
  required ImportReport merged,
  required int mediaWritten,
  required int mediaOverwritten,
  required int mediaEntryCount,
}) => ImportResult(
  report: merged.withMedia(
    mediaWritten: mediaWritten,
    mediaOverwritten: mediaOverwritten,
  ),
  manifestInfo: ImportManifestInfo(
    schemaVersion: manifest.schemaVersion,
    exportedAt: manifest.exportedAt,
    cards: manifest.cards.length,
    // ⚠️ `media` 缺失（老包）才退回「按实际成员数」；**空数组不退回** ——
    // 这正是 `media` 在 [BackupManifest] 里是 `List?` 而不是 `List` 的原因。
    media: manifest.media?.length ?? mediaEntryCount,
  ),
  apiKeys: manifest.apiKeys,
);

/// 全量导入：先清 DB，再清媒体。
///
/// 顺序是刻意的：DB 先空掉，就不会出现「卡片还在、文件已经删了」的中间态；
/// 媒体清空失败时留下的也只是孤儿文件，下次启动的回收会处理。
Future<void> _resetBeforeFullImport(BackupDeps deps) async {
  final media = deps.media is ResettableMediaStore
      ? deps.media as ResettableMediaStore
      : null;
  if (media == null) {
    throw StateError('全量导入需要可清空的媒体存储');
  }
  clearAllUserData(deps.db);
  await media.reset();
}

T? _firstOrNull<T>(Iterable<T> items, bool Function(T) test) {
  for (final item in items) {
    if (test(item)) return item;
  }
  return null;
}
