import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:erp_distribution/ui/identity_client.dart';

void main() {
  test('admin scope resolution paginates past first 100 with exact names', () async {
    final requests=<String>[];
    String id(int index)=>
      '00000000-0000-4000-8000-${index.toRadixString(16).padLeft(12,'0')}';
    final client=ErpIdentityClient(apiOrigin:'https://erp.example.test',
      httpClient:MockClient((req)async{
        requests.add(req.url.toString());
        if(req.url.path!='/v1/admin/scopes'){
          return http.Response('{}',404);
        }
        final offset=int.tryParse(req.url.queryParameters['offset']??'0')??0;
        final start=offset,end=offset==0?100:101;
        return http.Response(jsonEncode({
          'branches':[
            for(var i=start;i<end;i++)
              {'id':id(i+1),'code':'CN$i','name':'Chi nhánh $i'},
          ],
          'warehouses':[
            for(var i=start;i<end;i++)
              {'id':id(i+1001),'branchId':id(1),
                'code':'K$i','name':'Kho $i'},
          ],
          'hasMoreBranches':offset==0,'hasMoreWarehouses':offset==0,
        }),200,headers:const {'content-type':'application/json; charset=utf-8'});
      }));
    addTearDown(client.dispose);
    final resolved=await client.scopes('synthetic-admin-token');
    expect(resolved.branches.length,101);
    expect(resolved.warehouses.length,101);
    expect(resolved.branches.last.name,'Chi nhánh 100');
    expect(resolved.warehouses.last.name,'Kho 100');
    expect(requests.length,2);
    expect(requests.last,contains('offset=100'));
  });
}
