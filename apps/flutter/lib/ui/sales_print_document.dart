import 'dart:convert';
import 'erp_number_input.dart';

/// A printable local artifact, based only on the immutable server version.
/// No external assets/network, credentials, scripts containing customer data,
/// or claim that printing has happened before the operator actually prints.
String confirmedSalesPrintDocument(Map<String,dynamic> order){
  final documentNo=order['documentNo'];
  if(order['status']!='CONFIRMED'||order['versionStatus']!='CONFIRMED'||
    documentNo is! String||!RegExp(r'^SO-\d{8}-\d{6}$').hasMatch(documentNo)){
    throw const FormatException('Chỉ in đơn hàng đã xác nhận');
  }
  const escape=HtmlEscape(HtmlEscapeMode.element);
  String e(Object? v)=>escape.convert(v?.toString()??'');
  String n(Object? v)=>e(erpGroupedDecimalText(v));
  final shipping=order['shipping'] is Map?order['shipping'] as Map:const {};
  const delivery={'MANUAL':'Giao thủ công','TRIP':'Giao thường','PICKUP':'Khách lấy tại kho'};
  const collection={'COLLECT_ON_DELIVERY':'Thu khi giao','PREPAID':'Trả trước',
    'COLLECT_AFTER_DELIVERY':'Thu sau giao','CREDIT_TERMS':'Công nợ theo hạn'};
  final out=StringBuffer('<!doctype html><html lang="vi"><head><meta charset="utf-8">');
  out.write('<meta name="viewport" content="width=device-width,initial-scale=1">');
  out.write('<title>Đơn bán hàng ${e(documentNo)}</title><style>'
    '@page{size:A4;margin:14mm}body{font:14px Arial,sans-serif;color:#202020;max-width:850px;margin:16px auto;padding:12px}'
    'h1{font-size:21px;text-align:center}table{border-collapse:collapse;width:100%;margin:16px 0}'
    'th,td{border:1px solid #aaa;padding:7px;text-align:left;overflow-wrap:anywhere}.num{text-align:right}'
    'thead{display:table-header-group}tr{break-inside:avoid}.totals{text-align:right;line-height:1.7}'
    '@media print{button{display:none}body{margin:0;padding:0}}</style></head><body>');
  out.write('<button onclick="window.print()">In đơn hàng</button><h1>ĐƠN BÁN HÀNG</h1>'
    '<p>Số: ${e(documentNo)} · Phiên bản ${e(order['version'])}</p>'
    '<p>Khách hàng: ${e(shipping['walkInName']??order['customerName'])}</p>');
  if(shipping.isNotEmpty){
    out.write('<p>Kho xuất: ${e(shipping['warehouseName'])} · Giao nhận: ${e(delivery[shipping['deliveryChoice']])}</p>'
      '<p>Địa chỉ: ${e(shipping['deliveryAddress'])} · Ngày giao: ${e(shipping['requestedDeliveryDate'])}</p>'
      '<p>Điều kiện thanh toán: ${e(collection[shipping['collectionPolicy']])} · ${e(shipping['paymentTermsDays'])} ngày</p>');
  }
  out.write('<table><thead><tr><th>STT</th><th>Hàng hóa / SKU</th><th>ĐVT</th><th>SL</th><th>Đơn giá</th><th>CK</th><th>Thuế</th><th>Thành tiền</th></tr></thead><tbody>');
  for(final line in order['lines'] as List){
    out.write('<tr><td>${e(line['lineNo'])}</td><td>${e(line['productName'])}<br>${e(line['sku'])}</td>'
      '<td>${e(line['unitCode'])}</td><td class="num">${n(line['quantity'])}</td>'
      '<td class="num">${n(line['unitPrice'])}</td><td class="num">${n(line['discountAmount'])}</td>'
      '<td class="num">${n(line['taxAmount'])}</td><td class="num">${n(line['lineTotal'])}</td></tr>');
  }
  out.write('</tbody></table><div class="totals">Tiền hàng: ${n(order['subtotal'])} ₫<br>'
    'Chiết khấu: ${n(order['discountTotal'])} ₫<br>Thuế: ${n(order['taxTotal'])} ₫<br>'
    '<strong>Tổng tiền: ${n(order['total'])} ₫</strong></div>'
    '<p>Ghi chú: ${e(order['note'])}</p><p>Chứng từ bán hàng; không thay thế chứng từ thu tiền hoặc hóa đơn thuế.</p></body></html>');
  return out.toString();
}
