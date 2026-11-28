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
          'stock':{'onHand':'3.000000','reserved':'0','available':'3.000000'},
          'locations':[],'lots':[],'scopes':[]},
        '/v1/inventory/guard-policy'=>{'policy':{
          'reserveShortageMode':'WARN','negativeIssueMode':'BLOCK','revision':0}},
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
   expect(find.textContaining('Tồn khả dụng tại kho: 3 cai'),findsOneWidget);
   expect(writes,0);
   expect(acknowledged,false);
   // Dismiss while quantity input owns focus: no disposed-controller frame.
   await tester.tap(find.byType(TextField).last);
   await tester.pumpAndSettle();
   await tester.tap(find.byKey(const ValueKey('manual-issue-confirm')));
   await tester.pumpAndSettle();
   expect(submitted?['lines'],[{'lineNo':1,'quantityBase':'3.000000'}]);
   expect(submitted?['allowNegative'],false);
   expect(revision,4);
   expect(writes,0,reason:'The dialog cannot post stock without explicit parent mutation');
 });
 test('T5-A 409 preserves server business reason instead of generic duplicate',()async{
  final client=ErpIdentityClient(apiOrigin:'https://erp.example.test',
   httpClient:MockClient((request)async=>http.Response(jsonEncode({
    'error':{'code':'INSUFFICIENT_AVAILABLE_STOCK',
      'message':'Tồn khả dụng không đủ. Vui lòng nhập kho hoặc giảm số xuất.',
      'requestId':'test-request-123'}
    }),409,headers:const {'content-type':'application/json; charset=utf-8'})));
  addTearDown(client.dispose);
  try{
   await client.inventoryAction('test-token','direct-issues',
     {'branchId':branch,'warehouseId':warehouse,'orderId':order,'lines':[]},
     key:'stock-feedback-test',revision:2);
   fail('The 409 must be reported');
  }on ErpApiError catch(e){
   expect(e.status,409);
   expect(e.code,'INSUFFICIENT_AVAILABLE_STOCK');
   expect(e.message,'Tồn khả dụng không đủ. Vui lòng nhập kho hoặc giảm số xuất.');
  }
 });

 testWidgets('T5-A zero available prevents issue intent before any POST', (tester)async{
  var submitCount=0,writeCount=0;
  final client=ErpIdentityClient(apiOrigin:'https://erp.example.test',
   httpClient:MockClient((request)async{
    if(request.method!='GET')writeCount++;
    final data=switch(request.url.path){
      '/v1/sales/orders/$order'=>{'order':{
        'id':order,'branchId':branch,'version':1,'revision':3,
        'status':'CONFIRMED','versionStatus':'CONFIRMED',
        'fulfillmentStatus':'NOT_ALLOCATED',
        'shipping':{'warehouseId':warehouse,'deliveryChoice':'MANUAL'},
        'lines':[{'lineNo':1,'productId':product,'sku':'P1',
          'productName':'Hàng chưa nhập kho','unitCode':'cai',
          'quantity':'8','priceSnapshot':{'normalizedBaseQuantity':'8.000000'}}]}},
      '/v1/inventory/direct-issues/totals'=>{'items':[{
        'lineNo':1,'issuedBase':'0','baseUnit':'cai','productId':product}]},
      '/v1/inventory/stock-scopes'=>{
        'policy':{'requireLocation':false,'requireLot':false},
        'stock':{'onHand':'0','reserved':'0','available':'0'},
        'locations':[],'lots':[],'scopes':[]},
      '/v1/inventory/guard-policy'=>{'policy':{
        'negativeIssueMode':'BLOCK','reserveShortageMode':'WARN'}},
      _=>throw StateError('Unexpected read ${request.url.path}'),
    };
    return http.Response(jsonEncode(data),200,
      headers:const {'content-type':'application/json; charset=utf-8'});
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
        onSubmit:(body,rev)async{submitCount++;});
    },child:const Text('Mở xuất kho'))))));
  await tester.tap(find.text('Mở xuất kho'));
  await tester.pumpAndSettle();
  expect(find.textContaining('Tồn khả dụng tại kho: 0 cai'),findsOneWidget);
  await tester.tap(find.byKey(const ValueKey('manual-issue-confirm')));
  await tester.pumpAndSettle();
  expect(find.textContaining('Số xuất vượt tồn khả dụng'),findsOneWidget);
  expect(submitCount,0,reason:'No warehouse OUT intent without real stock');
  expect(writeCount,0);
  await tester.tap(find.text('Đóng'));
  await tester.pumpAndSettle();
  expect(tester.takeException(),isNull);
 });

}
