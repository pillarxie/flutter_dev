import 'dart:io';

/// Keep WebView2's writable profile outside the executable/install directory.
Future<String> windowsWebViewUserDataFolder({
  Map<String, String>? environment,
}) async {
  final root = (environment ?? Platform.environment)['LOCALAPPDATA'];
  if (root == null || root.trim().isEmpty || !Directory(root).isAbsolute) {
    throw StateError('无法确定 LOCALAPPDATA 用户目录，不能创建 WebView2 数据目录。');
  }
  final folder = Directory.fromUri(
    Directory(root).uri.resolve('flutter_dev/WebView2/'),
  );
  await folder.create(recursive: true);
  return folder.path;
}
