import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:erp_distribution/ui/org_directory_workspace.dart';
import 'package:erp_distribution/ui/identity_client.dart';

const branch='00000000-0000-4000-8000-000000000001';
const warehouse='00000000-0000-4000-8000-000000000002';
const actor='00000000-0000-4000-8000-000000000003';
void main(){
 testWidgets('Owner sees Vietnamese branch/warehouse names and saves real negative policy', (tester)async{
   final mutations=<Map<String,dynamic>>[];
   const headers={'content-type':'application/json; charset=utf-8'};
   final grants=[
     {'roleId':'r','permission':'identity.roles.manage'},
     {'roleId':'r','permission':'inventory.policy.manage',
      'branchId':branch,'warehouseId':warehouse},
     {'roleId':'r','permission':'inventory.read',
      'branchId':branch,'warehouseId':warehouse},
   ];
   final client=ErpIdentityClient(apiOrigin:'https://erp.example.test',
     httpClient:MockClient((request)async{
      final path=request.url.path;
      if(path=='/v1/admin/scopes'){
        return http.Response(jsonEncode({
         'branches':[{'id':branch,'name':'Chi nhánh chính','code':'MAIN'}],
         'warehouses':[{'id':warehouse,'branchId':branch,'name':'Kho chính','code':'MAIN'}],
         'hasMoreBranches':false,'hasMoreWarehouses':false}),200,headers:headers);
      }
      if(path=='/v1/auth/session'){
        return http.Response(jsonEncode({'actorId':actor,
         'installationId':'00000000-0000-4000-8000-000000000004',
         'loginName':'admin','expiresAt':'2099-01-01T00:00:00Z',
         'grants':grants}),200,headers:headers);
      }
      if(path=='/v1/inventory/guard-policy'&&request.method=='GET'){
        return http.Response(jsonEncode({'policy':{
          'reserveShortageMode':'WARN','negativeIssueMode':'BLOCK','revision':0}}),200,headers:headers);
      }
      if(path=='/v1/inventory/guard-policy'&&request.method=='POST'){
        mutations.add(jsonDecode(request.body) as Map<String,dynamic>);
        expect(request.headers['if-match'],'0');
        expect(request.headers['idempotency-key'],isNotEmpty);
        return http.Response(jsonEncode({'reserveShortageMode':'WARN',
          'negativeIssueMode':'ALLOW','revision':1}),200,headers:headers);
      }
      throw StateError('Unexpected method/path: ${request.method} $path');
   }));
   addTearDown(client.dispose);
   tester.view.devicePixelRatio=1;
   tester.view.physicalSize=const Size(1100,950);
   addTearDown(tester.view.resetDevicePixelRatio);
   addTearDown(tester.view.resetPhysicalSize);
   final session=IdentitySession(actorId:actor,token:'test-token',
    expiresAt:DateTime.now().add(const Duration(hours:1)),grants:const [
      IdentityGrant(roleId:'r',permission:'identity.roles.manage'),
      IdentityGrant(roleId:'r',permission:'inventory.read',
       branchId:branch,warehouseId:warehouse),
      IdentityGrant(roleId:'r',permission:'inventory.policy.manage',
       branchId:branch,warehouseId:warehouse),
    ]);
   await tester.pumpWidget(MaterialApp(home:Scaffold(body:SingleChildScrollView(
     child:OrgDirectoryWorkspace(client:client,session:session)))));
   await tester.pumpAndSettle();
   expect(find.text('Chi nhánh chính'),findsWidgets);
   expect(find.text('Kho chính'),findsOneWidget);
   expect(find.text('MAIN'),findsNothing);
   expect(find.text('Thêm chi nhánh'),findsOneWidget);
   expect(find.text('Thêm kho'),findsOneWidget);
   await tester.tap(find.text('Xuất âm / giữ hàng'));
   await tester.pumpAndSettle();
   expect(find.text('Cho phép xuất vượt tồn'),findsOneWidget);
   await tester.tap(find.text('Không cho phép (mặc định)'));
   await tester.pumpAndSettle();
   await tester.tap(find.text('Cho phép xuất âm có kiểm soát').last);
   await tester.pumpAndSettle();
   await tester.tap(find.text('Lưu chính sách'));
   await tester.pumpAndSettle();
   expect(mutations,single);
   expect(mutations.single['negativeIssueMode'],'ALLOW');
   expect(mutations.single['warehouseId'],warehouse);
   expect(tester.takeException(),isNull);
 });
}
