import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'local_driver.dart';
import 'local_driver_native.dart' if (dart.library.js_interop) 'local_driver_web.dart' as platform;

/// All keys are installation + actor + branch + warehouse scoped.
/// The server remains the only authority for price, inventory and posting.
class LocalScope {
  final String origin,installation,actor,branch,warehouse;
  const LocalScope({required this.origin,required this.installation,required this.actor,
    required this.branch,this.warehouse=''});
  String get prefix {
    if(Uri.tryParse(origin)?.scheme!='https'||installation.isEmpty||actor.isEmpty||branch.isEmpty){
      throw StateError('Missing verified local scope');
    }
    return sha256.convert(utf8.encode(jsonEncode([origin,installation,actor,branch,warehouse]))).toString();
  }
}
class LocalRecoveryConflict implements Exception {
  const LocalRecoveryConflict();
  @override String toString()=>'Yêu cầu đang được xử lý trong cửa sổ khác.';
}
class ErpLocalStore {
  final LocalDriver driver;
  ErpLocalStore(this.driver);
  factory ErpLocalStore.platform()=>ErpLocalStore(platform.createDriver());
  String _key(LocalScope scope,String type,String id)=>jsonEncode([scope.prefix,type,id]);
  Future<void> saveCart(LocalScope scope,Map<String,dynamic> draft)=>
    driver.write(_key(scope,'cart','current'),jsonEncode(draft));
  Future<Map<String,dynamic>?> loadCart(LocalScope scope)async{
    final raw=await driver.read(_key(scope,'cart','current'));
    return raw==null?null:Map<String,dynamic>.from(jsonDecode(raw) as Map);
  }
  Future<void> clearCart(LocalScope scope)=>driver.remove(_key(scope,'cart','current'));
  Future<void> saveCache(LocalScope scope,String resource,Object value,{required DateTime fetchedAt,required Duration ttl})=>
    driver.write(_key(scope,'cache',resource),jsonEncode({
      'fetchedAt':fetchedAt.toUtc().toIso8601String(),'ttlSeconds':ttl.inSeconds,'value':value}));
  Future<({Object? value,bool stale,DateTime fetchedAt})?> cache(LocalScope scope,String resource,{required DateTime now})async{
    final raw=await driver.read(_key(scope,'cache',resource));
    if(raw==null)return null;
    final data=jsonDecode(raw) as Map;
    final fetched=DateTime.parse(data['fetchedAt'] as String);
    return (value:data['value'],stale:now.isBefore(fetched)||!now.isBefore(fetched.add(Duration(seconds:data['ttlSeconds'] as int))),fetchedAt:fetched);
  }
  // One command per branch, with transactional compare-and-swap across tabs.
  Future<void> saveSalesRecovery(LocalScope scope,Map<String,dynamic>? state,{String? expectedKey})async{
    if(driver is! AtomicLocalDriver)throw StateError('Atomic storage required for sales recovery');
    final key=_key(scope,'sales-recovery','current'),nextKey=state?['key'];
    if(state!=null&&(nextKey is! String||nextKey.isEmpty))throw const FormatException('Missing recovery key');
    if(state==null&&(expectedKey==null||expectedKey.isEmpty))throw const FormatException('Unowned recovery clear');
    final next=state==null?null:jsonEncode(state);
    for(var attempt=0;attempt<8;attempt++){
      final old=await driver.read(key);
      if(old==null){
        if(expectedKey!=null){
          if(state==null)return;
          throw const LocalRecoveryConflict();
        }
      }else{
        Map<String,dynamic> current;
        try{current=Map<String,dynamic>.from(jsonDecode(old) as Map);}catch(_){throw const LocalRecoveryConflict();}
        if(current['key']!=(expectedKey??nextKey))throw const LocalRecoveryConflict();
        if(expectedKey==null&&old!=next)throw const LocalRecoveryConflict();
      }
      if(await (driver as AtomicLocalDriver).compareAndSwap(key,old,next))return;
    }
    throw const LocalRecoveryConflict();
  }
  Future<Map<String,dynamic>?> salesRecovery(LocalScope scope)async{
    final raw=await driver.read(_key(scope,'sales-recovery','current'));
    return raw==null?null:Map<String,dynamic>.from(jsonDecode(raw) as Map);
  }
  /// Durable command intent only; never a local receipt, stock or ledger post.
  Future<void> saveIntent(LocalScope scope,String id,Map<String,dynamic> body)async{
    final key=_key(scope,'intent',id);
    final encoded=jsonEncode(body);
    final existing=await driver.read(key);
    if(existing!=null&&existing!=encoded)throw StateError('Intent payload changed');
    await driver.write(key,encoded);
  }
  Future<Map<String,dynamic>?> loadIntent(LocalScope scope,String id)async{
    final raw=await driver.read(_key(scope,'intent',id));
    return raw==null?null:Map<String,dynamic>.from(jsonDecode(raw) as Map);
  }
  Future<void> clearAcknowledgedIntent(LocalScope scope,String id)=>driver.remove(_key(scope,'intent',id));
}

/// Serialize snapshot writes and discard, so a slow autosave cannot resurrect a deleted cart.
class LocalCartWriter {
  final ErpLocalStore store;
  final LocalScope scope;
  Future<void> _tail=Future<void>.value();
  LocalCartWriter(this.store,this.scope);
  Future<void> save(Map<String,dynamic> snapshot){
    final frozen=Map<String,dynamic>.from(jsonDecode(jsonEncode(snapshot)) as Map);
    _tail=_tail.catchError((Object _){}).then((_)=>store.saveCart(scope,frozen));
    return _tail;
  }
  Future<void> clear(){
    _tail=_tail.catchError((Object _){}).then((_)=>store.clearCart(scope));
    return _tail;
  }
}
