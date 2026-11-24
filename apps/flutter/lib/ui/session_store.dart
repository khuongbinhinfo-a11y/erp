import 'package:shared_preferences/shared_preferences.dart';
import 'native_session.dart';

/// Persist only the bearer token (never passwords). Android and Windows use
/// platform-backed secure storage; browser storage remains same-origin.
abstract final class ErpSessionStore {
  static const key='erp.session.token.v1';
  static final _valid=RegExp(r'^[A-Za-z0-9_-]{43}$');
  static Future<void> _writes=Future<void>.value();

  static Future<String?> load() async {
    await _writes.catchError((Object _){});
    final prefs=await SharedPreferences.getInstance();
    var value=secureSessionSupported?await readSecureSession(key):prefs.getString(key);
    if(secureSessionSupported){
      final legacy=prefs.getString(key);
      if(value==null&&legacy!=null&&_valid.hasMatch(legacy)){
        await writeSecureSession(key,legacy);value=legacy;
      }
      if(legacy!=null)await prefs.remove(key);
    }
    return value!=null&&_valid.hasMatch(value)?value:null;
  }
  static Future<void> save(String token) async {
    if(!_valid.hasMatch(token))throw ArgumentError.value(token.length,'token length','Invalid session token format');
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
