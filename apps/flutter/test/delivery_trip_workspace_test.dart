import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:erp_distribution/ui/delivery_trip_workspace.dart';
import 'package:erp_distribution/ui/identity_client.dart';
import 'package:erp_distribution/ui/erp_tokens.dart';

const b='00000000-0000-4000-8000-000000000001';
const w='00000000-0000-4000-8000-000000000009';
const tid='00000000-0000-4000-8000-000000000026';
const oid='00000000-0000-4000-8000-000000000027';
void main(){
  testWidgets('T5-B trip dispatcher lists scoped routes, order stops and does not post on read',
      (tester)async{
    var writes=0,detailReads=0;
    final client=ErpIdentityClient(apiOrigin:'https://erp.example.test',
      httpClient:MockClient((req)async{
        if(req.method!='GET')writes++;
        if(req.headers['authorization']!='Bearer local-test-token'){
          return http.Response('{}',401);
        }
        Object data;
        switch(req.url.path){
          case '/v1/admin/scopes':
            data={'branches':[{'id':b,'code':'MAIN','name':'Chi nhánh chính'}],
              'warehouses':[{'id':w,'branchId':b,'code':'K01','name':'Kho trung tâm'}]};
          case '/v1/delivery/trips':
            data={'items':[{'id':tid,'tripNo':'TG-20261128-000001',
              'status':'DRAFT','revision':0,'plannedDate':'2026-11-28',
              'stopCount':1}]};
          case '/v1/delivery/drivers':
            data={'items':[]};
          case '/v1/delivery/vehicles':
            data={'items':[]};
          case '/v1/delivery/trips/eligible':
            data={'items':[]};
          case '/v1/delivery/trips/$tid':
            detailReads++;
            data={'trip':{'id':tid,'tripNo':'TG-20261128-000001',
              'status':'DRAFT','revision':0,'plannedDate':'2026-11-28',
              'stops':[{'orderId':oid,'documentNo':'SO-20261128-000001',
                'customerName':'Khách A','deliveryAddress':'Đường A, Mỹ Tho'}]}};
          default:
            return http.Response('{}',404);
        }
        return http.Response(jsonEncode(data),200,
          headers:const {'content-type':'application/json; charset=utf-8'});
      }));
    addTearDown(client.dispose);
    final session=IdentitySession(actorId:'actor',token:'local-test-token',
      expiresAt:DateTime.now().add(const Duration(hours:1)),
      grants:[
        IdentityGrant(roleId:'d',permission:'delivery.read',branchId:b),
        IdentityGrant(roleId:'u',permission:'delivery.update',branchId:b),
        IdentityGrant(roleId:'o',permission:'orders.read',branchId:b),
        IdentityGrant(roleId:'i',permission:'inventory.read',branchId:b,warehouseId:w),
      ]);
    tester.view.physicalSize=const Size(1280,920);
    tester.view.devicePixelRatio=1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(theme:erpTheme(touch:false),
      home:Scaffold(body:SingleChildScrollView(
        child:DeliveryTripWorkspace(client:client,session:session)))));
    await tester.pumpAndSettle();
    expect(find.text('Điều phối giao hàng'),findsOneWidget);
    expect(find.byKey(const ValueKey('trip-create')),findsOneWidget);
    expect(find.byKey(const ValueKey('trip-row-$tid')),findsOneWidget);
    expect(writes,0);
    await tester.tap(find.byKey(const ValueKey('trip-row-$tid')));
    await tester.pumpAndSettle();
    expect(detailReads,1);
    expect(find.textContaining('Khách A · SO-20261128-000001'),findsOneWidget);
    expect(find.text('Phân xe, tài xế'),findsOneWidget);
    expect(writes,0,reason:'Reading a trip cannot dispatch, stock-out or collect money');
  });
}
