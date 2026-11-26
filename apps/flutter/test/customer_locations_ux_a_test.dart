import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:erp_distribution/ui/customer_locations_dialog.dart';
import 'package:erp_distribution/ui/identity_client.dart';
import 'package:erp_distribution/ui/erp_tokens.dart';

const branch='00000000-0000-4000-8000-000000000001';
const customer='00000000-0000-4000-8000-000000000002';

void main(){
  testWidgets('UX-A: delivery address alone is required; no store code or new customer',
    (tester)async{
    var writes=0;
    Map<String,dynamic>? posted;
    final client=ErpIdentityClient(apiOrigin:'https://erp.example.test',
      httpClient:MockClient((request)async{
        http.Response reply(Map<String,dynamic> body,[int status=200])=>
          http.Response(jsonEncode(body),status,
            headers:{'content-type':'application/json; charset=utf-8'});
        if(request.url.path=='/v1/catalog/customers/$customer/locations'){
          if(request.method=='GET')return reply({'items':[]});
          if(request.method=='POST'){
            writes++;
            posted=jsonDecode(request.body) as Map<String,dynamic>;
            expect(request.headers['idempotency-key'],isNotEmpty);
            return reply({'id':'00000000-0000-4000-8000-000000000003','revision':0},201);
          }
        }
        return reply({'error':{'code':'NOT_FOUND'}},404);
      }));
    addTearDown(client.dispose);
    final session=IdentitySession(actorId:customer,token:'mock-token',
      expiresAt:DateTime.now().add(const Duration(hours:1)),
      grants:const [IdentityGrant(roleId:'catalog',permission:'catalog.write',branchId:branch)]);
    await tester.pumpWidget(MaterialApp(theme:erpTheme(touch:true),
      home:Scaffold(body:Center(child:CustomerLocationsDialog(
        client:client,session:session,branchId:branch,customerId:customer,
        customerName:'Khách A',canWrite:true)))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Thêm địa chỉ'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('location-code')),findsNothing);
    expect(find.byKey(const ValueKey('location-address')),findsOneWidget);
    expect(find.byKey(const ValueKey('location-name')),findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('location-save')));
    await tester.pumpAndSettle();
    expect(find.text('Vui lòng nhập địa chỉ giao hàng'),findsOneWidget);
    expect(writes,0);
    await tester.enterText(find.byKey(const ValueKey('location-address')),'12 Lê Lợi, Quận 1');
    await tester.tap(find.byKey(const ValueKey('location-save')));
    await tester.pumpAndSettle();
    expect(writes,1);
    expect(posted?['branchId'],branch);
    expect(posted?['address'],'12 Lê Lợi, Quận 1');
    expect(posted?['name'],'');
    expect(posted?.containsKey('code'),isFalse);
  });
}
