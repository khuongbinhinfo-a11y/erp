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
const list='00000000-0000-4000-8000-000000000005';
const warehouse='00000000-0000-4000-8000-000000000009';

void main(){
  test('mobile quantity step never uses floating point or creates zero',(){
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

  testWidgets('Android-sized retail opens the canonical cart with server price, pickup and safe CTA',(tester)async{
    final calls=<String>[];
    final session=IdentitySession(actorId:customer,token:'session-not-secret',
      expiresAt:DateTime.now().add(const Duration(hours:1)),
      grants:const [
        IdentityGrant(roleId:'create',permission:'orders.create',branchId:branch),
        IdentityGrant(roleId:'read',permission:'orders.read',branchId:branch),
        IdentityGrant(roleId:'confirm',permission:'orders.confirm',branchId:branch),
        IdentityGrant(roleId:'catalog',permission:'catalog.read',branchId:branch),
        IdentityGrant(roleId:'stock',permission:'inventory.read',branchId:branch,warehouseId:warehouse),
      ]);
    final client=ErpIdentityClient(apiOrigin:'https://erp.example.test',
      httpClient:MockClient((request)async{
        final path=request.url.path;
        calls.add(path);
        http.Response reply(Map<String,dynamic> obj,[int code=200])=>
          http.Response(jsonEncode(obj),code,headers:{'content-type':'application/json; charset=utf-8'});
        switch(path){
          case '/v1/catalog/branches':
            return reply({'items':[{'id':branch,'name':'Chi nhánh 1','code':'MAIN'}]});
          case '/v1/catalog/customers':
            return reply({'items':[{'id':customer,'name':'Khách lẻ','code':'WALK','active':true}]});
          case '/v1/catalog/r1/skus':
            return reply({'items':[{'id':sku,'productId':product,'code':'SKU-01',
              'sku':'SKU-01','productName':'Hàng bán lẻ A','unitCode':'cái',
              'barcode':'8931234567890','active':true}]});
          case '/v1/catalog/price-lists':
            return reply({'items':[{'id':list,'name':'Giá bán lẻ','code':'RETAIL','active':true}]});
          case '/v1/catalog/r1/channels':
            return reply({'items':[]});
          case '/v1/catalog/warehouses':
            return reply({'items':[{'id':warehouse,'name':'Kho chính','code':'MAIN'}]});
          case '/v1/inventory/balances':
            return reply({'items':[{'productId':product,'available':'50','baseUnit':'cái'}]});
          case '/v1/sales/entry-settings':
            return reply({'settings':{'deliveryChoice':'TRIP',
              'walkInCustomer':{'id':customer,'code':'WALK','name':'Khách lẻ','active':true}}});
          case '/v1/sales/orders':
            return reply({'items':[]});
          case '/v1/sales/quote':
            final body=jsonDecode(request.body) as Map<String,dynamic>;
            final lines=body['lines'] as List<dynamic>;
            final amount=(lines.first as Map)['quantity'].toString()=='2'?'24000':'12000';
            return reply({'quote':{'lines':[{'sellSkuId':sku,'unitPrice':'12000',
              'lineTotal':amount,'priceSignature':'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'}],
              'subtotal':amount,'discountTotal':'0','taxTotal':'0','grandTotal':amount}});
          default: return reply({'error':{'code':'NOT_FOUND'}},404);
        }
      }));
    addTearDown(client.dispose);
    tester.view.devicePixelRatio=1;
    tester.view.physicalSize=const Size(360,760);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(theme:erpTheme(touch:true,dark:true),
      home:ErpShell(session:session,client:client,previewOnly:false)));
    await tester.pumpAndSettle();
    await tester.runAsync(()async=>Future<void>.delayed(const Duration(milliseconds:150)));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('erp-mobile-retail-workspace')),findsOneWidget);
    expect(find.byKey(const ValueKey('sales-sku-search')),findsOneWidget,
      reason:'Retail must open real order entry, not a placeholder. Calls: $calls');
    expect(find.byKey(const ValueKey('sales-retail-submit')),findsOneWidget);
    expect(find.byKey(const ValueKey('sales-retail-more-settings')),findsOneWidget);
    expect(find.byKey(const ValueKey('sales-delivery-TRIP')),findsNothing);
    expect(find.byKey(const ValueKey('sales-retail-unsettled-notice')),findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('sales-sku-search')));
    await tester.enterText(find.byKey(const ValueKey('sales-sku-search')),'8931234567890');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump(const Duration(milliseconds:350));
    await tester.runAsync(()async=>Future<void>.delayed(const Duration(milliseconds:150)));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sales-retail-plus-0')),findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('sales-retail-plus-0')));
    await tester.pump(const Duration(milliseconds:350));
    await tester.runAsync(()async=>Future<void>.delayed(const Duration(milliseconds:160)));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byKey(const ValueKey('sales-qty-0'))).controller?.text,'2');
    expect(find.textContaining('24,000 ₫'),findsWidgets);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('sales-retail-submit'))).onPressed,isNotNull);
    expect(calls.where((x)=>x=='/v1/sales/orders').isNotEmpty,isTrue);
    // A price preview or cart gesture never posts stock or records payment.
    expect(calls.where((x)=>x.contains('/issue')||x.contains('/payment')||x.contains('/settle')),isEmpty);
    // Changing between handset and desktop must retain the same mounted
    // SalesWorkspace, its editable cart and its pending command state.
    tester.view.physicalSize=const Size(1100,820);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sales-sku-search')),findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('sales-qty-0'))).controller?.text,'2');
    tester.view.physicalSize=const Size(360,760);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sales-retail-submit')),findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('sales-qty-0'))).controller?.text,'2');
    expect(tester.takeException(),isNull);
  });
}
