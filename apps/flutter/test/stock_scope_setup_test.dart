import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:erp_distribution/ui/stock_scope_setup.dart';
import 'package:erp_distribution/ui/identity_client.dart';

const branch='00000000-0000-4000-8000-000000000001';
const warehouse='00000000-0000-4000-8000-000000000002';
const product='00000000-0000-4000-8000-000000000003';
const location='00000000-0000-4000-8000-000000000004';
const lot='00000000-0000-4000-8000-000000000005';
const actor='00000000-0000-4000-8000-000000000006';

void main(){
 testWidgets('T3-B classifies existing stock by lot/bin only after explicit approval',(tester)async{
  final methods=<String>[];
  final client=ErpIdentityClient(apiOrigin:'https://erp.example.test',
   httpClient:MockClient((req)async{
    methods.add(req.method);
    final payload=switch(req.url.path){
     '/v1/catalog/products'=>{'items':[{
       'id':product,'code':'P1','name':'Sản phẩm A','active':true}]},
     '/v1/inventory/stock-scopes'=>{
       'policy':{'requireLocation':false,'requireLot':false,'revision':'0'},
       'locations':[{'id':location,'code':'A-1','name':'Kệ 1'}],
       'lots':[{'id':lot,'lotCode':'LO-01','expiryDate':null}],
       'scopes':[]},
     _=>throw StateError('Unexpected route ${req.url.path}')
    };
    return http.Response(jsonEncode(payload),200,headers:const {
      'content-type':'application/json; charset=utf-8'});
   }));
  addTearDown(client.dispose);
  tester.view.devicePixelRatio=1;
  tester.view.physicalSize=const Size(1100,900);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final session=IdentitySession(actorId:actor,token:'synthetic-token',
    expiresAt:DateTime.now().add(const Duration(hours:1)),grants:[]);
  String? selectedAction;
  Map<String,dynamic>? selectedBody;
  int? selectedRevision;
  await tester.pumpWidget(MaterialApp(home:Scaffold(body:Builder(builder:(ctx)=>
    FilledButton(onPressed:()async{
      await showStockScopeSetup(context:ctx,client:client,session:session,
       branchId:branch,warehouseId:warehouse,
       canManagePolicy:false,canAssign:true,
       onSubmit:(action,body,revision)async{
         selectedAction=action;selectedBody=body;selectedRevision=revision;
       });
    },child:const Text('Cấu hình tồn kho'))))));
  await tester.tap(find.text('Cấu hình tồn kho'));
  await tester.pumpAndSettle();
  expect(find.text('Quản lý lô và vị trí kho'),findsOneWidget);
  expect(methods,everyElement('GET'));
  await tester.tap(find.text('Tiếp tục'));
  await tester.pumpAndSettle();
  expect(find.text('Thiết lập lô/vị trí'),findsOneWidget);
  expect(selectedAction,isNull);
  await tester.tap(find.text('Chọn Vị trí kho'));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('stock-scope-choice-location-$location')));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Chọn Lô hàng'));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('stock-scope-choice-lot-$lot')));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField).last,'2.5');
  await tester.tap(find.byKey(const ValueKey('t3b-scope-confirm')));
  await tester.pumpAndSettle();
  expect(selectedAction,'stock-scopes/assign');
  expect(selectedBody,{
   'branchId':branch,'warehouseId':warehouse,'productId':product,
   'quantityBase':'2.500000','locationId':location,'lotId':lot});
  expect(selectedRevision,0);
  expect(methods,everyElement('GET'),
   reason:'No stock mutation may be sent before parent idempotent action');
 });
}
