import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:erp_distribution/ui/company_workspace.dart';
import 'package:erp_distribution/ui/erp_tokens.dart';
import 'package:erp_distribution/ui/identity_client.dart';

const branch='00000000-0000-4000-8000-000000000001';
const user='00000000-0000-4000-8000-000000000002';
const customer='00000000-0000-4000-8000-000000000003';
const product='00000000-0000-4000-8000-000000000004';
const sellSku='00000000-0000-4000-8000-000000000005';
const priceList='00000000-0000-4000-8000-000000000006';
const customerGroupId='00000000-0000-4000-8000-000000000007';
const customerRegionId='00000000-0000-4000-8000-000000000008';

void main(){
  testWidgets('quick customer in sale preserves order context and idempotent lost ACK retry',
    (tester)async{
    final sentKeys=<String?>[], sentBodies=<String>[];
    var attempts=0;
    http.Response reply(Object data,int status)=>http.Response(jsonEncode(data),status,
      headers:const {'content-type':'application/json; charset=utf-8'});
    final rights=[
      const IdentityGrant(roleId:'a',permission:'orders.read',branchId:branch),
      const IdentityGrant(roleId:'b',permission:'orders.create',branchId:branch),
      const IdentityGrant(roleId:'c',permission:'catalog.read',branchId:branch),
      const IdentityGrant(roleId:'d',permission:'catalog.write',branchId:branch),
    ];
    final session=IdentitySession(actorId:user,token:'synthetic-token',
      expiresAt:DateTime.now().add(const Duration(hours:1)),grants:rights);
    final client=ErpIdentityClient(apiOrigin:'https://erp.example.test',
      httpClient:MockClient((request)async{
        final path=request.url.path;
        if(path=='/v1/catalog/branches'){
          return reply({'items':[{'id':branch,'code':'MAIN','name':'Chi nhánh chính'}]},200);
        }
        if(path=='/v1/catalog/customers'&&request.method=='GET'){
          return reply({'items':[]},200);
        }
        if(path=='/v1/catalog/customer-groups')return reply({'items':[
          {'id':customerGroupId,'code':'KH_DAILY','name':'Đại lý','active':true},
        ]},200);
        if(path=='/v1/catalog/customer-regions')return reply({'items':[
          {'id':customerRegionId,'code':'KV_MT','name':'Mỹ Tho','active':true},
        ]},200);
        if(path=='/v1/catalog/customers'&&request.method=='POST'){
          attempts++;
          sentKeys.add(request.headers['idempotency-key']);
          sentBodies.add(request.body);
          final body=jsonDecode(request.body) as Map<String,dynamic>;
          expect(body['branchId'],branch);
          expect(body['code'],'KH-T01');
          expect(body['name'],'Cửa hàng thử nghiệm');
          expect(body['customerGroupId'],customerGroupId);
          expect(body['customerRegionId'],customerRegionId);
          expect(body.containsKey('customerGroup'),false,
            reason:'coded categories are never posted as free text');
          expect(body['paymentTermsDays'],30);
          if(attempts==1)throw http.ClientException('ACK lost after COMMIT');
          if(attempts==2)return reply({'error':{'code':'AUTH_DENIED'}},401);
          return reply({'id':customer,'code':'KH-T01',
            'name':'Cửa hàng thử nghiệm','revision':0},201);
        }
        if(path=='/v1/catalog/r1/skus'){
          return reply({'items':[{'id':sellSku,'productId':product,
            'code':'SP01','productName':'Hàng A','unitCode':'cai',
            'active':true}]},200);
        }
        if(path=='/v1/catalog/price-lists'){
          return reply({'items':[{'id':priceList,'code':'SELL',
            'name':'Giá bán','active':true}]},200);
        }
        if(path=='/v1/catalog/r1/channels')return reply({'items':[]},200);
        if(path=='/v1/sales/orders'&&request.method=='GET')
          return reply({'items':[]},200);
        return reply({'error':{'code':'NOT_FOUND'}},404);
      }));
    addTearDown(client.dispose);
    tester.view.devicePixelRatio=1;
    tester.view.physicalSize=const Size(1280,900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(theme:erpTheme(touch:false),
      home:Scaffold(body:CompanyWorkspace(previewOnly:false,
        grants:rights,session:session,client:client))));
    await tester.tap(find.byKey(const ValueKey('company-CompanySection.orders')));
    await tester.pumpAndSettle();
    await tester.runAsync(()async=>
      Future<void>.delayed(const Duration(milliseconds:120)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sales-create')));
    await tester.pumpAndSettle();
    await tester.runAsync(()async=>
      Future<void>.delayed(const Duration(milliseconds:120)));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sales-quick-customer-toggle')),findsOneWidget);
    expect(find.byKey(const ValueKey('sales-sku-search')),findsOneWidget,
      reason:'Sale entry must open even when no customer exists yet');
    await tester.tap(find.byKey(const ValueKey('sales-quick-customer-toggle')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('sales-quick-customer-code')),
      'KH-T01');
    await tester.enterText(find.byKey(const ValueKey('sales-quick-customer-name')),
      'Cửa hàng thử nghiệm');
    await tester.tap(find.byKey(const ValueKey('sales-quick-customer-group-null')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('KH_DAILY · Đại lý').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sales-quick-customer-region-null')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('KV_MT · Mỹ Tho').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(
      const ValueKey('sales-quick-customer-payment-terms')),'30');
    await tester.ensureVisible(find.byKey(const ValueKey('sales-quick-customer-save')));
    await tester.tap(find.byKey(const ValueKey('sales-quick-customer-save')));
    await tester.pumpAndSettle();
    await tester.runAsync(()async=>
      Future<void>.delayed(const Duration(milliseconds:120)));
    await tester.pumpAndSettle();
    expect(attempts,1);
    expect(find.text('Kiểm tra lại'),findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(
      const ValueKey('sales-quick-customer-code'))).enabled,false);
    await tester.tap(find.byKey(const ValueKey('sales-quick-customer-save')));
    await tester.pumpAndSettle();
    await tester.runAsync(()async=>
      Future<void>.delayed(const Duration(milliseconds:120)));
    await tester.pumpAndSettle();
    expect(attempts,2);
    expect(find.text('Kiểm tra lại'),findsOneWidget,
      reason:'401 cannot prove the first POST was rolled back');
    // Close the order composer and reopen after reauthentication. The same
    // actor/branch command must remain recoverable with the original key.
    await tester.tap(find.text('Đóng').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sales-create')),findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('sales-create')));
    await tester.pumpAndSettle();
    await tester.runAsync(()async=>
      Future<void>.delayed(const Duration(milliseconds:120)));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sales-quick-customer-panel')),findsOneWidget);
    expect(find.text('Kiểm tra lại'),findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('sales-quick-customer-save')));
    await tester.tap(find.byKey(const ValueKey('sales-quick-customer-save')));
    await tester.pumpAndSettle();
    await tester.runAsync(()async=>
      Future<void>.delayed(const Duration(milliseconds:120)));
    await tester.pumpAndSettle();
    expect(attempts,3);
    expect(sentKeys[0],isNotNull);
    expect(sentKeys[0],sentKeys[1]);
    expect(sentKeys[1],sentKeys[2]);
    expect(sentBodies[0],sentBodies[1]);
    expect(sentBodies[1],sentBodies[2]);
    expect(find.byKey(const ValueKey('sales-quick-customer-panel')),findsNothing);
    expect(find.textContaining('Cửa hàng thử nghiệm'),findsWidgets);
    expect(find.byKey(const ValueKey('sales-sku-search')),findsOneWidget);
    await tester.tap(find.text('Đóng').last);
    await tester.pumpAndSettle();
    if(find.text('Bỏ thay đổi').evaluate().isNotEmpty){
      await tester.tap(find.text('Bỏ thay đổi'));
      await tester.pumpAndSettle();
    }
    await tester.pump(const Duration(seconds:5));
  });
}
