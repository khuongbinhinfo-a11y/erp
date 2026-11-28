import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:erp_distribution/ui/admin_workspace.dart';
import 'package:erp_distribution/ui/identity_client.dart';
import 'package:erp_distribution/ui/erp_tokens.dart';

void main() {
  testWidgets('permission dialogs show real branch and warehouse names, not UUIDs',
    (tester) async {
    const branch = '00000000-0000-4000-8000-000000000001';
    const warehouse = '00000000-0000-4000-8000-000000000002';
    const target = '00000000-0000-4000-8000-000000000003';
    final requests = <String>[];
    const headers = {'content-type':'application/json; charset=utf-8'};
    final client = ErpIdentityClient(apiOrigin:'https://erp.example.test',
      httpClient:MockClient((req) async {
        requests.add(req.url.path);
        if (req.url.path == '/v1/admin/users') {
          return http.Response(jsonEncode({'users':[
            {'id':target,'loginName':'nhan_vien_1','revision':0,'disabled':false}
          ]}),200,headers:headers);
        }
        if(req.url.path=='/v1/admin/permissions'){
          return http.Response(jsonEncode({'permissions':[
            {'code':'identity.users.read','scope':'installation'},
            {'code':'inventory.read','scope':'warehouse'},
            {'code':'inventory.policy.manage','scope':'warehouse'},
          ]}),200,headers:headers);
        }
        if(req.url.path=='/v1/admin/audit'){
          return http.Response(jsonEncode({'events':[]}),200,headers:headers);
        }
        if (req.url.path == '/v1/admin/scopes') {
          return http.Response(jsonEncode({
            'branches':[{'id':branch,'code':'CN01','name':'Chi nhánh miền Nam'}],
            'warehouses':[{'id':warehouse,'branchId':branch,
              'code':'K01','name':'Kho trung tâm'}],
          }),200,headers:headers);
        }
        if (req.url.path == '/v1/admin/users/$target/grants') {
          return http.Response(jsonEncode({'grants':[
            {'roleId':'grant1','permission':'inventory.read',
              'branchId':branch,'warehouseId':warehouse}
          ]}),200,headers:headers);
        }
        return http.Response(jsonEncode({'error':{'code':'NOT_FOUND'}}),
          404,headers:headers);
      }));
    addTearDown(client.dispose);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = IdentitySession(actorId:target,token:'synthetic-token',
      expiresAt:DateTime.now().add(const Duration(hours:1)),grants:const [
        IdentityGrant(roleId:'r1',permission:'identity.users.read'),
        IdentityGrant(roleId:'r2',permission:'identity.roles.manage'),
        IdentityGrant(roleId:'r3',permission:'inventory.read',
          branchId:branch,warehouseId:warehouse),
      ]);
    await tester.pumpWidget(MaterialApp(theme:erpTheme(touch:false),
      home:Scaffold(body:AdminWorkspace(previewOnly:false,
        client:client,session:session))));
    await tester.pumpAndSettle();
    expect(requests,contains('/v1/admin/scopes'));
    expect(requests,isNot(contains('/v1/admin/users')));
    await tester.tap(find.text('Tài khoản').last);
    await tester.pumpAndSettle();
    expect(requests,contains('/v1/admin/users'));
    await tester.tap(find.byTooltip('Cấp quyền'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('admin-grant-selector')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Xem tồn kho'),findsWidgets);
    expect(find.textContaining('Kho trung tâm (K01)'),findsWidgets);
    expect(find.textContaining('Chi nhánh miền Nam'),findsWidgets);
    expect(find.textContaining('inventory.read'),findsNothing);
    expect(find.textContaining('00000000-0000'),findsNothing);
    // Close the open dropdown overlay before tapping the dialog action.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hủy').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Thu quyền'));
    await tester.pumpAndSettle();
    expect(requests,contains('/v1/admin/users/$target/grants'));
    expect(find.text('Xem tồn kho'),findsOneWidget);
    expect(find.textContaining('Kho trung tâm (K01)'),findsOneWidget);
    expect(find.textContaining('00000000-0000'),findsNothing);
    await tester.tap(find.text('Đóng').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Phân quyền').last);
    await tester.pumpAndSettle();
    expect(requests,contains('/v1/admin/permissions'));
    expect(find.text('Ma trận quyền'),findsOneWidget);
    expect(find.text('Đã cấp'),findsWidgets);
  });
}
