import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:erp_distribution/ui/transfer_workspace.dart';
import 'package:erp_distribution/ui/identity_client.dart';
import 'package:erp_distribution/ui/erp_tokens.dart';

const branch='00000000-0000-4000-8000-000000000001';
const source='00000000-0000-4000-8000-000000000002';
const dest='00000000-0000-4000-8000-000000000003';
const actor='00000000-0000-4000-8000-000000000004';
const transfer='00000000-0000-4000-8000-000000000005';
void main(){
 testWidgets('R3.3 transfer rows and destination partial receipt only after ACK',
 (tester)async{
  var calls=0,accepted=false;
  const headers={'content-type':'application/json; charset=utf-8'};
  http.Response ok(Object data,int status)=>http.Response(jsonEncode(data),status,headers:headers);
  final client=ErpIdentityClient(apiOrigin:'https://erp.example.test',
   httpClient:MockClient((req)async{
    if(req.url.path=='/v1/inventory/transfers/scopes')return ok({
      'branches':[{'id':branch,'name':'Chi nhánh chính'}],
      'warehouses':req.url.queryParameters.containsKey('branchId')?[
        {'id':source,'name':'Kho chính'},{'id':dest,'name':'Kho nhận'}]:[],
    },200);
    if(req.url.path=='/v1/inventory/transfers'&&req.method=='GET')
      return ok({'items':[{'id':transfer,'sourceWarehouseId':source,
        'destinationWarehouseId':dest,'sourceWarehouseName':'Kho chính',
        'destinationWarehouseName':'Kho nhận','status':accepted?
        'PARTIALLY_RECEIVED':'IN_TRANSIT','revision':accepted?3:2,
        'lineCount':1,'receiptCount':accepted?1:0}],'hasMore':false},200);
    if(req.url.path=='/v1/inventory/transfers/$transfer'&&req.method=='GET')
      return ok({'transfer':{'id':transfer,'revision':2,'lines':[
        {'lineNo':1,'sku':'SP01','name':'Hàng hóa',
        'dispatchedBase':'3.000000','receivedBase':'0.000000',
        'inTransitBase':'3.000000'}]}},200);
    if(req.url.path=='/v1/inventory/transfers/$transfer/receipts'){
      calls++;
      expect(req.headers['if-match'],'2');
      expect((jsonDecode(req.body) as Map<String,dynamic>)['lines'],[
        {'transferLineNo':1,'quantity':'1'}]);
      accepted=true;
      return ok({'id':'00000000-0000-4000-8000-000000000006',
        'status':'POSTED','transferRevision':3},201);
    }
    return ok({'error':{'code':'NOT_FOUND'}},404);
   }));
  addTearDown(client.dispose);
  tester.view.devicePixelRatio=1;tester.view.physicalSize=const Size(1250,900);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final session=IdentitySession(actorId:actor,token:'synthetic-token',
   expiresAt:DateTime.now().add(const Duration(hours:1)),grants:const [
     IdentityGrant(roleId:'r1',permission:'inventory.transfer.read',
       branchId:branch,warehouseId:source),
     IdentityGrant(roleId:'r2',permission:'inventory.transfer.read',
       branchId:branch,warehouseId:dest),
     IdentityGrant(roleId:'r3',permission:'inventory.transfer.receive',
       branchId:branch,warehouseId:dest),
   ]);
  await tester.pumpWidget(MaterialApp(theme:erpTheme(touch:false),
    home:Scaffold(body:SingleChildScrollView(
      child:TransferWorkspace(client:client,session:session)))));
  for(var i=0;i<5;i++){
    await tester.runAsync(()async=>Future<void>.delayed(const Duration(milliseconds:80)));
    await tester.pumpAndSettle();
  }
  expect(find.text('Chuyển kho và hàng đang đi đường'),findsOneWidget);
  expect(find.text('Kho chính → Kho nhận'),findsOneWidget);
  expect(find.byType(Card),findsNothing);
  expect(find.text('Nhận hàng'),findsNothing);
  await tester.tap(find.text('Kho chính').last);
  await tester.pumpAndSettle();
  await tester.tap(find.text('Kho nhận').last);
  for(var i=0;i<4;i++){
    await tester.runAsync(()async=>Future<void>.delayed(const Duration(milliseconds:80)));
    await tester.pumpAndSettle();
  }
  expect(find.text('Nhận hàng'),findsOneWidget);
  await tester.tap(find.text('Nhận hàng'));
  for(var i=0;i<3;i++){
    await tester.runAsync(()async=>Future<void>.delayed(const Duration(milliseconds:80)));
    await tester.pumpAndSettle();
  }
  expect(find.text('Nhận hàng chuyển kho'),findsOneWidget);
  await tester.enterText(find.byType(TextField).last,'1');
  await tester.tap(find.text('Ghi nhận hàng'));
  for(var i=0;i<5;i++){
    await tester.runAsync(()async=>Future<void>.delayed(const Duration(milliseconds:80)));
    await tester.pumpAndSettle();
  }
  expect(calls,1);
  expect(find.textContaining('Đã nhận một phần'),findsOneWidget);
  await tester.pump(const Duration(seconds:5));
  await tester.pumpAndSettle();
 });
}
