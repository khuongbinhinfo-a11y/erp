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
  /// POS carts are separate from distribution sales editor drafts.
  /// Scope includes installation, actor, branch and warehouse; no auth token.
  Future<void> saveRetailCart(LocalScope scope,Map<String,dynamic> draft)=>
    driver.write(_key(scope,'retail-pos-cart','current'),jsonEncode(draft));
  Future<Map<String,dynamic>?> loadRetailCart(LocalScope scope)async{
    final raw=await driver.read(_key(scope,'retail-pos-cart','current'));
    if(raw==null)return null;
    return Map<String,dynamic>.from(jsonDecode(raw) as Map);
  }
  Future<void> clearRetailCart(LocalScope scope)=>
    driver.remove(_key(scope,'retail-pos-cart','current'));
  /// A checkout command survives process death/lost ACK. A second tab may not
  /// silently replace it with another key or body.
  Future<void> saveRetailPending(LocalScope scope,Map<String,dynamic> command)async{
    final path=_key(scope,'retail-pos-command','current');
    final payload=jsonEncode(command),old=await driver.read(path);
    if(old==payload)return;
    if(old!=null)throw StateError('POS command pending reconciliation');
    if(driver is! AtomicLocalDriver)throw StateError('Atomic POS storage required');
    if(!await (driver as AtomicLocalDriver).compareAndSwap(path,null,payload))
      throw StateError('POS command already in flight');
  }
  Future<Map<String,dynamic>?> retailPending(LocalScope scope)async{
    final raw=await driver.read(_key(scope,'retail-pos-command','current'));
    return raw==null?null:Map<String,dynamic>.from(jsonDecode(raw) as Map);
  }
  Future<void> clearRetailPending(LocalScope scope,String expectedKey)async{
    final path=_key(scope,'retail-pos-command','current');
    if(driver is! AtomicLocalDriver)throw StateError('Atomic POS storage required');
    for(var i=0;i<12;i++){
      final before=await driver.read(path);
      if(before==null)return;
      final data=Map<String,dynamic>.from(jsonDecode(before) as Map);
      if(data['key']!=expectedKey)throw StateError('POS command changed');
      if(await (driver as AtomicLocalDriver).compareAndSwap(path,before,null))return;
    }
    throw StateError('POS command write conflict');
  }


  /// T5-A order posting intent: one in-flight MANUAL delivery/return/payment
  /// per installation+actor+branch+warehouse+order. The original key, revision
  /// and full body are retained across process death and network loss.
  Future<void> saveExecutionPending(LocalScope scope,String orderId,
      Map<String,dynamic> command)async{
    final path=_key(scope,'sales-execution',orderId);
    final payload=jsonEncode(command),old=await driver.read(path);
    if(old==payload)return;
    if(old!=null||driver is! AtomicLocalDriver)throw const LocalRecoveryConflict();
    if(!await (driver as AtomicLocalDriver).compareAndSwap(path,null,payload))
      throw const LocalRecoveryConflict();
  }
  Future<Map<String,dynamic>?> executionPending(LocalScope scope,String orderId)async{
    final raw=await driver.read(_key(scope,'sales-execution',orderId));
    return raw==null?null:Map<String,dynamic>.from(jsonDecode(raw) as Map);
  }
  Future<void> clearExecutionPending(LocalScope scope,String orderId,String expectedKey)async{
    final path=_key(scope,'sales-execution',orderId);
    if(driver is! AtomicLocalDriver)throw const LocalRecoveryConflict();
    for(var attempt=0;attempt<12;attempt++){
      final before=await driver.read(path);
      if(before==null)return;
      final entry=Map<String,dynamic>.from(jsonDecode(before) as Map);
      if(entry['key']!=expectedKey)throw const LocalRecoveryConflict();
      if(await (driver as AtomicLocalDriver).compareAndSwap(path,before,null))return;
    }
    throw const LocalRecoveryConflict();
  }



  /// T5-D: one unresolved trip posting at a time. Persist exact actor/scope,
  /// action, body, revision and idempotency key across app restarts.
  Future<void> saveDeliveryPending(LocalScope scope,String tripId,
      Map<String,dynamic> command)async{
    final path=_key(scope,'delivery-execution',tripId);
    final payload=jsonEncode(command),old=await driver.read(path);
    if(old==payload)return;
    if(old!=null||driver is! AtomicLocalDriver)throw const LocalRecoveryConflict();
    if(!await (driver as AtomicLocalDriver).compareAndSwap(path,null,payload))
      throw const LocalRecoveryConflict();
  }
  Future<Map<String,dynamic>?> deliveryPending(LocalScope scope,String tripId)async{
    final raw=await driver.read(_key(scope,'delivery-execution',tripId));
    return raw==null?null:Map<String,dynamic>.from(jsonDecode(raw) as Map);
  }
  Future<void> clearDeliveryPending(LocalScope scope,String tripId,String expectedKey)async{
    final path=_key(scope,'delivery-execution',tripId);
    if(driver is! AtomicLocalDriver)throw const LocalRecoveryConflict();
    for(var attempt=0;attempt<12;attempt++){
      final before=await driver.read(path);
      if(before==null)return;
      final entry=Map<String,dynamic>.from(jsonDecode(before) as Map);
      if(entry['key']!=expectedKey)throw const LocalRecoveryConflict();
      if(await (driver as AtomicLocalDriver).compareAndSwap(path,before,null))return;
    }
    throw const LocalRecoveryConflict();
  }

  // An editor owns one UUID-like token. Lease expiry permits crash recovery,
  // but the old editor can neither autosave nor submit after a takeover.
  static const _cartLease=Duration(seconds:30);
  int _cartDeadline()=>DateTime.now().toUtc().millisecondsSinceEpoch+_cartLease.inMilliseconds;
  bool _cartActive(Map<String,dynamic> record)=>
    record['status']=='editing'&&
    (record['leaseUntil'] is int)&&
    (record['leaseUntil'] as int)>DateTime.now().toUtc().millisecondsSinceEpoch;
  Map<String,dynamic> _cartEntry(Object? raw){
    if(raw is! Map)throw const LocalRecoveryConflict();
    final item=Map<String,dynamic>.from(raw);
    if(item['_kind']=='erp-cart-lease-v1')return item;
    // Old pre-release carts: move into a lease on first explicit resume.
    return {'_kind':'erp-cart-lease-v1','draft':item,'status':'released','owner':'',
      'leaseUntil':0};
  }
  Future<List<({String id,Map<String,dynamic> draft})>> savedCarts(LocalScope scope)async{
    final result=<({String id,Map<String,dynamic> draft})>[];
    final legacy=await loadCart(scope);
    if(legacy!=null)result.add((id:'legacy',draft:legacy));
    final raw=await driver.read(_key(scope,'cart','multi'));
    if(raw==null)return result;
    try{
      final items=Map<String,dynamic>.from(jsonDecode(raw) as Map);
      for(final item in items.entries){
        final entry=_cartEntry(item.value);
        if(!{'editing','released','submitted','rejected'}.contains(entry['status']))continue;
        result.add((id:item.key,draft:Map<String,dynamic>.from(entry['draft'] as Map)));
      }
    }catch(_){throw const LocalRecoveryConflict();}
    return result;
  }
  Future<void> saveScopedCart(LocalScope scope,String id,Map<String,dynamic> cart,{required String owner})async{
    if(driver is! AtomicLocalDriver||id.isEmpty||id=='legacy'||owner.isEmpty)throw const LocalRecoveryConflict();
    final key=_key(scope,'cart','multi');
    final snapshot=Map<String,dynamic>.from(jsonDecode(jsonEncode(cart)) as Map);
    for(var attempt=0;attempt<24;attempt++){
      final old=await driver.read(key);
      Map<String,dynamic> items;
      try{items=old==null?<String,dynamic>{}:Map<String,dynamic>.from(jsonDecode(old) as Map);}
      catch(_){throw const LocalRecoveryConflict();}
      final entry=items[id]==null?null:_cartEntry(items[id]);
      if(entry==null){
        if(items.values.where((v){
          try{return {'editing','released','submitted'}.contains(_cartEntry(v)['status']);}
          catch(_){return true;}
        }).length>=40)throw const LocalRecoveryConflict();
      }else if(entry['status']!='editing'||entry['owner']!=owner){
        throw const LocalRecoveryConflict();
      }
      items[id]={'_kind':'erp-cart-lease-v1','draft':snapshot,'status':'editing',
        'owner':owner,'leaseUntil':_cartDeadline()};
      if(await (driver as AtomicLocalDriver).compareAndSwap(key,old,jsonEncode(items)))return;
    }
    throw const LocalRecoveryConflict();
  }
  Future<Map<String,dynamic>> claimScopedCart(LocalScope scope,String sourceId,String newId,
      {required String owner})async{
    if(driver is! AtomicLocalDriver||newId.isEmpty||owner.isEmpty||
      sourceId==newId||newId=='legacy')throw const LocalRecoveryConflict();
    if(sourceId=='legacy'){
      final legacyKey=_key(scope,'cart','current'),prior=await driver.read(legacyKey);
      if(prior==null)throw const LocalRecoveryConflict();
      late Map<String,dynamic> cart;
      try{cart=Map<String,dynamic>.from(jsonDecode(prior) as Map);}
      catch(_){throw const LocalRecoveryConflict();}
      await saveScopedCart(scope,newId,cart,owner:owner);
      if(!await (driver as AtomicLocalDriver).compareAndSwap(legacyKey,prior,null)){
        await clearScopedCart(scope,newId,owner:owner);
        throw const LocalRecoveryConflict();
      }
      return cart;
    }
    final key=_key(scope,'cart','multi');
    for(var attempt=0;attempt<24;attempt++){
      final old=await driver.read(key);
      if(old==null)throw const LocalRecoveryConflict();
      Map<String,dynamic> items;
      try{items=Map<String,dynamic>.from(jsonDecode(old) as Map);}
      catch(_){throw const LocalRecoveryConflict();}
      if(!items.containsKey(sourceId)||items.containsKey(newId))throw const LocalRecoveryConflict();
      final from=_cartEntry(items[sourceId]);
      if(!{'editing','released','rejected'}.contains(from['status'])||_cartActive(from)){
        throw const LocalRecoveryConflict();
      }
      final cart=Map<String,dynamic>.from(from['draft'] as Map);
      // Retired tombstones prevent the previous live editor resurrecting an ID.
      items[sourceId]={'_kind':'erp-cart-lease-v1','draft':<String,dynamic>{},
        'owner':from['owner'],'status':'retired','leaseUntil':0,
        if({'editing','released'}.contains(from['status']))'neverSubmitted':true,
        if(from['status']=='rejected'&&from['commandKey'] is String)
          'rejectedCommandKey':from['commandKey']};
      items[newId]={'_kind':'erp-cart-lease-v1','draft':cart,'status':'editing',
        'owner':owner,'leaseUntil':_cartDeadline()};
      if(await (driver as AtomicLocalDriver).compareAndSwap(key,old,jsonEncode(items)))return cart;
    }
    throw const LocalRecoveryConflict();
  }
  Future<void> releaseScopedCart(LocalScope scope,String id,{required String owner})async{
    await _mutateScopedCart(scope,id,(entry){
      if(entry['owner']!=owner||entry['status']!='editing')throw const LocalRecoveryConflict();
      return {...entry,'status':'released','leaseUntil':0};
    });
  }
  Future<void> markCartSubmitting(LocalScope scope,String id,{required String owner,required String commandKey})async{
    if(commandKey.isEmpty)throw const LocalRecoveryConflict();
    await _mutateScopedCart(scope,id,(entry){
      if(entry['owner']!=owner)throw const LocalRecoveryConflict();
      if(entry['status']=='submitted'&&entry['commandKey']==commandKey)return entry;
      if(entry['status']!='editing')throw const LocalRecoveryConflict();
      return {...entry,'status':'submitted','commandKey':commandKey,'leaseUntil':0};
    });
  }
  Future<void> releaseRejectedCart(LocalScope scope,String id,{required String owner,required String commandKey})async{
    await _mutateScopedCart(scope,id,(entry){
      // A second tab may receive the same definitive rejection AFTER the
      // operator has resumed the cart. The old retired ID preserves only this
      // terminal key; never touch the new owner's editing record.
      if(entry['owner']==owner&&entry['status']=='retired'&&
        entry['rejectedCommandKey']==commandKey)return entry;
      if(entry['owner']!=owner||entry['commandKey']!=commandKey){
        throw const LocalRecoveryConflict();
      }
      if(entry['status']=='rejected')return entry; // same confirmed rejection in another tab
      if(entry['status']!='submitted')throw const LocalRecoveryConflict();
      return {...entry,'status':'rejected','leaseUntil':0};
    });
  }
  /// Authenticated server receipt remains canonical. This local disposition is
  /// only a deny-replay guard after the server definitively rejected a create.
  Future<String> cartCreateDisposition(LocalScope scope,String id,
      {required String owner,required String commandKey})async{
    final raw=await driver.read(_key(scope,'cart','multi'));
    if(raw==null)return 'unknown';
    late Map<String,dynamic> items;
    try{items=Map<String,dynamic>.from(jsonDecode(raw) as Map);}
    catch(_){throw const LocalRecoveryConflict();}
    if(!items.containsKey(id))return 'unknown';
    final entry=_cartEntry(items[id]);
    if(entry['owner']!=owner)return 'other-owner';
    if(entry['status']=='submitted'&&entry['commandKey']==commandKey)return 'submitted';
    if(entry['status']=='rejected'&&entry['commandKey']==commandKey)return 'rejected';
    if(entry['status']=='retired'&&entry['rejectedCommandKey']==commandKey)return 'rejected';
    if(entry['status']=='retired'&&entry['neverSubmitted']==true)return 'never-submitted';
    if(entry['status']=='released')return 'never-submitted';
    if(entry['status']=='editing')return 'editing';
    return 'unknown';
  }
  Future<void> clearScopedCart(LocalScope scope,String id,{required String owner,String? commandKey})async{
    await _mutateScopedCart(scope,id,(entry){
      if(entry['owner']!=owner)throw const LocalRecoveryConflict();
      if(entry['status']=='submitted'&&entry['commandKey']!=commandKey)throw const LocalRecoveryConflict();
      if(!{'submitted','editing','released'}.contains(entry['status']))throw const LocalRecoveryConflict();
      return {'_kind':'erp-cart-lease-v1','draft':<String,dynamic>{},
        'owner':owner,'status':'retired','leaseUntil':0};
    });
  }
  Future<void> _mutateScopedCart(LocalScope scope,String id,
      Map<String,dynamic> Function(Map<String,dynamic>) change)async{
    if(driver is! AtomicLocalDriver||id.isEmpty)throw const LocalRecoveryConflict();
    final key=_key(scope,'cart','multi');
    for(var attempt=0;attempt<24;attempt++){
      final old=await driver.read(key);
      if(old==null)throw const LocalRecoveryConflict();
      Map<String,dynamic> items;
      try{items=Map<String,dynamic>.from(jsonDecode(old) as Map);}
      catch(_){throw const LocalRecoveryConflict();}
      if(!items.containsKey(id))throw const LocalRecoveryConflict();
      final existing=_cartEntry(items[id]);
      items[id]=change(existing);
      if(await (driver as AtomicLocalDriver).compareAndSwap(key,old,jsonEncode(items)))return;
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
  /// CAS-only reconciliation claim. A never-confirmed command cannot be rebased.
  /// An abandoned editor becomes reclaimable after ten minutes, but its old
  /// claim token can never replace the newly claimed record.
  Future<void> claimRejectedSalesUpdate(LocalScope scope,String orderId,String key,String owner,
      {DateTime? now})async{
    if(driver is! AtomicLocalDriver||key.isEmpty||owner.isEmpty)throw const LocalRecoveryConflict();
    final path=_key(scope,'unsent-update',orderId);
    final at=(now??DateTime.now()).toUtc().millisecondsSinceEpoch;
    for(var attempt=0;attempt<24;attempt++){
      final old=await driver.read(path);
      if(old==null)throw const LocalRecoveryConflict();
      late List<Map<String,dynamic>> items;
      try{items=(jsonDecode(old) as List).map((x)=>Map<String,dynamic>.from(x as Map)).toList();}
      catch(_){throw const LocalRecoveryConflict();}
      final found=items.where((x)=>x['key']==key).toList();
      if(found.length!=1)throw const LocalRecoveryConflict();
      final entry=found.single;
      final abandoned=entry['status']=='reconciling'&&entry['claimUntil'] is int&&
          (entry['claimUntil'] as int)<=at;
      if(entry['status']!='rejected'&&!abandoned)throw const LocalRecoveryConflict();
      entry['status']='reconciling';entry['claimOwner']=owner;
      entry['claimUntil']=at+const Duration(minutes:10).inMilliseconds;
      if(await (driver as AtomicLocalDriver).compareAndSwap(path,old,jsonEncode(items)))return;
    }
    throw const LocalRecoveryConflict();
  }
  Future<void> releaseRejectedSalesClaim(LocalScope scope,String orderId,String key,String owner)async{
    if(driver is! AtomicLocalDriver||owner.isEmpty)throw const LocalRecoveryConflict();
    final path=_key(scope,'unsent-update',orderId);
    for(var attempt=0;attempt<24;attempt++){
      final old=await driver.read(path);
      if(old==null)throw const LocalRecoveryConflict();
      late List<Map<String,dynamic>> items;
      try{items=(jsonDecode(old) as List).map((x)=>Map<String,dynamic>.from(x as Map)).toList();}
      catch(_){throw const LocalRecoveryConflict();}
      final matches=items.where((x)=>x['key']==key).toList();
      if(matches.length!=1||matches.single['status']!='reconciling'||
        matches.single['claimOwner']!=owner)throw const LocalRecoveryConflict();
      matches.single['status']='rejected';
      matches.single.remove('claimOwner');matches.single.remove('claimUntil');
      if(await (driver as AtomicLocalDriver).compareAndSwap(path,old,jsonEncode(items)))return;
    }
    throw const LocalRecoveryConflict();
  }
  Future<void> replaceReconciledSalesUpdate(LocalScope scope,String orderId,
      String oldKey,String claimOwner,String newKey,Map<String,dynamic> command)async{
    if(driver is! AtomicLocalDriver||oldKey==newKey||claimOwner.isEmpty||newKey.isEmpty||
      command['id']!=orderId)throw const LocalRecoveryConflict();
    final path=_key(scope,'unsent-update',orderId);
    for(var attempt=0;attempt<24;attempt++){
      final old=await driver.read(path);
      if(old==null)throw const LocalRecoveryConflict();
      late List<Map<String,dynamic>> items;
      try{items=(jsonDecode(old) as List).map((x)=>Map<String,dynamic>.from(x as Map)).toList();}
      catch(_){throw const LocalRecoveryConflict();}
      final match=items.where((x)=>x['key']==oldKey).toList();
      if(match.length!=1||match.single['status']!='reconciling'||
        match.single['claimOwner']!=claimOwner||
        items.any((x)=>x['key']==newKey))throw const LocalRecoveryConflict();
      items.removeWhere((x)=>x['key']==oldKey);
      items.add({'key':newKey,'command':command,'status':'unsent'});
      if(await (driver as AtomicLocalDriver).compareAndSwap(path,old,jsonEncode(items)))return;
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
  final String? owner;
  Future<void> _tail=Future<void>.value();
  LocalCartWriter(this.store,this.scope,[this.cartId,this.owner]);
  Future<void> save(Map<String,dynamic> snapshot){
    final frozen=Map<String,dynamic>.from(jsonDecode(jsonEncode(snapshot)) as Map);
    _tail=_tail.catchError((Object _){}).then((_)=>cartId==null?store.saveCart(scope,frozen):store.saveScopedCart(scope,cartId!,frozen,owner:owner!));
    return _tail;
  }
  Future<void> release(){
    if(cartId==null||owner==null)return Future<void>.value();
    _tail=_tail.catchError((Object _){}).then((_)=>store.releaseScopedCart(scope,cartId!,owner:owner!));
    return _tail;
  }
  Future<void> clear(){
    _tail=_tail.catchError((Object _){}).then((_)=>cartId==null?store.clearCart(scope):store.clearScopedCart(scope,cartId!,owner:owner!));
    return _tail;
  }
}
