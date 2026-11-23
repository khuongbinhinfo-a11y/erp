import 'dart:convert';
import 'dart:typed_data';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:erp_distribution/ui/identity_client.dart';
import 'package:erp_distribution/ui/catalog_bulk_workspace.dart';
import 'package:erp_distribution/ui/erp_tokens.dart';

const branch='00000000-0000-4000-8000-000000000001';
IdentitySession session()=>IdentitySession(
 actorId:'00000000-0000-4000-8000-000000000002',
 token:'r1b-synthetic-token',
 expiresAt:DateTime.now().add(const Duration(hours:1)),
 grants:const [
  IdentityGrant(roleId:'read',permission:'catalog.read',branchId:branch),
  IdentityGrant(roleId:'write',permission:'catalog.write',branchId:branch),
 ],
);

void main(){
 test('R1-B client: inspect, preview, atomic COMMIT and idempotency replay path',()async{
  final paths=<String>[],keys=<String?>[];
  final file=base64Encode(utf8.encode('Mã KH,Tên khách\nKH01,Khách A\n'));
  final client=ErpIdentityClient(apiOrigin:'https://erp.example.test',
   httpClient:MockClient((request)async{
    paths.add(request.url.path);
    keys.add(request.headers['idempotency-key']);
    expect(request.headers['authorization'],'Bearer r1b-synthetic-token');
    if(request.url.path.endsWith('/inspect')){
     expect(request.headers.containsKey('if-match'),false);
     return http.Response(jsonEncode({'headers':['Mã KH','Tên khách'],
      'rowCount':1,'sample':[['KH01','Khách A']],
      'suggestedMapping':{'code':'Mã KH','name':'Tên khách'},
      'allowedColumns':['code','name']}),200);
    }
    if(request.url.path.endsWith('/preview')){
     expect(request.headers.containsKey('if-match'),false);
     return http.Response(jsonEncode({'hash':'a'*64,
      'summary':{'create':1,'update':0,'unchanged':0,'error':0,'total':1},
      'rows':[{'line':2,'key':'KH01','action':'CREATE','before':null,
        'after':{'name':'Khách A'},'error':null}]}),200);
    }
    if(request.url.path.endsWith('/apply')){
     expect(request.headers['idempotency-key'],'bulk-constant-key');
     expect(request.headers['if-match'],'0');
     final json=jsonDecode(request.body) as Map<String,dynamic>;
     expect(json['previewHash'],'a'*64);
     expect(json['contentBase64'],file);
     expect(json['branchId'],branch);
     return http.Response(jsonEncode({'summary':{'create':1},'replayed':false,
      'applied':[{'line':2,'id':'r1b-id','action':'CREATE'}]}),200);
    }
    throw StateError('Unexpected endpoint '+request.url.path);
   }));
  addTearDown(client.dispose);
  final body={'branchId':branch,'resource':'customers','fileName':'data.csv',
   'contentBase64':file,'hasHeader':true,'mode':'UPSERT',
   'mapping':{'code':'Mã KH','name':'Tên khách'}};
  final inspected=await client.bulkInspect('r1b-synthetic-token',body);
  expect(inspected['rowCount'],1);
  final preview=await client.bulkPreview('r1b-synthetic-token',body);
  expect(preview['summary']['create'],1);
  final result=await client.bulkApply('r1b-synthetic-token',
   {...body,'previewHash':preview['hash']},key:'bulk-constant-key');
  expect((result['applied'] as List).length,1);
  expect(paths,['/v1/catalog/bulk/inspect','/v1/catalog/bulk/preview',
   '/v1/catalog/bulk/apply']);
  expect(keys,[null,null,'bulk-constant-key']);
 });
 testWidgets('R1-B CSV template and export deliver valid UTF-8 BOM bytes to browser saver',
  (tester)async{
   final paths=<String>[],downloads=<({String name,Uint8List bytes})>[];
   final client=ErpIdentityClient(apiOrigin:'https://erp.example.test',
    httpClient:MockClient((request)async{
     paths.add(request.url.path);
     expect(request.method,'GET');
     expect(request.url.queryParameters['resource'],'customers');
     expect(request.url.queryParameters['branchId'],branch);
     expect(request.headers['authorization'],'Bearer r1b-synthetic-token');
     final template=request.url.path.endsWith('/template');
     return http.Response(jsonEncode({
      'fileName':template?'mau-khach-hang.csv':'khach-hang.csv',
      'content':template?'Mã KH,Tên khách\n':'\uFEFFMã KH,Tên khách\nKH01,Nguyễn Văn A\n',
     }),200,headers:{'content-type':'application/json; charset=utf-8'});
    }));
   addTearDown(client.dispose);
   tester.view.devicePixelRatio=1;
   tester.view.physicalSize=const Size(1024,800);
   addTearDown(tester.view.resetPhysicalSize);
   addTearDown(tester.view.resetDevicePixelRatio);
   await tester.pumpWidget(MaterialApp(theme:erpTheme(touch:false),
    home:Scaffold(body:SingleChildScrollView(
     child:CatalogBulkWorkspace(client:client,session:session(),
      branchId:branch,canWrite:true,initialArea:'customers',
      saveCsvForTest:(name,bytes)async{
       downloads.add((name:name,bytes:bytes));
      })))));
   await tester.tap(find.byKey(const ValueKey('catalog-bulk-template')));
   await tester.pumpAndSettle();
   await tester.tap(find.byKey(const ValueKey('catalog-bulk-export')));
   await tester.pumpAndSettle();
   expect(paths,['/v1/catalog/bulk/template','/v1/catalog/bulk/export']);
   expect(downloads.map((d)=>d.name),['mau-khach-hang.csv','khach-hang.csv']);
   expect(downloads[0].bytes.take(3).toList(),[0xEF,0xBB,0xBF]);
   expect(downloads[1].bytes.take(3).toList(),[0xEF,0xBB,0xBF]);
   // Dart's UTF-8 decoder intentionally strips the leading BOM; assert it
   // in raw bytes separately and ensure there is no duplicate BOM.
   expect(utf8.decode(downloads[0].bytes),'Mã KH,Tên khách\n');
   expect(utf8.decode(downloads[1].bytes),
    'Mã KH,Tên khách\nKH01,Nguyễn Văn A\n',
    reason:'CSV already containing a BOM must never get a second BOM');
   expect(find.byKey(const ValueKey('catalog-bulk-error')),findsNothing);
   expect(tester.takeException(),isNull);
  });

 testWidgets('R1-B CSV save failure shows actionable browser guidance',
  (tester)async{
   final client=ErpIdentityClient(apiOrigin:'https://erp.example.test',
    httpClient:MockClient((_)async=>http.Response(jsonEncode({
     'fileName':'mau.csv','content':'Mã,Tên\n',
    }),200,headers:{'content-type':'application/json; charset=utf-8'})));
   addTearDown(client.dispose);
   tester.view.devicePixelRatio=1;
   tester.view.physicalSize=const Size(1024,800);
   addTearDown(tester.view.resetPhysicalSize);
   addTearDown(tester.view.resetDevicePixelRatio);
   await tester.pumpWidget(MaterialApp(theme:erpTheme(touch:false),
    home:Scaffold(body:SingleChildScrollView(
     child:CatalogBulkWorkspace(client:client,session:session(),
      branchId:branch,canWrite:true,initialArea:'customers',
      saveCsvForTest:(_,__)async{throw UnsupportedError('download blocked');})))));
   await tester.tap(find.byKey(const ValueKey('catalog-bulk-template')));
   await tester.pumpAndSettle();
   expect(find.textContaining('Trình duyệt không hỗ trợ tải CSV'),findsOneWidget);
   expect(tester.takeException(),isNull);
  });

 testWidgets('R1-B exposes controlled import under Company secondary tabs without fake rows',
  (tester)async{
   final client=ErpIdentityClient(apiOrigin:'https://erp.example.test',
    httpClient:MockClient((_)async=>http.Response('{}',200)));
   addTearDown(client.dispose);
   tester.view.devicePixelRatio=1;
   tester.view.physicalSize=const Size(1024,800);
   addTearDown(tester.view.resetPhysicalSize);
   addTearDown(tester.view.resetDevicePixelRatio);
   await tester.pumpWidget(MaterialApp(theme:erpTheme(touch:false),
    home:Scaffold(body:SingleChildScrollView(
     child:CatalogBulkWorkspace(client:client,session:session(),
      branchId:branch,canWrite:true,initialArea:'products')))));
   expect(find.text('Nhập / cập nhật Excel – CSV'),findsOneWidget);
   expect(find.byKey(const ValueKey('catalog-bulk-resource')),findsOneWidget);
   expect(find.byKey(const ValueKey('catalog-bulk-file')),findsOneWidget);
   expect(find.byKey(const ValueKey('catalog-bulk-template')),findsOneWidget);
   expect(find.byKey(const ValueKey('catalog-bulk-export')),findsOneWidget);
   expect(find.byKey(const ValueKey('catalog-bulk-apply')),findsNothing,
    reason:'cannot COMMIT without server preview/confirmation');
   expect(tester.takeException(),isNull);
 });

 testWidgets('R1-B: download XLSX template and formatted workbook as binary, no UTF-8 BOM',
  (tester)async{
   final requests=<String>[],downloads=<({String name,Uint8List bytes})>[];
   final sample=Uint8List.fromList([0x50,0x4b,0x03,0x04,0x00,0xff]);
   final client=ErpIdentityClient(apiOrigin:'https://erp.example.test',
     httpClient:MockClient((request)async{
       requests.add(request.url.path+'?'+request.url.queryParameters['format'].toString());
       expect(request.url.queryParameters['format'],'xlsx');
       expect(request.url.queryParameters['resource'],'customers');
       return http.Response(jsonEncode({
         'fileName':request.url.path.endsWith('template')?'mau-khach-hang.xlsx':'xuat-khach-hang.xlsx',
         'contentBase64':base64Encode(sample),
       }),200);
     }));
   addTearDown(client.dispose);
   tester.view.devicePixelRatio=1;
   tester.view.physicalSize=const Size(1280,900);
   addTearDown(tester.view.resetPhysicalSize);
   addTearDown(tester.view.resetDevicePixelRatio);
   await tester.pumpWidget(MaterialApp(theme:erpTheme(touch:false),
    home:Scaffold(body:SingleChildScrollView(
     child:CatalogBulkWorkspace(client:client,session:session(),
      branchId:branch,canWrite:true,initialArea:'customers',
      saveCsvForTest:(name,bytes)async{downloads.add((name:name,bytes:bytes));})))));
   await tester.tap(find.byKey(const ValueKey('catalog-bulk-template-xlsx')));
   await tester.pumpAndSettle();
   await tester.tap(find.byKey(const ValueKey('catalog-bulk-export-xlsx')));
   await tester.pumpAndSettle();
   expect(requests,['/v1/catalog/bulk/template?xlsx','/v1/catalog/bulk/export?xlsx']);
   expect(downloads.map((x)=>x.name),['mau-khach-hang.xlsx','xuat-khach-hang.xlsx']);
   expect(downloads.every((x)=>x.bytes.length==sample.length&&x.bytes[0]==0x50&&x.bytes[1]==0x4b),true);
   expect(tester.takeException(),isNull);
 });
}
