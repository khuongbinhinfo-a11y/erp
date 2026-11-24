import 'dart:async';
import 'dart:convert';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:erp_distribution/ui/company_workspace.dart';
import 'package:erp_distribution/ui/catalog_workspace.dart';
import 'package:erp_distribution/ui/erp_tokens.dart';
import 'package:erp_distribution/ui/identity_client.dart';

const branch='00000000-0000-4000-8000-000000000001';
const actor='00000000-0000-4000-8000-000000000002';
final grants=<IdentityGrant>[
  const IdentityGrant(roleId:'catalog-reader',permission:'catalog.read',branchId:branch),
  const IdentityGrant(roleId:'catalog-writer',permission:'catalog.write',branchId:branch),
];
IdentitySession activeSession()=>IdentitySession(actorId:actor,token:'test-local-session',
  expiresAt:DateTime.now().add(const Duration(hours:1)),grants:grants);

Future<void> openCompanyCatalog(WidgetTester tester,String destination)async{
 final business=find.byKey(const ValueKey('company-CompanyGroup.catalog'));
 await tester.ensureVisible(business);
 await tester.tap(business);
 await tester.pumpAndSettle();
 final leaf=find.byKey(ValueKey('company-sub-CompanySection.$destination'));
 await tester.ensureVisible(leaf);
 await tester.tap(leaf);
 await tester.pumpAndSettle();
}

void main(){
  test('batch group change retains same-group categories and clears only changed groups',(){
    final product=<String,dynamic>{
      'groupId':'TAP','categoryId':'F04NA',
    };
    expect(shouldClearCategoryForTargetGroup(product,'TAP'),isFalse);
    expect(shouldClearCategoryForTargetGroup(product,'PAPER'),isTrue);
    expect(shouldClearCategoryForTargetGroup(product,null),isTrue);
    expect(shouldClearCategoryForTargetGroup(
      {'groupId':'TAP','categoryId':null},'PAPER'),isFalse);
  });

  test('lost ACK group edit replays original derived category removal',(){
    final pending=<String,dynamic>{
      'branchId':branch,'groupId':'new-group','categoryId':null,
    };
    final refreshed=<String,dynamic>{'branchId':branch,'groupId':'new-group'};
    expect(samePendingProductBulkIntent(pending,'group',refreshed),isTrue);
    expect(samePendingProductBulkIntent(pending,'group',
      {'branchId':branch,'groupId':'other-group'}),isFalse);
    expect(samePendingProductBulkIntent(pending,'category',
      {'branchId':branch,'categoryId':null}),isTrue);
    expect(samePendingProductBulkIntent(pending,'active',
      {'branchId':branch,'active':true}),isFalse);
  });

  test('login 503 is a backend problem, never shown as user network or bad password', () async {
    final client=ErpIdentityClient(apiOrigin:'https://erp.example.test',
      httpClient:MockClient((request)async{
        expect(request.url.path,'/v1/auth/login');
        return http.Response(jsonEncode({'error':{'code':'IDENTITY_UNAVAILABLE'}}),
          503,headers:const {'content-type':'application/json'});
      }));
    addTearDown(client.dispose);
    await expectLater(client.login('synthetic-user','synthetic-invalid-secret'),
      throwsA(isA<ErpApiError>()
        .having((e)=>e.status,'status',503)
        .having((e)=>e.message,'message',contains('Đăng nhập đang tạm gián đoạn'))));
  });

  test('browser auth network error probes public auth config for precise diagnostics', () async {
    final paths=<String>[];
    final client=ErpIdentityClient(apiOrigin:'https://erp.example.test',
      httpClient:MockClient((request)async{
        paths.add(request.url.path);
        if(request.url.path=='/v1/auth/login'){
          throw http.ClientException('simulated CORS/transport rejection');
        }
        return http.Response(jsonEncode({'enabled':true}),200);
      }));
    addTearDown(client.dispose);
    await expectLater(client.login('synthetic-user','synthetic-invalid-secret'),
      throwsA(isA<ErpApiError>()
        .having((e)=>e.status,'status',424)
        .having((e)=>e.message,'message',contains('đăng nhập'))));
    expect(paths,containsAll(['/v1/auth/login','/v1/auth/config']));
  });

  testWidgets('logged-in Company shows real catalog rows from API, no fabricated entries',
    (tester)async{
      final paths=<String>[];
      final branchQueries=<String?>[];
      final bearerHeaders=<String?>[];
      final mock=MockClient((request)async{
        paths.add(request.url.path);
        bearerHeaders.add(request.headers['authorization']);
        if(request.url.path=='/v1/catalog/branches')return http.Response(jsonEncode({
          'items':[{'id':branch,'code':'MAIN','name':'Chi nhánh chính'}]}),200);
        if(request.url.path=='/v1/catalog/customers'){
          branchQueries.add(request.url.queryParameters['branchId']);
          return http.Response(jsonEncode({'items':[
            {'id':'row-1','code':'KH-REAL-001','name':'Khách thực từ API',
              'active':true,'customerGroup':'VIP'},
          ]}),200,headers:const {'content-type':'application/json; charset=utf-8'});
        }
        return http.Response(jsonEncode({'items':[]}),200);
      });
      final client=ErpIdentityClient(apiOrigin:'https://erp.example.test',httpClient:mock);
      addTearDown(client.dispose);
      final direct=await tester.runAsync(()=>
        client.catalogItems('test-local-session','customers',branchId:branch));
      expect(direct!.first['code'],'KH-REAL-001',
        reason:'The mocked authenticated HTTP adapter must decode its response');
      tester.view.devicePixelRatio=1;
      tester.view.physicalSize=const Size(1280,800);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(theme:erpTheme(touch:false),home:Scaffold(
        body:CompanyWorkspace(previewOnly:false,grants:grants,
          session:activeSession(),client:client))));
      await openCompanyCatalog(tester,'customers');
      await tester.pumpAndSettle();
      // MockClient streamed responses can resolve outside the initial frame pump.
      await tester.runAsync(() async =>
        Future<void>.delayed(const Duration(milliseconds:120)));
      await tester.pumpAndSettle();
      expect(paths,contains('/v1/catalog/branches'));
      expect(paths,contains('/v1/catalog/customers'));
      expect(branchQueries,contains(branch));
      expect(bearerHeaders,everyElement('Bearer test-local-session'));
      expect(find.text('KH-REAL-001'),findsOneWidget);
      expect(find.text('Khách thực từ API'),findsOneWidget);
      expect(find.byKey(const ValueKey('catalog-live-table')),findsOneWidget);
    });

  testWidgets('staged catalog can be read but multi-SKU product create stays disabled',
    (tester)async{
      final client=ErpIdentityClient(apiOrigin:'https://erp.example.test',
        httpClient:MockClient((req)async{
          const headers={'content-type':'application/json; charset=utf-8'};
          if(req.url.path=='/v1/catalog/branches'){
            return http.Response(jsonEncode({'items':[
              {'id':branch,'code':'MAIN','name':'Chi nhánh chính'},
            ]}),200,headers:headers);
          }
          if(req.url.path=='/v1/catalog/products'){
            return http.Response(jsonEncode({
              'items':[{'id':'old-product','code':'SP01','name':'Sản phẩm cũ',
                'baseUnit':'cai','sellSkuCount':0,'active':true}],
              'r1ProductReady':false,
            }),200,headers:headers);
          }
          return http.Response(jsonEncode({'items':[]}),200,headers:headers);
        }));
      addTearDown(client.dispose);
      tester.view.devicePixelRatio=1;
      tester.view.physicalSize=const Size(1280,800);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(theme:erpTheme(touch:false),
        home:Scaffold(body:CompanyWorkspace(previewOnly:false,grants:grants,
          session:activeSession(),client:client))));
      await openCompanyCatalog(tester,'products');
      await tester.pumpAndSettle();
      await tester.runAsync(()async=>
        Future<void>.delayed(const Duration(milliseconds:120)));
      await tester.pumpAndSettle();
      expect(find.text('Sản phẩm cũ'),findsOneWidget);
      expect(find.byKey(const ValueKey('catalog-create')),findsNothing,
        reason:'Do not offer a write that needs uninstalled migration 0009');
      expect(find.textContaining('chưa cập nhật đủ cấu trúc SKU'),findsOneWidget);
    });

  test('legacy backend without catalog CORS is identified without blaming network',()async{
    final paths=<String>[];
    final mock=MockClient((request)async{
      paths.add(request.url.path);
      if(request.url.path.startsWith('/v1/catalog/')){
        throw http.ClientException('CORS preflight rejected by legacy backend');
      }
      if(request.url.path=='/v1/auth/config'){
        return http.Response(jsonEncode({'enabled':true}),200);
      }
      return http.Response('{}',404);
    });
    final client=ErpIdentityClient(apiOrigin:'https://erp.example.test',httpClient:mock);
    addTearDown(client.dispose);
    await expectLater(client.catalogItems('token','branches'),throwsA(
      isA<ErpApiError>().having((e)=>e.status,'status',424).having(
        (e)=>e.message,'message',contains('Danh mục đang tạm gián đoạn'))));
    expect(paths,containsAll(['/v1/catalog/branches','/v1/auth/config']));
  });

  testWidgets('navigation has white top-level tabs at right and left nested tabs',
    (tester)async{
      final mock=MockClient((request)async{
        if(request.url.path=='/v1/catalog/branches'){
          return http.Response(jsonEncode({'items':[
            {'id':branch,'code':'MAIN','name':'Chi nhánh chính'}]}),
            200,headers:const {'content-type':'application/json; charset=utf-8'});
        }
        return http.Response(jsonEncode({'items':[]}),200,
          headers:const {'content-type':'application/json; charset=utf-8'});
      });
      final client=ErpIdentityClient(apiOrigin:'https://erp.example.test',httpClient:mock);
      addTearDown(client.dispose);
      tester.view.devicePixelRatio=1;
      tester.view.physicalSize=const Size(1600,900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(theme:erpTheme(touch:false),home:Scaffold(
        body:CompanyWorkspace(previewOnly:false,grants:grants,
          session:activeSession(),client:client))));
      final header=find.byKey(const ValueKey('erp-page-header'));
      final mainTab=find.byKey(const ValueKey('company-CompanyGroup.catalog'));
      expect(tester.getRect(mainTab).center.dy,greaterThan(tester.getRect(header).top));
      expect(tester.getRect(mainTab).center.dy,lessThan(tester.getRect(header).bottom));
      expect(tester.getRect(mainTab).left,greaterThan(tester.getRect(header).left+200));
      await tester.tap(mainTab);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('company-sub-CompanySection.products')));
      await tester.pumpAndSettle();
      await tester.runAsync(()async=>Future<void>.delayed(const Duration(milliseconds:120)));
      await tester.pumpAndSettle();
      final inner=find.byKey(const ValueKey('catalog-inner-groups'));
      expect(inner,findsOneWidget);
      expect(tester.getRect(inner).top,greaterThan(tester.getRect(header).bottom));
      expect(tester.getRect(inner).left,lessThan(tester.getRect(header).left+160));
    });

  testWidgets('migration missing is explicit, no fake empty successful catalog',
    (tester)async{
      final mock=MockClient((_)async=>http.Response(jsonEncode({
        'error':{'code':'CATALOG_MIGRATION_REQUIRED','message':'not ready'}
      }),503));
      final client=ErpIdentityClient(apiOrigin:'https://erp.example.test',httpClient:mock);
      addTearDown(client.dispose);
      await tester.pumpWidget(MaterialApp(theme:erpTheme(touch:false),home:Scaffold(
        body:CompanyWorkspace(previewOnly:false,grants:grants,
          session:activeSession(),client:client))));
      await openCompanyCatalog(tester,'customers');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('catalog-error')),findsOneWidget);
      expect(find.textContaining('tạm gián đoạn'),findsOneWidget);
      expect(find.byKey(const ValueKey('catalog-live-table')),findsNothing);
    });
  testWidgets('catalog edit sends the server row revision and refreshes after ACK',(tester)async{
    var edited=false,patches=0;
    Map<String,dynamic>? submitted;
    final mock=MockClient((request)async{
      if(request.url.path=='/v1/catalog/branches')return http.Response(
        jsonEncode({'items':[{'id':branch,'code':'MAIN','name':'Chi nhánh chính'}]}),
        200,headers:const {'content-type':'application/json; charset=utf-8'});
      if(request.url.path=='/v1/catalog/customers'&&request.method=='GET')return http.Response(
        jsonEncode({'items':[{'id':'row-1','code':'KH-001',
          'name':edited?'Khách đã sửa':'Khách ban đầu','active':!edited,
          'revision':edited?1:0,'customerGroup':null}]}),
        200,headers:const {'content-type':'application/json; charset=utf-8'});
      if(request.url.path=='/v1/catalog/customers/row-1'&&request.method=='PATCH'){
        expect(request.headers['if-match'],'0');
        expect(request.headers['idempotency-key'],isNotEmpty);
        submitted=jsonDecode(request.body) as Map<String,dynamic>;
        patches++;edited=true;
        return http.Response(jsonEncode({'id':'row-1','revision':1}),200);
      }
      return http.Response(jsonEncode({'items':[]}),200);
    });
    final client=ErpIdentityClient(apiOrigin:'https://erp.example.test',httpClient:mock);
    addTearDown(client.dispose);
    tester.view.devicePixelRatio=1;
    tester.view.physicalSize=const Size(1280,800);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(theme:erpTheme(touch:false),home:Scaffold(
      body:CompanyWorkspace(previewOnly:false,grants:grants,
        session:activeSession(),client:client))));
    await openCompanyCatalog(tester,'customers');
    await tester.pumpAndSettle();
    await tester.runAsync(()async=>Future<void>.delayed(const Duration(milliseconds:120)));
    await tester.pumpAndSettle();
    expect(find.text('Khách ban đầu'),findsOneWidget);
    final catalogTable=tester.widget<DataTable>(
      find.byKey(const ValueKey('catalog-live-table')));
    expect((catalogTable.columns.last.label as Text).data,'Thao tác');
    expect(catalogTable.rows.single.cells.length,catalogTable.columns.length);
    expect(catalogTable.rows.single.cells.first.child,isA<Text>(),
      reason:'Ô Mã chỉ chứa mã, không có nút thao tác');
    await tester.ensureVisible(find.byKey(const ValueKey('catalog-edit-row-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('catalog-edit-row-1')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('catalog-edit-name')),'Khách đã sửa');
    await tester.tap(find.byKey(const ValueKey('catalog-edit-active')));
    await tester.tap(find.byKey(const ValueKey('catalog-edit-save')));
    await tester.pumpAndSettle();
    await tester.runAsync(()async=>Future<void>.delayed(const Duration(milliseconds:120)));
    await tester.pumpAndSettle();
    expect(patches,1);
    expect(submitted?['branchId'],branch);
    expect(submitted?['active'],false);
    expect(find.text('Khách đã sửa'),findsOneWidget);
    await tester.pump(const Duration(seconds:5));
    await tester.pumpAndSettle();
  });

  testWidgets('R1-A customer editor fits narrow viewport and uses coded group/region',
    (tester)async{
      var patches=0;
      Map<String,dynamic>? saved;
      final client=ErpIdentityClient(apiOrigin:'https://erp.example.test',
        httpClient:MockClient((req)async{
          const headers={'content-type':'application/json; charset=utf-8'};
          if(req.url.path=='/v1/catalog/branches')return http.Response(
            jsonEncode({'items':[{'id':branch,'code':'MAIN','name':'Chi nhánh chính'}]}),
            200,headers:headers);
          if(req.url.path=='/v1/catalog/customer-groups')return http.Response(
            jsonEncode({'items':[{'id':'group-1','code':'KH_SI',
              'name':'Khách bán sỉ','active':true}]}),200,headers:headers);
          if(req.url.path=='/v1/catalog/customer-regions')return http.Response(
            jsonEncode({'items':[{'id':'region-1','code':'KV_MT',
              'name':'Khu vực Mỹ Tho','active':true}]}),200,headers:headers);
          if(req.url.path=='/v1/catalog/customers'&&req.method=='GET'){
            return http.Response(jsonEncode({'items':[{
              'id':'customer-r1a','code':'KH0001','name':'Khách kiểm tra',
              'customerGroupId':'group-1','customerGroupCode':'KH_SI',
              'customerRegionId':null,'customerRegionCode':null,
              'phone':'+84912345678','deliveryAddress':'Đường thử',
              'paymentTermsDays':15,'active':true,'revision':0,
            }]}),200,headers:headers);
          }
          if(req.url.path=='/v1/catalog/customers/customer-r1a'&&req.method=='PATCH'){
            saved=jsonDecode(req.body) as Map<String,dynamic>;patches++;
            return http.Response(jsonEncode({'id':'customer-r1a','revision':1}),200,headers:headers);
          }
          return http.Response(jsonEncode({'items':[]}),200,headers:headers);
        }));
      addTearDown(client.dispose);
      tester.view.devicePixelRatio=1;
      tester.view.physicalSize=const Size(390,680);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(theme:erpTheme(touch:true),
        home:Scaffold(body:CompanyWorkspace(previewOnly:false,grants:grants,
          session:activeSession(),client:client))));
      await tester.pumpAndSettle();
      expect(tester.takeException(),isNull,reason:'overview narrow initial overflow');
      await openCompanyCatalog(tester,'customers');
      await tester.pumpAndSettle();
      await tester.runAsync(()async=>Future<void>.delayed(const Duration(milliseconds:150)));
      await tester.pumpAndSettle();
      expect(tester.takeException(),isNull,
        reason:'mobile catalog must not overflow before opening edit dialog');
      await tester.ensureVisible(find.byKey(const ValueKey('catalog-edit-customer-r1a')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('catalog-edit-customer-r1a')));
      await tester.pumpAndSettle();
      expect(tester.takeException(),isNull,reason:'opened edit dialog overflow');
      expect(find.byKey(const ValueKey('catalog-edit-scroll')),findsOneWidget);
      expect(find.byKey(const ValueKey('catalog-edit-customer-group')),findsOneWidget);
      final region=find.byKey(const ValueKey('catalog-edit-customer-region'));
      expect(region,findsOneWidget);
      await tester.ensureVisible(region);
      await tester.pumpAndSettle();
      expect(tester.takeException(),isNull,reason:'scrolled edit dialog overflow');
      await tester.tap(region);
      await tester.pumpAndSettle();
      await tester.tap(find.text('KV_MT · Khu vực Mỹ Tho').last);
      await tester.pumpAndSettle();
      expect(tester.takeException(),isNull,reason:'dropdown selection overflow');
      await tester.tap(find.byKey(const ValueKey('catalog-edit-save')));
      await tester.pumpAndSettle();
      await tester.runAsync(()async=>Future<void>.delayed(const Duration(milliseconds:150)));
      await tester.pumpAndSettle();
      expect(tester.takeException(),isNull,reason:'after save overflow');
      expect(patches,1);
      expect(saved?['customerRegionId'],'region-1');
      expect(saved?.containsKey('customerGroupId'),false,
        reason:'unchanged group must not trigger irrelevant re-assignment');
      expect(saved?['branchId'],branch);
      // A success toast owns an expiry timer; advance fake time before teardown.
      await tester.pump(const Duration(seconds:5));
      await tester.pumpAndSettle();
    });

  testWidgets('R1-A quick customer setup creates coded directories and submits ID references',
    (tester)async{
      final creations=<String>[];
      final delayedRegion=Completer<http.Response>();
      Map<String,dynamic>? customerBody;
      const headers={'content-type':'application/json; charset=utf-8'};
      final client=ErpIdentityClient(apiOrigin:'https://erp.example.test',
        httpClient:MockClient((req)async{
          if(req.url.path=='/v1/catalog/branches')return http.Response(
            jsonEncode({'items':[{'id':branch,'code':'MAIN','name':'Chi nhánh chính'}]}),
            200,headers:headers);
          if(req.method=='GET')return http.Response(
            jsonEncode({'items':[]}),200,headers:headers);
          if(req.url.path=='/v1/catalog/customer-groups'&&req.method=='POST'){
            creations.add(req.url.path);
            final body=jsonDecode(req.body) as Map<String,dynamic>;
            expect(body['code'],'KH_SI');
            expect(body['name'],'Khách bán sỉ');
            return http.Response(jsonEncode({'id':'group-created'}),201,headers:headers);
          }
          if(req.url.path=='/v1/catalog/customer-regions'&&req.method=='POST'){
            creations.add(req.url.path);
            final body=jsonDecode(req.body) as Map<String,dynamic>;
            expect(body['code'],'KV_MT');
            return delayedRegion.future;
          }
          if(req.url.path=='/v1/catalog/customers'&&req.method=='POST'){
            customerBody=jsonDecode(req.body) as Map<String,dynamic>;
            return http.Response(jsonEncode({'id':'customer-created'}),201,headers:headers);
          }
          return http.Response(jsonEncode({'error':{'code':'INVALID_ROUTE'}}),
            404,headers:headers);
        }));
      addTearDown(client.dispose);
      tester.view.devicePixelRatio=1;
      tester.view.physicalSize=const Size(1024,800);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(theme:erpTheme(touch:false),
        home:Scaffold(body:CompanyWorkspace(previewOnly:false,grants:grants,
          session:activeSession(),client:client))));
      await openCompanyCatalog(tester,'customers');
      await tester.pumpAndSettle();
      await tester.runAsync(()async=>Future<void>.delayed(const Duration(milliseconds:150)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('catalog-create')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('catalog-create-code')),'KH-NEW');
      await tester.enterText(find.byKey(const ValueKey('catalog-create-name')),'Khách mã mới');
      await tester.ensureVisible(find.byKey(const ValueKey('catalog-quick-customer-group-code')));
      await tester.enterText(find.byKey(const ValueKey('catalog-quick-customer-group-code')),'kh_si');
      await tester.enterText(find.byKey(const ValueKey('catalog-quick-customer-group-name')),'Khách bán sỉ');
      await tester.ensureVisible(find.byKey(
        const ValueKey('catalog-quick-customer-group-save')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(
        const ValueKey('catalog-quick-customer-group-save')));
      await tester.pumpAndSettle();
      await tester.runAsync(()async=>Future<void>.delayed(const Duration(milliseconds:120)));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('catalog-create-customer-group-group-created')),findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('catalog-quick-customer-region-code')));
      await tester.enterText(find.byKey(const ValueKey('catalog-quick-customer-region-code')),'kv_mt');
      await tester.enterText(find.byKey(const ValueKey('catalog-quick-customer-region-name')),'Mỹ Tho');
      await tester.ensureVisible(find.byKey(
        const ValueKey('catalog-quick-customer-region-save')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(
        const ValueKey('catalog-quick-customer-region-save')));
      await tester.pumpAndSettle();
      // Do not allow customer creation until the new region ID has a server ACK.
      final submit=find.byKey(const ValueKey('catalog-create-confirm'));
      expect(tester.widget<FilledButton>(submit).onPressed,isNull,
        reason:'customer submit must stay disabled during region creation');
      expect(customerBody,isNull);
      delayedRegion.complete(http.Response(
        jsonEncode({'id':'region-created'}),201,headers:headers));
      await tester.runAsync(()async=>Future<void>.delayed(const Duration(milliseconds:120)));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('catalog-create-customer-region-region-created')),findsOneWidget);
      expect(tester.widget<FilledButton>(submit).onPressed,isNotNull,
        reason:'save enabled only after region creation ACK');
      await tester.ensureVisible(find.text('Lưu trên server'));
      await tester.tap(find.text('Lưu trên server'));
      await tester.pumpAndSettle();
      await tester.runAsync(()async=>Future<void>.delayed(const Duration(milliseconds:150)));
      await tester.pumpAndSettle();
      expect(creations,['/v1/catalog/customer-groups','/v1/catalog/customer-regions']);
      expect(customerBody?['customerGroupId'],'group-created');
      expect(customerBody?['customerRegionId'],'region-created');
      expect(customerBody?.containsKey('customerGroup'),false,
        reason:'never submit manually typed group label');
      expect(tester.takeException(),isNull);
      await tester.pump(const Duration(seconds:5));
      await tester.pumpAndSettle();
    });

  testWidgets('price list view menu remains visible for catalog.read-only users',
    (tester)async{
      const priceId='00000000-0000-4000-8000-000000000099';
      final readOnly=<IdentityGrant>[
        const IdentityGrant(roleId:'reader',permission:'catalog.read',branchId:branch),
      ];
      final session=IdentitySession(actorId:actor,token:'test-local-session',
        expiresAt:DateTime.now().add(const Duration(hours:1)),grants:readOnly);
      final client=ErpIdentityClient(apiOrigin:'https://erp.example.test',
        httpClient:MockClient((req)async{
          final items=req.url.path=='/v1/catalog/branches'
            ?[{'id':branch,'code':'MAIN','name':'Chi nhánh chính'}]
            :req.url.path=='/v1/catalog/price-lists'
              ?[{'id':priceId,'code':'GIA','name':'Giá bán',
                  'active':true,'revision':0}]
              :<Map<String,dynamic>>[];
          return http.Response(jsonEncode({'items':items}),200,
            headers:const {'content-type':'application/json; charset=utf-8'});
        }));
      addTearDown(client.dispose);
      tester.view.devicePixelRatio=1;
      tester.view.physicalSize=const Size(1300,900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(theme:erpTheme(touch:false),
        home:Scaffold(body:CompanyWorkspace(previewOnly:false,grants:readOnly,
          session:session,client:client))));
      await openCompanyCatalog(tester,'prices');
      await tester.runAsync(()async=>
        Future<void>.delayed(const Duration(milliseconds:120)));
      await tester.pumpAndSettle();
      final menu=find.byKey(const ValueKey('catalog-price-list-actions-'+priceId));
      expect(menu,findsOneWidget,reason:'View-only users must reach price tools');
      expect(find.byKey(const ValueKey('catalog-edit-'+priceId)),findsNothing);
      expect(find.byKey(const ValueKey('catalog-price-list-clone-'+priceId)),findsNothing);
      await tester.tap(menu);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Giá bán').last);
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('price-skus-'+branch+'-'+priceId)),findsOneWidget);
      expect(tester.takeException(),isNull);
    });

  testWidgets('price list search + selector share a row; editors are opt-in',
    (tester)async{
      const priceId='00000000-0000-4000-8000-000000000099';
      final client=ErpIdentityClient(apiOrigin:'https://erp.example.test',
        httpClient:MockClient((request)async{
          if(request.url.path=='/v1/catalog/branches'){
            return http.Response(jsonEncode({'items':[
              {'id':branch,'code':'MAIN','name':'Chi nhánh chính'}]}),200);
          }
          if(request.url.path=='/v1/catalog/price-lists'){
            return http.Response(jsonEncode({'items':[
              {'id':priceId,'code':'GIATEST','name':'Giá Test',
                'active':true,'revision':0}]}),200);
          }
          return http.Response(jsonEncode({'items':[]}),200,
            headers:const {'content-type':'application/json; charset=utf-8'});
        }));
      addTearDown(client.dispose);
      tester.view.devicePixelRatio=1;
      tester.view.physicalSize=const Size(1600,900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(theme:erpTheme(touch:false),
        home:Scaffold(body:CompanyWorkspace(previewOnly:false,grants:grants,
          session:activeSession(),client:client))));
      await openCompanyCatalog(tester,'prices');
      await tester.pumpAndSettle();
      await tester.runAsync(()async=>Future<void>.delayed(const Duration(milliseconds:120)));
      await tester.pumpAndSettle();
      final search=find.byKey(const ValueKey('catalog-search'));
      final picker=find.byKey(const ValueKey('price-workspace-selected-$priceId'));
      expect(search,findsOneWidget);
      expect(picker,findsOneWidget);
      expect((tester.getTopLeft(search).dy-tester.getTopLeft(picker).dy).abs(),
        lessThan(16),reason:'Desktop search and selected price list occupy one row');
      final editor=find.byKey(const ValueKey('price-skus-$branch-$priceId'));
      expect(editor,findsNothing,reason:'Price editor must not appear on its own');
      final menu=find.byKey(const ValueKey('catalog-price-list-actions-$priceId'));
      await tester.tap(menu);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Giá bán').last);
      await tester.pumpAndSettle();
      expect(editor,findsOneWidget);
    });

  testWidgets('T1 customer assignment searches beyond first page and preserves selected IDs', (tester)async{
    const priceId='00000000-0000-4000-8000-000000000099';
    const selectedId='00000000-0000-4000-8000-000000000098';
    const foundId='00000000-0000-4000-8000-000000000097';
    Map<String,dynamic>? posted;
    final client=ErpIdentityClient(apiOrigin:'https://erp.example.test',
      httpClient:MockClient((req)async{
        http.Response reply(Object body,[int status=200])=>http.Response(jsonEncode(body),status,
          headers:const {'content-type':'application/json; charset=utf-8'});
        final path=req.url.path;
        if(path=='/v1/catalog/branches')return reply({'items':[{'id':branch,'name':'Chi nhánh chính','code':'MAIN'}]});
        if(path=='/v1/catalog/price-lists')return reply({'items':[{'id':priceId,'name':'Giá Test','code':'GIATEST','active':true,'revision':0}]});
        if(path=='/v1/catalog/price-lists/assignments')return reply({'items':[{'id':'assigned','scopeKind':'CUSTOMER','customerId':selectedId,'customerCode':'KH-0000','customerName':'Khách đã có','active':true}],'hasMore':false});
        if(path=='/v1/catalog/customers'){
          final term=req.url.queryParameters['q'];
          if(term=='KH-1001')return reply({'items':[{'id':foundId,'code':'KH-1001','name':'Khách tìm được','active':true}]});
          return reply({'items':[for(var n=0;n<100;n++){'id':'customer-$n','code':'KH-$n','name':'Khách $n','active':true}]});
        }
        if(path=='/v1/catalog/price-lists/$priceId'&&req.method=='PATCH'){
          posted=jsonDecode(req.body) as Map<String,dynamic>;
          return reply({'id':priceId,'revision':1});
        }
        return reply({'items':[]});
      }));
    addTearDown(client.dispose);
    tester.view.devicePixelRatio=1;
    tester.view.physicalSize=const Size(1440,900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(theme:erpTheme(touch:false),home:Scaffold(
      body:CatalogWorkspace(area:'price-lists',session:activeSession(),client:client))));
    await tester.pumpAndSettle();
    final edit=find.byKey(const ValueKey('catalog-edit-$priceId'));
    await tester.ensureVisible(edit);
    await tester.tap(edit);
    await tester.pumpAndSettle();
    final search=find.byKey(const ValueKey('price-edit-customer-search'));
    await tester.ensureVisible(search);
    await tester.enterText(search,'KH-1001');
    await tester.pump(const Duration(milliseconds:350));
    await tester.pumpAndSettle();
    final add=find.byKey(const ValueKey('price-edit-customer-$foundId'));
    await tester.ensureVisible(add);
    await tester.tap(add);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('catalog-edit-save')));
    await tester.pumpAndSettle();
    expect(posted?['customerIds'],unorderedEquals([selectedId,foundId]));
  });

  testWidgets('T1 product edit exposes locked identity, SKU, units, barcode and images in one dialog', (tester)async{
    const product='00000000-0000-4000-8000-000000000020';
    final reads=<String>[];
    final client=ErpIdentityClient(apiOrigin:'https://erp.example.test',
      httpClient:MockClient((req)async{
        final path=req.url.path;reads.add(path);
        http.Response reply(Object body)=>http.Response(jsonEncode(body),200,headers:const {'content-type':'application/json; charset=utf-8'});
        if(path=='/v1/catalog/branches')return reply({'items':[{'id':branch,'code':'MAIN','name':'Chi nhánh chính'}]});
        if(path=='/v1/catalog/products')return reply({'items':[{'id':product,'code':'SP01','name':'Hàng A','baseUnit':'cai','active':true,'revision':0}],'r1ProductReady':true});
        if(path=='/v1/catalog/r1/skus'||path=='/v1/catalog/r1/units'||path=='/v1/catalog/r1/barcodes'){
          expect(req.url.queryParameters['productId'],product);
          return reply({'items':[]});
        }
        if(path=='/v1/catalog/products/$product/media')return reply({'items':[]});
        return reply({'items':[]});
      }));
    addTearDown(client.dispose);
    tester.view.devicePixelRatio=1;
    tester.view.physicalSize=const Size(1440,900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(theme:erpTheme(touch:false),home:Scaffold(
      body:CatalogWorkspace(area:'products',session:activeSession(),client:client))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('catalog-edit-$product')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('catalog-edit-dialog')),findsOneWidget);
    for(final kind in ['units','skus','barcodes']){
      expect(find.byKey(ValueKey('product-edit-$product-$kind')),findsOneWidget);
    }
    expect(find.byKey(const ValueKey('product-edit-$product-images')),findsOneWidget);
    expect(find.byKey(const ValueKey('catalog-edit-product-skus')),findsNothing);
    expect(tester.widgetList<TextField>(find.byType(TextField)).where((x)=>x.readOnly).length,greaterThanOrEqualTo(2));
    expect(reads,containsAll(['/v1/catalog/r1/skus','/v1/catalog/r1/units','/v1/catalog/r1/barcodes','/v1/catalog/products/$product/media']));
  });

}
