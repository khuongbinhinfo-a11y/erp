import 'package:shared_preferences/shared_preferences.dart';
import 'native_session.dart';

/// Persist only the bearer token (never passwords), scoped to this app origin.
abstract final class ErpSessionStore {
  static const key='erp.session.token.v1';
  static Future<void> _writes=Future<void>.value();

  static Future<String?> load() async {
    await _writes;
    final prefs=await SharedPreferences.getInstance();
    var value=secureSessionSupported?await readSecureSession(key):prefs.getString(key);
    if(secureSessionSupported){
      final legacy=prefs.getString(key);
      if(value==null&&legacy!=null&&RegExp(r'^[A-Za-z0-9_-]{43}
    return value!=null && RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(value)
      ? value : null;
  }

  static Future<void> save(String token) async {
    if(!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(token)) {
      throw ArgumentError.value(token.length,'token length','Invalid session token format');
    }
    _writes=_writes.catchError((Object _){}).then((_)async{
      final prefs=await SharedPreferences.getInstance();
      if(secureSessionSupported){await writeSecureSession(key,token);await prefs.remove(key);}
      else{await prefs.setString(key,token);}
    });
    await _writes;
  }

  static Future<void> clear() async {
    _writes=_writes.catchError((Object _){}).then((_)async{
      final prefs=await SharedPreferences.getInstance();
      await prefs.remove(key);
      if(secureSessionSupported)await deleteSecureSession(key);
    });
    await _writes;
  }
}
).hasMatch(legacy)){
        await writeSecureSession(key,legacy);value=legacy;
      }
      if(legacy!=null)await prefs.remove(key);
    }
    return value!=null && RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(value)
      ? value : null;
  }

  static Future<void> save(String token) async {
    if(!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(token)) {
      throw ArgumentError.value(token.length,'token length','Invalid session token format');
    }
    _writes=_writes.catchError((Object _){}).then((_)async{
      final prefs=await SharedPreferences.getInstance();
      await prefs.setString(key,token);
    });
    await _writes;
  }

  static Future<void> clear() async {
    _writes=_writes.catchError((Object _){}).then((_)async{
      final prefs=await SharedPreferences.getInstance();
      await prefs.remove(key);
    });
    await _writes;
  }
}
