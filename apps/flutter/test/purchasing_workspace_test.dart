import 'dart:async';
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

testWidgets('R3.2 retains exact receipt through 503, 401 and changed PO revision',
 (tester)async{
  var attempts=0;
  final observedKeys=<String?>[];
  final observedRevisions=<String?>[];
  final observedBodies=<String>[];
  final calls=<String>[];
  final payload=<String,dynamic>{'branchId':branch,'warehouseId':warehouse,
    'lines':[{'orderLineNo':1,'quantity':'2'}]};
  final expectedPath='orders/$order/receipts';
  const expectedKey='purchase-lost-ack-synthetic-key';
  final client=ErpIdentityClient(apiOrigin:'https://erp.example.test',
   httpClient:MockClient((req)async{
    calls.add(req.url.path);
    const headers={'content-type':'application/json; charset=utf-8'};
    if(req.url.path=='/v1/catalog/branches'){
     return http.Response(jsonEncode({'items':[{'id':branch,'name':'Chi nhánh chính'}]}),
       200,headers:headers);
    }
    if(req.url.path=='/v1/catalog/warehouses'){
     return http.Response(jsonEncode({'items':[{'id':warehouse,'name':'Kho chính'}]}),
       200,headers:headers);
    }
    if(req.url.path=='/v1/purchasing/orders'&&req.method=='GET'){
     return http.Response(jsonEncode({'items':[{
       'id':order,'documentNo':'PO-00000001','supplierName':'Nhà cung cấp A',
       'warehouseId':warehouse,'status':'PARTIALLY_RECEIVED','revision':2,
       'lineCount':1,'receiptCount':1}],'hasMore':false}),200,headers:headers);
    }
    if(req.url.path=='/v1/purchasing/$expectedPath'&&req.method=='POST'){
     attempts++;observedKeys.add(req.headers['idempotency-key']);
     observedRevisions.add(req.headers['if-match']);
     observedBodies.add(req.body);
     if(attempts==1)return http.Response(
       jsonEncode({'error':{'code':'PURCHASE_UNAVAILABLE'}}),503,headers:headers);
     if(attempts==2)return http.Response(
       jsonEncode({'error':{'code':'AUTH_REQUIRED'}}),401,headers:headers);
     return http.Response(jsonEncode({
       'id':'00000000-0000-4000-8000-000000000011',
       'purchaseRevision':2,'purchaseStatus':'PARTIALLY_RECEIVED','status':'POSTED'}),
       201,headers:headers);
    }
    return http.Response(jsonEncode({'error':{'code':'NOT_FOUND'}}),404,headers:headers);
   }));
  addTearDown(client.dispose);
  final scope='$actor:$branch:$warehouse';
  client.retainPurchase(scope,payload,expectedKey,path:expectedPath,revision:1);
  tester.view.devicePixelRatio=1;
  tester.view.physicalSize=const Size(1280,900);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final session=IdentitySession(actorId:actor,token:'local-synthetic-token',
    expiresAt:DateTime.now().add(const Duration(hours:1)),grants:const [
      IdentityGrant(roleId:'a',permission:'purchase.read',branchId:branch),
      IdentityGrant(roleId:'b',permission:'purchase.receive',
        branchId:branch,warehouseId:warehouse),
      IdentityGrant(roleId:'c',permission:'inventory.read',
        branchId:branch,warehouseId:warehouse),
    ]);
  await tester.pumpWidget(MaterialApp(theme:erpTheme(touch:false),
   home:Scaffold(body:SingleChildScrollView(
     child:PurchasingWorkspace(client:client,session:session)))));
  for(var i=0;i<5;i++){
    await tester.runAsync(()async=>Future<void>.delayed(const Duration(milliseconds:80)));
    await tester.pumpAndSettle();
  }
  expect(find.text('Xác minh lệnh đang chờ'),findsOneWidget);
  expect(find.text('Nhận hàng'),findsNothing);
  await tester.tap(find.text('Xác minh lệnh đang chờ'));
  await tester.runAsync(()async=>Future<void>.delayed(const Duration(milliseconds:100)));
  await tester.pumpAndSettle();
  expect(attempts,1);
  expect(client.pendingPurchase(scope),isNotNull);
  await tester.tap(find.text('Xác minh lệnh đang chờ'));
  await tester.runAsync(()async=>Future<void>.delayed(const Duration(milliseconds:100)));
  await tester.pumpAndSettle();
  expect(attempts,2);
  expect(client.pendingPurchase(scope),isNotNull);
  // An authentication challenge is not a definitive answer about the first COMMIT.
  await tester.tap(find.text('Xác minh lệnh đang chờ'));
  await tester.runAsync(()async=>Future<void>.delayed(const Duration(milliseconds:100)));
  await tester.pumpAndSettle();
  expect(attempts,3);
  expect(observedKeys,[expectedKey,expectedKey,expectedKey]);
  expect(observedRevisions,['1','1','1']);
  expect(observedBodies[0],observedBodies[1]);
  expect(observedBodies[1],observedBodies[2]);
  expect(jsonDecode(observedBodies[0]),payload);
  expect(client.pendingPurchase(scope),isNull);
  expect(calls.where((s)=>s=='/v1/purchasing/orders/$order').isEmpty,true);
  await tester.pump(const Duration(seconds:5));
  await tester.pumpAndSettle();
});

test('R3.2 same-actor login preserves pending receipt and different actor cannot reuse it',()async{
  var activeActor=actor;
  const headers={'content-type':'application/json; charset=utf-8'};
  final client=ErpIdentityClient(apiOrigin:'https://erp.example.test',
    httpClient:MockClient((req)async{
      if(req.url.path=='/v1/auth/login'){
        return http.Response(jsonEncode({'token':'synthetic-token',
          'expiresAt':'2035-12-31T23:00:00Z'}),200,headers:headers);
      }
      if(req.url.path=='/v1/auth/session'){
        return http.Response(jsonEncode({'actorId':activeActor,
          'loginName':'synthetic','expiresAt':'2035-12-31T23:00:00Z',
          'grants':[]}),200,headers:headers);
      }
      return http.Response('{}',404,headers:headers);
    }));
  addTearDown(client.dispose);
  final scope='$actor:$branch:$warehouse';
  const key='same-actor-retry';
  final original=<String,dynamic>{'branchId':branch,
    'warehouseId':warehouse,'lines':[{'orderLineNo':1,'quantity':'2'}]};
  client.retainPurchase(scope,original,key,
    path:'orders/$order/receipts',revision:1);
  await client.login('synthetic','password');
  expect(client.pendingPurchase(scope)?.key,key);
  activeActor='00000000-0000-4000-8000-000000000099';
  await client.login('another-account','password');
  expect(client.pendingPurchase(scope),isNull);
});

testWidgets('R3.2 definite overreceipt 409 releases PO lock for correction',
 (tester)async{
  const headers={'content-type':'application/json; charset=utf-8'};
  final payload=<String,dynamic>{'branchId':branch,'warehouseId':warehouse,
    'lines':[{'orderLineNo':1,'quantity':'999'}]};
  final scope='$actor:$branch:$warehouse';
  final client=ErpIdentityClient(apiOrigin:'https://erp.example.test',
   httpClient:MockClient((req)async{
    if(req.url.path=='/v1/catalog/branches')return http.Response(
      jsonEncode({'items':[{'id':branch,'name':'Chi nhánh chính'}]}),
      200,headers:headers);
    if(req.url.path=='/v1/catalog/warehouses')return http.Response(
      jsonEncode({'items':[{'id':warehouse,'name':'Kho chính'}]}),
      200,headers:headers);
    if(req.url.path=='/v1/purchasing/orders'&&req.method=='GET')
      return http.Response(jsonEncode({'items':[{'id':order,'documentNo':'PO-001',
        'supplierName':'NCC 1','warehouseId':warehouse,
        'status':'PARTIALLY_RECEIVED','revision':3,
        'lineCount':1}],'hasMore':false}),200,headers:headers);
    if(req.url.path=='/v1/purchasing/orders/$order/receipts'&&req.method=='POST')
      return http.Response(jsonEncode(
        {'error':{'code':'RECEIPT_OVER_ORDERED'}}),409,headers:headers);
    return http.Response('{}',404,headers:headers);
   }));
  addTearDown(client.dispose);
  client.retainPurchase(scope,payload,'purchase-overreceipt-rejected',
    path:'orders/$order/receipts',revision:2);
  tester.view.devicePixelRatio=1;
  tester.view.physicalSize=const Size(1280,850);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final session=IdentitySession(actorId:actor,token:'synthetic-token',
    expiresAt:DateTime.now().add(const Duration(hours:1)),grants:const [
      IdentityGrant(roleId:'read',permission:'purchase.read',branchId:branch),
      IdentityGrant(roleId:'recv',permission:'purchase.receive',
        branchId:branch,warehouseId:warehouse),
      IdentityGrant(roleId:'stock',permission:'inventory.read',
        branchId:branch,warehouseId:warehouse),
    ]);
  await tester.pumpWidget(MaterialApp(theme:erpTheme(touch:false),
    home:Scaffold(body:SingleChildScrollView(
      child:PurchasingWorkspace(client:client,session:session)))));
  for(var i=0;i<5;i++){
    await tester.runAsync(()async=>Future<void>.delayed(const Duration(milliseconds:70)));
    await tester.pumpAndSettle();
  }
  expect(find.text('Xác minh lệnh đang chờ'),findsOneWidget);
  await tester.tap(find.text('Xác minh lệnh đang chờ'));
  await tester.runAsync(()async=>Future<void>.delayed(const Duration(milliseconds:80)));
  await tester.pumpAndSettle();
  expect(client.pendingPurchase(scope),isNull);
  expect(find.text('Xác minh lệnh đang chờ'),findsNothing);
  expect(find.text('Nhận hàng'),findsOneWidget);
  await tester.pump(const Duration(seconds:5));
  await tester.pumpAndSettle();
});

testWidgets('R3.2 warehouse switch during detail load cannot post receipt to wrong scope',
 (tester)async{
  const w2='00000000-0000-4000-8000-000000000077';
  const headers={'content-type':'application/json; charset=utf-8'};
  final delayed=Completer<http.Response>();
  var detailRequests=0,postRequests=0;
  final client=ErpIdentityClient(apiOrigin:'https://erp.example.test',
   httpClient:MockClient((req)async{
    if(req.url.path=='/v1/catalog/branches')return http.Response(jsonEncode({
     'items':[{'id':branch,'name':'Chi nhánh chính'}]}),200,headers:headers);
    if(req.url.path=='/v1/catalog/warehouses')return http.Response(jsonEncode({
     'items':[{'id':warehouse,'name':'Kho chính'},{'id':w2,'name':'Kho phụ'}]}),
     200,headers:headers);
    if(req.url.path=='/v1/purchasing/orders'&&req.method=='GET')return
      http.Response(jsonEncode({'items':[{'id':order,'documentNo':'PO-001',
       'supplierName':'Nhà cung cấp A','warehouseId':warehouse,
       'status':'CONFIRMED','revision':1,'lineCount':1}],'hasMore':false}),
       200,headers:headers);
    if(req.url.path=='/v1/purchasing/orders/$order'&&req.method=='GET'){
      detailRequests++;
      return delayed.future;
    }
    if(req.method=='POST'&&req.url.path.endsWith('/receipts'))postRequests++;
    return http.Response('{}',404,headers:headers);
   }));
  addTearDown(client.dispose);
  tester.view.devicePixelRatio=1;
  tester.view.physicalSize=const Size(1280,850);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final session=IdentitySession(actorId:actor,token:'synthetic-token',
    expiresAt:DateTime.now().add(const Duration(hours:1)),grants:[
      const IdentityGrant(roleId:'read',permission:'purchase.read',branchId:branch),
      const IdentityGrant(roleId:'recv',permission:'purchase.receive',
        branchId:branch,warehouseId:warehouse),
      const IdentityGrant(roleId:'stock',permission:'inventory.read',
        branchId:branch,warehouseId:warehouse),
      const IdentityGrant(roleId:'recv2',permission:'purchase.receive',
        branchId:branch,warehouseId:w2),
      const IdentityGrant(roleId:'stock2',permission:'inventory.read',
        branchId:branch,warehouseId:w2),
    ]);
  await tester.pumpWidget(MaterialApp(theme:erpTheme(touch:false),
    home:Scaffold(body:SingleChildScrollView(
      child:PurchasingWorkspace(client:client,session:session)))));
  for(var i=0;i<5;i++){
    await tester.runAsync(()async=>Future<void>.delayed(const Duration(milliseconds:80)));
    await tester.pumpAndSettle();
  }
  expect(find.text('Nhận hàng'),findsOneWidget);
  await tester.tap(find.text('Nhận hàng'));
  await tester.runAsync(()async=>Future<void>.delayed(const Duration(milliseconds:80)));
  await tester.pumpAndSettle();
  expect(detailRequests,1);
  await tester.tap(find.text('Kho chính'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Kho phụ').last);
  for(var i=0;i<3;i++){
    await tester.runAsync(()async=>Future<void>.delayed(const Duration(milliseconds:80)));
    await tester.pumpAndSettle();
  }
  delayed.complete(http.Response(jsonEncode({'order':{
    'id':order,'revision':1,'lines':[{'lineNo':1,'sku':'SP01',
      'name':'Hàng hóa','orderedBase':'3','receivedBase':'0'}]}}),
    200,headers:headers));
  for(var i=0;i<3;i++){
    await tester.runAsync(()async=>Future<void>.delayed(const Duration(milliseconds:80)));
    await tester.pumpAndSettle();
  }
  expect(find.text('Ghi nhận hàng từ nhà cung cấp'),findsNothing);
  expect(postRequests,0);
  expect(client.pendingPurchase('$actor:$branch:$warehouse'),isNull);
  expect(client.pendingPurchase('$actor:$branch:$w2'),isNull);
});
}
