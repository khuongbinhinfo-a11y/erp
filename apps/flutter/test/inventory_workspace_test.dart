import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:erp_distribution/ui/inventory_workspace.dart';
import 'package:erp_distribution/ui/identity_client.dart';
import 'package:erp_distribution/ui/erp_tokens.dart';

const branch='00000000-0000-4000-8000-000000000001';
const warehouse='00000000-0000-4000-8000-000000000002';
const product='00000000-0000-4000-8000-000000000003';
const actor='00000000-0000-4000-8000-000000000004';

void main(){
 testWidgets('R3 warehouse displays canonical balances and safely retries a lost ACK',
  (tester)async{
   var onHand=true,attempts=0;
   final keys=<String?>[],bodies=<String>[];
   final calls=<String>[];
   final client=ErpIdentityClient(apiOrigin:'https://erp.example.test',
     httpClient:MockClient((req)async{
       calls.add(req.url.path);
       if(req.url.path=='/v1/catalog/branches')return http.Response(jsonEncode({'items':[
         {'id':branch,'name':'Chi nhánh chính'}]}),200);
       if(req.url.path=='/v1/catalog/warehouses')return http.Response(jsonEncode({'items':[
         {'id':warehouse,'name':'Kho chính','branchId':branch}]}),200);
       if(req.url.path=='/v1/catalog/products')return http.Response(jsonEncode({'items':[
         {'id':product,'code':'SP01','name':'Hàng kiểm thử','active':true}]}),200);
       if(req.url.path=='/v1/inventory/balances')return http.Response(jsonEncode({'items':onHand?[
         {'productId':product,'sku':'SP01','name':'Hàng kiểm thử',
          'onHand':'5.000000','reserved':'0.000000','available':'5.000000'}
       ]:[]}),200);
       if(req.url.path=='/v1/inventory/movements')return http.Response(jsonEncode({'items':[]}),200);
       if(req.url.path=='/v1/inventory/reservations')return http.Response(jsonEncode({'items':[]}),200);
       if(req.url.path=='/v1/inventory/openings'){
         attempts++;keys.add(req.headers['idempotency-key']);bodies.add(req.body);
         final obj=jsonDecode(req.body) as Map<String,dynamic>;
         expect(obj['quantity'],'5');expect(obj['warehouseId'],warehouse);
         if(attempts==1)throw http.ClientException('response lost after commit');
         onHand=true;
         return http.Response(jsonEncode({'id':'id',
          'kind':'OPENING','deltaBase':'5.000000'}),201);
       }
       return http.Response(jsonEncode({'error':{'code':'NOT_FOUND'}}),404);
     }));
   addTearDown(client.dispose);
   tester.view.devicePixelRatio=1;
   tester.view.physicalSize=const Size(1280,900);
   addTearDown(tester.view.resetPhysicalSize);
   addTearDown(tester.view.resetDevicePixelRatio);
   final session=IdentitySession(actorId:actor,token:'synthetic-token',
     expiresAt:DateTime.now().add(const Duration(hours:1)),grants:[
       const IdentityGrant(roleId:'a',permission:'inventory.read',
          branchId:branch,warehouseId:warehouse),
       const IdentityGrant(roleId:'b',permission:'inventory.post',
          branchId:branch,warehouseId:warehouse),
     ]);
   await tester.pumpWidget(MaterialApp(theme:erpTheme(touch:false),
     home:Scaffold(body:SingleChildScrollView(child:
       InventoryWorkspace(client:client,session:session)))));
   for(var i=0;i<6;i++){
     await tester.runAsync(()async=>
       Future<void>.delayed(const Duration(milliseconds:100)));
     await tester.pumpAndSettle();
   }
   expect(calls,contains('/v1/catalog/branches'));
   expect(calls,contains('/v1/catalog/warehouses'));
   expect(calls,contains('/v1/inventory/balances'));
   expect(find.text('Kho và tồn khả dụng'),findsOneWidget);
   // Stock display is only the backend projection, never a locally computed balance.
   // Synthetic UI debugging only; no real business data or credentials.
   print('R3_TEST_RENDERED='+tester.widgetList<Text>(find.byType(Text))
       .map((x)=>x.data).whereType<String>().take(25).toList().toString());
   expect(find.textContaining('SP01 · Hàng kiểm thử'),findsOneWidget);
   expect(find.textContaining('Khả dụng: 5.000000'),findsOneWidget);
   // A client preserves the immutable request body/key for a retry after lost ACK.
   final cmd={'branchId':branch,'warehouseId':warehouse,
     'productId':product,'quantity':'5'};
   const key='stock-retry-fixed-key';
   client.retainInventory('opening-test',cmd,key);
   try {
     await client.inventoryAction(session.token,'openings',cmd,key:key,revision:0);
     fail('First request simulates a lost acknowledgment');
   }on ErpApiError catch(e){
     expect(e.status,0);
   }
   final pending=client.pendingInventory('opening-test')!;
   expect(pending.payload,cmd);
   expect(pending.key,key);
   await client.inventoryAction(session.token,'openings',pending.payload,
     key:pending.key,revision:0);
   client.clearInventory('opening-test');
   expect(client.pendingInventory('opening-test'),isNull);
   expect(attempts,2);
   expect(keys[0],keys[1]);
   expect(bodies[0],bodies[1]);
   await tester.tap(find.text('Sổ kho'));
   for(var i=0;i<3;i++){
     await tester.runAsync(()async=>
       Future<void>.delayed(const Duration(milliseconds:100)));
     await tester.pumpAndSettle();
   }
   expect(find.text('Chưa có chứng từ ở mục này.'),findsOneWidget);
 });
}
