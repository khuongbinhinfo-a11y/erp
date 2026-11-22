import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:erp_distribution/ui/identity_client.dart';

void main(){
  test('R1 product form loads all UOM dictionary pages after 100',()async{
    final seen=<String>[];
    final client=ErpIdentityClient(
      apiOrigin:'https://erp.example.test',
      httpClient:MockClient((req)async{
        expect(req.method,'GET');
        expect(req.url.path,'/v1/catalog/unit-definitions');
        expect(req.url.queryParameters['branchId'],'branch-one');
        final after=req.url.queryParameters['after'];
        seen.add(after??'first');
        final start=after==null?1:101;
        final end=after==null?100:125;
        final result=<String,dynamic>{
          'items':[
            for(var n=start;n<=end;n++){
              'id':'u-$n','code':'U${n.toString().padLeft(3,'0')}',
              'name':'Đơn vị $n','active':true,
            }
          ],
          if(after==null)'nextAfter':'U100',
        };
        return http.Response(jsonEncode(result),200,headers:{
          'content-type':'application/json; charset=utf-8',
        });
      }),
    );
    addTearDown(client.dispose);
    final units=await client.catalogUnitDefinitionsAll(
      'test-token',branchId:'branch-one');
    expect(units.length,125);
    expect(units.last['code'],'U125');
    expect(units.first['code'],'U001');
    expect(units.map((x)=>x['code']).toSet().length,125);
    expect(seen,['first','U100']);
  });
}
