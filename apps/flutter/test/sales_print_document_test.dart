import 'package:flutter_test/flutter_test.dart';
import 'package:erp_distribution/ui/sales_print_document.dart';

Map<String,dynamic> _order(String number,{String discount='0',String tax='0'})=>
  <String,dynamic>{
    'status':'CONFIRMED','versionStatus':'CONFIRMED',
    'documentNo':number,'version':1,'customerName':'<script>alert(1)</script>',
    'companyName':'ERP',
    'createdAt':'2026-11-28T08:00:00+07:00',
    'shipping':{'deliveryChoice':'MANUAL','warehouseName':'Kho Trung tâm',
      'deliveryAddress':'Ấp A & B','walkInPhone':'0123456789',
      'collectionPolicy':'COLLECT_ON_DELIVERY'},
    'total':'9800.0000','subtotal':'9800','discountTotal':discount,'taxTotal':tax,
    'lines':[{'lineNo':1,'productName':'Hàng & hóa','sku':'A','unitCode':'cái',
      'quantity':'1.000','unitPrice':'9800.0000','lineTotal':'9800',
      'discountAmount':discount,'taxAmount':tax}]
  };

void main(){
 test('Confirmed print matches legacy A4 warehouse issue document structure',(){
  final result=confirmedSalesPrintDocument(_order('SO-20261128-000001'));
  expect(result,contains('PHIẾU XUẤT KHO'));
  expect(result,contains('size:A4'));
  expect(result,contains('Kho giao hàng'));
  expect(result,contains('Người lập'));
  expect(result,contains('Khách hàng'));
  expect(result,contains('Đơn giá'));
  expect(result,contains('9,800'));
  expect(result,contains('Hàng &amp; hóa'));
  expect(result,contains('&lt;script&gt;'));
  expect(result,contains('Ấp A &amp; B'));
  expect(result,isNot(contains('<script>')));
  // Legacy printed only money columns that actually have values.
  expect(result,isNot(contains('<th class="num">CK</th>')));
  expect(result,isNot(contains('<th class="num">Thuế</th>')));
 });
 test('Discount and tax columns are conditional but preserved when nonzero',(){
  final result=confirmedSalesPrintDocument(
    _order('SO-20261128-000001',discount:'50',tax:'800'));
  expect(result,contains('<th class="num">CK</th>'));
  expect(result,contains('<th class="num">Thuế</th>'));
 });
 test('Print retains the confirmed customer credit term',(){
  final original=_order('SO-20261128-000001');
  final copy={...original,
    'shipping':{...original['shipping'] as Map,
      'collectionPolicy':'CREDIT_TERMS','paymentTermsDays':30}};
  final result=confirmedSalesPrintDocument(copy);
  expect(result,contains('Công nợ theo hạn · 30 ngày'));
 });
 test('Bulk print has separate full A4 slip per selected confirmed order',(){
  final result=confirmedSalesBatchPrintDocument([
    _order('SO-20261128-000001'),_order('SO-20261128-000002')]);
  expect(RegExp('PHIẾU XUẤT KHO').allMatches(result).length,2);
  expect(result,contains('page-break-before:always'));
  expect(result,contains('SO-20261128-000001'));
  expect(result,contains('SO-20261128-000002'));
  expect(()=>confirmedSalesBatchPrintDocument([]),throwsFormatException);
  expect(()=>confirmedSalesBatchPrintDocument([
    _order('SO-20261128-000001'),
    {..._order('SO-20261128-000002'),'versionStatus':'DRAFT'}]),
    throwsFormatException);
 });
 test('Cannot print unconfirmed or invalid document number',(){
  final original=_order('SO-20261128-000001');
  expect(()=>confirmedSalesPrintDocument({...original,'versionStatus':'DRAFT'}),
    throwsFormatException);
  expect(()=>confirmedSalesPrintDocument({...original,'documentNo':'wrong'}),
    throwsFormatException);
 });
}
