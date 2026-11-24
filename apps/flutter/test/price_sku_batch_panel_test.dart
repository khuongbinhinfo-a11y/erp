import 'dart:convert';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:erp_distribution/ui/erp_tokens.dart';
import 'package:erp_distribution/ui/identity_client.dart';
import 'package:erp_distribution/ui/price_sku_batch_panel.dart';

const branch='00000000-0000-4000-8000-000000000001';
const list='00000000-0000-4000-8000-000000000002';
const skuA='00000000-0000-4000-8000-000000000003';
const skuB='00000000-0000-4000-8000-000000000004';
const actor='00000000-0000-4000-8000-000000000005';
void main(){
  testWidgets('multi-SKU correction appends distinct BASE rules with idempotency',
    (tester)async{
    final writes=<Map<String,dynamic>>[];
    final keys=<String?>[];
    final client=ErpIdentityClient(apiOrigin:'https://erp.example.test',
      httpClient:MockClient((request)async{
        if(request.url.path=='/v1/catalog/r1/skus'){
          return http.Response(jsonEncode({'items':[
            {'id':skuA,'code':'SKU-A','productName':'Hàng A',
              'unitCode':'CHAI','active':true},
            {'id':skuB,'code':'SKU-B','productName':'Hàng B',
              'unitCode':'THUNG','active':true},
          ]}),200);
        }
        if(request.url.path=='/v1/catalog/r1/resolve'){
          final body=jsonDecode(request.body) as Map<String,dynamic>;
          return http.Response(jsonEncode({'quote':{
            'unitPrice':'9000','basePrice':'10000',
            'trace':[if(body['sellSkuId']==skuA)
              {'scope':'BASE_RULE','priority':27}
              else {'scope':'EXISTING_BASE_PRICE','priority':null}],
          }}),200);
        }
        if(request.url.path=='/v1/catalog/r1/rules'&&request.method=='POST'){
          writes.add(jsonDecode(request.body) as Map<String,dynamic>);
          keys.add(request.headers['idempotency-key']);
          return http.Response(jsonEncode({'id':skuA}),201);
        }
        return http.Response(jsonEncode({'error':{'code':'NOT_FOUND'}}),404);
      }));
    addTearDown(client.dispose);
    tester.view.devicePixelRatio=1;
    tester.view.physicalSize=const Size(1200,900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session=IdentitySession(actorId:actor,token:'local-test-token',
      expiresAt:DateTime.now().add(const Duration(hours:1)),grants:const []);
    await tester.pumpWidget(MaterialApp(theme:erpTheme(touch:false),
      home:Scaffold(body:SingleChildScrollView(
        child:PriceSkuBatchPanel(client:client,session:session,
          branchId:branch,priceList:const {'id':list,'code':'BASE'},
          canWrite:true,onClose:(){})))));
    await tester.pumpAndSettle();
    expect(find.text('Hàng A'),findsOneWidget);
    expect(find.textContaining('Giá cơ sở: 10,000 ₫'),findsWidgets);
    expect(find.textContaining('Giá cơ sở: 9,000 ₫'),findsNothing);
    await tester.tap(find.text('Chọn trang'));
    await tester.pump();
    expect(find.text('Đã chọn 2 SKU'),findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('price-sku-shared')),'25000');
    expect(tester.widget<TextField>(find.byKey(const ValueKey('price-sku-shared'))).controller!.text,'25,000');
    await tester.tap(find.text('Áp cho SKU đã chọn'));
    await tester.pump();
    expect(find.byKey(const ValueKey('price-sku-new-'+skuA)),findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('price-sku-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('price-sku-confirm')));
    await tester.pumpAndSettle();
    expect(writes.length,2);
    expect(writes.map((x)=>x['sellSkuId']).toSet(),{skuA,skuB});
    for(final row in writes){
      expect(row['scopeKind'],'BASE');
      expect(row['priceListId'],list);
      expect(row['adjustment'],'FIXED_PRICE');
      expect(row['amount'],'25000');
      expect(row['priority'],row['sellSkuId']==skuA?27:0);
      expect(row['effectiveFrom'],isNotNull);
    }
    expect(keys.length,2);
    expect(keys.every((x)=>x?.isNotEmpty==true),isTrue);
    expect(keys[0],isNot(keys[1]));
    expect(find.text('Đã chọn 0 SKU'),findsOneWidget);
  });
}
