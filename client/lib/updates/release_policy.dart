import 'update_contract.dart';

class ReleaseVersion implements Comparable<ReleaseVersion> {
  ReleaseVersion._(this.parts, this.pre, this.label);
  final List<int> parts;
  final List<String> pre;
  final String label;
  static ReleaseVersion parse(String raw) {
    final label = raw.startsWith('v') ? raw.substring(1) : raw;
    final m = RegExp(
      r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z.-]+))?(?:\+([0-9A-Za-z.-]+))?$',
    ).firstMatch(label);
    if (m == null) throw FormatException('版本号不是有效的语义版本：$raw');
    final pre = m[4]?.split('.') ?? <String>[];
    for (final p in [...pre, ...?m[5]?.split('.')]) {
      if (p.isEmpty) throw const FormatException('版本号包含空标识符');
    }
    for (final p in pre) {
      if (RegExp(r'^0\d+$').hasMatch(p)) {
        throw const FormatException('预发布版本数字不能有前导零');
      }
    }
    return ReleaseVersion._(
      [int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!)],
      pre,
      label,
    );
  }

  @override
  int compareTo(ReleaseVersion other) {
    for (var i = 0; i < 3; i++) {
      final c = parts[i].compareTo(other.parts[i]);
      if (c != 0) return c;
    }
    if (pre.isEmpty || other.pre.isEmpty) {
      return pre.isEmpty ? (other.pre.isEmpty ? 0 : 1) : -1;
    }
    for (var i = 0; i < pre.length && i < other.pre.length; i++) {
      final a = int.tryParse(pre[i]);
      final b = int.tryParse(other.pre[i]);
      final c = a != null && b != null
          ? a.compareTo(b)
          : a != null
          ? -1
          : b != null
          ? 1
          : pre[i].compareTo(other.pre[i]);
      if (c != 0) return c;
    }
    return pre.length.compareTo(other.pre.length);
  }
}

String assetName(String version, UpdatePlatformInfo info) {
  if (info.os == 'windows' && info.architecture == 'x64') {
    return 'bb-$version-windows-x64.zip';
  }
  if (info.os == 'android' &&
      const [
        'arm64-v8a',
        'armeabi-v7a',
        'x86_64',
      ].contains(info.architecture)) {
    return 'bb-$version-android-${info.architecture}.apk';
  }
  throw StateError('暂不支持此平台或 CPU 架构的自动更新。');
}

bool secureUri(Uri u) =>
    u.scheme == 'https' &&
    u.port == 443 &&
    u.userInfo.isEmpty &&
    !u.hasFragment;

UpdateRelease? selectRelease(List<dynamic> rows, UpdatePlatformInfo info) {
  final installed = ReleaseVersion.parse(info.version);
  Map<String, dynamic>? selected;
  ReleaseVersion? newest;
  for (final raw in rows) {
    final row = raw as Map<String, dynamic>;
    if (row['draft'] != false || row['prerelease'] != false) continue;
    ReleaseVersion version;
    try {
      version = ReleaseVersion.parse(row['tag_name'] as String);
    } on FormatException {
      continue;
    }
    if (version.pre.isNotEmpty || version.compareTo(installed) <= 0) continue;
    if (newest == null || version.compareTo(newest) > 0) {
      newest = version;
      selected = row;
    } else if (version.compareTo(newest) == 0) {
      throw StateError('多个 Release 使用相同版本，无法安全选择。');
    }
  }
  if (selected == null) return null;
  final tag = selected['tag_name'] as String;
  final version = newest!.label;
  final assets = selected['assets'] as List<dynamic>;
  UpdateAsset pick(String name) {
    final matches = assets
        .cast<Map<String, dynamic>>()
        .where((a) => a['name'] == name)
        .toList();
    if (matches.length != 1) throw StateError('更新缺少唯一的 $name，不能下载安装。');
    final a = matches.single;
    final uri = Uri.parse(a['browser_download_url'] as String);
    if (!secureUri(uri) ||
        uri.hasQuery ||
        uri.host != 'github.com' ||
        uri.pathSegments.join('/') !=
            'iiishop/BB/releases/download/$tag/$name' ||
        a['state'] != 'uploaded' ||
        a['id'] is! int ||
        a['size'] is! int ||
        (a['size'] as int) <= 0) {
      throw StateError('Release 资产来源或元数据不符合预期。');
    }
    return UpdateAsset(
      id: a['id'] as int,
      name: name,
      url: uri,
      size: a['size'] as int,
    );
  }

  final html = Uri.parse(selected['html_url'] as String);
  if (!secureUri(html) ||
      html.host != 'github.com' ||
      html.hasQuery ||
      html.pathSegments.join('/') != 'iiishop/BB/releases/tag/$tag') {
    throw StateError('Release 来源不符合预期仓库。');
  }
  return UpdateRelease(
    id: selected['id'] as int,
    tag: tag,
    version: version,
    body: selected['body'] as String? ?? '',
    htmlUrl: html,
    asset: pick(assetName(version, info)),
    checksums: pick('SHA256SUMS'),
  );
}

String checksumFor(String text, String asset) {
  String? result;
  for (final line in text.split('\n')) {
    if (line.trim().isEmpty) continue;
    final match = RegExp(r'^([a-fA-F0-9]{64}) [ *](?:\./)?([^\r\n]+)\r?$')
        .firstMatch(line);
    if (match == null) throw const FormatException('SHA256SUMS 格式不正确。');
    if (match[2] == asset) {
      if (result != null) throw const FormatException('SHA256SUMS 包含重复资产。');
      result = match[1]!.toLowerCase();
    }
  }
  if (result == null) throw const FormatException('SHA256SUMS 未包含所选安装包。');
  return result;
}
