/// Read-only display projections of the server's independent order states.
/// Do not infer goods issued or receivables from order confirmation.
String erpSalesProgressText(Object? code,String type)=>switch(type){
  'warehouse'=>switch(code){
    'NOT_ALLOCATED'=>'Chưa phân bổ','PARTIAL'=>'Phân bổ một phần',
    'ALLOCATED'=>'Đã phân bổ','COMPLETED'=>'Đã xuất kho',_=>'Chưa xác định'},
  'delivery'=>switch(code){
    'NOT_DISPATCHED'=>'Chưa giao','PARTIAL'=>'Giao một phần',
    'DELIVERED'=>'Đã giao','RETURNED'=>'Trả hết',_=>'Chưa xác định'},
  'payment'=>switch(code){
    'NOT_DUE'=>'Chưa phát sinh phải thu','PARTIAL'=>'Thu một phần',
    'PAID'=>'Đã thanh toán',_=>'Chưa xác định'},
  _=>'Chưa xác định',
};
bool erpSalesCanAmendOrCancel(Map<String,dynamic> row)=>
  row['status']!='CANCELLED'&&
  row['fulfillmentStatus']=='NOT_ALLOCATED'&&
  row['deliveryStatus']=='NOT_DISPATCHED'&&row['paymentStatus']=='NOT_DUE';

Object? erpSalesDeliveryChoice(Map<String,dynamic> row){
  final shipping=row['shipping'];
  return row['deliveryChoice']??(shipping is Map?shipping['deliveryChoice']:null);
}
bool erpSalesCanHold(Map<String,dynamic> row)=>
  (erpSalesDeliveryChoice(row)==null||erpSalesDeliveryChoice(row)=='TRIP')&&
  row['status']=='CONFIRMED'&&row['versionStatus']=='CONFIRMED'&&
  const ['NOT_ALLOCATED','PARTIAL','ALLOCATED'].contains(row['fulfillmentStatus'])&&
  row['deliveryStatus']=='NOT_DISPATCHED';

bool erpSalesMatchesFilter(Map<String,dynamic> row,String filter)=>switch(filter){
  'entry'=>row['versionStatus']=='DRAFT'&&row['status']!='CANCELLED',
  'confirmed'=>row['status']=='CONFIRMED'&&row['versionStatus']=='CONFIRMED',
  'warehouse'=>erpSalesCanHold(row),
  'delivery'=>row['status']=='CONFIRMED'&&row['versionStatus']=='CONFIRMED'&&
    row['fulfillmentStatus']=='COMPLETED'&&
    row['deliveryStatus']=='NOT_DISPATCHED',
  'payment'=>row['status']=='CONFIRMED'&&row['versionStatus']=='CONFIRMED'&&
    row['fulfillmentStatus']=='COMPLETED'&&
    const ['DELIVERED','PARTIAL'].contains(row['deliveryStatus'])&&
    row['paymentStatus']!='PAID',
  'cancelled'=>row['status']=='CANCELLED',
  _=>true,
};
