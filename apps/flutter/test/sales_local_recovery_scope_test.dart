import 'dart:convert';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:erp_distribution/local/local_driver.dart';
import 'package:erp_distribution/local/local_store.dart';
import 'package:erp_distribution/ui/identity_client.dart';
import 'package:erp_distribution/ui/sales_workspace.dart';
import 'package:erp_distribution/ui/erp_tokens.dart';

class _Memory implements AtomicLocalDriver {
  final data=<String,String>{};
  @override Future<String?> read(String key) async=>data[key];
  @override Future<bool> compareAndSwap(String key,String? expected,String? next)async{
    if(data[key]!=expected)return false;
    if(next==null)data.remove(key);else data[key]=next;
    return true;
  }
  @override Future<void> write(String key,String value) async{data[key]=value;}
  @override Future<void> remove(String key) async{data.remove(key);}
}
void main(){
  testWidgets('Creating a distribution order skips stored cart selection but preserves recovery', (tester)async{
    const branch='00000000-0000-4000-8000-000000000001';
    const warehouse='00000000-0000-4000-8000-000000000009';
    const customer='00000000-0000-4000-8000-000000000003';
    const sellSku='00000000-0000-4000-8000-000000000007';
    const priceList='00000000-0000-4000-8000-000000000005';
    final store=ErpLocalStore(_Memory());
    final session=IdentitySession(actorId:'actor',token:'synthetic-token',
      installationId:'installation',expiresAt:DateTime.now().add(const Duration(hours:1)),
      grants:const [
        IdentityGrant(roleId:'orders-read',permission:'orders.read',branchId:branch),
        IdentityGrant(roleId:'orders-create',permission:'orders.create',branchId:branch),
        IdentityGrant(roleId:'catalog-read',permission:'catalog.read',branchId:branch),
        IdentityGrant(roleId:'inventory',permission:'inventory.read',branchId:branch,warehouseId:warehouse),
      ]);
    var writes=0;
    final client=ErpIdentityClient(apiOrigin:'https://erp.example.test',localStore:store,
      httpClient:MockClient((request)async{
        if(request.method!='GET')writes++;
        Map<String,dynamic> data;
        switch(request.url.path){
          case '/v1/catalog/branches':
            data={'items':[{'id':branch,'name':'Chi nhánh chính'}]};
          case '/v1/sales/orders':data={'items':[]};
          case '/v1/catalog/customers':
            data={'items':[{'id':customer,'name':'Khách A','active':true}]};
          case '/v1/catalog/r1/skus':
            data={'items':[{'id':sellSku,'productId':'product-a',
              'sku':'SP01','code':'SP01','productName':'Hàng A','unitCode':'cái','active':true}]};
          case '/v1/catalog/r1/channels':data={'items':[]};
          case '/v1/catalog/price-lists':
            data={'items':[{'id':priceList,'name':'Bán thường','active':true}]};
          case '/v1/catalog/warehouses':
            data={'items':[{'id':warehouse,'name':'Kho chính'}]};
          case '/v1/sales/entry-settings':data={'settings':{'deliveryChoice':'MANUAL'}};
          default:data={'items':[]};
        }
        return http.Response(jsonEncode(data),200,headers:const {'content-type':'application/json'});
      }));
    addTearDown(client.dispose);
    final scope=client.localScope(session,branch)!;
    await store.saveCart(scope,{'customerId':customer,'lines':[]});
    tester.view.devicePixelRatio=1;
    tester.view.physicalSize=const Size(1280,900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(theme:erpTheme(touch:false),
      home:Scaffold(body:SalesWorkspace(client:client,session:session))));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sales-resume-local-order')),findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('sales-create')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sales-order-context')),findsOneWidget);
    expect(find.byKey(const ValueKey('sales-remember-delivery')),findsOneWidget);
    expect(find.text('Đơn đang nhập trên máy'),findsNothing);
    expect((await store.savedCarts(scope)).isNotEmpty,isTrue,
      reason:'Starting a new order must not erase the previously saved cart');
    expect(writes,0,reason:'Opening a new order must never post a sale');
    // Close the dialog through its real lifecycle so the local cart autosave
    // timer and route controllers are disposed only after route.completed.
    await tester.tap(find.byTooltip('Đóng').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sales-order-context')),findsNothing);
    expect((await store.savedCarts(scope)).isNotEmpty,isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });


  const branch='00000000-0000-4000-8000-000000000001';
  const warehouse='00000000-0000-4000-8000-000000000009';
  for(final revoke in const ['orders.create','inventory.read']){
    testWidgets('T2 $revoke revoked: no replay, logout unlocked, intent preserved', (tester) async {
      final store=ErpLocalStore(_Memory());
      final grants=<IdentityGrant>[
        const IdentityGrant(roleId:'orders-read',permission:'orders.read',branchId:branch),
        if(revoke!='orders.create')
          const IdentityGrant(roleId:'orders-create',permission:'orders.create',branchId:branch),
        if(revoke!='inventory.read')
          const IdentityGrant(roleId:'inventory',permission:'inventory.read',
            branchId:branch,warehouseId:warehouse),
      ];
      final session=IdentitySession(actorId:'actor',token:'synthetic-token',
        installationId:'installation',expiresAt:DateTime.now().add(const Duration(hours:1)),
        grants:grants);
      var mutations=0;
      final client=ErpIdentityClient(apiOrigin:'https://erp.example.test',localStore:store,
        httpClient:MockClient((request)async{
          if(request.method!='GET')mutations++;
          Map<String,dynamic> result;
          switch(request.url.path){
            case '/v1/catalog/branches':
              result={'items':[{'id':branch,'code':'MAIN','name':'Chi nhánh chính'}]};
            case '/v1/sales/orders':result={'items':[]};
            default:result={'items':[]};
          }
          return http.Response(jsonEncode(result),200,
            headers:const {'content-type':'application/json'});
        }));
      addTearDown(client.dispose);
      final scope=client.localScope(session,branch)!;
      await store.saveSalesRecovery(scope,{'kind':'create','key':'retry-exact-key',
        'body':{'branchId':branch,'shipping':{'warehouseId':warehouse}},'auto':false});
      final locks=<bool>[];
      await tester.pumpWidget(MaterialApp(theme:erpTheme(touch:false),
        home:Scaffold(body:SalesWorkspace(client:client,session:session,
          onNavigationLockChanged:locks.add))));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds:100));
      expect(locks,isNotEmpty);
      expect(locks.last,false,reason:'blocked recovery must not trap logout/account switch');
      expect(mutations,0,reason:'revoked action must not be submitted to the server');
      expect((await store.salesRecovery(scope))?['key'],'retry-exact-key');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }
}
