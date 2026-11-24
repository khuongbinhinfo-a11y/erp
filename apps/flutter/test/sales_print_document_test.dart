import 'package:flutter_test/flutter_test.dart';
import 'package:erp_distribution/ui/sales_print_document.dart';
void main(){
 test('Printable document uses confirmed snapshot and escapes all commercial text',(){
  final item=<String,dynamic>{'status':'CONFIRMED','versionStatus':'CONFIRMED',
    'documentNo':'SO-20261124-000001','version':1,'customerName':'<script>alert(1)</script>',
    'total':'9800.0000','subtotal':'9800','discountTotal':'0','taxTotal':'0',
    'lines':[{'lineNo':1,'productName':'Hàng & hóa','sku':'A','unitCode':'cái',
      'quantity':'1.000','unitPrice':'9800.0000','lineTotal':'9800','discountAmount':'0','taxAmount':'0'}]};
  final result=confirmedSalesPrintDocument(item);
  expect(result,contains('9,800'));
  expect(result,contains('&lt;script&gt;'));
  expect(result,contains('Hàng &amp; hóa'));
  expect(result,isNot(contains('<script>')));
  expect(()=>confirmedSalesPrintDocument({...item,'versionStatus':'DRAFT'}),throwsFormatException);
 });
}
