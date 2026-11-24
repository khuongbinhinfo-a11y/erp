bool get secureSessionSupported=>false;
Future<String?> readSecureSession(String key)async=>null;
Future<void> writeSecureSession(String key,String token)async=>throw UnsupportedError('Native only');
Future<void> deleteSecureSession(String key)async=>throw UnsupportedError('Native only');
