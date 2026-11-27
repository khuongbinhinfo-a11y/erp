import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:erp_distribution/ui/pos_product_photo_cache.dart';

void main(){
  const id='00000000-0000-4000-8000-000000000001';
  test('primary signed photo deduplicates per product and refreshes before expiry',()async{
    var calls=0;
    var now=DateTime(2026,11,27);
    final cache=PosProductPhotoCache((_)async{
      calls++;
      return [{'downloadUrl':'https://example.test/secondary'},
        {'isPrimary':true,'downloadUrl':'https://example.test/primary'}];
    },clock:()=>now);
    final a=cache.urlFor(id),b=cache.urlFor(id);
    expect(identical(a,b),isTrue);
    expect(await a,'https://example.test/primary');
    expect(calls,1);
    now=now.add(const Duration(minutes:4,seconds:1));
    expect(await cache.urlFor(id),'https://example.test/primary');
    expect(calls,2);
    cache.dispose();
  });
  test('no more than four requests and old scope cancels queued images',()async{
    final pending=<Completer<List<Map<String,dynamic>>>>[];
    final cache=PosProductPhotoCache((_) {
      final c=Completer<List<Map<String,dynamic>>>();
      pending.add(c);return c.future;
    });
    final futures=[for(var i=1;i<=8;i++)
      cache.urlFor('00000000-0000-4000-8000-00000000000$i')];
    expect(pending.length,4);
    cache.dispose();
    for(final c in pending)c.complete([{'downloadUrl':'https://example.test/image'}]);
    expect(await Future.wait(futures),everyElement(isNull));
    expect(pending.length,4);
  });
  test('reject non HTTPS and allow retry of missing/error photo',()async{
    var now=DateTime(2026,11,27),calls=0;
    final cache=PosProductPhotoCache((_)async{
      calls++;
      if(calls==1)throw StateError('unavailable');
      return [{'downloadUrl':'http://example.test/photo'}];
    },clock:()=>now);
    expect(await cache.urlFor(id),isNull);
    expect(await cache.urlFor(id),isNull);
    expect(calls,1);
    now=now.add(const Duration(seconds:31));
    expect(await cache.urlFor(id),isNull);
    expect(calls,2);
    cache.dispose();
  });
}
