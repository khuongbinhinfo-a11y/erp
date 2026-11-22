import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:erp_distribution/ui/identity_client.dart';

void main() {
  const alice='00000000-0000-4000-8000-000000000001';
  const bob='00000000-0000-4000-8000-000000000002';
  const branch='00000000-0000-4000-8000-000000000003';
  const kind='sales.customer.quick';
  const command={'branchId':branch,'code':'KH-001','name':'Khách mới'};
  const key='same-original-request-key';
  late ErpIdentityClient client;

  setUp((){
    client=ErpIdentityClient(apiOrigin:'https://erp.example.test',
      httpClient:MockClient((req) async {
        const headers={'content-type':'application/json; charset=utf-8'};
        if(req.url.path=='/v1/auth/login'&&req.method=='POST'){
          final raw=jsonDecode(req.body) as Map<String,dynamic>;
          return http.Response(jsonEncode({
            'token':raw['loginName']=='alice'?'alice-token':'bob-token',
            'expiresAt':'2099-01-01T00:00:00Z',
          }),200,headers:headers);
        }
        if(req.url.path=='/v1/auth/session'&&req.method=='GET'){
          final isAlice=req.headers['authorization']=='Bearer alice-token';
          return http.Response(jsonEncode({
            'actorId':isAlice?alice:bob,
            'loginName':isAlice?'alice':'bob',
            'expiresAt':'2099-01-01T00:00:00Z',
            'grants':[],
          }),200,headers:headers);
        }
        if(req.url.path=='/v1/auth/logout'&&req.method=='POST'){
          return http.Response(jsonEncode({'signedOut':true}),200,headers:headers);
        }
        return http.Response('{}',404,headers:headers);
      }));
  });
  tearDown(()=>client.dispose());

  test('same-actor login preserves pending customer body and key after expired session', ()async{
    client.retainR1(alice,branch,kind,command,key);
    final next=await client.login('alice','synthetic-password');
    expect(next.actorId,alice);
    final pending=client.pendingR1(alice,branch,kind);
    expect(pending,isNotNull);
    expect(pending!.key,key);
    expect(pending.payload,command);
  });

  test('account switch discards catalog commands belonging to other actor', ()async{
    client.retainR1(alice,branch,kind,command,key);
    final next=await client.login('bob','synthetic-password');
    expect(next.actorId,bob);
    expect(client.pendingR1(alice,branch,kind),isNull);
    expect(client.pendingR1(bob,branch,kind),isNull);
  });

  test('explicit logout clears unresolved catalog commands', ()async{
    client.retainR1(alice,branch,kind,command,key);
    await client.logout('alice-token');
    expect(client.pendingR1(alice,branch,kind),isNull);
  });
}
