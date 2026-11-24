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
  /// Distinct per-tab carts within one CAS record; no lost writes across tabs.
  Future<List<({String id,Map<String,dynamic> draft})>> savedCarts(LocalScope scope)async{
    final result=<({String id,Map<String,dynamic> draft})>[];
    final legacy=await loadCart(scope);
    if(legacy!=null)result.add((id:'legacy',draft:legacy));
    final raw=await driver.read(_key(scope,'cart','multi'));
    if(raw==null)return result;
    try{
      final content=Map<String,dynamic>.from(jsonDecode(raw) as Map);
      for(final item in content.entries){
        result.add((id:item.key,draft:Map<String,dynamic>.from(item.value as Map)));
      }
    }catch(_){throw const LocalRecoveryConflict();}
    return result;
  }
  Future<void> saveScopedCart(LocalScope scope,String id,Map<String,dynamic> cart)async{
    if(driver is! AtomicLocalDriver||id.isEmpty||id=='legacy')throw const LocalRecoveryConflict();
    final location=_key(scope,'cart','multi');
    final snapshot=Map<String,dynamic>.from(jsonDecode(jsonEncode(cart)) as Map);
    for(var attempt=0;attempt<16;attempt++){
      final old=await driver.read(location);
      Map<String,dynamic> items;
      try{items=old==null?<String,dynamic>{}:Map<String,dynamic>.from(jsonDecode(old) as Map);}
      catch(_){throw const LocalRecoveryConflict();}
      if(!items.containsKey(id)&&items.length>=40)throw const LocalRecoveryConflict();
      items[id]=snapshot;
      if(await (driver as AtomicLocalDriver).compareAndSwap(location,old,jsonEncode(items)))return;
    }
    throw const LocalRecoveryConflict();
  }
  /// Atomically move a saved cart into a unique editor identity. Two tabs
  /// selecting the same old cart cannot both submit it as separate orders.
  Future<Map<String,dynamic>> claimScopedCart(LocalScope scope,String sourceId,String newId)async{
    if(driver is! AtomicLocalDriver||newId.isEmpty||sourceId==newId||newId=='legacy'){
      throw const LocalRecoveryConflict();
    }
    if(sourceId=='legacy'){
      final oldKey=_key(scope,'cart','current'),old=await driver.read(oldKey);
      if(old==null)throw const LocalRecoveryConflict();
      Map<String,dynamic> cart;
      try{cart=Map<String,dynamic>.from(jsonDecode(old) as Map);}
      catch(_){throw const LocalRecoveryConflict();}
      await saveScopedCart(scope,newId,cart);
      if(!await (driver as AtomicLocalDriver).compareAndSwap(oldKey,old,null)){
        await clearScopedCart(scope,newId);throw const LocalRecoveryConflict();
      }
      return cart;
    }
    final location=_key(scope,'cart','multi');
    for(var attempt=0;attempt<16;attempt++){
      final old=await driver.read(location);
      if(old==null)throw const LocalRecoveryConflict();
      Map<String,dynamic> items;
      try{items=Map<String,dynamic>.from(jsonDecode(old) as Map);}
      catch(_){throw const LocalRecoveryConflict();}
      if(!items.containsKey(sourceId)||items.containsKey(newId))throw const LocalRecoveryConflict();
      final cart=Map<String,dynamic>.from(items.remove(sourceId) as Map);
      items[newId]=cart;
      if(await (driver as AtomicLocalDriver).compareAndSwap(location,old,jsonEncode(items)))return cart;
    }
    throw const LocalRecoveryConflict();
  }
  Future<void> clearScopedCart(LocalScope scope,String id)async{
    if(id=='legacy'){await clearCart(scope);return;}
    if(driver is! AtomicLocalDriver||id.isEmpty)throw const LocalRecoveryConflict();
    final location=_key(scope,'cart','multi');
    for(var attempt=0;attempt<16;attempt++){
      final old=await driver.read(location);
      if(old==null)return;
      Map<String,dynamic> items;
      try{items=Map<String,dynamic>.from(jsonDecode(old) as Map);}
      catch(_){throw const LocalRecoveryConflict();}
      if(!items.containsKey(id))return;
      items.remove(id);
      if(await (driver as AtomicLocalDriver).compareAndSwap(location,old,
        items.isEmpty?null:jsonEncode(items)))return;
    }
    throw const LocalRecoveryConflict();
  }
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
  /// Durable unsubmitted order edits, independent of the single active mutation.
  /// A CAS-protected per-order array retains multiple tabs' different edits.
  Future<List<Map<String,dynamic>>> unsentSalesUpdates(LocalScope scope,String orderId)async{
    final raw=await driver.read(_key(scope,'unsent-update',orderId));
    if(raw==null)return [];
    try{
      final decoded=jsonDecode(raw);
      if(decoded is! List)throw const FormatException();
      return decoded.map((x)=>Map<String,dynamic>.from(x as Map)).toList();
    }catch(_){throw const LocalRecoveryConflict();}
  }
  Future<void> saveUnsentSalesUpdate(LocalScope scope,String orderId,String key,
    Map<String,dynamic> command)async{
    if(driver is! AtomicLocalDriver||key.isEmpty||orderId.isEmpty||command['id']!=orderId){
      throw const LocalRecoveryConflict();
    }
    final location=_key(scope,'unsent-update',orderId);
    final serialized=jsonEncode({'key':key,'command':command,'status':'unsent'});
    for(var attempt=0;attempt<16;attempt++){
      final before=await driver.read(location);
      List<Map<String,dynamic>> drafts;
      if(before==null){drafts=[];}
      else {
        try{
          final value=jsonDecode(before) as List;
          drafts=value.map((x)=>Map<String,dynamic>.from(x as Map)).toList();
        }catch(_){throw const LocalRecoveryConflict();}
      }
      final same=drafts.where((x)=>x['key']==key).toList();
      if(same.isNotEmpty){
        if(same.length!=1||jsonEncode(same.single)!=serialized)throw const LocalRecoveryConflict();
        return;
      }
      if(drafts.length>=50)throw const LocalRecoveryConflict();
      drafts.add({'key':key,'command':command,'status':'unsent'});
      if(await (driver as AtomicLocalDriver).compareAndSwap(location,before,jsonEncode(drafts)))return;
    }
    throw const LocalRecoveryConflict();
  }
  /// Explicit transaction state: before any network send, mark in-flight.
  /// Rebase is permitted only for a never-sent or server-rejected command.
  Future<void> markUnsentSalesUpdate(LocalScope scope,String orderId,String key,String status)async{
    if(driver is! AtomicLocalDriver||!{'inflight','rejected'}.contains(status))throw const LocalRecoveryConflict();
    final location=_key(scope,'unsent-update',orderId);
    for(var attempt=0;attempt<16;attempt++){
      final before=await driver.read(location);
      if(before==null)throw const LocalRecoveryConflict();
      List<Map<String,dynamic>> drafts;
      try{drafts=(jsonDecode(before) as List).map((x)=>Map<String,dynamic>.from(x as Map)).toList();}
      catch(_){throw const LocalRecoveryConflict();}
      final match=drafts.where((x)=>x['key']==key).toList();
      if(match.length!=1)throw const LocalRecoveryConflict();
      final previous=match.single['status'];
      if(previous==status)return;
      if(status=='inflight'&&!{'unsent',null}.contains(previous))throw const LocalRecoveryConflict();
      if(status=='rejected'&&previous!='inflight')throw const LocalRecoveryConflict();
      match.single['status']=status;
      if(await (driver as AtomicLocalDriver).compareAndSwap(location,before,jsonEncode(drafts)))return;
    }
    throw const LocalRecoveryConflict();
  }
  Future<void> clearUnsentSalesUpdate(LocalScope scope,String orderId,String key,{String? requiredStatus})async{
    if(driver is! AtomicLocalDriver||key.isEmpty)throw const LocalRecoveryConflict();
    final location=_key(scope,'unsent-update',orderId);
    for(var attempt=0;attempt<16;attempt++){
      final before=await driver.read(location);
      if(before==null)return;
      final drafts=await unsentSalesUpdates(scope,orderId);
      final match=drafts.where((x)=>x['key']==key).toList();
      if(match.isEmpty)return;
      if(match.length!=1||(requiredStatus!=null&&match.single['status']!=requiredStatus))throw const LocalRecoveryConflict();
      final remaining=drafts.where((x)=>x['key']!=key).toList();
      if(await (driver as AtomicLocalDriver).compareAndSwap(location,before,
        remaining.isEmpty?null:jsonEncode(remaining)))return;
    }
    throw const LocalRecoveryConflict();
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
  final String? cartId;
  Future<void> _tail=Future<void>.value();
  LocalCartWriter(this.store,this.scope,[this.cartId]);
  Future<void> save(Map<String,dynamic> snapshot){
    final frozen=Map<String,dynamic>.from(jsonDecode(jsonEncode(snapshot)) as Map);
    _tail=_tail.catchError((Object _){}).then((_)=>cartId==null?store.saveCart(scope,frozen):store.saveScopedCart(scope,cartId!,frozen));
    return _tail;
  }
  Future<void> clear(){
    _tail=_tail.catchError((Object _){}).then((_)=>cartId==null?store.clearCart(scope):store.clearScopedCart(scope,cartId!));
    return _tail;
  }
}
