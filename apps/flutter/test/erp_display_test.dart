import 'package:flutter_test/flutter_test.dart';
import 'package:erp_distribution/ui/erp_display.dart';

void main() {
  test('exact decimal display removes only insignificant zero padding', () {
    expect(erpDecimalText('0.000000'), '0');
    expect(erpDecimalText('5.000000'), '5');
    expect(erpDecimalText('1.500000'), '1.5');
    expect(erpDecimalText('12.250000'), '12.25');
    expect(erpDecimalText('0.000001'), '0.000001');
    expect(erpDecimalText('999999999999999.123450000'), '999999999999999.12345');
    expect(erpDecimalText('-0.000000'), '0');
    expect(erpDecimalText('-1.250000'), '-1.25');
    expect(erpDecimalText(null), '—');
  });

  test('VND display groups thousands and preserves exact fractional prices', () {
    expect(erpVndText('35000.000000'), '35.000 ₫');
    expect(erpVndText('123456789.125000'), '123.456.789,125 ₫');
    expect(erpVndText('-1500.5000'), '-1.500,5 ₫');
    expect(erpVndText('0.000000'), '0 ₫');
    expect(erpVndText(null), 'Chưa có giá');
  });

  test('operator-friendly price and permission labels are Vietnamese', () {
    expect(erpPriceRuleLabel('CUSTOMER_GROUP'), 'Theo nhóm khách');
    expect(erpPriceRuleLabel('PERCENT_DISCOUNT'), 'Giảm theo phần trăm');
    expect(erpPermissionLabel('inventory.read'), 'Xem tồn kho');
    expect(erpPermissionLabel('inventory.stocktake.approve'), 'Duyệt kiểm kê');
    expect(erpPermissionLabel('identity.roles.manage'), 'Cấp và thu hồi quyền');
    expect(erpPermissionLabel('orders.confirm'), 'Xác nhận đơn hàng');
    expect(erpPermissionLabel('purchase.receive'), 'Nhận hàng mua');
    expect(erpPermissionLabel('unknown.permission'), 'Quyền chưa có tên hiển thị');
  });
}
