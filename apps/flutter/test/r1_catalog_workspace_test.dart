import 'dart:convert';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:erp_distribution/ui/identity_client.dart';
import 'package:erp_distribution/ui/r1_catalog_workspace.dart';
import 'package:erp_distribution/ui/erp_tokens.dart';

const branch='00000000-0000-4000-8000-000000000001';
const sku='00000000-0000-4000-8000-000000000002';
const product='00000000-0000-4000-8000-000000000003';
const list='00000000-0000-4000-8000-000000000004';
const clientId='00000000-0000-4000-8000-000000000005';
const outlet='00000000-0000-4000-8000-000000000006';
const branches=[{'id':branch,'code':'MAIN','name':'Chi nhánh chính'}];

IdentitySession session({bool write=true})=>IdentitySession(
  actorId:'00000000-0000-4000-8000-000000000007',
  token:'integration-only-session',
  expiresAt:DateTime.now().add(const Duration(hours:3)),
  grants:[
    IdentityGrant(roleId:'reader',permission:'catalog.read',branchId:branch),
    if(write)IdentityGrant(roleId:'editor',permission:'catalog.write',branchId:branch),
  ],
);
List<Map<String,dynamic>> sample(String resource)=>switch(resource){
  'products'=>[{'id':product,'code':'SP01','name':'Sản phẩm thử','active':true}],
  'r1/skus'=>[{'id':sku,'code':'SP01-T','productName':'Sản phẩm thử',
    'unitCode':'thung','toBase':'12.000000','active':true}],
  'price-lists'=>[{'id':list,'code':'SELL','name':'Bảng giá','active':true}],
  'customers'=>[{'id':clientId,'code':'KH01','name':'Khách hàng thử','active':true}],
  'r1/channels'=>[{'id':outlet,'code':'SHOP','name':'Cửa hàng','active':true}],
  _=>[],
};

void main(){
  test('R1 promotion restrictions do not silently expand customer or channel',(){
    final selected=r1RuleRestrictions('PROMOTION',
      customerId:clientId,channelId:outlet,customerGroup:'VIP');
    expect(selected,{
      'customerId':clientId,'channelId':outlet,'customerGroup':'VIP',
    });
    final targeted=r1RuleRestrictions('CUSTOMER',
      customerId:clientId,channelId:outlet,customerGroup:'VIP');
    expect(targeted['channelId'],outlet);
    expect(targeted['customerId'],clientId);
    expect(r1RuleRestrictions('BASE',
      customerId:clientId,channelId:outlet,customerGroup:'VIP'),isEmpty);
  });
  testWidgets('R1 channel editor saves through scoped authenticated API; no sample sale', (tester)async{
    var saved=false;String? idempotency;
    final client=ErpIdentityClient(apiOrigin:'https://erp.example.test',
      httpClient:MockClient((request)async{
        expect(request.headers['authorization'],'Bearer integration-only-session');
        final path=request.url.path;
        if(path=='/v1/catalog/r1/channels'&&request.method=='POST'){
          idempotency=request.headers['idempotency-key'];
          final payload=jsonDecode(request.body) as Map<String,dynamic>;
          expect(payload['branchId'],branch);
          expect(payload['code'],'ONLINE');
          saved=true;
          return http.Response(jsonEncode({'id':outlet,'code':'ONLINE','name':'Bán trực tuyến'}),201,
            headers:{'content-type':'application/json; charset=utf-8'});
        }
        if(request.method=='GET'&&path.startsWith('/v1/catalog/')){
          final resource=path.substring('/v1/catalog/'.length);
          final items=resource=='r1/channels'&&saved
            ?[{'id':outlet,'code':'ONLINE','name':'Bán trực tuyến','active':true}]
            :sample(resource);
          return http.Response(jsonEncode({'items':items}),200,
            headers:{'content-type':'application/json; charset=utf-8'});
        }
        return http.Response(jsonEncode({'error':{'code':'NOT_FOUND'}}),404);
      }));
    addTearDown(client.dispose);
    tester.view.devicePixelRatio=1;
    tester.view.physicalSize=const Size(1100,800);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(theme:erpTheme(touch:false),home:
      Scaffold(body:SingleChildScrollView(child:R1CatalogWorkspace(
        kind:'channels',branchId:branch,branches:branches,
        client:client,session:session(),changeBranch:(_){},
      )))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('r1-new')));
    await tester.pumpAndSettle();
    await tester.runAsync(() async =>
      Future<void>.delayed(const Duration(milliseconds:150)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('r1-input-code')),'ONLINE');
    await tester.enterText(find.byKey(const ValueKey('r1-input-name')),'Bán trực tuyến');
    await tester.tap(find.byKey(const ValueKey('r1-save')));
    await tester.pumpAndSettle();
    expect(saved,true);
    expect(idempotency,isNotNull);
    expect(find.text('Bán trực tuyến'),findsWidgets);
    await tester.pump(const Duration(seconds:5));
  });

  testWidgets('R1 mobile quote returns server amount and explainable trace', (tester)async{
    var quoteCalls=0;
    final requests=<String>[];
    final client=ErpIdentityClient(apiOrigin:'https://erp.example.test',
      httpClient:MockClient((request)async{
        requests.add(request.method+' '+request.url.path);
        if(request.method=='GET'){
          final resource=request.url.path.substring('/v1/catalog/'.length);
          return http.Response(jsonEncode({'items':sample(resource)}),200,
            headers:{'content-type':'application/json; charset=utf-8'});
        }
        if(request.url.path=='/v1/catalog/r1/resolve'&&request.method=='POST'){
          quoteCalls++;
          final payload=jsonDecode(request.body) as Map<String,dynamic>;
          expect(payload['sellSkuId'],sku);
          expect(payload['priceListId'],list);
          expect(payload['quantity'],'2');
          return http.Response(jsonEncode({'quote':{
            'unitPrice':'111150','lineTotal':'222300','normalizedBaseQuantity':'24.000000',
            'trace':[
              {'scope':'BASE_RULE','adjustment':'FIXED_PRICE','result':'130000.0000'},
              {'scope':'CHANNEL','adjustment':'PERCENT_DISCOUNT','result':'117000'},
              {'scope':'CUSTOMER_GROUP','adjustment':'PERCENT_DISCOUNT','result':'111150'},
            ],
          }}),200,headers:{'content-type':'application/json; charset=utf-8'});
        }
        return http.Response(jsonEncode({'error':{'code':'NOT_FOUND'}}),404);
      }));
    addTearDown(client.dispose);
    tester.view.devicePixelRatio=1;
    tester.view.physicalSize=const Size(390,900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(theme:erpTheme(touch:true),home:
      Scaffold(body:SingleChildScrollView(child:R1CatalogWorkspace(
        kind:'quote',branchId:branch,branches:branches,
        client:client,session:session(write:false),changeBranch:(_){},
      )))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('r1-new')));
    await tester.pumpAndSettle();
    await tester.runAsync(() async =>
      Future<void>.delayed(const Duration(milliseconds:150)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('r1-input-quantity')),'2');
    // Price-list and SKU choices are loaded asynchronously. Do not press a
    // disabled action; wait until its bound server-scoped selections exist.
    for(var attempt=0;attempt<12;attempt++){
      final button=tester.widget<FilledButton>(find.byKey(const ValueKey('r1-save')));
      if(button.onPressed!=null)break;
      await tester.runAsync(() async =>
        Future<void>.delayed(const Duration(milliseconds:120)));
      await tester.pumpAndSettle();
    }
    expect(tester.widget<FilledButton>(
      find.byKey(const ValueKey('r1-save'))).onPressed,isNotNull);
    await tester.ensureVisible(find.byKey(const ValueKey('r1-save')));
    await tester.tap(find.byKey(const ValueKey('r1-save')));
    await tester.pumpAndSettle();
    expect(requests, isNot(contains('GET /v1/catalog/customer-groups')),
      reason:'R1 quote must remain usable before customer directory 0017');
    expect(requests, isNot(contains('GET /v1/catalog/unit-definitions')),
      reason:'R1 quote must not depend on irrelevant UOM dictionary requests');
    expect(quoteCalls,1,reason:'R1 HTTP calls: '+requests.join(' | ')+
      ' / widgets: '+tester.widgetList<Text>(find.byType(Text))
        .map((e)=>e.data??'').where((e)=>e.isNotEmpty).take(24).join(' / '));
    expect(find.textContaining('111,150 ₫'),findsWidgets);
    expect(find.textContaining('222,300 ₫'),findsWidgets);
  });
  testWidgets('R1 rules: retire promotion after lost ACK without duplicate mutation', (tester)async{
    var attempts=0,retired=false;
    String? firstKey,firstBody;
    final rule='00000000-0000-4000-8000-000000000090';
    final client=ErpIdentityClient(apiOrigin:'https://erp.example.test',
      httpClient:MockClient((request)async{
        if(request.method=='GET'&&request.url.path=='/v1/catalog/r1/rules'){
          return http.Response(jsonEncode({'items':[{
            'id':rule,'sku':'SP01-T','scopeKind':'PROMOTION',
            'adjustment':'PERCENT_DISCOUNT','amount':'10.0000',
            'priority':1,'retiredAt':retired?'2026-11-21T06:00:00Z':null,
          }]}),200);
        }
        if(request.method=='POST'&&
          request.url.path=='/v1/catalog/r1/rules/$rule/retire'){
          attempts++;
          final key=request.headers['idempotency-key'];
          if(attempts==1){
            firstKey=key;firstBody=request.body;retired=true;
            throw http.ClientException('ACK lost after COMMIT');
          }
          expect(key,firstKey);
          expect(request.body,firstBody);
          final payload=jsonDecode(request.body) as Map<String,dynamic>;
          expect(payload['branchId'],branch);
          expect(payload['reason'],'Chính sách đã hoàn thành');
          return http.Response(jsonEncode({
            'id':rule,'branchId':branch,'retiredAt':'2026-11-21T06:00:00Z',
          }),200);
        }
        return http.Response(jsonEncode({'error':{'code':'NOT_FOUND'}}),404);
      }));
    addTearDown(client.dispose);
    tester.view.devicePixelRatio=1;
    tester.view.physicalSize=const Size(1100,900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(theme:erpTheme(touch:false),home:
      Scaffold(body:SingleChildScrollView(child:R1CatalogWorkspace(
        kind:'rules',branchId:branch,branches:branches,
        client:client,session:session(),changeBranch:(_){},
      )))));
    await tester.pumpAndSettle();
    // DataTable may scroll horizontally; hit testing offscreen text is invalid.
    await tester.ensureVisible(find.text('Kết thúc').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Kết thúc').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last,'Chính sách đã hoàn thành');
    await tester.tap(find.text('Kết thúc chính sách').last);
    await tester.pumpAndSettle();
    expect(attempts,1);
    expect(client.pendingR1(session().actorId,branch,'rules.retire.$rule'),isNotNull);
    await tester.ensureVisible(find.text('Kiểm tra yêu cầu').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Kiểm tra yêu cầu').last);
    await tester.pumpAndSettle();
    expect(attempts,2);
    expect(client.pendingR1(session().actorId,branch,'rules.retire.$rule'),isNull);
    expect(find.text('Đã kết thúc'),findsWidgets);
    await tester.pump(const Duration(seconds:5));
  });

  testWidgets('R1-B base SKU can be stopped after entering mandatory reason',
    (tester)async{
    var patched=false;
    final client=ErpIdentityClient(apiOrigin:'https://erp.example.test',
      httpClient:MockClient((req)async{
        const headers={'content-type':'application/json; charset=utf-8'};
        if(req.url.path=='/v1/catalog/r1/skus'&&req.method=='GET'){
          return http.Response(jsonEncode({'items':[{
            'id':sku,'code':'SP01','productName':'Sản phẩm thử',
            'unitCode':'cai','toBase':'1.000000','isBase':true,
            'active':true,'revision':0,
          }]}),200,headers:headers);
        }
        if(req.method=='GET')return http.Response(
          jsonEncode({'items':sample(req.url.path.replaceFirst('/v1/catalog/',''))}),
          200,headers:headers);
        if(req.url.path=='/v1/catalog/r1/skus/$sku'&&req.method=='PATCH'){
          final payload=jsonDecode(req.body) as Map<String,dynamic>;
          expect(payload['active'],false);
          expect(payload['reason'],'SKU gốc nhập sai mã');
          expect(req.headers['if-match'],'0');
          expect(req.headers['idempotency-key'],isNotNull);
          patched=true;
          return http.Response(jsonEncode({'id':sku,'revision':1}),200,
            headers:headers);
        }
        return http.Response(jsonEncode({'error':{'code':'NOT_FOUND'}}),404);
      }));
    addTearDown(client.dispose);
    tester.view.devicePixelRatio=1;
    tester.view.physicalSize=const Size(390,850);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(theme:erpTheme(touch:true),home:
      Scaffold(body:SingleChildScrollView(child:R1CatalogWorkspace(
        kind:'skus',branchId:branch,branches:branches,
        client:client,session:session(),changeBranch:(_){},
      )))));
    await tester.pumpAndSettle();
    await tester.runAsync(()async=>Future<void>.delayed(const Duration(milliseconds:120)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('r1-edit-$sku')));
    await tester.pumpAndSettle();
    final toggle=find.byKey(const ValueKey('r1-lifecycle-active'));
    expect(toggle,findsOneWidget);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    final save=find.byKey(const ValueKey('r1-lifecycle-save'));
    expect(tester.widget<FilledButton>(save).onPressed,isNull,
      reason:'No SKU may stop without an auditable reason');
    await tester.enterText(find.byKey(const ValueKey('r1-sku-disable-reason')),
      'SKU gốc nhập sai mã');
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(save).onPressed,isNotNull,
      reason:'Entering 3+ chars must enable save');
    await tester.tap(save);
    await tester.pumpAndSettle();
    await tester.runAsync(()async=>Future<void>.delayed(const Duration(milliseconds:150)));
    await tester.pumpAndSettle();
    expect(patched,true);
    expect(tester.takeException(),isNull);
    await tester.pump(const Duration(seconds:5));
  });

}
