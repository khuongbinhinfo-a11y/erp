import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:erp_distribution/ui/company_workspace.dart';
import 'package:erp_distribution/ui/erp_tokens.dart';
import 'package:erp_distribution/ui/identity_client.dart';

const branch='00000000-0000-4000-8000-000000000001';
const user='00000000-0000-4000-8000-000000000002';
const customer='00000000-0000-4000-8000-000000000003';
const product='00000000-0000-4000-8000-000000000004';
const sellSku='00000000-0000-4000-8000-000000000007';
const priceList='00000000-0000-4000-8000-000000000005';
const order='00000000-0000-4000-8000-000000000006';
const rights=[
  IdentityGrant(roleId:'a',permission:'orders.read',branchId:branch),
  IdentityGrant(roleId:'b',permission:'orders.create',branchId:branch),
  IdentityGrant(roleId:'c',permission:'catalog.read',branchId:branch),
];
IdentitySession loggedIn()=>IdentitySession(actorId:user,token:'local-test-token',
  expiresAt:DateTime.now().add(const Duration(hours:1)),grants:rights);

void main(){
  testWidgets('Công Ty orders uses authenticated data and plain Vietnamese status', (tester)async{
    var created=false;
    var createRequests=0;
    final observedKeys=<String?>[];
    final observedBodies=<String>[];
    String? postedKey;
    Map<String,dynamic>? posted;
    final calls=<String>[];
    final client=ErpIdentityClient(apiOrigin:'https://erp.example.test',
      httpClient:MockClient((request)async{
        calls.add(request.url.path);
        if(request.url.path=='/v1/catalog/branches'){
          return http.Response(jsonEncode({'items':[
            {'id':branch,'code':'MAIN','name':'Chi nhánh chính'}]}),200);
        }
        if(request.url.path=='/v1/catalog/customers'){
          return http.Response(jsonEncode({'items':[
            {'id':customer,'code':'KH01','name':'Khách hàng A','active':true}]}),200);
        }
        if(request.url.path=='/v1/catalog/products'){
          return http.Response(jsonEncode({'items':[
            {'id':product,'code':'P01','name':'Hàng A','active':true}]}),200);
        }
        if(request.url.path=='/v1/catalog/r1/skus'){
          return http.Response(jsonEncode({'items':[
            {'id':sellSku,'productId':product,'sku':'P01','code':'P01',
             'productName':'Hàng A','unitCode':'cai','active':true}]}),200);
        }
        if(request.url.path=='/v1/catalog/r1/channels'){
          return http.Response(jsonEncode({'items':[]}),200);
        }
        if(request.url.path=='/v1/sales/quote'){
          final req=jsonDecode(request.body) as Map<String,dynamic>;
          expect(req['customerId'],customer);
          expect((req['lines'] as List).single['sellSkuId'],sellSku);
          return http.Response(jsonEncode({'quote':{
            'lines':[{
              'sellSkuId':sellSku,'unitPrice':'12000','lineTotal':'12000',
              'normalizedBaseQuantity':'1.000000','trace':[],
              'priceSignature':'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
            }],
            'subtotal':'12000','discountTotal':'0','taxTotal':'0',
            'grandTotal':'12000',
          }}),200);
        }
        if(request.url.path=='/v1/catalog/price-lists'){
          return http.Response(jsonEncode({'items':[
            {'id':priceList,'code':'SELL','name':'Giá bán','active':true}]}),200);
        }
        if(request.url.path=='/v1/sales/orders'&&request.method=='GET'){
          return http.Response(jsonEncode({'items':created?[
            {'id':order,'documentNo':null,'customerName':'Khách hàng A',
              'total':'12000','status':'DRAFT','versionStatus':'DRAFT','revision':0},
          ]:[]}),200);
        }
        if(request.url.path=='/v1/sales/orders'&&request.method=='POST'){
          postedKey=request.headers['idempotency-key'];
          posted=jsonDecode(request.body) as Map<String,dynamic>;
          createRequests++;
          observedKeys.add(postedKey);
          observedBodies.add(request.body);
          created=true;
          if(createRequests==1)throw http.ClientException('ACK lost after COMMIT');
          if(createRequests==3)return http.Response(jsonEncode({
            'error':{'code':'PRICE_UNAVAILABLE_OR_PRODUCT_INACTIVE'}}),409);
          return http.Response(jsonEncode({
            'id':order,'status':'DRAFT','versionStatus':'DRAFT',
            'revision':0,'total':'12000'}),201);
        }
        return http.Response(jsonEncode({'error':{'code':'NOT_FOUND'}}),404);
      }));
    addTearDown(client.dispose);
    tester.view.devicePixelRatio=1;
    tester.view.physicalSize=const Size(1280,900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(theme:erpTheme(touch:false),
      home:Scaffold(body:CompanyWorkspace(previewOnly:false,
        grants:rights,session:loggedIn(),client:client))));
    await tester.ensureVisible(find.byKey(const ValueKey('company-CompanyGroup.sales')));
    await tester.tap(find.byKey(const ValueKey('company-CompanyGroup.sales')));
    await tester.pumpAndSettle();
    await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds:120)));
    await tester.pumpAndSettle();
    expect(calls,contains('/v1/catalog/branches'));
    expect(calls,contains('/v1/sales/orders'));
    expect(find.text('Chưa có đơn hàng.'),findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('sales-create')));
    await tester.pumpAndSettle();
    await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds:120)));
    await tester.pumpAndSettle();
    expect(find.text('Lập đơn bán hàng'),findsWidgets);
    await tester.enterText(find.byKey(const ValueKey('sales-sku-search')),'P01');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    await tester.runAsync(() async=>
      Future<void>.delayed(const Duration(milliseconds:120)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sales-quote')));
    await tester.pumpAndSettle();
    await tester.runAsync(() async =>
      Future<void>.delayed(const Duration(milliseconds:120)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sales-save')));
    await tester.pumpAndSettle();
    await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds:120)));
    await tester.pumpAndSettle();
    expect(createRequests,1);
    expect(find.text('Kiểm tra đơn vừa lưu'),findsOneWidget);
    // The next tap replays the same JSON and key; it must not open a new form.
    await tester.tap(find.byKey(const ValueKey('sales-create')));
    await tester.pumpAndSettle();
    await tester.runAsync(() async =>
      Future<void>.delayed(const Duration(milliseconds:120)));
    await tester.pumpAndSettle();
    expect(createRequests,2);
    expect(observedKeys[0],isNotNull);
    expect(observedKeys[1],observedKeys[0]);
    expect(observedBodies[1],observedBodies[0]);
    expect(postedKey,isNotNull);
    expect(posted!['branchId'],branch);
    expect((posted!['lines'] as List).single['quantity'],'1');
    expect((posted!['lines'] as List).single['sellSkuId'],sellSku);
    expect(calls,contains('/v1/sales/quote'));
    expect(find.text('Đang lập'),findsOneWidget);

    // A definitive price validation error is not an ambiguous lost ACK.
    // The form must be reopened with a new key rather than retrying forever.
    await tester.tap(find.byKey(const ValueKey('sales-create')));
    await tester.pumpAndSettle();
    await tester.runAsync(() async =>
      Future<void>.delayed(const Duration(milliseconds:120)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('sales-sku-search')),'P01');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    await tester.runAsync(() async=>
      Future<void>.delayed(const Duration(milliseconds:120)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sales-quote')));
    await tester.pumpAndSettle();
    await tester.runAsync(() async =>
      Future<void>.delayed(const Duration(milliseconds:120)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sales-save')));
    await tester.pumpAndSettle();
    await tester.runAsync(() async =>
      Future<void>.delayed(const Duration(milliseconds:120)));
    await tester.pumpAndSettle();
    expect(createRequests,3);
    expect(find.text('Kiểm tra đơn vừa lưu'),findsNothing);
    expect(find.byKey(const ValueKey('sales-create')),findsOneWidget);
    // After definite rejection the user can compose a new order.
    await tester.tap(find.byKey(const ValueKey('sales-create')));
    await tester.pumpAndSettle();
    await tester.runAsync(() async =>
      Future<void>.delayed(const Duration(milliseconds:120)));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sales-save')),findsOneWidget);
    await tester.tap(find.text('Đóng').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('nháp',findRichText:true),findsNothing);
    expect(find.textContaining('DEV',findRichText:true),findsNothing);
    // Allow the upper-right success notification to expire before disposing the test tree.
    await tester.pump(const Duration(seconds:5));
  });
  testWidgets('R2: scan barcode, quote and recover lost confirm ACK without double posting', (tester)async{
    var saved=false,confirmed=false,confirmCount=0,quoteCount=0,skuSearchCount=0;
    var useLongQuotedPrice=false;
    final traces=<String>[];
    http.Response reply(Object data,int status)=>http.Response(jsonEncode(data),status,
      headers:const {'content-type':'application/json; charset=utf-8'});
    final grants=[...rights,
      IdentityGrant(roleId:'confirm',permission:'orders.confirm',branchId:branch)];
    final session=IdentitySession(actorId:user,token:'local-r2-session',
      expiresAt:DateTime.now().add(const Duration(hours:1)),grants:grants);
    final client=ErpIdentityClient(apiOrigin:'https://erp.example.test',
      httpClient:MockClient((request)async{
        final path=request.url.path;
        traces.add(request.method+' '+path);
        if(path=='/v1/auth/config'){
          return reply({'enabled':true},200);
        }
        if(path=='/v1/catalog/branches'){
          return reply({'items':[{'id':branch,'code':'MAIN',
            'name':'Chi nhánh chính'}]},200);
        }
        if(path=='/v1/catalog/customers'){
          return reply({'items':[{'id':customer,'code':'KH01',
            'name':'Khách A','active':true,'deliveryAddress':'Địa chỉ A'}]},200);
        }
        if(path=='/v1/catalog/r1/skus'){
          if(request.url.queryParameters['q']!=null)skuSearchCount++;
          return reply({'items':[{'id':sellSku,
            'productId':product,'code':'SKU-01','productName':'Sản phẩm A',
            'barcode':'BARCODE-A1','unitCode':'thùng','active':true}]},200);
        }
        if(path=='/v1/catalog/price-lists'){
          return reply({'items':[{'id':priceList,
            'code':'SELL','name':'Bảng giá bán','active':true}]},200);
        }
        if(path=='/v1/catalog/r1/channels'){
          return reply({'items':[]},200);
        }
        if(path=='/v1/sales/orders'&&request.method=='GET'){
          return reply({'items':saved?[{
            'id':order,'documentNo':confirmed?'SO-20261121-000001':null,
            'status':confirmed?'CONFIRMED':'DRAFT',
            'versionStatus':confirmed?'CONFIRMED':'DRAFT',
            'customerName':'Khách A','total':'35000',
            'revision':confirmed?1:0,
            'fulfillmentStatus':'NOT_ALLOCATED','deliveryStatus':'NOT_DISPATCHED',
            'paymentStatus':'NOT_DUE',
          }]:[]},200);
        }
        if(path=='/v1/sales/quote'){
          quoteCount++;
          final body=jsonDecode(request.body) as Map<String,dynamic>;
          expect(body['branchId'],branch);
          expect((body['lines'] as List).single['sellSkuId'],sellSku);
          final amount=useLongQuotedPrice?'123456789012345':'35000';
          return reply({'quote':{
            'lines':[{'sellSkuId':sellSku,'unitPrice':amount,'lineTotal':amount,
              'normalizedBaseQuantity':'1.000000',
              'trace':[{'scope':'BASE_RULE'}],
              'priceSignature':'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'}],
            'subtotal':amount,'discountTotal':'0','taxTotal':'0',
            'grandTotal':amount,
          }},200);
        }
        if(path=='/v1/sales/orders'&&request.method=='POST'){
          final body=jsonDecode(request.body) as Map<String,dynamic>;
          expect((body['lines'] as List).single['sellSkuId'],sellSku);
          expect(body.containsKey('_confirmAfterSave'),false);
          saved=true;
          return reply({'id':order,'branchId':branch,
            'status':'DRAFT','revision':0,'total':'35000'},201);
        }
        if(path=='/v1/sales/orders/$order'&&request.method=='GET'){
          return reply({'order':{
            'id':order,'branchId':branch,'revision':confirmed?1:0,
            'versionStatus':confirmed?'CONFIRMED':'DRAFT',
            'status':confirmed?'CONFIRMED':'DRAFT',
            'total':'35000','lines':[],'history':[],
          }},200);
        }
        if(path=='/v1/sales/orders/$order/confirm'){
          confirmCount++;
          expect(request.headers['if-match'],'0');
          confirmed=true;
          throw http.ClientException('Confirmation ACK lost after COMMIT');
        }
        return reply({'error':{'code':'NOT_FOUND'}},404);
      }));
    addTearDown(client.dispose);
    tester.view.devicePixelRatio=1;
    tester.view.physicalSize=const Size(1366,768);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(theme:erpTheme(touch:false),
      home:Scaffold(body:CompanyWorkspace(previewOnly:false,
        grants:grants,session:session,client:client))));
    await tester.ensureVisible(find.byKey(const ValueKey('company-CompanyGroup.sales')));
    await tester.tap(find.byKey(const ValueKey('company-CompanyGroup.sales')));
    await tester.pumpAndSettle();
    await tester.runAsync(() async=>Future<void>.delayed(const Duration(milliseconds:120)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sales-create')));
    await tester.pumpAndSettle();
    await tester.runAsync(() async=>
      Future<void>.delayed(const Duration(milliseconds:120)));
    await tester.pumpAndSettle();
    expect(tester.takeException(),isNull,reason:'Composer render error: $traces');
    expect(find.byKey(const ValueKey('sales-sku-search')),findsOneWidget,
      reason:'Actual calls: $traces; visible text: ${tester.widgetList<Text>(find.byType(Text)).map((t)=>t.data).take(30).toList()}');
    expect(find.byKey(const ValueKey('sales-save-confirm')),findsOneWidget);
    // Fast-sale shortcuts navigate without closing the composer.
    await tester.sendKeyEvent(LogicalKeyboardKey.f3);
    await tester.pump();
    expect(tester.widget<TextField>(find.byKey(const ValueKey('sales-sku-search')))
      .focusNode?.hasFocus,isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.f4);
    await tester.pump();
    expect(tester.widget<TextField>(find.byKey(const ValueKey('sales-customer-search')))
      .focusNode?.hasFocus,isTrue);
    await tester.enterText(find.byKey(const ValueKey('sales-sku-search')),'BARCODE-A1');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    await tester.runAsync(() async=>Future<void>.delayed(const Duration(milliseconds:120)));
    await tester.pumpAndSettle();
    expect(skuSearchCount,greaterThanOrEqualTo(1));
    expect(find.byKey(const ValueKey('sales-line-0')),findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('sales-qty-0')))
      .focusNode?.hasFocus,isTrue,reason:'Selecting a SKU must focus its quantity');
    // Escape cannot silently discard a composed sale.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Bỏ thay đổi đơn hàng?'),findsOneWidget);
    await tester.tap(find.text('Tiếp tục nhập'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sales-line-0')),findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('sales-quote')));
    await tester.pumpAndSettle();
    await tester.runAsync(() async=>Future<void>.delayed(const Duration(milliseconds:120)));
    await tester.pumpAndSettle();
    expect(quoteCount,1);
    expect(find.textContaining('35.000 ₫'),findsWidgets);
    // Large server amounts and a carton unit must fit a 320px viewport.
    useLongQuotedPrice=true;
    await tester.tap(find.byKey(const ValueKey('sales-quote')));
    await tester.pumpAndSettle();
    await tester.runAsync(() async=>
      Future<void>.delayed(const Duration(milliseconds:120)));
    await tester.pumpAndSettle();
    expect(quoteCount,2);
    for(final viewport in const [Size(1440,900),Size(1280,800),
      Size(390,844),Size(360,740),Size(320,700)]){
      tester.view.physicalSize=viewport;
      await tester.pumpAndSettle();
      expect(tester.takeException(),isNull,
        reason:'R2 order workspace must remain usable at $viewport');
      expect(find.byKey(const ValueKey('sales-quote')),findsOneWidget);
      expect(find.byKey(const ValueKey('sales-save-confirm')),findsOneWidget);
      expect(find.byKey(const ValueKey('sales-line-0')),findsOneWidget);
    }
    tester.view.physicalSize=const Size(1366,768);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sales-save-confirm')));
    await tester.pumpAndSettle();
    await tester.runAsync(() async=>Future<void>.delayed(const Duration(milliseconds:150)));
    await tester.pumpAndSettle();
    expect(confirmCount,1);
    expect(find.text('Kiểm tra xác nhận'),findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('sales-create')));
    await tester.pumpAndSettle();
    await tester.runAsync(() async=>Future<void>.delayed(const Duration(milliseconds:120)));
    await tester.pumpAndSettle();
    expect(confirmCount,1,reason:'Read-before-retry must not confirm a second time');
    expect(find.text('Kiểm tra xác nhận'),findsNothing);
    await tester.pump(const Duration(seconds:5));
  });

}
