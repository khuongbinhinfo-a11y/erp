import 'dart:convert';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:erp_distribution/ui/identity_client.dart';
import 'package:erp_distribution/ui/sales_workspace.dart';
import 'package:erp_distribution/ui/erp_tokens.dart';

const branch='00000000-0000-4000-8000-000000000001';
const actor='00000000-0000-4000-8000-000000000002';
const customer='00000000-0000-4000-8000-000000000003';
const location2='00000000-0000-4000-8000-000000000004';
const location3='00000000-0000-4000-8000-000000000005';
const warehouse='00000000-0000-4000-8000-000000000009';

void main(){
  testWidgets('UX-A: primary and secondary addresses coexist and do not overwrite the customer',
    (tester)async{
    final client=ErpIdentityClient(apiOrigin:'https://erp.example.test',
      httpClient:MockClient((request)async{
        http.Response reply(Map<String,dynamic> body)=>
          http.Response(jsonEncode(body),200,
            headers:{'content-type':'application/json; charset=utf-8'});
        switch(request.url.path){
          case '/v1/catalog/branches':return reply({'items':[{'id':branch,'name':'Chính','code':'MAIN'}]});
          case '/v1/catalog/customers':return reply({'items':[
            {'id':customer,'name':'Khách A','code':'KH01','active':true,
              'deliveryAddress':'10 Nguyễn Huệ, Quận 1'}]});
          case '/v1/catalog/customers/$customer/locations':return reply({'items':[
            {'id':location2,'name':'Đại lý 2','address':'20 Pasteur, Quận 1','active':true},
            {'id':location3,'name':'Địa chỉ giao hàng','address':'30 Lê Lợi, Quận 1','active':true}
          ]});
          case '/v1/catalog/warehouses':return reply({'items':[{'id':warehouse,'name':'Kho chính','code':'MAIN'}]});
          case '/v1/catalog/price-lists':return reply({'items':[{'id':'00000000-0000-4000-8000-000000000008','name':'Giá bán','code':'SELL','active':true}]});
          case '/v1/catalog/r1/skus':return reply({'items':[{'id':'00000000-0000-4000-8000-000000000007','productId':'00000000-0000-4000-8000-000000000006','sku':'P01','code':'P01','productName':'Hàng A','unitCode':'cai','active':true}]});
          case '/v1/catalog/r1/channels':return reply({'items':[]});
          case '/v1/inventory/balances':return reply({'items':[]});
          case '/v1/sales/entry-settings':return reply({'settings':{'deliveryChoice':'MANUAL','walkInCustomer':null}});
          case '/v1/sales/orders':return reply({'items':[]});
          default:return http.Response(jsonEncode({'error':{'code':'NOT_FOUND'}}),404);
        }
      }));
    addTearDown(client.dispose);
    tester.view.devicePixelRatio=1;
    tester.view.physicalSize=const Size(1280,900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session=IdentitySession(actorId:actor,token:'test',
      expiresAt:DateTime.now().add(const Duration(hours:1)),grants:const [
        IdentityGrant(roleId:'create',permission:'orders.create',branchId:branch),
        IdentityGrant(roleId:'read',permission:'orders.read',branchId:branch),
        IdentityGrant(roleId:'catalog',permission:'catalog.read',branchId:branch),
        IdentityGrant(roleId:'stock',permission:'inventory.read',branchId:branch,warehouseId:warehouse),
      ]);
    await tester.pumpWidget(MaterialApp(theme:erpTheme(touch:false),
      home:Scaffold(body:SalesWorkspace(client:client,session:session))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sales-create')));
    await tester.pumpAndSettle();
    final selectPrimary=find.byKey(const ValueKey('sales-location-$customer-null-0'));
    expect(selectPrimary,findsOneWidget);
    await tester.ensureVisible(selectPrimary);
    await tester.tap(selectPrimary);
    await tester.pumpAndSettle();
    expect(find.text('Địa chỉ chính · 10 Nguyễn Huệ, Quận 1'),findsWidgets);
    expect(find.text('Đại lý 2 · 20 Pasteur, Quận 1'),findsWidgets);
    expect(find.text('30 Lê Lợi, Quận 1'),findsWidgets);
    await tester.tap(find.text('Đại lý 2 · 20 Pasteur, Quận 1').last);
    await tester.pumpAndSettle();
    // A selected saved address occupies exactly one control, not a duplicate
    // read-only field in a second row.
    expect(find.byKey(const ValueKey('sales-delivery-address-$customer-1')),findsNothing);
    final selectSecondary=find.byKey(const ValueKey('sales-location-$customer-$location2-1'));
    expect(tester.widget<DropdownButtonFormField<String>>(selectSecondary).initialValue,location2);
    await tester.tap(selectSecondary);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Địa chỉ chính · 10 Nguyễn Huệ, Quận 1').last);
    await tester.pumpAndSettle();
    final primarySelected=find.byKey(const ValueKey('sales-location-$customer-null-2'));
    expect(tester.widget<DropdownButtonFormField<String>>(primarySelected).initialValue,'__primary__');
    expect(find.byKey(const ValueKey('sales-delivery-address-$customer-2')),findsNothing);
    await tester.tap(primarySelected);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Nhập địa chỉ khác').last);
    await tester.pumpAndSettle();
    final manual=find.byKey(const ValueKey('sales-delivery-address-$customer-3'));
    expect(manual,findsOneWidget);
    await tester.enterText(manual,'99 Lý Tự Trọng');
    expect(tester.widget<EditableText>(find.descendant(of:manual,
      matching:find.byType(EditableText))).controller.text,'99 Lý Tự Trọng');
  });
}
