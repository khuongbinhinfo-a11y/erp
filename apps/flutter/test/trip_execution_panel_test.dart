import 'dart:convert';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:erp_distribution/ui/identity_client.dart';
import 'package:erp_distribution/ui/trip_execution_panel.dart';
import 'package:erp_distribution/ui/erp_tokens.dart';

const b='11111111-1111-4111-8111-111111111111';
const w='22222222-2222-4222-8222-222222222222';
const t='33333333-3333-4333-8333-333333333333';
const o='44444444-4444-4444-8444-444444444444';
const d='55555555-5555-4555-8555-555555555555';

void main(){
 testWidgets('T5-D mobile detail is read-only, and cancelled execution sheets never post',
 (tester)async{
  var writes=0,reads=0;
  final client=ErpIdentityClient(apiOrigin:'https://erp.example.test',
   httpClient:MockClient((req)async{
    if(req.method!='GET')writes++;
    if(req.headers['authorization']!='Bearer test-token'){
     return http.Response('{}',401);
    }
    if(req.url.path!='/v1/delivery/execution/read'){
     return http.Response('{}',404);
    }
    reads++;
    return http.Response(jsonEncode({'execution':{
     'tripId':t,'tripNo':'TG-20261128-000001','status':'DEPARTED','revision':3,
     'driverId':'66666666-6666-4666-8666-666666666666',
     'collections':[],
     'stops':[{
      'orderId':o,'revision':5,'sequenceNo':1,'customerName':'Khách giao',
      'documentNo':'SO-20261128-000001','deliveryAddress':'Đường A',
      'due':'2000','paid':'0','remaining':'2000',
      'attempts':[],
      'lines':[{
       'dispatchId':d,'sourceLine':1,'productName':'Sản phẩm A',
       'baseUnit':'cai','issuedBase':'4.000000','deliveredBase':'2.000000',
       'returnedBase':'0.000000','onVehicleBase':'2.000000'
      }]
     }]
    }}),200,headers:const {'content-type':'application/json'});
   }));
  addTearDown(client.dispose);
  final session=IdentitySession(actorId:'driver',token:'test-token',
   expiresAt:DateTime.now().add(const Duration(hours:2)),grants:[
    IdentityGrant(roleId:'d',permission:'delivery.execute',branchId:b),
    IdentityGrant(roleId:'m',permission:'delivery.update',branchId:b),
    IdentityGrant(roleId:'h',permission:'delivery.cod.handover',branchId:b),
    IdentityGrant(roleId:'p',permission:'finance.payments.record',branchId:b),
    IdentityGrant(roleId:'r',permission:'inventory.read',branchId:b,warehouseId:w),
    IdentityGrant(roleId:'i',permission:'inventory.post',branchId:b,warehouseId:w),
   ]);
  tester.view.physicalSize=const Size(420,900);
  tester.view.devicePixelRatio=1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(theme:erpTheme(touch:true),
   home:Scaffold(body:SingleChildScrollView(child:TripExecutionPanel(
    client:client,session:session,branchId:b,warehouseId:w,tripId:t)))));
  await tester.pumpAndSettle();
  expect(reads,1);
  expect(writes,0);
  await tester.tap(find.byKey(const ValueKey('exec-stop-$o')));
  await tester.pumpAndSettle();
  for(final action in ['Xác nhận giao','Nhập trả','Thu COD']){
   await tester.tap(find.text(action).first);
   await tester.pumpAndSettle();
   if(action!='Xác nhận giao')expect(find.byType(TextFormField),findsWidgets);
   else expect(find.textContaining('Kết quả giao'),findsWidgets);
   await tester.tapAt(const Offset(8,8)); // dismiss modal barrier, no POST
   await tester.pumpAndSettle();
   expect(tester.takeException(),isNull,reason:'No disposed controller during reverse animation');
   expect(writes,0,reason:'Cancelled action cannot create a server mutation');
  }
 });
}
