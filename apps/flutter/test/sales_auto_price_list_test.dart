import 'dart:convert';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:erp_distribution/ui/company_workspace.dart';
import 'package:erp_distribution/ui/erp_tokens.dart';
import 'package:erp_distribution/ui/identity_client.dart';

const branch='00000000-0000-4000-8000-000000000001';
const customer='00000000-0000-4000-8000-000000000002';
const sku='00000000-0000-4000-8000-000000000003';
const product='00000000-0000-4000-8000-000000000004';
const listA='00000000-0000-4000-8000-000000000005';
const listB='00000000-0000-4000-8000-000000000006';

void main(){
  testWidgets('new orders automatically resolve assigned customer list and price',
    (tester)async{
    final selectedLists=<String>[];
    var autoLookups=0;
    final requested=<String>[];
    final grants=[
      IdentityGrant(roleId:'a',permission:'orders.read',branchId:branch),
      IdentityGrant(roleId:'b',permission:'orders.create',branchId:branch),
      IdentityGrant(roleId:'c',permission:'catalog.read',branchId:branch),
    ];
    final session=IdentitySession(actorId:customer,token:'local-test-token',
      expiresAt:DateTime.now().add(const Duration(hours:1)),grants:grants);
    final client=ErpIdentityClient(apiOrigin:'https://erp.example.test',
      httpClient:MockClient((request)async{
        requested.add(request.url.path);
        switch(request.url.path){
          case '/v1/catalog/branches':
            return http.Response(jsonEncode({'items':[
              {'id':branch,'code':'MAIN','name':'Chi nhánh chính'}]}),200);
          case '/v1/catalog/customers':
            return http.Response(jsonEncode({'items':[
              {'id':customer,'code':'KH1','name':'Khách hàng 1','active':true}]}),200);
          case '/v1/catalog/customer-groups':
          case '/v1/catalog/customer-regions':
          case '/v1/catalog/r1/channels':
            return http.Response(jsonEncode({'items':[]}),200);
          case '/v1/catalog/r1/skus':
            return http.Response(jsonEncode({'items':[
              {'id':sku,'productId':product,'code':'SP-01','sku':'SP-01',
               'productName':'Sản phẩm A','unitCode':'THUNG','active':true}]}),200);
          case '/v1/catalog/price-lists':
            return http.Response(jsonEncode({'items':[
              {'id':listA,'code':'BASE','name':'Giá mặc định','active':true},
              {'id':listB,'code':'KH','name':'Giá khách hàng','active':true},
            ]}),200);
          case '/v1/sales/orders':
            return http.Response(jsonEncode({'items':[]}),200);
          case '/v1/catalog/r1/resolve':
            autoLookups++;
            final body=jsonDecode(request.body) as Map<String,dynamic>;
            expect(body['priceListId'],isNull);
            expect(body['customerId'],customer);
            return http.Response(jsonEncode({'quote':{
              'priceListId':listB,'priceListCode':'KH','unitPrice':'30000',
              'basePrice':'30000','sellSkuId':sku,
            }}),200);
          case '/v1/sales/quote':
            final body=jsonDecode(request.body) as Map<String,dynamic>;
            selectedLists.add(body['priceListId'] as String);
            return http.Response(jsonEncode({'quote':{
              'lines':[{'sellSkuId':sku,'unitPrice':'30000',
                'lineTotal':'30000','priceSignature':'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'}],
              'subtotal':'30000','discountTotal':'0','taxTotal':'0',
              'grandTotal':'30000',
            }}),200);
        }
        return http.Response(jsonEncode({'error':{'code':'NOT_FOUND'}}),404);
      }));
    addTearDown(client.dispose);
    tester.view.devicePixelRatio=1;
    tester.view.physicalSize=const Size(1280,900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(theme:erpTheme(touch:false),
      home:Scaffold(body:CompanyWorkspace(previewOnly:false,grants:grants,
        session:session,client:client))));
    await tester.ensureVisible(find.byKey(const ValueKey('company-CompanyGroup.sales')));
    await tester.tap(find.byKey(const ValueKey('company-CompanyGroup.sales')));
    await tester.pumpAndSettle();
    await tester.runAsync(() async=>Future<void>.delayed(const Duration(milliseconds:120)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sales-create')));
    await tester.pumpAndSettle();
    await tester.runAsync(() async=>Future<void>.delayed(const Duration(milliseconds:120)));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sales-sku-search')),findsOneWidget,
      reason:'Requested endpoints: ${requested.join(", ")}; '
        'visible: ${tester.widgetList<Text>(find.byType(Text)).map((t)=>t.data).whereType<String>().take(30).join(" / ")}');
    await tester.enterText(find.byKey(const ValueKey('sales-sku-search')),'SP-01');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    await tester.runAsync(() async=>Future<void>.delayed(const Duration(milliseconds:200)));
    await tester.pump(const Duration(milliseconds:400));
    await tester.runAsync(() async=>Future<void>.delayed(const Duration(milliseconds:160)));
    await tester.pumpAndSettle();
    expect(autoLookups,greaterThanOrEqualTo(1));
    expect(selectedLists,contains(listB));
    final save=tester.widget<FilledButton>(find.byKey(const ValueKey('sales-save')));
    expect(save.onPressed,isNotNull);
    expect(find.textContaining('30.000 ₫'),findsWidgets);
  });
}
