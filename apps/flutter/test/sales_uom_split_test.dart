import 'dart:async';
import 'dart:convert';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:erp_distribution/ui/identity_client.dart';
import 'package:erp_distribution/ui/sales_workspace.dart';
import 'package:erp_distribution/ui/erp_tokens.dart';

void main(){
  const branch='00000000-0000-4000-8000-000000000001';
  const user='00000000-0000-4000-8000-000000000002';
  const customer='00000000-0000-4000-8000-000000000003';
  const product='00000000-0000-4000-8000-000000000004';
  const list='00000000-0000-4000-8000-000000000005';
  const base='00000000-0000-4000-8000-000000000006';
  const carton='00000000-0000-4000-8000-000000000007';

  for(final canUpdate in const [true,false]){
  testWidgets(canUpdate
    ?'T1 split resets override and discards stale purchase price'
    :'T1 create-only actor splits same SKU without changing original quantity', (tester)async{
    final quotedSkuPairs=<List<String>>[];
    final pendingLastPurchase=Completer<http.Response>();
    final rights=[
      IdentityGrant(roleId:'a',permission:'orders.read',branchId:branch),
      IdentityGrant(roleId:'b',permission:'orders.create',branchId:branch),
      if(canUpdate)IdentityGrant(roleId:'c',permission:'orders.update',branchId:branch),
      IdentityGrant(roleId:'d',permission:'catalog.read',branchId:branch),
    ];
    http.Response reply(Object data,int status)=>http.Response(jsonEncode(data),status,
      headers:const {'content-type':'application/json'});
    final client=ErpIdentityClient(apiOrigin:'https://erp.example.test',
      httpClient:MockClient((req)async{
        final path=req.url.path;
        if(path=='/v1/catalog/branches')return reply({'items':[
          {'id':branch,'code':'MAIN','name':'Chi nhánh chính'}]},200);
        if(path=='/v1/catalog/customers')return reply({'items':[
          {'id':customer,'code':'KH','name':'Khách A','active':true}]},200);
        if(path=='/v1/catalog/r1/skus'){
          final baseRow={'id':base,'productId':product,'code':'SKU-BASE',
            'productName':'Sản phẩm A','unitCode':'cái','active':true};
          final cartonRow={'id':carton,'productId':product,'code':'SKU-CARTON',
            'productName':'Sản phẩm A','unitCode':'thùng','active':true};
          if(req.url.queryParameters.containsKey('productId')){
            expect(req.url.queryParameters['productId'],product);
            return reply({'items':[baseRow,cartonRow]},200);
          }
          if(req.url.queryParameters.containsKey('q')){
            return reply({'items':[baseRow]},200);
          }
          return reply({'items':[baseRow,cartonRow]},200);
        }
        if(path=='/v1/catalog/price-lists')return reply({'items':[
          {'id':list,'code':'SELL','name':'Giá bán','active':true}]},200);
        if(path=='/v1/catalog/r1/channels')return reply({'items':[]},200);
        if(path=='/v1/sales/orders'&&req.method=='GET')return reply({'items':[]},200);
        if(path=='/v1/sales/last-purchase'){
          expect(req.url.queryParameters['sellSkuId'],base);
          return pendingLastPurchase.future;
        }
        if(path=='/v1/catalog/r1/resolve'){
          final body=jsonDecode(req.body) as Map<String,dynamic>;
          return reply({'quote':{'unitPrice':body['sellSkuId']==base?'9800':'90000',
            'priceSignature':'signature'}},200);
        }
        if(path=='/v1/sales/quote'){
          final body=jsonDecode(req.body) as Map<String,dynamic>;
          final lines=(body['lines'] as List<dynamic>)
            .map((v)=>Map<String,dynamic>.from(v as Map)).toList();
          quotedSkuPairs.add(lines.map((v)=>v['sellSkuId'].toString()).toList());
          final prices=[for(final line in lines)
            line['sellSkuId']==base?'9800':'90000'];
          final quoted=[for(var i=0;i<lines.length;i++){
            'sellSkuId':lines[i]['sellSkuId'],
            'unitPrice':prices[i], 'lineTotal':prices[i],
            'priceSignature':'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd',
          }];
          return reply({'quote':{'lines':quoted,'subtotal':'9800',
            'discountTotal':'0','taxTotal':'0','grandTotal':'9800'}},200);
        }
        return reply({'error':{'code':'NOT_FOUND'}},404);
      }));
    addTearDown(client.dispose);
    tester.view.devicePixelRatio=1;
    tester.view.physicalSize=const Size(1440,900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session=IdentitySession(actorId:user,token:'test-token',
      expiresAt:DateTime.now().add(const Duration(hours:1)),grants:rights);
    await tester.pumpWidget(MaterialApp(theme:erpTheme(touch:false),
      home:Scaffold(body:SalesWorkspace(session:session,client:client))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sales-create')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('sales-sku-search')),'SKU-BASE');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    await tester.runAsync(()async=>Future<void>.delayed(const Duration(milliseconds:150)));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sales-line-0')),findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('sales-qty-0')),'3');
    if(canUpdate){
      await tester.enterText(find.byKey(const ValueKey('sales-price-0')),'9800');
      await tester.enterText(find.byKey(const ValueKey('sales-discount-0')),'5');
    }
    await tester.ensureVisible(find.byKey(const ValueKey('sales-split-0')));
    await tester.tap(find.byKey(const ValueKey('sales-split-0')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byKey(const ValueKey('sales-qty-0')))
      .controller!.text,'3');
    expect(tester.widget<TextField>(find.byKey(const ValueKey('sales-qty-1')))
      .controller!.text,'1');
    expect(tester.widget<TextField>(find.byKey(const ValueKey('sales-price-1')))
      .controller!.text,isEmpty);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('sales-discount-1')))
      .controller!.text,'0');
    expect(find.byKey(const ValueKey('sales-unit-1-$base')),findsOneWidget);
    await tester.runAsync(()async=>Future<void>.delayed(const Duration(milliseconds:150)));
    await tester.pumpAndSettle();
    // Simulate a slow previous-purchase response for the old per-piece SKU.
    if(canUpdate){
      await tester.ensureVisible(find.byKey(const ValueKey('sales-last-price-1')));
      await tester.tap(find.byKey(const ValueKey('sales-last-price-1')));
      await tester.pump();
    }
    await tester.ensureVisible(find.byKey(const ValueKey('sales-unit-1-$base')));
    await tester.tap(find.byKey(const ValueKey('sales-unit-1-$base')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('thùng').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sales-unit-1-$carton')),findsOneWidget);
    if(canUpdate)pendingLastPurchase.complete(reply({'price':{
      'unitPrice':'1','discountRate':'20','taxRate':'5',
    }},200));
    await tester.runAsync(()async=>Future<void>.delayed(const Duration(milliseconds:50)));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byKey(const ValueKey('sales-price-1')))
      .controller!.text,isEmpty,reason:'Old UOM price must never override carton price');
    expect(tester.widget<TextField>(find.byKey(const ValueKey('sales-discount-1')))
      .controller!.text,'0');
    await tester.pump(const Duration(milliseconds:400));
    await tester.runAsync(()async=>Future<void>.delayed(const Duration(milliseconds:150)));
    await tester.pumpAndSettle();
    expect(quotedSkuPairs.any((pair)=>pair.length==2&&pair[0]==base&&pair[1]==carton),isTrue,
      reason:'Changing UOM must requote exact target SKU, not multiply client prices');
  });  }
}
