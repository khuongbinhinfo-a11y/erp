import 'package:flutter_test/flutter_test.dart';
import 'package:erp_distribution/local/local_driver.dart';
import 'package:erp_distribution/local/local_store.dart';
class Memory implements AtomicLocalDriver{
  final rows=<String,String>{};
  @override Future<String?> read(String key)async=>rows[key];
  @override Future<bool> compareAndSwap(String key,String? expected,String? next)async{
    if(rows[key]!=expected)return false;
    if(next==null)rows.remove(key);else rows[key]=next;
    return true;
  }
  @override Future<void> write(String key,String value)async{rows[key]=value;}
  @override Future<void> remove(String key)async{rows.remove(key);}
}
void main(){
  const a=LocalScope(origin:'https://erp.example',installation:'i',actor:'a',branch:'b',warehouse:'w');
  const b=LocalScope(origin:'https://erp.example',installation:'i',actor:'other',branch:'b',warehouse:'w');
  test('cart and intent survive recreation, cannot cross actor scope',()async{
    final driver=Memory();final store=ErpLocalStore(driver);
    await store.saveCart(a,{'lines':[{'sellSkuId':'sku','quantity':'2'}]});
    await store.saveIntent(a,'key',{'quantity':'2'});
    final restored=ErpLocalStore(driver);
    expect(await restored.loadCart(a),isNotNull);
    expect(await restored.loadCart(b),isNull);
    expect(await restored.loadIntent(b,'key'),isNull);
    expect(await restored.loadIntent(a,'key'),{'quantity':'2'});
    await expectLater(restored.saveIntent(a,'key',{'quantity':'3'}),throwsStateError);
    await restored.clearAcknowledgedIntent(a,'key');
    expect(await restored.loadIntent(a,'key'),isNull);
  });
  test('queued snapshots cannot resurrect a discarded cart',()async{
    final store=ErpLocalStore(Memory()),writer=LocalCartWriter(store,a);
    final mutable={'quantity':'1'};
    final first=writer.save(mutable);mutable['quantity']='2';
    final second=writer.save(mutable);
    await Future.wait([first,second,writer.clear()]);
    expect(await store.loadCart(a),isNull);
    await writer.save(mutable);
    expect((await store.loadCart(a))?['quantity'],'2');
  });
  test('two tabs cannot overwrite or clear each other durable sales command',()async{
    final aTab=ErpLocalStore(Memory());final bTab=ErpLocalStore(aTab.driver);
    final first={'kind':'create','key':'first','body':{'quantity':'2'}};
    await aTab.saveSalesRecovery(a,first);
    await expectLater(bTab.saveSalesRecovery(a,{'kind':'create','key':'second','body':{'quantity':'3'}}),throwsA(isA<LocalRecoveryConflict>()));
    await expectLater(bTab.saveSalesRecovery(a,null,expectedKey:'second'),throwsA(isA<LocalRecoveryConflict>()));
    await aTab.saveSalesRecovery(a,first);
    await expectLater(aTab.saveSalesRecovery(a,{'kind':'create','key':'first','body':{'quantity':'999'}}),throwsA(isA<LocalRecoveryConflict>()));
    await aTab.saveSalesRecovery(a,{'kind':'confirm','key':'confirm','body':{'revision':1}},expectedKey:'first');
    await expectLater(bTab.saveSalesRecovery(a,null,expectedKey:'first'),throwsA(isA<LocalRecoveryConflict>()));
    expect((await aTab.salesRecovery(a))?['key'],'confirm');
    await aTab.saveSalesRecovery(a,null,expectedKey:'confirm');
    expect(await bTab.salesRecovery(a),isNull);
  });
  test('distinct tabs preserve multiple unsent order edits and selective clear',()async{
    final shared=Memory(),firstTab=ErpLocalStore(shared),secondTab=ErpLocalStore(shared);
    const orderId='00000000-0000-4000-8000-000000000005';
    final first={'id':orderId,'body':{'branchId':'b','lines':[{'quantity':'1'}]}};
    final second={'id':orderId,'body':{'branchId':'b','lines':[{'quantity':'2'}]}};
    await Future.wait([
      firstTab.saveUnsentSalesUpdate(a,orderId,'first',first),
      secondTab.saveUnsentSalesUpdate(a,orderId,'second',second),
    ]);
    final snapshot=await firstTab.unsentSalesUpdates(a,orderId);
    expect(snapshot.map((x)=>x['key']).toSet(),{'first','second'});
    await expectLater(firstTab.saveUnsentSalesUpdate(a,orderId,'first',second),
      throwsA(isA<LocalRecoveryConflict>()));
    await firstTab.clearUnsentSalesUpdate(a,orderId,'first');
    expect((await secondTab.unsentSalesUpdates(a,orderId)).single['key'],'second');
    await secondTab.clearUnsentSalesUpdate(a,orderId,'second');
    expect(await firstTab.unsentSalesUpdates(a,orderId),isEmpty);
  });
  test('unsent vs in-flight vs rejected edits permit only safe reconciliation',()async{
    final store=ErpLocalStore(Memory());
    const id='00000000-0000-4000-8000-000000000005';
    await store.saveUnsentSalesUpdate(a,id,'k',{'id':id,'body':{'lines':[]}});
    expect((await store.unsentSalesUpdates(a,id)).single['status'],'unsent');
    await store.markUnsentSalesUpdate(a,id,'k','inflight');
    expect((await store.unsentSalesUpdates(a,id)).single['status'],'inflight');
    await store.markUnsentSalesUpdate(a,id,'k','rejected');
    expect((await store.unsentSalesUpdates(a,id)).single['status'],'rejected');
    await expectLater(store.markUnsentSalesUpdate(a,id,'wrong','rejected'),
      throwsA(isA<LocalRecoveryConflict>()));
  });
  test('terminal rejection cannot be reposted; compare and delete requires status',()async{
    final store=ErpLocalStore(Memory());
    const id='00000000-0000-4000-8000-000000000005';
    await store.saveUnsentSalesUpdate(a,id,'k2',{'id':id,'body':{'lines':[]}});
    await store.markUnsentSalesUpdate(a,id,'k2','inflight');
    await store.markUnsentSalesUpdate(a,id,'k2','rejected');
    await expectLater(store.markUnsentSalesUpdate(a,id,'k2','inflight'),
      throwsA(isA<LocalRecoveryConflict>()));
    await expectLater(store.clearUnsentSalesUpdate(a,id,'k2',requiredStatus:'unsent'),
      throwsA(isA<LocalRecoveryConflict>()));
    await store.clearUnsentSalesUpdate(a,id,'k2',requiredStatus:'rejected');
    expect(await store.unsentSalesUpdates(a,id),isEmpty);
  });
  test('cache expiry is explicit, never proof of a current price',()async{
    final store=ErpLocalStore(Memory());
    final time=DateTime.utc(2026,11,24);
    await store.saveCache(a,'price',{'amount':'123'},fetchedAt:time,ttl:const Duration(minutes:1));
    expect((await store.cache(a,'price',now:time))!.stale,false);
    expect((await store.cache(a,'price',now:time.add(const Duration(minutes:1))))!.stale,true);
    expect(await store.cache(b,'price',now:time),isNull);
  });
}
