import 'dart:io';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
bool get secureSessionSupported=>Platform.isAndroid||Platform.isWindows;
const _secure=FlutterSecureStorage(aOptions:AndroidOptions(encryptedSharedPreferences:true));
Future<String?> readSecureSession(String key)=>_secure.read(key:key);
Future<void> writeSecureSession(String key,String token)=>_secure.write(key:key,value:token);
Future<void> deleteSecureSession(String key)=>_secure.delete(key:key);
