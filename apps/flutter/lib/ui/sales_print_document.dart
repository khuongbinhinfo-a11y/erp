import 'dart:convert';
import 'erp_number_input.dart';

/// A4 phiếu xuất kho based on the confirmed canonical sales snapshot.
/// Template structure follows the legacy SalesOrderPrintSheet, without
/// reusing a different customer's brand, identities, assets or source code.
const _html=HtmlEscape(HtmlEscapeMode.element);
String _e(Object? value)=>_html.convert(value?.toString()??'');
String _num(Object? value)=>_e(erpGroupedDecimalText(value));
bool _nonzero(Object? value){
  final normalized=(value??'0').toString().trim();
  return normalized.isNotEmpty&&!RegExp(r'^[-+]?0+(?:\.0+)?$').hasMatch(normalized);
}
String _date(Object? value){
  final raw=value?.toString()??'';
  if(raw.isEmpty)return '—';
  final parsed=DateTime.tryParse(raw);
  if(parsed==null)return _e(raw);
  final d=parsed.toLocal();
  String two(int n)=>n.toString().padLeft(2,'0');
  return '${two(d.day)}/${two(d.month)}/${d.year}';
}
String _style= '''
@page{size:A4;margin:10mm}
*{box-sizing:border-box}
body{margin:0 auto;padding:10mm 8mm;font:11.5px/1.35 Arial,sans-serif;color:#171717;max-width:210mm}
.print-action{margin-bottom:14px;padding:7px 12px}
.sheet{width:100%;break-inside:auto}
.header{display:grid;grid-template-columns:1fr 1.5fr;gap:18px;align-items:start;border-bottom:2px solid #111;padding-bottom:10px}
.brand{font-size:18px;font-weight:800;letter-spacing:.08em}
.title-block{text-align:right}
.title-block h1{margin:0;font-size:22px;letter-spacing:.04em}
.title-block p,.header p{margin:2px 0 0}
.meta-grid{display:grid;grid-template-columns:1fr 1fr;gap:6px 18px;padding:12px 0}
.meta{display:grid;grid-template-columns:105px minmax(0,1fr);gap:8px;overflow-wrap:anywhere}
.meta span{color:#444}.meta.full{grid-column:1/-1}
table{width:100%;border-collapse:collapse;table-layout:auto}
th,td{border:1px solid #777;padding:6px 5px;vertical-align:top;overflow-wrap:anywhere}
th{background:#f3f4f3;text-align:left}
th:first-child,td:first-child{width:32px;text-align:center}
.num{text-align:right;white-space:nowrap}
.center{text-align:center}.name{font-weight:700}.sku{font-size:10px;color:#555}
.summary{width:min(340px,55%);margin:10px 0 0 auto}
.sum-row{display:flex;justify-content:space-between;gap:16px;padding:3px 0}
.grand{margin-top:4px;border-top:1.5px solid #111;padding-top:7px;font-size:13px;font-weight:800}
.note{margin-top:12px;padding:8px;border:1px solid #aaa;white-space:pre-wrap}
.signatures{display:grid;grid-template-columns:repeat(3,1fr);gap:24px;margin-top:28px;text-align:center}
.signatures div{min-height:85px}.signatures strong,.signatures span{display:block}
.signatures span{margin-top:3px;font-size:10px;font-style:italic}
.footer{margin-top:8px;color:#444;font-size:10px}
.pagebreak{break-before:page;page-break-before:always}
thead{display:table-header-group}tr{break-inside:avoid;page-break-inside:avoid}
@media print{
 body{max-width:none;padding:0;margin:0}
 .print-action{display:none}
 .header,.meta-grid,.summary,.note,.signatures{break-inside:avoid}
}
''';

void _requireConfirmed(Map<String,dynamic> order){
  final no=order['documentNo'];
  if(order['status']!='CONFIRMED'||order['versionStatus']!='CONFIRMED'||
      no is! String||!RegExp(r'^SO-\d{8}-\d{6}$').hasMatch(no)||
      order['lines'] is! List){
    throw const FormatException('Chỉ in đơn hàng đã xác nhận');
  }
}

String _renderSheet(Map<String,dynamic> order){
  _requireConfirmed(order);
  final shipping=order['shipping'] is Map?order['shipping'] as Map:const {};
  const delivery={'MANUAL':'Giao thủ công','TRIP':'Giao theo chuyến','PICKUP':'Khách lấy tại kho'};
  const collection={'COLLECT_ON_DELIVERY':'Thu khi giao','PREPAID':'Trả trước',
    'COLLECT_AFTER_DELIVERY':'Thu sau giao','CREDIT_TERMS':'Công nợ theo hạn'};
  final lines=(order['lines'] as List).whereType<Map>().toList(growable:false);
  final showDiscount=_nonzero(order['discountTotal'])||
    lines.any((r)=>_nonzero(r['discountAmount']));
  final showTax=_nonzero(order['taxTotal'])||
    lines.any((r)=>_nonzero(r['taxAmount']));
  final name=(shipping['walkInName']??order['customerName']??'—').toString();
  final company=(order['companyName']??'ERP').toString();
  final printDate=order['confirmedAt']??order['createdAt'];
  final address=shipping['deliveryAddress']??order['customerAddress'];
  final weight=order['totalWeightKg'];
  final out=StringBuffer('<section class="sheet" data-print-template-ready="true">');
  out.write('<header class="header"><div><div class="brand">${_e(company)}</div></div>'
    '<div class="title-block"><h1>PHIẾU XUẤT KHO</h1>'
    '<p>Số: ${_e(order['documentNo'])}</p>'
    '<p>Ngày: ${_date(printDate)}</p></div></header>');
  void meta(String label,Object? value,{bool full=false}){
    if(value==null||value.toString().trim().isEmpty)return;
    out.write('<div class="meta${full?' full':''}"><span>${_e(label)}</span>'
      '<strong>${_e(value)}</strong></div>');
  }
  out.write('<div class="meta-grid">');
  meta('Khách hàng',name);
  meta('Ngày đơn',_date(printDate));
  if(weight!=null)meta('Khối lượng',weight.toString()+' kg',full:true);
  meta('Mã khách',order['customerCode']);
  meta('Điện thoại',shipping['walkInPhone']??order['customerPhone']);
  meta('Địa chỉ',address,full:true);
  meta('Kho',shipping['warehouseName']??order['warehouseName']);
  meta('Giao nhận',delivery[shipping['deliveryChoice']]);
  final collectionLabel=collection[shipping['collectionPolicy']];
  final terms=shipping['paymentTermsDays'];
  meta('Thanh toán',terms==null||collectionLabel==null?collectionLabel:
    '$collectionLabel · $terms ngày');
  meta('Ngày giao dự kiến',_date(shipping['requestedDeliveryDate']));
  out.write('</div>');
  out.write('<table><thead><tr><th>STT</th><th>Tên sản phẩm</th><th>SKU</th>'
    '<th class="num">SL</th><th>ĐVT</th><th class="num">Đơn giá</th>');
  if(showDiscount)out.write('<th class="num">CK</th>');
  if(showTax)out.write('<th class="num">Thuế</th>');
  out.write('<th class="num">Thành tiền</th></tr></thead><tbody>');
  for(final line in lines){
    out.write('<tr><td>${_e(line['lineNo'])}</td>'
      '<td class="name">${_e(line['productName'])}</td>'
      '<td class="sku">${_e(line['sku'])}</td>'
      '<td class="num">${_num(line['quantity'])}</td>'
      '<td class="center">${_e(line['unitName']??line['unitCode'])}</td>'
      '<td class="num">${_num(line['unitPrice'])}</td>');
    if(showDiscount)out.write('<td class="num">${_num(line['discountAmount'])}</td>');
    if(showTax)out.write('<td class="num">${_num(line['taxAmount'])}</td>');
    out.write('<td class="num"><strong>${_num(line['lineTotal'])}</strong></td></tr>');
  }
  out.write('</tbody></table><div class="summary">');
  void amount(String label,Object? value,{bool grand=false}){
    out.write('<div class="sum-row${grand?' grand':''}"><span>${_e(label)}</span>'
      '<strong>${_num(value)} ₫</strong></div>');
  }
  amount('Tạm tính',order['subtotal']);
  if(showDiscount)amount('Chiết khấu',order['discountTotal']);
  if(showTax)amount('Thuế',order['taxTotal']);
  amount('TỔNG CỘNG',order['total'],grand:true);
  out.write('</div>');
  if((order['note']??'').toString().trim().isNotEmpty)
    out.write('<div class="note"><strong>Ghi chú:</strong> ${_e(order['note'])}</div>');
  out.write('<div class="signatures">'
    '<div><strong>Người lập</strong><span>(Ký, ghi rõ họ tên)</span></div>'
    '<div><strong>Kho giao hàng</strong><span>(Ký, ghi rõ họ tên)</span></div>'
    '<div><strong>Khách hàng</strong><span>(Ký, ghi rõ họ tên)</span></div>'
    '</div><div class="footer">Phiếu xuất kho theo đơn bán; '
    'không thay thế hóa đơn thuế hoặc biên nhận thanh toán.</div></section>');
  return out.toString();
}

/// Only the server-confirmed snapshot is printable; it is never silently posted.
String confirmedSalesPrintDocument(Map<String,dynamic> order)=>
  _htmlDocument([order]);

/// Each confirmed order has its own complete sheet and page-break.
String confirmedSalesBatchPrintDocument(List<Map<String,dynamic>> orders){
  if(orders.isEmpty)throw const FormatException('Chưa chọn đơn để in');
  return _htmlDocument(orders);
}

String _htmlDocument(List<Map<String,dynamic>> orders){
  final papers=orders.map(_renderSheet).join('<div class="pagebreak"></div>');
  final title=orders.length==1?
    'Phiếu xuất kho ${_e(orders.first['documentNo'])}':'In phiếu xuất kho hàng loạt';
  return '<!doctype html><html lang="vi"><head><meta charset="utf-8">'
    '<meta name="viewport" content="width=device-width,initial-scale=1">'
    '<title>$title</title><style>$_style</style></head><body>'
    '<button class="print-action" onclick="window.print()">In phiếu xuất kho</button>'
    '$papers</body></html>';
}
