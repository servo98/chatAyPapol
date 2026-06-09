import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;

class ApiException implements Exception {
  final String message;
  final int status;
  ApiException(this.message, this.status);
  @override
  String toString() => message;
}

class Api {
  String base = '';
  String? token;

  Uri _u(String path) => Uri.parse('$base$path');
  String fileUrl(String path) => path.startsWith('http') ? path : '$base$path';

  Map<String, String> get _headers => {
        'content-type': 'application/json',
        if (token != null) 'authorization': 'Bearer $token',
      };

  Future<dynamic> _send(String method, String path, [Object? body]) async {
    final req = http.Request(method, _u(path))..headers.addAll(_headers);
    if (body != null) req.body = jsonEncode(body);
    final res = await http.Response.fromStream(await req.send());
    final decoded = res.body.isEmpty ? null : jsonDecode(utf8.decode(res.bodyBytes));
    if (res.statusCode >= 400) {
      throw ApiException(
          (decoded is Map ? decoded['error'] : null) ?? 'Error ${res.statusCode}', res.statusCode);
    }
    return decoded;
  }

  Future<dynamic> get(String p) => _send('GET', p);
  Future<dynamic> post(String p, [Object? b]) => _send('POST', p, b ?? {});
  Future<dynamic> patch(String p, Object b) => _send('PATCH', p, b);
  Future<dynamic> put(String p, Object b) => _send('PUT', p, b);
  Future<dynamic> delete(String p) => _send('DELETE', p);

  Future<dynamic> upload(String path, Uint8List bytes, String filename,
      {Map<String, String> fields = const {}}) async {
    final req = http.MultipartRequest('POST', _u(path))
      ..headers['authorization'] = 'Bearer $token'
      ..fields.addAll(fields)
      ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename));
    final res = await http.Response.fromStream(await req.send());
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    if (res.statusCode >= 400) {
      throw ApiException(decoded['error'] ?? 'Error ${res.statusCode}', res.statusCode);
    }
    return decoded;
  }
}
