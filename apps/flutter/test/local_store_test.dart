import 'package:flutter_test/flutter_test.dart';
import 'package:erp_distribution/local/local_driver.dart';
import 'package:erp_distribution/local/local_store.dart';
class Memory implements LocalDriver{
  final rows=<String,String>{};
  @override Future<String?> read(String key)async=>rows[key];
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
  test('cache expiry is explicit, never proof of a current price',()async{
    final store=ErpLocalStore(Memory());
    final time=DateTime.utc(2026,11,24);
    await store.saveCache(a,'price',{'amount':'123'},fetchedAt:time,ttl:const Duration(minutes:1));
    expect((await store.cache(a,'price',now:time))!.stale,false);
    expect((await store.cache(a,'price',now:time.add(const Duration(minutes:1))))!.stale,true);
    expect(await store.cache(b,'price',now:time),isNull);
  });
}
