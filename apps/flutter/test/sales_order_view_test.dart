import 'package:flutter_test/flutter_test.dart';
import 'package:erp_distribution/ui/sales_order_view.dart';

void main(){
  test('order confirmation is not fulfillment, delivery or payment',(){
    final order=<String,dynamic>{'status':'CONFIRMED','versionStatus':'CONFIRMED',
      'fulfillmentStatus':'NOT_ALLOCATED','deliveryStatus':'NOT_DISPATCHED','paymentStatus':'NOT_DUE'};
    expect(erpSalesCanHold(order),isTrue);
    expect(erpSalesCanAmendOrCancel(order),isTrue);
    expect(erpSalesMatchesFilter(order,'warehouse'),isTrue);
    expect(erpSalesMatchesFilter(order,'delivery'),isFalse);
    expect(erpSalesMatchesFilter(order,'payment'),isFalse);
    expect(erpSalesProgressText('NOT_DUE','payment'),'Chưa phát sinh phải thu');
    expect(erpSalesProgressText('NOT_ALLOCATED','warehouse'),'Chưa phân bổ');
    order['fulfillmentStatus']='COMPLETED';
    expect(erpSalesCanAmendOrCancel(order),isFalse);
    expect(erpSalesMatchesFilter(order,'delivery'),isTrue);
    expect(erpSalesProgressText('COMPLETED','warehouse'),'Đã xuất kho');
    order['deliveryStatus']='DELIVERED';
    expect(erpSalesMatchesFilter(order,'payment'),isTrue);
    order['paymentStatus']='PAID';
    expect(erpSalesMatchesFilter(order,'payment'),isFalse);
    order['status']='CANCELLED';
    expect(erpSalesCanHold(order),isFalse);
    expect(erpSalesMatchesFilter(order,'cancelled'),isTrue);
  });
}
