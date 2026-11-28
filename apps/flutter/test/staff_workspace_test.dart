import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:erp_distribution/ui/staff_workspace.dart';
import 'package:erp_distribution/ui/identity_client.dart';
import 'package:erp_distribution/ui/erp_tokens.dart';

const branch='00000000-0000-4000-8000-000000000001';
const staffId='00000000-0000-4000-8000-000000000002';
void main(){
 testWidgets('IA-A: Company manages canonical staff without warehouse/delivery',
  (tester)async{
   final writes=<http.Request>[];
   final client=ErpIdentityClient(apiOrigin:'https://erp.example.test',
    httpClient:MockClient((req)async{
     Object result;
     if(req.url.path=='/v1/org/employees/branches'){
      result={'items':[{'id':branch,'code':'MAIN','name':'Chi nhánh chính'}]};
     }else if(req.url.path=='/v1/org/employees'&&req.method=='GET'){
      result={'items':[{'id':staffId,'code':'NV01','fullName':'Nhân viên kho',
        'department':'Kho vận','jobTitle':'Thủ kho','phone':'0912345678',
        'active':true,'revision':0,'linkedDriver':false,'accountUserId':null}]};
     }else if(req.url.path=='/v1/org/employees'&&req.method=='POST'){
      writes.add(req);result={'employee':{
        'id':'00000000-0000-4000-8000-000000000003','revision':0}};
     }else if(req.url.path=='/v1/org/employees/$staffId'&&req.method=='PATCH'){
      writes.add(req);result={'employee':{'id':staffId,'revision':1}};
     }else{return http.Response('{}',404);}
     return http.Response(jsonEncode(result),req.method=='POST'?201:200,
      headers:const {'content-type':'application/json'});
    }));
   addTearDown(client.dispose);
   final session=IdentitySession(actorId:'actor',installationId:'install',
    token:'test-token',expiresAt:DateTime.now().add(const Duration(hours:1)),
    grants:const [IdentityGrant(roleId:'hr',permission:'org.employees.manage',
      branchId:branch)]);
   tester.view.physicalSize=const Size(1440,900);
   tester.view.devicePixelRatio=1;
   addTearDown(tester.view.resetPhysicalSize);
   addTearDown(tester.view.resetDevicePixelRatio);
   await tester.pumpWidget(MaterialApp(theme:erpTheme(touch:false),
    home:Scaffold(body:SingleChildScrollView(
      child:StaffWorkspace(client:client,session:session)))));
   await tester.pumpAndSettle();
   expect(find.text('Nhân viên Công Ty'),findsOneWidget);
   expect(find.text('Nhân viên kho'),findsOneWidget);
   expect(find.textContaining('Kho vận'),findsOneWidget);
   expect(find.byKey(const ValueKey('staff-create')),findsOneWidget);
   expect(writes,isEmpty,reason:'Read must not create or mutate HR data');
   await tester.tap(find.byKey(const ValueKey('staff-create')));
   await tester.pumpAndSettle();
   expect(find.text('Thêm nhân viên'),findsOneWidget);
   await tester.tap(find.widgetWithText(TextButton,'Hủy').last);
   await tester.pumpAndSettle();
   expect(writes,isEmpty,reason:'Cancel must not POST an employee');
   await tester.tap(find.byKey(const ValueKey('staff-create')));
   await tester.pumpAndSettle();
   final fields=find.descendant(of:find.byType(AlertDialog),
    matching:find.byType(TextFormField));
   await tester.enterText(fields.at(0),'NV02');
   await tester.enterText(fields.at(1),'Nhân viên kế toán');
   await tester.enterText(fields.at(2),'Kế toán');
   await tester.enterText(fields.at(3),'Kế toán trưởng');
   await tester.tap(find.widgetWithText(FilledButton,'Lưu').last);
   await tester.pumpAndSettle();
   expect(writes.length,1);
   final created=jsonDecode(writes.first.body) as Map<String,dynamic>;
   expect(created['branchId'],branch);
   expect(created['warehouseId'],isNull);
   expect(created['department'],'Kế toán');
   expect(created['code'],'NV02');
   expect(writes.first.headers['if-match'],'0');
   await tester.tap(find.byTooltip('Sửa nhân viên').first);
   await tester.pumpAndSettle();
   final editFields=find.descendant(of:find.byType(AlertDialog),
    matching:find.byType(TextFormField));
   await tester.enterText(editFields.at(1),'Kho vận mới');
   await tester.tap(find.widgetWithText(FilledButton,'Lưu').last);
   await tester.pumpAndSettle();
   expect(writes.length,2);
   expect(writes.last.url.path,'/v1/org/employees/$staffId');
   expect((jsonDecode(writes.last.body) as Map)['department'],'Kho vận mới');
   expect(tester.takeException(),isNull);
 });
 testWidgets('IA-A: staff read permission does not enable mutations',(tester)async{
  final client=ErpIdentityClient(apiOrigin:'https://erp.example.test',
   httpClient:MockClient((req)async{
    final data=req.url.path.endsWith('/branches')?
     {'items':[{'id':branch,'code':'MAIN','name':'Chi nhánh chính'}]}:
     {'items':<Object>[]};
    return http.Response(jsonEncode(data),200);
   }));
  addTearDown(client.dispose);
  final session=IdentitySession(actorId:'a',token:'test-token',
   expiresAt:DateTime.now().add(const Duration(hours:1)),
   grants:const [IdentityGrant(roleId:'read',permission:'org.employees.read',
     branchId:branch)]);
  await tester.pumpWidget(MaterialApp(home:Scaffold(body:StaffWorkspace(
   client:client,session:session))));
  await tester.pumpAndSettle();
  final create=tester.widget<FilledButton>(
   find.ancestor(of:find.byKey(const ValueKey('staff-create')),
    matching:find.byType(FilledButton)).first);
  expect(create.onPressed,isNull);
  expect(tester.takeException(),isNull);
 });
}
