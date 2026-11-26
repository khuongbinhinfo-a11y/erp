import 'package:flutter_test/flutter_test.dart';
import 'package:erp_distribution/ui/retail_receipt.dart';

void main(){
  test('POS receipt is escaped, local-only and states payment and change exactly',(){
    final html=erpRetailReceiptHtml({
      'documentNo':'SO-20261126-000001',
      'createdAt':'2026-11-26T14:00:00Z',
      'total':'2000','cashReceived':'2500','bankAmount':'0','changeDue':'500',
      'lines':[{'productName':'Nước <script>alert(1)</script>','sku':'S-01',
        'unitCode':'chai','quantity':'2.000','unitPrice':'1000',
        'lineTotal':'2000'}],
    });
    expect(html,startsWith('<!doctype html>'));
    expect(html,contains('2,000'));
    expect(html,contains('2,500'));
    expect(html,contains('500'));
    expect(html,contains('Nước &lt;script&gt;'));
    expect(html,contains('Phiếu bán hàng'));
    expect(html,contains('không thay thế hóa đơn thuế'));
    expect(html.contains('<script'),isFalse);
    expect(html.contains('https://'),false);
  });
  test('unacknowledged, malformed or missing server lines cannot be printed',(){
    expect(()=>erpRetailReceiptHtml({'documentNo':'SO-20261126-000001',
      'total':'2000','cashReceived':'2000','bankAmount':'0','changeDue':'0',
      'lines':[]}),throwsFormatException);
    expect(()=>erpRetailReceiptHtml({'documentNo':'draft',
      'total':'2000','cashReceived':'2000','bankAmount':'0','changeDue':'0',
      'lines':[{'productName':'X','lineTotal':'2000'}]}),throwsFormatException);
  });
}
