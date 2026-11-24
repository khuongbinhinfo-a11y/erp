import 'package:idb_shim/idb.dart';
import 'package:idb_shim/idb_browser.dart';
import 'local_driver.dart';

LocalDriver createDriver()=>_IndexedDriver();
class _IndexedDriver implements LocalDriver {
  Future<Database>? _opening;
  Future<Database> _open()=>_opening??=idbFactoryWeb.open('erp-local-v1',version:1,
    onUpgradeNeeded:(event)=>event.database.createObjectStore('records'));
  @override Future<String?> read(String key)async{
    final tx=(await _open()).transaction('records',idbModeReadOnly);
    final value=await tx.objectStore('records').getObject(key);
    await tx.completed;
    return value as String?;
  }
  @override Future<void> write(String key,String value)async{
    final tx=(await _open()).transaction('records',idbModeReadWrite);
    await tx.objectStore('records').put(value,key);
    await tx.completed;
  }
  @override Future<void> remove(String key)async{
    final tx=(await _open()).transaction('records',idbModeReadWrite);
    await tx.objectStore('records').delete(key);
    await tx.completed;
  }
}
