import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:erp_distribution/ui/manual_stock_issue.dart';
import 'package:erp_distribution/ui/identity_client.dart';

const branch='00000000-0000-4000-8000-000000000001';
const warehouse='00000000-0000-4000-8000-000000000002';
const order='00000000-0000-4000-8000-000000000003';
const product='00000000-0000-4000-8000-000000000004';
const actor='00000000-0000-4000-8000-000000000005';

void main(){
 test('T3-B inventory quantities stay exact without binary floating point',(){
  expect(erpInventoryBaseUnits('9.800,00125'),isNull);
  expect(erpInventoryBaseUnits('9800.00125'),BigInt.from(9800001250));
  expect(erpInventoryFormatUnits(BigInt.from(9800001250)),'9800.001250');
  expect(erpInventoryBaseUnits('1.0000001'),isNull);
  expect(erpInventoryBaseUnits('1e3'),isNull);
 });
 testWidgets('T3-B MANUAL issue shows remaining quantity and only submits after confirmation',
  (tester)async{
   var writes=0,acknowledged=false;
   Map<String,dynamic>? submitted;
   int? revision;
   final client=ErpIdentityClient(apiOrigin:'https://erp.example.test',
    httpClient:MockClient((request)async{
      if(request.method!='GET')writes++;
      final data=switch(request.url.path){
        '/v1/sales/orders/$order'=>{'order':{
          'id':order,'branchId':branch,'version':1,'revision':4,
          'status':'CONFIRMED','versionStatus':'CONFIRMED',
          'fulfillmentStatus':'PARTIAL',
          'shipping':{'warehouseId':warehouse,'deliveryChoice':'MANUAL'},
          'lines':[{'lineNo':1,'productId':product,'sku':'P1','productName':'Mì gói',
           'unitCode':'cai','quantity':'5',
           'priceSnapshot':{'normalizedBaseQuantity':'5.000000'}}]}},
        '/v1/inventory/direct-issues/totals'=>{'items':[{
          'lineNo':1,'issuedBase':'2.000000','baseUnit':'cai','productId':product}]},
        '/v1/inventory/stock-scopes'=>{
          'policy':{'requireLocation':false,'requireLot':false},
          'locations':[],'lots':[],'scopes':[]},
        _=>throw StateError('Unexpected read ${request.url.path}'),
      };
      return http.Response(jsonEncode(data),200,headers:const {
        'content-type':'application/json; charset=utf-8'});
    }));
   addTearDown(client.dispose);
   tester.view.devicePixelRatio=1;
   tester.view.physicalSize=const Size(1000,850);
   addTearDown(tester.view.resetPhysicalSize);
   addTearDown(tester.view.resetDevicePixelRatio);
   final session=IdentitySession(actorId:actor,token:'test-token',
    expiresAt:DateTime.now().add(const Duration(hours:1)),grants:[]);
   await tester.pumpWidget(MaterialApp(home:Scaffold(body:Builder(builder:(ctx)=>
     FilledButton(onPressed:()async{
       await showManualStockIssue(context:ctx,client:client,session:session,
        branchId:branch,warehouseId:warehouse,orderId:order,
        onSubmit:(body,rev)async{
          submitted=body;revision=rev;acknowledged=true;
        });
     },child:const Text('Mở xuất kho'))))));
   await tester.tap(find.text('Mở xuất kho'));
   await tester.pumpAndSettle();
   expect(find.text('Xuất kho trực tiếp'),findsOneWidget);
   expect(find.textContaining('Còn phải xuất: 3 cai'),findsOneWidget);
   expect(writes,0);
   expect(acknowledged,false);
   await tester.tap(find.byKey(const ValueKey('manual-issue-confirm')));
   await tester.pumpAndSettle();
   expect(submitted?['lines'],[{'lineNo':1,'quantityBase':'3.000000'}]);
   expect(submitted?['allowNegative'],false);
   expect(revision,4);
   expect(writes,0,reason:'The dialog cannot post stock without explicit parent mutation');
 });
}
