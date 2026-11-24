import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as mobile;
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;
import 'local_driver.dart';

LocalDriver createDriver()=>_SqliteDriver();
class _SqliteDriver implements AtomicLocalDriver {
  Future<mobile.Database>? _opening;
  Future<mobile.Database> _open()=>_opening??=_connect();
  Future<mobile.Database> _connect()async{
    final dir=await getApplicationSupportDirectory();
    final path=Uri.directory(dir.path).resolve('erp-local-v1.sqlite').toFilePath();
    final desktop=Platform.isWindows||Platform.isLinux||Platform.isMacOS;
    if(desktop)ffi.sqfliteFfiInit();
    final factory=desktop?ffi.databaseFactoryFfi:mobile.databaseFactory;
    return factory.openDatabase(path,options:mobile.OpenDatabaseOptions(
      version:1,onCreate:(db,version)=>db.execute(
        'CREATE TABLE records (k TEXT PRIMARY KEY, v TEXT NOT NULL)')));
  }
  @override Future<String?> read(String key)async{
    final rows=await (await _open()).query('records',columns:['v'],where:'k = ?',whereArgs:[key],limit:1);
    return rows.isEmpty?null:rows.first['v'] as String;
  }
  @override Future<void> write(String key,String value)async{
    await (await _open()).insert('records',{'k':key,'v':value},conflictAlgorithm:mobile.ConflictAlgorithm.replace);
  }
  @override Future<bool> compareAndSwap(String key,String? expected,String? next)async{
    return (await _open()).transaction<bool>((tx)async{
      final rows=await tx.query('records',columns:['v'],where:'k = ?',whereArgs:[key],limit:1);
      final old=rows.isEmpty?null:rows.first['v'] as String;
      if(old!=expected)return false;
      if(next==null){await tx.delete('records',where:'k = ?',whereArgs:[key]);}
      else{await tx.insert('records',{'k':key,'v':next},conflictAlgorithm:mobile.ConflictAlgorithm.replace);}
      return true;
    });
  }
  @override Future<void> remove(String key)async{
    await (await _open()).delete('records',where:'k = ?',whereArgs:[key]);
  }
}
