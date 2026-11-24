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
  test('two simultaneous tabs keep independent carts after one clears',()async{
    final driver=Memory(),first=ErpLocalStore(driver),second=ErpLocalStore(driver);
    await Future.wait([
      first.saveScopedCart(a,'tab-one',{'lines':[{'quantity':'1'}]},owner:'owner-one'),
      second.saveScopedCart(a,'tab-two',{'lines':[{'quantity':'2'}]},owner:'owner-two'),
    ]);
    expect((await first.savedCarts(a)).map((x)=>x.id).toSet(),{'tab-one','tab-two'});
    await first.clearScopedCart(a,'tab-one',owner:'owner-one');
    final remaining=(await second.savedCarts(a)).single;
    expect(remaining.id,'tab-two');
    expect((remaining.draft['lines'] as List).single['quantity'],'2');
  });
  test('claim a saved cart exactly once across racing tabs',()async{
    final driver=Memory(),first=ErpLocalStore(driver),second=ErpLocalStore(driver);
    await first.saveScopedCart(a,'old-cart',{'lines':[{'quantity':'7'}]},owner:'owner-old');
    await expectLater(second.claimScopedCart(a,'old-cart','opened-early',owner:'owner-other'),throwsA(isA<LocalRecoveryConflict>()));
    await first.releaseScopedCart(a,'old-cart',owner:'owner-old');
    final firstResult=await first.claimScopedCart(a,'old-cart','opened-one',owner:'new-owner');
    expect((firstResult['lines'] as List).single['quantity'],'7');
    await expectLater(second.claimScopedCart(a,'old-cart','opened-two',owner:'other-owner'),
      throwsA(isA<LocalRecoveryConflict>()));
    expect((await second.savedCarts(a)).map((x)=>x.id).toList(),['opened-one']);
    await first.clearScopedCart(a,'opened-one',owner:'new-owner');
    expect(await second.savedCarts(a),isEmpty);
  });
  test('previous cart owner cannot revive a moved cart or submit with a new key',()async{
    final driver=Memory(),old=ErpLocalStore(driver),next=ErpLocalStore(driver);
    await old.saveScopedCart(a,'cart-1',{'quantity':'1'},owner:'old-editor');
    await old.releaseScopedCart(a,'cart-1',owner:'old-editor');
    final taken=await next.claimScopedCart(a,'cart-1','cart-2',owner:'new-editor');
    expect(taken['quantity'],'1');
    await expectLater(old.saveScopedCart(a,'cart-1',{'quantity':'5'},owner:'old-editor'),
      throwsA(isA<LocalRecoveryConflict>()));
    await expectLater(old.markCartSubmitting(a,'cart-1',owner:'old-editor',commandKey:'other'),
      throwsA(isA<LocalRecoveryConflict>()));
    await next.markCartSubmitting(a,'cart-2',owner:'new-editor',commandKey:'original-key');
    await next.markCartSubmitting(a,'cart-2',owner:'new-editor',commandKey:'original-key');
    await expectLater(next.markCartSubmitting(a,'cart-2',owner:'new-editor',commandKey:'different-key'),
      throwsA(isA<LocalRecoveryConflict>()));
    await expectLater(next.saveScopedCart(a,'cart-2',{'quantity':'9'},owner:'new-editor'),
      throwsA(isA<LocalRecoveryConflict>()));
    await expectLater(next.clearScopedCart(a,'cart-2',owner:'new-editor',commandKey:'wrong'),
      throwsA(isA<LocalRecoveryConflict>()));
    await next.clearScopedCart(a,'cart-2',owner:'new-editor',commandKey:'original-key');
    expect(await next.savedCarts(a),isEmpty);
  });
  test('definitively rejected create can resume a released cart; ambiguous create cannot',()async{
    final store=ErpLocalStore(Memory());
    await store.saveScopedCart(a,'cart',{'lines':[]},owner:'editor');
    await store.markCartSubmitting(a,'cart',owner:'editor',commandKey:'k');
    await expectLater(store.releaseScopedCart(a,'cart',owner:'editor'),
      throwsA(isA<LocalRecoveryConflict>()));
    await store.releaseRejectedCart(a,'cart',owner:'editor',commandKey:'k');
    final reopened=await store.claimScopedCart(a,'cart','new-cart',owner:'new-editor');
    expect(reopened['lines'],isEmpty);
  });
  test('reconciliation claims are exclusive across tabs and replacement is atomic',()async{
    final shared=Memory(),tabOne=ErpLocalStore(shared),tabTwo=ErpLocalStore(shared);
    const id='00000000-0000-4000-8000-000000000005';
    final original={'id':id,'body':{'branchId':'b','lines':[{'quantity':'1'}]}};
    final revised={'id':id,'body':{'branchId':'b','lines':[{'quantity':'2'}]}};
    await tabOne.saveUnsentSalesUpdate(a,id,'old',original);
    await tabOne.markUnsentSalesUpdate(a,id,'old','inflight');
    await tabOne.markUnsentSalesUpdate(a,id,'old','rejected');
    await tabOne.claimRejectedSalesUpdate(a,id,'old','editor-one');
    await expectLater(tabTwo.claimRejectedSalesUpdate(a,id,'old','editor-two'),
      throwsA(isA<LocalRecoveryConflict>()));
    await expectLater(tabTwo.clearUnsentSalesUpdate(a,id,'old',requiredStatus:'rejected'),
      throwsA(isA<LocalRecoveryConflict>()));
    await expectLater(tabTwo.markUnsentSalesUpdate(a,id,'old','inflight'),
      throwsA(isA<LocalRecoveryConflict>()));
    await tabOne.replaceReconciledSalesUpdate(a,id,'old','editor-one','new',revised);
    expect((await tabTwo.unsentSalesUpdates(a,id)).map((e)=>e['key']).toList(),['new']);
    await expectLater(tabTwo.replaceReconciledSalesUpdate(a,id,'old','editor-two','duplicate',revised),
      throwsA(isA<LocalRecoveryConflict>()));
  });
  test('expired reconciliation transfers claim without allowing old editor to replace',()async{
    final store=ErpLocalStore(Memory());
    const id='00000000-0000-4000-8000-000000000005';
    final original={'id':id,'body':{'branchId':'b','lines':[]}};
    await store.saveUnsentSalesUpdate(a,id,'old',original);
    await store.markUnsentSalesUpdate(a,id,'old','inflight');
    await store.markUnsentSalesUpdate(a,id,'old','rejected');
    final time=DateTime.utc(2026,11,24,10);
    await store.claimRejectedSalesUpdate(a,id,'old','editor-one',now:time);
    await store.claimRejectedSalesUpdate(a,id,'old','editor-two',
      now:time.add(const Duration(minutes:11)));
    await expectLater(store.replaceReconciledSalesUpdate(a,id,'old','editor-one','first',original),
      throwsA(isA<LocalRecoveryConflict>()));
    await store.releaseRejectedSalesClaim(a,id,'old','editor-two');
    expect((await store.unsentSalesUpdates(a,id)).single['status'],'rejected');
  });
  test('retired cart tombstones retain ownership fence but never customer PII',()async{
    final memory=Memory(),store=ErpLocalStore(memory);
    await store.saveScopedCart(a,'private',{'customerPhone':'0900000000'},owner:'person');
    await store.clearScopedCart(a,'private',owner:'person');
    final jsonBlob=memory.rows.values.join(' ');
    expect(jsonBlob.contains('0900000000'),false);
    await expectLater(store.saveScopedCart(a,'private',{'customerPhone':'0900000000'},owner:'person'),
      throwsA(isA<LocalRecoveryConflict>()));
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
