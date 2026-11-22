import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:erp_distribution/ui/company_workspace.dart';
import 'package:erp_distribution/ui/erp_tokens.dart';
import 'package:erp_distribution/ui/identity_client.dart';

const branch='00000000-0000-4000-8000-000000000001';
const actor='00000000-0000-4000-8000-000000000002';
final rights=[
  const IdentityGrant(roleId:'r',permission:'catalog.read',branchId:branch),
  const IdentityGrant(roleId:'w',permission:'catalog.write',branchId:branch),
];
http.Response reply(Object value,[int status=200])=>http.Response(jsonEncode(value),
  status,headers:const {'content-type':'application/json; charset=utf-8'});

Future<void> flush(WidgetTester tester)async{
  await tester.pumpAndSettle();
  await tester.runAsync(()async=>Future<void>.delayed(const Duration(milliseconds:120)));
  await tester.pumpAndSettle();
}

void main(){
  testWidgets('product fast setup submits exact 3 SKU and barcodes with same retry receipt',
    (tester)async{
    var attempts=0,complete=false;
    final keys=<String?>[],bodies=<String>[];
    final client=ErpIdentityClient(apiOrigin:'https://erp.example.test',
      httpClient:MockClient((req)async{
        if(req.url.path=='/v1/catalog/branches'){
          return reply({'items':[{'id':branch,'code':'MAIN','name':'Chi nhánh chính'}]});
        }
        if(req.url.path=='/v1/catalog/groups'&&req.method=='GET'){
          return reply({'items':[]});
        }
        if(req.url.path=='/v1/catalog/products'&&req.method=='GET'){
          return reply({'items':complete?[{
            'id':'product-1','code':'SP-001','name':'Nước uống',
            'baseUnit':'chai','sellSkuCount':3,'barcode':'BAR-BASE-01',
            'active':true,'revision':0,
          }]:[]});
        }
        if(req.url.path=='/v1/catalog/products'&&req.method=='POST'){
          attempts++;
          keys.add(req.headers['idempotency-key']);
          bodies.add(req.body);
          expect(req.headers['if-match'],'0');
          if(attempts==1)throw http.ClientException('lost ACK after COMMIT');
          if(attempts==2)return reply({'error':{'code':'AUTH_DENIED'}},401);
          complete=true;
          return reply({'id':'product-1','revision':0,'variants':[
            {'id':'s1','sku':'SP-001','unitCode':'chai'},
            {'id':'s2','sku':'SP-THUNG','unitCode':'thung'},
            {'id':'s3','sku':'SP-LOC','unitCode':'loc'},
          ]},201);
        }
        if(req.url.path=='/v1/auth/config')return reply({'enabled':true});
        return reply({'items':[]});
      }));
    addTearDown(client.dispose);
    tester.view.devicePixelRatio=1;
    tester.view.physicalSize=const Size(1440,1000);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(theme:erpTheme(touch:false),
      home:Scaffold(body:CompanyWorkspace(previewOnly:false,
        grants:rights,session:IdentitySession(actorId:actor,token:'test-token',
          expiresAt:DateTime.now().add(const Duration(hours:1)),grants:rights),
        client:client))));
    await tester.tap(find.byKey(const ValueKey('company-CompanySection.products')));
    await flush(tester);
    await tester.tap(find.byKey(const ValueKey('catalog-create')));
    await flush(tester);
    await tester.enterText(find.byKey(const ValueKey('catalog-create-code')),'SP-001');
    await tester.enterText(find.byKey(const ValueKey('catalog-create-name')),'Nước uống');
    await tester.enterText(find.byKey(const ValueKey('catalog-base-barcode')),'BAR-BASE-01');
    await tester.enterText(find.byKey(const ValueKey('catalog-conversion-unit-0')),'thung');
    await tester.enterText(find.byKey(const ValueKey('catalog-conversion-factor-0')),'24');
    await tester.enterText(find.byKey(const ValueKey('catalog-conversion-sku-0')),'SP-THUNG');
    await tester.enterText(find.byKey(const ValueKey('catalog-conversion-barcode-0')),'BAR-THUNG-01');
    await tester.ensureVisible(find.byKey(const ValueKey('catalog-add-unit-row')));
    await tester.tap(find.byKey(const ValueKey('catalog-add-unit-row')));
    await flush(tester);
    await tester.enterText(find.byKey(const ValueKey('catalog-conversion-unit-1')),'loc');
    await tester.enterText(find.byKey(const ValueKey('catalog-conversion-factor-1')),'6');
    await tester.enterText(find.byKey(const ValueKey('catalog-conversion-sku-1')),'SP-LOC');
    await tester.enterText(find.byKey(const ValueKey('catalog-conversion-barcode-1')),'BAR-LOC-01');
    await tester.ensureVisible(find.byKey(const ValueKey('catalog-create-confirm')));
    await tester.tap(find.byKey(const ValueKey('catalog-create-confirm')));
    await flush(tester);
    expect(attempts,1);
    expect(find.text('Kiểm tra yêu cầu trước'),findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('catalog-create')));
    await flush(tester);
    expect(attempts,2);
    await tester.tap(find.byKey(const ValueKey('catalog-create')));
    await flush(tester);
    expect(attempts,3);
    final payload=jsonDecode(bodies[0]) as Map<String,dynamic>;
    expect(payload['code'],'SP-001');
    expect(payload['barcode'],'BAR-BASE-01');
    expect(payload['units'],[
      {'unitCode':'thung','toBase':'24','sku':'SP-THUNG','barcode':'BAR-THUNG-01'},
      {'unitCode':'loc','toBase':'6','sku':'SP-LOC','barcode':'BAR-LOC-01'},
    ]);
    expect(keys[0],isNotNull);
    expect(keys[0],keys[1]);
    expect(keys[1],keys[2]);
    expect(bodies[0],bodies[1]);
    expect(bodies[1],bodies[2]);
    expect(find.text('Kiểm tra yêu cầu trước'),findsNothing);
    expect(find.text('Nước uống'),findsOneWidget);
    // Toast uses a four-second fake timer; complete it before teardown.
    await tester.pump(const Duration(seconds:5));
    await tester.pumpAndSettle();
  });
}
