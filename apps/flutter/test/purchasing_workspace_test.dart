import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:erp_distribution/ui/purchasing_workspace.dart';
import 'package:erp_distribution/ui/identity_client.dart';
import 'package:erp_distribution/ui/erp_tokens.dart';
const branch='00000000-0000-4000-8000-000000000001';
const warehouse='00000000-0000-4000-8000-000000000002';
const actor='00000000-0000-4000-8000-000000000003';
const order='00000000-0000-4000-8000-000000000004';
const supplier='00000000-0000-4000-8000-000000000005';
void main(){
 testWidgets('R3.2 purchasing renders live flat rows and confirms only after server ACK',(tester)async{
  var confirmed=false,postCount=0;
  final calls=<String>[];
  String? postedKey;
  final client=ErpIdentityClient(apiOrigin:'https://erp.example.test',
   httpClient:MockClient((req)async{
    calls.add(req.url.path);
    const headers={'content-type':'application/json; charset=utf-8'};
    if(req.url.path=='/v1/catalog/branches'){
      return http.Response(jsonEncode({'items':[
       {'id':branch,'code':'MAIN','name':'Chi nhánh chính'}]}),200,headers:headers);
    }
    if(req.url.path=='/v1/catalog/warehouses'){
      return http.Response(jsonEncode({'items':[
       {'id':warehouse,'code':'MAIN','name':'Kho chính'}]}),200,headers:headers);
    }
    if(req.url.path=='/v1/purchasing/orders'&&req.method=='GET'){
      return http.Response(jsonEncode({'items':[{
       'id':order,'documentNo':confirmed?'PO-00000001':null,
       'supplierId':supplier,'supplierName':'Nhà cung cấp A',
       'warehouseId':warehouse,'status':confirmed?'CONFIRMED':'DRAFT',
       'revision':confirmed?1:0,'lineCount':1,'receiptCount':0}]}),
       200,headers:headers);
    }
    if(req.url.path=='/v1/purchasing/orders/$order/confirm'&&req.method=='POST'){
      postCount++;postedKey=req.headers['idempotency-key'];
      expect(req.headers['if-match'],'0');
      final body=jsonDecode(req.body) as Map<String,dynamic>;
      expect(body['branchId'],branch);expect(body['warehouseId'],warehouse);
      confirmed=true;
      return http.Response(jsonEncode({
       'id':order,'status':'CONFIRMED','documentNo':'PO-00000001','revision':1}),
       200,headers:headers);
    }
    return http.Response(jsonEncode({'error':{'code':'NOT_FOUND'}}),404,headers:headers);
   }));
  addTearDown(client.dispose);
  tester.view.devicePixelRatio=1;
  tester.view.physicalSize=const Size(1280,900);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final session=IdentitySession(actorId:actor,token:'local-synthetic-token',
   expiresAt:DateTime.now().add(const Duration(hours:1)),grants:const [
    IdentityGrant(roleId:'a',permission:'purchase.read',branchId:branch),
    IdentityGrant(roleId:'b',permission:'purchase.create',branchId:branch),
    IdentityGrant(roleId:'c',permission:'purchase.confirm',branchId:branch),
    IdentityGrant(roleId:'d',permission:'inventory.read',branchId:branch,warehouseId:warehouse),
   ]);
  await tester.pumpWidget(MaterialApp(theme:erpTheme(touch:false),
   home:Scaffold(body:SingleChildScrollView(
    child:PurchasingWorkspace(client:client,session:session)))));
  for(var i=0;i<6;i++){
   await tester.runAsync(()async=>Future<void>.delayed(const Duration(milliseconds:100)));
   await tester.pumpAndSettle();
  }
  expect(calls,contains('/v1/purchasing/orders'));
  expect(find.text('Đơn mua và nhận hàng'),findsOneWidget);
  expect(find.textContaining('Nhà cung cấp A · Đang lập'),findsOneWidget);
  expect(find.byType(Card),findsNothing);
  expect(postCount,0);
  await tester.tap(find.text('Xác nhận'));
  await tester.pumpAndSettle();
  expect(find.text('Xác nhận đơn mua?'),findsOneWidget);
  await tester.tap(find.descendant(of:find.byType(AlertDialog),
    matching:find.text('Xác nhận')));
  for(var i=0;i<5;i++){
   await tester.runAsync(()async=>Future<void>.delayed(const Duration(milliseconds:100)));
   await tester.pumpAndSettle();
  }
  expect(postCount,1);
  expect(postedKey,isNotNull);
  expect(find.text('PO-00000001'),findsOneWidget);
  expect(find.textContaining('Nhà cung cấp A · Đã xác nhận'),findsOneWidget);
  // A successful server ACK shows a transient toast; drain its 4-second timer.
  await tester.pump(const Duration(seconds:5));
  await tester.pumpAndSettle();
 });
}
