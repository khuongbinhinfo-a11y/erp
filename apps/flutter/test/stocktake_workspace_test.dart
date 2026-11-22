import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:erp_distribution/ui/stocktake_workspace.dart';
import 'package:erp_distribution/ui/identity_client.dart';
import 'package:erp_distribution/ui/erp_tokens.dart';

const branch='00000000-0000-4000-8000-000000000001';
const wh='00000000-0000-4000-8000-000000000002';
const actor='00000000-0000-4000-8000-000000000003';
const doc='00000000-0000-4000-8000-000000000004';
void main(){
 testWidgets('R3.4 flat stocktake and count submission only after server acknowledgment',
 (tester)async{
  var submitted=false,submits=0;
  const headers={'content-type':'application/json; charset=utf-8'};
  final client=ErpIdentityClient(apiOrigin:'https://erp.example.test',
    httpClient:MockClient((req)async{
      http.Response ok(Object data,int code)=>http.Response(
        jsonEncode(data),code,headers:headers);
      if(req.url.path=='/v1/inventory/stocktakes/scopes'){
        return ok({'branches':[{'id':branch,'name':'Chi nhánh chính'}],
          'warehouses':req.url.queryParameters.containsKey('branchId')
            ?[{'id':wh,'name':'Kho chính'}]:[]},200);
      }
      if(req.url.path=='/v1/inventory/stocktakes'&&req.method=='GET'){
        return ok({'items':[{'id':doc,'warehouseId':wh,'warehouseName':'Kho chính',
          'status':submitted?'SUBMITTED':'COUNTING','revision':submitted?2:1,
          'lineCount':1,'adjustmentCount':0}],'hasMore':false},200);
      }
      if(req.url.path=='/v1/inventory/stocktakes/$doc/submit'){
        submits++;
        expect(req.headers['if-match'],'1');
        final body=jsonDecode(req.body) as Map<String,dynamic>;
        expect(body['branchId'],branch);
        expect(body['warehouseId'],wh);
        submitted=true;
        return ok({'id':doc,'status':'SUBMITTED','revision':2},200);
      }
      return ok({'error':{'code':'NOT_FOUND'}},404);
    }));
  addTearDown(client.dispose);
  tester.view.physicalSize=const Size(1200,800);
  tester.view.devicePixelRatio=1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final session=IdentitySession(actorId:actor,token:'synthetic-token',
    expiresAt:DateTime.now().add(const Duration(hours:1)),grants:const [
      IdentityGrant(roleId:'read',permission:'inventory.stocktake.read',
        branchId:branch,warehouseId:wh),
      IdentityGrant(roleId:'submit',permission:'inventory.stocktake.submit',
        branchId:branch,warehouseId:wh),
    ]);
  await tester.pumpWidget(MaterialApp(theme:erpTheme(touch:false),
    home:Scaffold(body:SingleChildScrollView(
      child:StocktakeWorkspace(client:client,session:session)))));
  for(var i=0;i<5;i++){
    await tester.runAsync(()async=>Future<void>.delayed(const Duration(milliseconds:70)));
    await tester.pumpAndSettle();
  }
  expect(find.text('Kiểm kê và chênh lệch kho'),findsOneWidget);
  expect(find.text('Kho chính · Đang kiểm đếm'),findsOneWidget);
  expect(find.byType(Card),findsNothing);
  expect(find.text('Gửi duyệt'),findsOneWidget);
  expect(submits,0);
  await tester.tap(find.text('Gửi duyệt'));
  await tester.pumpAndSettle();
  expect(find.text('Gửi duyệt'),findsWidgets);
  await tester.tap(find.descendant(of:find.byType(AlertDialog),
    matching:find.text('Xác nhận')));
  for(var i=0;i<4;i++){
    await tester.runAsync(()async=>Future<void>.delayed(const Duration(milliseconds:70)));
    await tester.pumpAndSettle();
  }
  expect(submits,1);
  expect(find.text('Kho chính · Chờ duyệt'),findsOneWidget);
  await tester.pump(const Duration(seconds:5));
  await tester.pumpAndSettle();
 });
}
