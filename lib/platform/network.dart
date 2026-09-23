/// 网络连通性的**近似**判断。
///
/// 对应 RN 的 `expo-network` + `useNetworkState()`（`app/index.tsx:217`
/// 的 `const offline = network.isConnected === false`）。
///
/// ⚠️ **它只用来决定「要不要提前说一句」，绝不用来决定「能不能发请求」**。
/// 插件给的是**无线电状态**（有没有连上 Wi-Fi / 蜂窝），不是「这个地址通不通」：
/// 连着一个没有出口的 Wi-Fi、或代理挂了，它照样报「已连接」。
/// 所以：
/// - 说「当前无网络」时，措辞是提示性的，不拦用户操作；
/// - 拿不到结果（插件不可用 / 抛错）一律**当成有网** —— 宁可少提示一句，
///   也不要在一个网络明明正常的设备上反复喊「无网」。
library;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 当前**看起来**有没有网。`true` 是保守默认值（见文件头）。
final onlineProvider = StreamProvider<bool>((ref) async* {
  final connectivity = Connectivity();

  bool online(List<ConnectivityResult> results) => results.hasConnectivity;

  try {
    yield online(await connectivity.checkConnectivity());
  } catch (_) {
    // 插件在这个平台上不可用：按「有网」处理，别吓唬用户
    yield true;
  }
  try {
    yield* connectivity.onConnectivityChanged.map(online);
  } catch (_) {
    // 订阅不上就停在上面那一次的结果（一般是 true）
  }
});

/// 只读一次，给不需要订阅的地方用（通知/一次性判断）。
Future<bool> isOnlineNow() async {
  try {
    return (await Connectivity().checkConnectivity()).hasConnectivity;
  } catch (_) {
    return true;
  }
}
