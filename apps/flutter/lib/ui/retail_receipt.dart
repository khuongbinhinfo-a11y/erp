import 'dart:convert';
import 'erp_display.dart';

/// Thermal receipt generated only from a server-ACK'd canonical POS receipt.
/// This is a proof of sale, not a VAT invoice or a claim that printing succeeded.
String erpRetailReceiptHtml(Map<String,dynamic> receipt){
  final doc=receipt['documentNo'];
  final lines=receipt['lines'];
  if(doc is! String||!RegExp(r'^SO-\d{8}-\d{6}$').hasMatch(doc)||
      lines is! List||lines.isEmpty||
      receipt['total'] is! String||receipt['cashReceived'] is! String||
      receipt['bankAmount'] is! String||receipt['changeDue'] is! String){
    throw const FormatException('Chưa có phiếu POS đã được xác minh');
  }
  const h=HtmlEscape(HtmlEscapeMode.element);
  String e(Object? value)=>h.convert(value?.toString()??'');
  String n(Object? v)=>e(erpNumberText(v));
  final out=StringBuffer('<!doctype html><html lang="vi"><head><meta charset="utf-8">'
    '<meta name="viewport" content="width=device-width,initial-scale=1">'
    '<title>Phiếu bán tại quầy</title><style>'
    '@page{size:80mm auto;margin:4mm}'
    'body{font:12px Arial,sans-serif;margin:0;padding:2mm;color:black}'
    'h1{font-size:16px;text-align:center;margin:6px 0 3px}'
    'p{margin:3px 0}.muted{font-size:11px}'
    'table{border-collapse:collapse;width:100%;table-layout:fixed;margin-top:9px}'
    'th,td{font-size:11px;padding:3px 0;border-bottom:1px dashed #ccc;overflow-wrap:anywhere}'
    'th{text-align:left}td.num,th.num{text-align:right}'
    'section{margin-top:10px;border-top:1px dashed #777;padding-top:5px}'
    '.total{font-size:15px;font-weight:700}'
    '</style></head><body><h1>ERP · PHIẾU BÁN LẺ</h1>');
  out.write('<p style="text-align:center">Số phiếu: ${e(doc)}</p>');
  if(receipt['createdAt']!=null)out.write('<p style="text-align:center">Thời điểm: ${e(erpDateTimeText(receipt['createdAt']))}</p>');
  if(receipt['returnId']!=null)out.write('<p><strong>GIAO DỊCH ĐÃ HOÀN HÀNG</strong></p>');
  out.write('<table><thead><tr><th style="width:53%">Mặt hàng</th><th class="num">SL</th><th class="num">Tiền</th></tr></thead><tbody>');
  for(final entry in lines){
    if(entry is! Map)throw const FormatException('Dòng phiếu không hợp lệ');
    out.write('<tr><td>${e(entry['productName'])} ${e(entry['sku'])}'
      '<div class="muted">${n(entry['unitPrice'])} ₫ / ${e(entry['unitCode'])}</div></td>'
      '<td class="num">${n(entry['quantity'])}</td>'
      '<td class="num">${n(entry['lineTotal'])}</td></tr>');
  }
  out.write('</tbody></table><section><p class="total">Tổng thanh toán: ${n(receipt['total'])} ₫</p>'
    '<p>Tiền mặt khách đưa: ${n(receipt['cashReceived'])} ₫</p>'
    '<p>Chuyển khoản: ${n(receipt['bankAmount'])} ₫</p>'
    '<p>Tiền thừa trả lại: ${n(receipt['changeDue'])} ₫</p>'
    '</section><p class="muted" style="text-align:center">Cảm ơn quý khách!'
    '<br>Phiếu bán hàng · không thay thế hóa đơn thuế</p></body></html>');
  return out.toString();
}
