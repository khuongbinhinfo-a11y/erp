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
    final eligibleOffsets=<String>[];
    final pagedQueries=<String>[];
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
            data={'items':[{'id':'00000000-0000-4000-8000-000000000091',
              'code':'TX01','name':'Tài xế Thử','active':true}]};
          case '/v1/delivery/vehicles':
            data={'items':[{'id':'00000000-0000-4000-8000-000000000092',
              'code':'XE01','name':'Xe thử','licensePlate':'59C-12345',
              'active':true}]};
          case '/v1/delivery/trips/eligible':
            eligibleOffsets.add(req.url.queryParameters['offset']??'0');
            pagedQueries.add(req.url.queryParameters['q']??'');
            final filtered=List.generate(201,(i)=> {
              'id':'00000000-0000-4000-8000-${i.toString().padLeft(12,'0')}',
              'documentNo':'SO-20261128-${i.toString().padLeft(6,'0')}',
              'customerName':'Điểm giao ${i+1}',
              'deliveryAddress':'Địa chỉ ${i+1}',
            }).where((o){
              final query=req.url.queryParameters['q']??'';
              return query.isEmpty||o['documentNo']!.contains(query);
            }).toList();
            final offset=int.tryParse(req.url.queryParameters['offset']??'0')??0;
            data={'items':filtered.skip(offset).take(200).toList()};
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
    await tester.tap(find.byKey(const ValueKey('trip-add-orders')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('trip-select-all-orders')));
    await tester.pumpAndSettle();
    expect(find.text('Thêm 100 đơn'),findsOneWidget,
      reason:'Select all must respect the atomic 100-order API limit.');
    expect(find.text('Thêm 101 đơn'),findsNothing);
    // Merely typing must not silently change the submitted search applied
    // to existing rows/page offset. The Load More request must use q=''.
    await tester.enterText(find.byKey(const ValueKey('trip-eligible-search')),
      'SO-20261128-000200');
    await tester.tap(find.byKey(const ValueKey('trip-eligible-load-more')));
    await tester.pumpAndSettle();
    expect(eligibleOffsets,contains('200'),
      reason:'Load more must fetch the 201st eligible order from the backend');
    expect(pagedQueries.last,isEmpty,
      reason:'An unsubmitted query must not combine with offset=200');
    await tester.tap(find.byTooltip('Tìm đơn chờ gán'));
    await tester.pumpAndSettle();
    await tester.pumpAndSettle();
    expect(find.textContaining('Điểm giao 201'),findsOneWidget);
    expect(find.textContaining('Điểm giao 1 ·'),findsNothing);
    expect(find.text('Thêm 100 đơn'),findsOneWidget,
      reason:'Search/paging must preserve selected ids without posting');
    await tester.tap(find.widgetWithText(TextButton,'Hủy').last);
    await tester.pumpAndSettle();
    expect(writes,0);

    // Regression: focused fields remain owned by Flutter until each
    // AlertDialog's reverse transition has fully unmounted.
    Future<void> cancelFocusedDialog(Finder trigger)async{
      await tester.tap(trigger);
      await tester.pumpAndSettle();
      final fields=find.byType(TextFormField);
      expect(fields,findsWidgets);
      await tester.enterText(fields.first,'Test nhập rồi hủy');
      await tester.tap(find.widgetWithText(TextButton,'Hủy').last);
      await tester.pumpAndSettle();
      expect(tester.takeException(),isNull);
      expect(writes,0,reason:'Cancelling a draft dialog must not POST');
    }
    await cancelFocusedDialog(find.byKey(const ValueKey('trip-create')));
    await cancelFocusedDialog(find.widgetWithText(OutlinedButton,'Thêm tài xế'));
    await cancelFocusedDialog(find.widgetWithText(OutlinedButton,'Thêm xe'));
    await cancelFocusedDialog(find.byKey(const ValueKey('trip-plan')));
  });
}
