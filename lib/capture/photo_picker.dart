/// 拍照与相册选取 —— 对应 RN 的 `capture/picker.ts`（23 行）+ `CameraModal.tsx`（144 行）。
///
/// ⚠️ **与 RN 的一处刻意不同，写在最前面**：
/// RN 用的是 `expo-camera` 的**应用内取景器**（`CameraModal.tsx`），
/// 这里改用 `image_picker` 调**系统相机**。
///
/// 原因是风险不对称：应用内取景器要自己拥有一套相机会话的生命周期
/// （权限、预览比例、旋转、前后台切换、多 ROM 差异），而这套东西**只有上了真机才知道有没有写对**
/// —— 本机没有 Android SDK、更没有真机，等于闭着眼写。
/// 系统相机是 OS 提供的，调起来几乎不可能出岔子。
///
/// 换来的是「每拍一张要回一次 App」这个代价。**构图引导与「不限张数」因此挪到录入坞上**
/// （见 `composer.dart` 的拍摄提示条）：拍完回到录入坞，引导和已拍张数就在眼前，
/// 想接着拍再点「再拍一张」即可。需求 173「不限制张数 + 给出构图引导」两条都还在。
///
/// 哪天要做成真·取景器连拍，把这里换成 `camera` 包即可 —— **只有本文件需要改**。
library;

import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';

/// 一张刚选/拍到的原图（**还没压缩**）。
final class RawPhoto {
  const RawPhoto({required this.bytes, required this.name});

  final Uint8List bytes;

  /// 用于报错时点名（系统相机的产物常常没有有意义的名字，那也没关系）。
  final String name;
}

/// 读进来之前就挡住的单张上限。比 `image_compress.dart` 的 [maxSourceBytes] 更严一档，
/// 目的是**别把它读进内存之后再拒绝** —— 那一下已经是几十 MB 了。
const int maxPickBytes = 24 * 1024 * 1024;

/// 选图/拍照过程中的失败。**消息都是人话**，调用方直接展示即可。
final class PickError implements Exception {
  const PickError(this.message);

  final String message;

  @override
  String toString() => message;
}

final ImagePicker _picker = ImagePicker();

/// 用系统相机拍一张。用户取消返回 null。
Future<RawPhoto?> takePhoto() async {
  final file = await _picker.pickImage(
    source: ImageSource.camera,
    // ⚠️ **不要传 imageQuality**：插件自带的压缩会先把图有损重编一遍，
    // 我们再压一次就是二压，画质白丢。压缩只由我们这一层做（`image_compress.dart`）。
    imageQuality: null,
  );
  if (file == null) return null;
  return _readOne(file);
}

/// 从相册选，**不限张数**（需求 173：流程备忘常要 5~8 张截图）。用户取消返回空表。
Future<List<RawPhoto>> pickPhotos() async {
  final files = await _picker.pickMultiImage(imageQuality: null);
  if (files.isEmpty) return const <RawPhoto>[];
  return <RawPhoto>[for (final f in files) await _readOne(f)];
}

Future<RawPhoto> _readOne(XFile file) async {
  final length = await file.length();
  if (length > maxPickBytes) {
    throw PickError(
      '「${_shortName(file.name)}」有 ${(length / (1024 * 1024)).toStringAsFixed(1)}MB，'
      '超过了单张 ${maxPickBytes ~/ (1024 * 1024)}MB 的上限。',
    );
  }
  try {
    return RawPhoto(bytes: await file.readAsBytes(), name: _shortName(file.name));
  } catch (e) {
    // 微信 / 云盘转存来的 `content://` 虚拟文档常常拿不到可读流 —— 这是真实存在的一类，
    // 所以给它一句明确的话，而不是把底层异常原样抛给用户
    throw PickError('读不了这张图（${_shortName(file.name)}）：$e');
  }
}

String _shortName(String name) {
  final t = name.trim();
  if (t.isEmpty) return '图片';
  return t.length <= 24 ? t : t.substring(0, 24);
}
