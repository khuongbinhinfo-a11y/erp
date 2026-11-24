import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:erp_distribution/ui/identity_client.dart';

void main(){
  const branch='00000000-0000-4000-8000-000000000001';
  const product='00000000-0000-4000-8000-000000000002';
  test('T1 loads every SKU for exact product instead of a global 100-SKU page',()async{
    final seen=<String?>[];
    final client=ErpIdentityClient(apiOrigin:'https://erp.example.test',
      httpClient:MockClient((req)async{
        expect(req.method,'GET');
        expect(req.url.path,'/v1/catalog/r1/skus');
        expect(req.url.queryParameters['branchId'],branch);
        expect(req.url.queryParameters['productId'],product);
        final after=req.url.queryParameters['after'];
        seen.add(after);
        final start=after==null?1:101;
        final end=after==null?100:125;
        return http.Response(jsonEncode({
          'items':[for(var n=start;n<=end;n++){
            'id':'sku-$n','productId':product,'active':true,
          }],
          if(after==null)'nextAfter':'sku-100',
        }),200,headers:{'content-type':'application/json'});
      }));
    addTearDown(client.dispose);
    final rows=await client.catalogProductSkusAll('test-token',
      branchId:branch,productId:product);
    expect(rows.length,125);
    expect(rows.last['id'],'sku-125');
    expect(rows.map((x)=>x['id']).toSet().length,125);
    expect(seen,[null,'sku-100']);
  });

  test('T1 rejects cross-product SKU in server response',()async{
    final client=ErpIdentityClient(apiOrigin:'https://erp.example.test',
      httpClient:MockClient((_)async=>http.Response(jsonEncode({
        'items':[{'id':'foreign','productId':'another-product','active':true}],
      }),200,headers:{'content-type':'application/json'})));
    addTearDown(client.dispose);
    await expectLater(client.catalogProductSkusAll('test-token',
      branchId:branch,productId:product),throwsA(isA<ErpApiError>()));
  });
  test('T1 rejects repeated keyset cursor to avoid incorrect unit selection',()async{
    final client=ErpIdentityClient(apiOrigin:'https://erp.example.test',
      httpClient:MockClient((_)async=>http.Response(jsonEncode({
        'items':[{'id':'sku-1','productId':product,'active':true}],
        'nextAfter':'sku-1',
      }),200,headers:{'content-type':'application/json'})));
    addTearDown(client.dispose);
    await expectLater(client.catalogProductSkusAll('test-token',
      branchId:branch,productId:product),throwsA(isA<ErpApiError>()));
  });
  for(final kind in ['units','barcodes']){
    test('Product editor pages $kind without mixing product IDs',()async{
      final cursorField=kind=='units'?'unitCode':'id';
      final seen=<String?>[];
      final client=ErpIdentityClient(apiOrigin:'https://erp.example.test',
        httpClient:MockClient((req)async{
          expect(req.url.path,'/v1/catalog/r1/$kind');
          expect(req.url.queryParameters['productId'],product);
          expect(req.url.queryParameters['branchId'],branch);
          final after=req.url.queryParameters['after'];seen.add(after);
          return http.Response(jsonEncode({
            'items':[{
              cursorField:after==null?'first':'second','productId':product,
            }],
            if(after==null)'nextAfter':'first',
          }),200,headers:{'content-type':'application/json'});
        }));
      addTearDown(client.dispose);
      final rows=await client.catalogProductDetailsAll('test-token',kind,
        branchId:branch,productId:product);
      expect(rows.map((x)=>x[cursorField]),['first','second']);
      expect(seen,[null,'first']);
    });
  }

}
