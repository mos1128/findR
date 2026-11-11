import 'dart:io';

import 'package:findr_app/capture/photo_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/image_picker');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('findr_picker_');
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    root.deleteSync(recursive: true);
  });

  test('选很多张图时仅返回文件引用，不提前读取整批原图', () async {
    final paths = List.generate(20, (i) => '${root.path}/not-loaded-$i.jpg');
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'pickMultiImage');
      return paths;
    });

    final selected = await pickPhotos();
    expect(selected.map((file) => file.path), paths);
  });

  test('轮到某张图片时才读取，并保留单张大小限制', () async {
    final file = File('${root.path}/photo.jpg');
    final bytes = Uint8List.fromList([1, 2, 3]);
    file.writeAsBytesSync(bytes);
    expect(await readPhoto(XFile(file.path)), bytes);

    final oversized = File('${root.path}/large.jpg').openSync(mode: FileMode.write);
    oversized.truncateSync(maxPickBytes + 1);
    oversized.closeSync();
    await expectLater(readPhoto(XFile('${root.path}/large.jpg')), throwsA(isA<PickError>()));
  });

  test('文件失效时给出明确错误，由录入条排除该附件', () async {
    await expectLater(readPhoto(XFile('${root.path}/missing.jpg')), throwsA(isA<PickError>()));
  });
}
