import 'dart:async';
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
         {'id':branch,'name':'Chi nhánh chính'}]}),200,headers:const {'content-type':'application/json; charset=utf-8'});
       if(req.url.path=='/v1/catalog/warehouses')return http.Response(jsonEncode({'items':[
         {'id':warehouse,'name':'Kho chính','branchId':branch}]}),200,headers:const {'content-type':'application/json; charset=utf-8'});
       if(req.url.path=='/v1/catalog/products'){
         final q=req.url.queryParameters['q'];
         return http.Response(jsonEncode({'items':[q=='SP101'
           ?{'id':'00000000-0000-4000-8000-000000000101','code':'SP101',
             'name':'Sản phẩm ngoài trang đầu','active':true}
           :{'id':product,'code':'SP01','name':'Hàng kiểm thử','active':true}]}),
           200,headers:const {'content-type':'application/json; charset=utf-8'});
       }
       if(req.url.path=='/v1/sales/orders'&&req.method=='GET'){
         final q=req.url.queryParameters['q'];
         return http.Response(jsonEncode({'items':q=='SO-OLD'?[
           {'id':'00000000-0000-4000-8000-000000000102','documentNo':'SO-OLD',
             'customerName':'Khách A','status':'CONFIRMED','versionStatus':'CONFIRMED'}
         ]:[]}),200,headers:const {'content-type':'application/json; charset=utf-8'});
       }
       if(req.url.path=='/v1/inventory/balances')return http.Response(jsonEncode({'items':onHand?[
         {'productId':product,'sku':'SP01','name':'Hàng kiểm thử',
          'onHand':'5.000000','reserved':'0.000000','available':'5.000000'}
       ]:[]}),200,headers:const {'content-type':'application/json; charset=utf-8'});
       if(req.url.path=='/v1/inventory/movements')return http.Response(jsonEncode({'items':[]}),200,headers:const {'content-type':'application/json; charset=utf-8'});
       if(req.url.path=='/v1/inventory/reservations')return http.Response(jsonEncode({'items':[]}),200,headers:const {'content-type':'application/json; charset=utf-8'});
       if(req.url.path=='/v1/inventory/openings'){
         attempts++;keys.add(req.headers['idempotency-key']);bodies.add(req.body);
         final obj=jsonDecode(req.body) as Map<String,dynamic>;
         expect(obj['quantity'],'5');expect(obj['warehouseId'],warehouse);
         if(attempts==1)throw http.ClientException('response lost after commit');
         onHand=true;
         return http.Response(jsonEncode({'id':'id',
          'kind':'OPENING','deltaBase':'5.000000'}),201,headers:const {'content-type':'application/json; charset=utf-8'});
       }
       return http.Response(jsonEncode({'error':{'code':'NOT_FOUND'}}),404,headers:const {'content-type':'application/json; charset=utf-8'});
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
       const IdentityGrant(roleId:'c',permission:'inventory.reserve',
          branchId:branch,warehouseId:warehouse),
     ]);
   // Verify that the same mock transport returns canonical inventory data before mounting.
   final direct=await client.inventoryItems(session.token,'balances',
     branchId:branch,warehouseId:warehouse);
   expect(direct.single['available'],'5.000000');
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
   // Product beyond catalog's first 100 can be located by server-side SKU search.
   await tester.tap(find.text('Tồn đầu kỳ'));
   for(var i=0;i<3;i++){
     await tester.runAsync(()async=>Future<void>.delayed(const Duration(milliseconds:80)));
     await tester.pumpAndSettle();
   }
   expect(find.text('Ghi tồn đầu kỳ'),findsOneWidget);
   await tester.enterText(find.byKey(const ValueKey('inventory-product-search')),'SP101');
   await tester.tap(find.byTooltip('Tìm sản phẩm'));
   for(var i=0;i<3;i++){
     await tester.runAsync(()async=>Future<void>.delayed(const Duration(milliseconds:80)));
     await tester.pumpAndSettle();
   }
   expect(find.text('SP101 · Sản phẩm ngoài trang đầu'),findsOneWidget);
   await tester.tap(find.descendant(of:find.byType(AlertDialog),
      matching:find.text('Đóng')));
   await tester.pumpAndSettle();
   // Confirmed order outside the initial capped listing is still reservable by number.
   await tester.tap(find.text('Giữ hàng'));
   for(var i=0;i<3;i++){
     await tester.runAsync(()async=>Future<void>.delayed(const Duration(milliseconds:80)));
     await tester.pumpAndSettle();
   }
   expect(find.text('Không có đơn phù hợp. Nhập số đơn để tìm thêm.'),findsOneWidget);
   await tester.enterText(find.byKey(const ValueKey('inventory-order-search')),'SO-OLD');
   await tester.tap(find.byTooltip('Tìm đơn bán'));
   for(var i=0;i<3;i++){
     await tester.runAsync(()async=>Future<void>.delayed(const Duration(milliseconds:80)));
     await tester.pumpAndSettle();
   }
   expect(find.text('SO-OLD · Khách A'),findsOneWidget);
   await tester.tap(find.descendant(of:find.byType(AlertDialog),
      matching:find.text('Đóng')));
   await tester.pumpAndSettle();
 });
testWidgets('R3 paginates 101 ACTIVE holds separately from release history',
 (tester)async{
  const branch='00000000-0000-4000-8000-000000000001';
  const warehouse='00000000-0000-4000-8000-000000000002';
  const actor='00000000-0000-4000-8000-000000000003';
  final requests=<String>[];
  Completer<http.Response>? staleSecondPage;
  var delayNextPage=true;
  final client=ErpIdentityClient(apiOrigin:'https://erp.example.test',
    httpClient:MockClient((req)async{
      requests.add(req.url.toString());
      const headers={'content-type':'application/json; charset=utf-8'};
      if(req.url.path=='/v1/catalog/branches'){
        return http.Response(jsonEncode({'items':[{'id':branch,'name':'Chi nhánh chính'}]}),
          200,headers:headers);
      }
      if(req.url.path=='/v1/catalog/warehouses'){
        return http.Response(jsonEncode({'items':[{'id':warehouse,'name':'Kho chính'}]}),
          200,headers:headers);
      }
      if(req.url.path=='/v1/inventory/balances'){
        return http.Response(jsonEncode({'items':[]}),200,headers:headers);
      }
      if(req.url.path=='/v1/inventory/reservations'){
        final state=req.url.queryParameters['state'];
        final offset=req.url.queryParameters['offset'];
        if(state=='RELEASED'){
          return http.Response(jsonEncode({'items':[{'id':'history1',
            'documentNo':'SO-HISTORY','sku':'SP01','quantityBase':'1',
            'state':'RELEASED'}],'hasMore':false}),200,headers:headers);
        }
        final items=offset=='100'
          ?[{'id':'active100','documentNo':'SO-100',
              'sku':'SP01','quantityBase':'1','state':'ACTIVE'}]
          :List.generate(100,(i)=>{'id':'active$i','documentNo':'SO-$i',
              'sku':'SP01','quantityBase':'1','state':'ACTIVE'});
        final response=http.Response(
          jsonEncode({'items':items,'hasMore':offset!='100'}),200,headers:headers);
        if(offset=='100'&&delayNextPage){
          delayNextPage=false;
          staleSecondPage=Completer<http.Response>();
          return staleSecondPage!.future;
        }
        return response;
      }
      return http.Response(jsonEncode({'error':{'code':'NOT_FOUND'}}),404,headers:headers);
    }));
  addTearDown(client.dispose);
  tester.view.devicePixelRatio=1;
  tester.view.physicalSize=const Size(1280,900);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final session=IdentitySession(actorId:actor,token:'synthetic-token',
    expiresAt:DateTime.now().add(const Duration(hours:1)),grants:const [
      IdentityGrant(roleId:'a',permission:'inventory.read',
        branchId:branch,warehouseId:warehouse),
    ]);
  await tester.pumpWidget(MaterialApp(theme:erpTheme(touch:false),
    home:Scaffold(body:SingleChildScrollView(
      child:InventoryWorkspace(client:client,session:session)))));
  for(var i=0;i<5;i++){
    await tester.runAsync(()async=>Future<void>.delayed(const Duration(milliseconds:80)));
    await tester.pumpAndSettle();
  }
  await tester.tap(find.text('Hàng đã giữ'));
  for(var i=0;i<4;i++){
    await tester.runAsync(()async=>Future<void>.delayed(const Duration(milliseconds:80)));
    await tester.pumpAndSettle();
  }
  expect(find.text('SO-99 · SP01'),findsOneWidget);
  expect(find.text('SO-100 · SP01'),findsNothing);
  final load=find.text('Tải thêm phiếu giữ hàng');
  await tester.ensureVisible(load);
  await tester.tap(load);
  await tester.runAsync(()async=>Future<void>.delayed(const Duration(milliseconds:80)));
  await tester.pump();
  expect(staleSecondPage,isNotNull);
  // Refresh invalidates the older page request. Its late ACK must not lock load-more.
  final refresh=find.byTooltip('Tải lại dữ liệu kho');
  await tester.ensureVisible(refresh);
  await tester.tap(refresh);
  for(var i=0;i<3;i++){
    await tester.runAsync(()async=>Future<void>.delayed(const Duration(milliseconds:80)));
    await tester.pumpAndSettle();
  }
  expect(tester.widget<TextButton>(
    find.widgetWithText(TextButton,'Tải thêm phiếu giữ hàng')).onPressed,isNotNull);
  staleSecondPage!.complete(http.Response(
    jsonEncode({'items':[{'id':'stale','documentNo':'SO-STALE',
      'sku':'SP01','quantityBase':'1','state':'ACTIVE'}],'hasMore':false}),
    200,headers:const {'content-type':'application/json; charset=utf-8'}));
  await tester.runAsync(()async=>Future<void>.delayed(const Duration(milliseconds:80)));
  await tester.pumpAndSettle();
  expect(find.text('SO-STALE · SP01'),findsNothing);
  await tester.ensureVisible(load);
  await tester.tap(load);
  for(var i=0;i<4;i++){
    await tester.runAsync(()async=>Future<void>.delayed(const Duration(milliseconds:80)));
    await tester.pumpAndSettle();
  }
  expect(find.text('SO-100 · SP01'),findsOneWidget);
  expect(find.text('Tải thêm phiếu giữ hàng'),findsNothing);
  expect(requests.any((x)=>x.contains('offset=100')),true);
  final history=find.text('Xem lịch sử đã giải phóng');
  await tester.ensureVisible(history);
  await tester.tap(history);
  for(var i=0;i<4;i++){
    await tester.runAsync(()async=>Future<void>.delayed(const Duration(milliseconds:80)));
    await tester.pumpAndSettle();
  }
  expect(find.text('SO-HISTORY · SP01'),findsOneWidget);
  expect(find.text('SO-100 · SP01'),findsNothing);
});


testWidgets('R3 rejects conflicting stock opening without locking the warehouse', (tester) async {
  const headers={'content-type':'application/json; charset=utf-8'};
  final pending=<String,dynamic>{'branchId':branch,'warehouseId':warehouse,
    'productId':product,'quantity':'5'};
  final client=ErpIdentityClient(apiOrigin:'https://erp.example.test',
    httpClient:MockClient((req) async {
      if(req.url.path=='/v1/catalog/branches')return http.Response(
        jsonEncode({'items':[{'id':branch,'name':'Chi nhánh chính'}]}),
        200,headers:headers);
      if(req.url.path=='/v1/catalog/warehouses')return http.Response(
        jsonEncode({'items':[{'id':warehouse,'name':'Kho chính'}]}),
        200,headers:headers);
      if(req.url.path=='/v1/inventory/balances')return http.Response(
        jsonEncode({'items':[]}),200,headers:headers);
      if(req.url.path=='/v1/inventory/openings')return http.Response(
        jsonEncode({'error':{'code':'OPENING_ALREADY_EXISTS'}}),
        409,headers:headers);
      return http.Response('{}',404,headers:headers);
    }));
  addTearDown(client.dispose);
  tester.view.devicePixelRatio=1;
  tester.view.physicalSize=const Size(1280,850);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final scope='$actor:$branch:$warehouse';
  client.retainInventory(scope,pending,'stock-definite-conflict',
    action:'openings',revision:0);
  final session=IdentitySession(actorId:actor,token:'synthetic-token',
    expiresAt:DateTime.now().add(const Duration(hours:1)),grants:const [
      IdentityGrant(roleId:'read',permission:'inventory.read',
        branchId:branch,warehouseId:warehouse),
      IdentityGrant(roleId:'post',permission:'inventory.post',
        branchId:branch,warehouseId:warehouse),
    ]);
  await tester.pumpWidget(MaterialApp(theme:erpTheme(touch:false),
    home:Scaffold(body:SingleChildScrollView(
      child:InventoryWorkspace(client:client,session:session)))));
  for(var i=0;i<5;i++){
    await tester.runAsync(()async=>Future<void>.delayed(const Duration(milliseconds:60)));
    await tester.pumpAndSettle();
  }
  expect(find.text('Xác minh lệnh kho đang chờ'),findsOneWidget);
  await tester.tap(find.text('Xác minh lệnh kho đang chờ'));
  await tester.runAsync(()async=>Future<void>.delayed(const Duration(milliseconds:80)));
  await tester.pumpAndSettle();
  expect(client.pendingInventory(scope),isNull);
  expect(find.text('Xác minh lệnh kho đang chờ'),findsNothing);
  expect(tester.widget<OutlinedButton>(
    find.widgetWithText(OutlinedButton,'Tồn đầu kỳ')).onPressed,isNotNull);
  await tester.pump(const Duration(seconds:5));
  await tester.pumpAndSettle();
});

testWidgets('R3 stock opening ignores stale product lookup after warehouse switch',
 (tester)async{
  const w2='00000000-0000-4000-8000-000000000099';
  const headers={'content-type':'application/json; charset=utf-8'};
  final delayed=Completer<http.Response>();
  var catalogCalls=0;
  final client=ErpIdentityClient(apiOrigin:'https://erp.example.test',
   httpClient:MockClient((req)async{
    if(req.url.path=='/v1/catalog/branches')return http.Response(
      jsonEncode({'items':[{'id':branch,'name':'Chi nhánh chính'}]}),
      200,headers:headers);
    if(req.url.path=='/v1/catalog/warehouses')return http.Response(
      jsonEncode({'items':[{'id':warehouse,'name':'Kho chính'},
        {'id':w2,'name':'Kho phụ'}]}),200,headers:headers);
    if(req.url.path=='/v1/inventory/balances')return http.Response(
      jsonEncode({'items':[]}),200,headers:headers);
    if(req.url.path=='/v1/catalog/products'){
      catalogCalls++;
      return delayed.future;
    }
    return http.Response('{}',404,headers:headers);
   }));
  addTearDown(client.dispose);
  tester.view.devicePixelRatio=1;
  tester.view.physicalSize=const Size(1280,850);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final session=IdentitySession(actorId:actor,token:'synthetic-token',
    expiresAt:DateTime.now().add(const Duration(hours:1)),grants:const [
      IdentityGrant(roleId:'stock',permission:'inventory.read',
        branchId:branch,warehouseId:warehouse),
      IdentityGrant(roleId:'post',permission:'inventory.post',
        branchId:branch,warehouseId:warehouse),
      IdentityGrant(roleId:'stock2',permission:'inventory.read',
        branchId:branch,warehouseId:w2),
      IdentityGrant(roleId:'post2',permission:'inventory.post',
        branchId:branch,warehouseId:w2),
    ]);
  await tester.pumpWidget(MaterialApp(theme:erpTheme(touch:false),
    home:Scaffold(body:SingleChildScrollView(
      child:InventoryWorkspace(client:client,session:session)))));
  for(var i=0;i<4;i++){
    await tester.runAsync(()async=>Future<void>.delayed(const Duration(milliseconds:80)));
    await tester.pumpAndSettle();
  }
  await tester.tap(find.text('Tồn đầu kỳ'));
  await tester.runAsync(()async=>Future<void>.delayed(const Duration(milliseconds:80)));
  await tester.pumpAndSettle();
  expect(catalogCalls,1);
  await tester.tap(find.text('Kho chính'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Kho phụ').last);
  for(var i=0;i<3;i++){
    await tester.runAsync(()async=>Future<void>.delayed(const Duration(milliseconds:80)));
    await tester.pumpAndSettle();
  }
  delayed.complete(http.Response(jsonEncode({'items':[{
    'id':product,'code':'SP01','name':'Hàng hóa','active':true}]}),
    200,headers:headers));
  for(var i=0;i<3;i++){
    await tester.runAsync(()async=>Future<void>.delayed(const Duration(milliseconds:80)));
    await tester.pumpAndSettle();
  }
  expect(find.text('Ghi tồn đầu kỳ'),findsNothing);
  expect(client.pendingInventory('$actor:$branch:$warehouse'),isNull);
  expect(client.pendingInventory('$actor:$branch:$w2'),isNull);
});
}
