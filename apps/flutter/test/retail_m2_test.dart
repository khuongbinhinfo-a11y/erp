import 'dart:convert';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:erp_distribution/ui/erp_shell.dart';
import 'package:erp_distribution/ui/erp_tokens.dart';
import 'package:erp_distribution/ui/sales_workspace.dart';
import 'package:erp_distribution/ui/identity_client.dart';

const branch='00000000-0000-4000-8000-000000000001';
const customer='00000000-0000-4000-8000-000000000002';
const sku='00000000-0000-4000-8000-000000000003';
const product='00000000-0000-4000-8000-000000000004';
const priceList='00000000-0000-4000-8000-000000000005';
const warehouse='00000000-0000-4000-8000-000000000009';

void main(){
  test('retail quantity stepping remains exact',(){
    expect(erpRetailStepQuantity('1',1),'2');
    expect(erpRetailStepQuantity('1',-1),'1');
    expect(erpRetailStepQuantity('1.125',1),'2.125');
    expect(erpRetailStepQuantity('2.125',-1),'1.125');
    expect(erpRetailStepQuantity('1,000',1),'1,001');
    expect(erpRetailStepQuantity('0.5',-1),'1');
    expect(erpRetailStepQuantity('999999999',1),isNull);
    expect(erpRetailStepQuantity('1.1234',1),isNull);
    expect(erpRetailStepQuantity('abc',1),isNull);
  });

  testWidgets('POS has independent catalog and quote-driven basket, never confirms distribution order as paid',(tester)async{
    final calls=<String>[];
     var guestPrepares=0;
    final session=IdentitySession(actorId:customer,token:'mock-token',
      expiresAt:DateTime.now().add(const Duration(hours:1)),
      grants:const [
        IdentityGrant(roleId:'create',permission:'orders.create',branchId:branch),
        IdentityGrant(roleId:'read',permission:'orders.read',branchId:branch),
        IdentityGrant(roleId:'catalog',permission:'catalog.read',branchId:branch),
        IdentityGrant(roleId:'stock',permission:'inventory.read',branchId:branch,warehouseId:warehouse),
      ]);
    final client=ErpIdentityClient(apiOrigin:'https://erp.example.test',
      httpClient:MockClient((request)async{
        calls.add(request.method+' '+request.url.path);
        http.Response reply(Map<String,dynamic> value,[int code=200])=>
          http.Response(jsonEncode(value),code,
            headers:{'content-type':'application/json; charset=utf-8'});
        switch(request.url.path){
          case '/v1/catalog/branches':
            return reply({'items':[{'id':branch,'name':'Chi nhánh 1','code':'MAIN'}]});
          case '/v1/catalog/customers':
            return reply({'items':[{'id':customer,'name':'Khách lẻ','code':'WALK','active':true}]});
          case '/v1/catalog/warehouses':
            return reply({'items':[{'id':warehouse,'name':'Kho chính','code':'MAIN'}]});
          case '/v1/catalog/price-lists':
            return reply({'items':[{'id':priceList,'name':'Giá bán lẻ','code':'RETAIL','active':true}]});
          case '/v1/catalog/r1/skus':
            return reply({'items':[{'id':sku,'productId':product,'code':'SKU-01',
              'productName':'Hàng bán lẻ A','unitCode':'cái',
              'barcode':'8931234567890','active':true}]});
          case '/v1/sales/entry-settings':
            return reply({'settings':{'deliveryChoice':'TRIP',
              'walkInCustomer':null}});
          case '/v1/sales/walk-in':
             guestPrepares++;
             expect(request.headers['idempotency-key'],isNotEmpty);
             return reply({'customer':{'id':customer,'code':'WALK','name':'Khách lẻ','active':true}});
           case '/v1/sales/quote':
            final body=jsonDecode(request.body) as Map<String,dynamic>;
            final lines=body['lines'] as List<dynamic>;
            final quantity=(lines.first as Map)['quantity'].toString();
            final total=quantity=='2'?'24000':'12000';
            return reply({'quote':{'lines':[{'sellSkuId':sku,'unitPrice':'12000',
              'lineTotal':total,
              'priceSignature':'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'}],
              'subtotal':total,'discountTotal':'0','taxTotal':'0','grandTotal':total}});
          default:return reply({'error':{'code':'NOT_FOUND'}},404);
        }
      }));
    addTearDown(client.dispose);
    tester.view.devicePixelRatio=1;
    tester.view.physicalSize=const Size(360,760);
    // Android cutout/status bar must not cover the full-screen register controls.
    tester.view.padding=const FakeViewPadding(top:36);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(theme:erpTheme(touch:true,dark:true),
      home:ErpShell(session:session,client:client,previewOnly:false)));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('erp-mobile-retail-workspace')),findsOneWidget);
    expect(find.byKey(const ValueKey('erp-pos-workspace')),findsOneWidget);
    expect(tester.getTopLeft(find.byKey(const ValueKey('pos-fullscreen-back'))).dy,
      greaterThanOrEqualTo(36),reason:'Status bar must not overlap POS back/toolbar');
    expect(find.byKey(const ValueKey('pos-sku-search')),findsOneWidget);
     expect(find.byKey(const ValueKey('pos-walk-in-quick')),findsOneWidget);
     await tester.tap(find.byKey(const ValueKey('pos-walk-in-quick')));
     await tester.pumpAndSettle();
     expect(guestPrepares,1);
     await tester.tap(find.byKey(const ValueKey('pos-walk-in-quick')));
     await tester.pumpAndSettle();
     expect(guestPrepares,1);
    expect(find.byKey(const ValueKey('sales-sku-search')),findsNothing);
    expect(find.byKey(const ValueKey('sales-create')),findsNothing);
    expect(find.byKey(const ValueKey('pos-checkout-disabled')),findsOneWidget);
    expect(tester.widget<FilledButton>(
      find.byKey(const ValueKey('pos-checkout-disabled'))).onPressed,isNull);
    await tester.enterText(find.byKey(const ValueKey('pos-sku-search')),'8931234567890');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump(const Duration(milliseconds:250));
    await tester.pumpAndSettle();
    // A barcode scanner sends Enter; exact barcode must add without a second tap.
    expect(find.byKey(const ValueKey('pos-cart')),findsOneWidget);
    expect(find.byKey(const ValueKey('pos-plus-0')),findsOneWidget);
    expect(find.textContaining('12,000 ₫'),findsWidgets);
    await tester.tap(find.byKey(const ValueKey('pos-plus-0')));
    await tester.pumpAndSettle();
    expect(find.textContaining('24,000 ₫'),findsWidgets);
    expect(calls.where((x)=>x=='POST /v1/sales/quote'),isNotEmpty);
    expect(calls.where((x)=>x.contains('/v1/sales/orders')||
      x.contains('/payment')||x.contains('/issue')||x.contains('/settle')),isEmpty);
    tester.view.physicalSize=const Size(1100,820);
    await tester.pumpAndSettle();
    // Desktop register keeps product grid and quoted cart visible in parallel.
    expect(find.byKey(const ValueKey('pos-products-grid')),findsOneWidget);
    expect(find.byKey(const ValueKey('pos-grid-item-$sku')),findsOneWidget);
    expect(find.byKey(const ValueKey('pos-cart')),findsOneWidget);
    expect(find.byKey(const ValueKey('pos-plus-0')),findsOneWidget);
    expect(find.textContaining('24,000 ₫'),findsWidgets);
    tester.view.physicalSize=const Size(360,760);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('pos-products-grid')),findsNothing);
    expect(find.byKey(const ValueKey('erp-mobile-navigation')),findsNothing);
    expect(find.byKey(const ValueKey('pos-fullscreen-back')),findsOneWidget);
    expect(find.byKey(const ValueKey('pos-cart')),findsOneWidget);
    expect(find.textContaining('24,000 ₫'),findsWidgets);
    // Verify no RenderFlex overflow as the browser/tablet/device width changes.
    for(final width in <double>[390,430,768,1024,1440,360]){
      tester.view.physicalSize=Size(width,820);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('pos-cart')),findsOneWidget);
      expect(tester.takeException(),isNull,reason:'POS width $width');
    }
  });
}
