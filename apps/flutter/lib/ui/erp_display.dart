/// Presentation-only formatting. Never round, parse as double, or mutate
/// the canonical PostgreSQL NUMERIC strings used in API requests.
String erpDecimalText(Object? value) {
  if (value == null) return '—';
  final text = value.toString().trim();
  final match = RegExp(r'^([+-]?)(\d+)(?:\.(\d+))?$').firstMatch(text);
  if (match == null) return text;
  final whole = match.group(2)!.replaceFirst(RegExp(r'^0+(?=\d)'), '');
  final fractional = (match.group(3) ?? '').replaceFirst(RegExp(r'0+$'), '');
  if (whole == '0' && fractional.isEmpty) return '0';
  final sign = match.group(1) == '-' ? '-' : '';
  return sign + whole + (fractional.isEmpty ? '' : '.' + fractional);
}

/// Exact human-readable business number: comma thousands, dot decimal.
/// No floating point and no rounding; only trailing zeros are removed.
String erpNumberText(Object? value) {
  final decimal=erpDecimalText(value);
  final match=RegExp(r'^(-?)(\d+)(?:\.(\d+))?$').firstMatch(decimal);
  if(match==null)return decimal;
  final whole=match.group(2)!.replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'),(_)=>',');
  final fractional=match.group(3);
  return (match.group(1)??'')+whole+
    (fractional==null?'':'.'+fractional);
}

/// VND follows the same numerical display as order entry, price workspace,
/// inventory, purchase and delivery. Never modify exact API decimal strings.
String erpVndText(Object? value) {
  if(value==null)return 'Chưa có giá';
  return erpNumberText(value)+' ₫';
}

/// Local Vietnamese date/time; ISO database timestamps stay unchanged.
String erpDateTimeText(Object? value,{bool withTime=true}){
  if(value==null)return '—';
  final parsed=DateTime.tryParse(value.toString());
  if(parsed==null)return value.toString();
  final local=parsed.toLocal();
  final day='${local.day.toString().padLeft(2,'0')}/'
    '${local.month.toString().padLeft(2,'0')}/${local.year}';
  return withTime?'$day ${local.hour.toString().padLeft(2,'0')}:'
    '${local.minute.toString().padLeft(2,'0')}':day;
}

const Map<String, String> _priceRuleNames = {
  'BASE': 'Giá cơ sở',
  'CHANNEL': 'Theo kênh bán',
  'CUSTOMER_GROUP': 'Theo nhóm khách',
  'CUSTOMER': 'Theo khách hàng',
  'PROMOTION': 'Khuyến mãi',
  'FIXED_PRICE': 'Giá cố định',
  'PERCENT_DISCOUNT': 'Giảm theo phần trăm',
  'AMOUNT_DISCOUNT': 'Giảm số tiền',
  'AMOUNT_MARKUP': 'Tăng số tiền',
  'PERCENT_MARKUP': 'Tăng theo phần trăm',
  'EXCLUSIVE': 'Ưu tiên riêng',
  'STACKABLE': 'Có thể cộng dồn',
};

String erpPriceRuleLabel(Object? code) {
  if (code == null) return '—';
  final text = code.toString();
  return _priceRuleNames[text] ?? text;
}

/// Only human-readable labels are shown in business permission pickers.
const Map<String, String> _permissionNames = {
  'identity.users.read': 'Xem tài khoản',
  'identity.users.manage': 'Quản lý tài khoản',
  'identity.roles.manage': 'Cấp và thu hồi quyền',
  'catalog.read': 'Xem danh mục',
  'catalog.write': 'Quản lý danh mục',
  'orders.read': 'Xem đơn hàng',
  'orders.create': 'Tạo đơn hàng',
  'orders.update': 'Chỉnh sửa đơn hàng',
  'orders.price.override': 'Điều chỉnh đơn giá bán',
  'orders.discount.override': 'Điều chỉnh chiết khấu',
  'orders.tax.override': 'Điều chỉnh thuế bán hàng',
  'orders.confirm': 'Xác nhận đơn hàng',
  'orders.amend': 'Điều chỉnh đơn hàng đã xác nhận',
  'orders.cancel': 'Hủy đơn hàng',
  'inventory.read': 'Xem tồn kho',
  'inventory.post': 'Ghi nhận tồn đầu kỳ',
  'inventory.reserve': 'Giữ hoặc giải phóng hàng',
  'inventory.transfer.read': 'Xem phiếu điều chuyển',
  'inventory.transfer.create': 'Lập phiếu điều chuyển',
  'inventory.transfer.approve': 'Duyệt điều chuyển',
  'inventory.transfer.dispatch': 'Xuất hàng điều chuyển',
  'inventory.transfer.receive': 'Nhận hàng điều chuyển',
  'inventory.stocktake.read': 'Xem kiểm kê',
  'inventory.stocktake.create': 'Tạo đợt kiểm kê',
  'inventory.stocktake.count': 'Ghi số kiểm kê',
  'inventory.stocktake.submit': 'Gửi duyệt kiểm kê',
  'inventory.stocktake.approve': 'Duyệt kiểm kê',
  'inventory.stocktake.post': 'Ghi sổ kiểm kê',
  'purchase.read': 'Xem đơn mua hàng',
  'purchase.create': 'Lập đơn mua hàng',
  'purchase.confirm': 'Xác nhận đơn mua hàng',
  'purchase.receive': 'Nhận hàng mua',
  'finance.receivables.read': 'Xem công nợ khách hàng',
  'finance.payments.record': 'Ghi nhận thanh toán',
  'delivery.read': 'Xem giao hàng',
  'delivery.update': 'Cập nhật giao hàng',
};

String erpPermissionLabel(String permission) =>
  _permissionNames[permission] ?? 'Quyền chưa có tên hiển thị';
