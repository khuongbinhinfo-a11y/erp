import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:erp_distribution/ui/identity_client.dart';

const token='test-session-token', actor='user-1', branch='branch-1', product='product-1';
final first=Uint8List.fromList([137,80,78,71,13,10,26,10,0]);
final corrected=Uint8List.fromList([137,80,78,71,13,10,26,10,1]);
http.Response reply(Object body,int status)=>http.Response(
  jsonEncode(body),status,headers:const {'content-type':'application/json'});
void main(){
  test('definitive image validation failure permits a different corrected file',
    ()async{
      var complete=0,put=0;
      final httpClient=MockClient((request)async{
        if(request.url.path.endsWith('/prepare')){
          expect(request.method,'POST');
          return reply({'putUrl':'https://unit.r2.cloudflarestorage.com/erp-r1-media/key.png'},200);
        }
        if(request.url.host.endsWith('.r2.cloudflarestorage.com')){
          put++;
          expect(request.method,'PUT');
          expect(request.headers['if-none-match'],'*');
          return http.Response('',200);
        }
        if(request.url.path.endsWith('/complete')){
          complete++;
          return complete==1
            ?reply({'error':{'code':'INVALID_IMAGE_CONTENT'}},400)
            :reply({'id':'accepted'},201);
        }
        return reply({},404);
      });
      final client=ErpIdentityClient(
        apiOrigin:'https://erp.example.test',httpClient:httpClient);
      addTearDown(client.dispose);
      await expectLater(client.uploadProductPhoto(token,actor,branch,product,
        first,'image/png'),throwsA(isA<ErpApiError>()));
      final saved=await client.uploadProductPhoto(token,actor,branch,product,
        corrected,'image/png');
      expect(saved['id'],'accepted');
      expect(put,2);
      expect(complete,2);
    });

  test('lost ACK retains exact image/key and existing R2 object 412 reconciles',
    ()async{
      var completed=0,put=0;
      Map<String,dynamic>? originalBody;
      String? originalIdempotency;
      final httpClient=MockClient((request)async{
        if(request.url.path.endsWith('/prepare')){
          final body=jsonDecode(request.body) as Map<String,dynamic>;
          originalBody??=body;
          expect(body,originalBody);
          return reply({'putUrl':'https://unit.r2.cloudflarestorage.com/erp-r1-media/key.webp'},200);
        }
        if(request.url.host.endsWith('.r2.cloudflarestorage.com')){
          put++;
          expect(request.headers['if-none-match'],'*');
          return http.Response('',put==1?200:412);
        }
        if(request.url.path.endsWith('/complete')){
          completed++;
          final body=jsonDecode(request.body) as Map<String,dynamic>;
          expect(body,originalBody);
          originalIdempotency??=request.headers['idempotency-key'];
          expect(request.headers['idempotency-key'],originalIdempotency);
          if(completed==1){
            throw http.ClientException('server COMMITed but ACK lost');
          }
          return reply({'id':'same-receipt'},201);
        }
        return reply({},404);
      });
      final client=ErpIdentityClient(
        apiOrigin:'https://erp.example.test',httpClient:httpClient);
      addTearDown(client.dispose);
      await expectLater(client.uploadProductPhoto(token,actor,branch,product,
        first,'image/webp'),throwsA(isA<ErpApiError>()));
      final saved=await client.uploadProductPhoto(token,actor,branch,product,
        first,'image/webp');
      expect(saved['id'],'same-receipt');
      expect(put,2);
      expect(completed,2);
    });
}
