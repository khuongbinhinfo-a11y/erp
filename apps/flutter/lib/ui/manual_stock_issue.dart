import 'package:material_ui/material_ui.dart';
import 'erp_display.dart';
import 'erp_number_input.dart';
import 'identity_client.dart';

/// Exact six-decimal stock quantities. UI never uses floating point.
BigInt? erpInventoryBaseUnits(String input){
  final value=erpNumberCanonical(input);
  final m=RegExp(r'^(0|[1-9][0-9]{0,11})(?:\.([0-9]{1,6}))?$').firstMatch(value);
  if(m==null)return null;
  return BigInt.parse(m.group(1)!)*BigInt.from(1000000)+
    BigInt.parse((m.group(2)??'').padRight(6,'0').isEmpty
      ?'0':(m.group(2)??'').padRight(6,'0'));
}
String erpInventoryFormatUnits(BigInt n)=>
  (n~/BigInt.from(1000000)).toString()+'.'+
  (n%BigInt.from(1000000)).toString().padLeft(6,'0');

/// Confirmed MANUAL only. This dialog builds intent; server owns actual ISSUE.
Future<void> showManualStockIssue({
 required BuildContext context,required ErpIdentityClient client,
 required IdentitySession session,required String branchId,required String warehouseId,
 String? orderId,
 required Future<void> Function(Map<String,dynamic>,int) onSubmit,
})async{
 final token=session.token;
 String? chosen=orderId;
 if(chosen==null){
  final orders=(await client.salesOrders(token,branchId)).where((x)=>
    x['deliveryChoice']=='MANUAL'&&x['status']=='CONFIRMED'&&
    x['versionStatus']=='CONFIRMED'&&x['fulfillmentStatus']!='COMPLETED').toList();
  if(!context.mounted)return;
  if(orders.isEmpty)throw const ErpApiError(409,'Không có đơn MANUAL còn cần xuất.');
  chosen=orders.first['id'].toString();
  chosen=await showDialog<String>(context:context,builder:(dialog)=>
   StatefulBuilder(builder:(dialog,refresh)=>AlertDialog(
    title:const Text('Chọn đơn xuất kho thủ công'),
    content:SizedBox(width:460,child:DropdownButtonFormField<String>(
      isExpanded:true,initialValue:chosen,
      decoration:const InputDecoration(labelText:'Đơn hàng'),
      items:orders.map((o)=>DropdownMenuItem<String>(value:o['id'].toString(),
       child:Text((o['documentNo']??'').toString()+' · '+
          (o['customerName']??'').toString(),overflow:TextOverflow.ellipsis))).toList(),
      onChanged:(v)=>refresh(()=>chosen=v))),
    actions:[TextButton(onPressed:()=>Navigator.pop(dialog),child:const Text('Đóng')),
     FilledButton(onPressed:()=>Navigator.pop(dialog,chosen),child:const Text('Tiếp tục'))])));
 }
 final selectedOrderId=chosen;
 if(selectedOrderId==null||!context.mounted)return;
 final detail=await client.salesOrder(token,selectedOrderId,branchId);
 final shipping=detail['shipping'];
 if(detail['status']!='CONFIRMED'||detail['versionStatus']!='CONFIRMED'||
   detail['fulfillmentStatus']=='COMPLETED'||
   shipping is! Map||shipping['deliveryChoice']!='MANUAL'||
   shipping['warehouseId']!=warehouseId)
  throw const ErpApiError(409,'Đơn không còn đủ điều kiện xuất thủ công ở kho này.');
 // Server aggregate is complete regardless of the number of partial issues.
 final totals=await client.inventoryDirectIssueTotals(token,
  branchId:branchId,warehouseId:warehouseId,orderId:selectedOrderId);
 final byLine={for(final row in totals) (row['lineNo'] as num).toInt():row};
 final lines=(detail['lines'] as List<dynamic>).map((x)=>Map<String,dynamic>.from(x as Map)).toList();
 final pending=<Map<String,dynamic>>[];
 final scopes=<String,Map<String,dynamic>>{};
 for(final row in lines){
  final n=(row['lineNo'] as num).toInt();
  final snapshot=row['priceSnapshot'];
  final original=snapshot is Map&&snapshot['normalizedBaseQuantity'] is String
    ?snapshot['normalizedBaseQuantity'].toString():row['quantity'].toString();
  final ordered=erpInventoryBaseUnits(original);
  if(ordered==null)throw const ErpApiError(409,'Đơn thiếu số lượng theo đơn vị gốc.');
  final total=byLine[n];
  if(total==null)throw const ErpApiError(409,'Không thể đối chiếu số thực xuất.');
  final issued=erpInventoryBaseUnits(total['issuedBase'].toString());
  final baseUnit=total['baseUnit']?.toString()??'';
  if(issued==null||baseUnit.isEmpty)
    throw const ErpApiError(409,'Thiếu đơn vị gốc hoặc tổng xuất kho.');
  final remaining=ordered-issued;
  if(remaining<=BigInt.zero)continue;
  final product=row['productId'].toString();
  if(!scopes.containsKey(product))
    scopes[product]=await client.inventoryStockScopes(token,
      branchId:branchId,warehouseId:warehouseId,productId:product);
  pending.add({...row,'remainingBase':erpInventoryFormatUnits(remaining),
    'baseUnit':baseUnit});
 }
 if(!context.mounted)return;
 if(pending.isEmpty)throw const ErpApiError(409,'Đơn đã xuất đủ hàng.');
 final quantities=<int,TextEditingController>{},selectedLocation=<int,String>{},
  selectedLot=<int,String>{};
 for(final row in pending){
  final n=(row['lineNo'] as num).toInt();
  quantities[n]=TextEditingController(text:erpGroupedDecimalText(row['remainingBase']));
 }
 String? dialogError;
 List<Map<String,dynamic>>? accepted;
 try{
  accepted=await showDialog<List<Map<String,dynamic>>>(context:context,
    builder:(dialog)=>StatefulBuilder(builder:(dialog,refresh)=>AlertDialog(
      title:const Text('Xuất kho trực tiếp'),
      content:SizedBox(width:580,height:420,child:ListView(children:[
        const Text('Số lượng thực xuất. Có thể nhập một phần; không tạo chuyến giao.'),
        const SizedBox(height:12),
        for(final row in pending)...[
          Text((row['sku']??'').toString()+' · '+(row['productName']??'').toString(),
            style:const TextStyle(fontWeight:FontWeight.w600)),
          Text('Còn phải xuất: '+erpNumberText(row['remainingBase'])+
            ' '+row['baseUnit'].toString()),
          TextField(controller:quantities[(row['lineNo'] as num).toInt()],
            inputFormatters:const [ErpGroupedNumberFormatter(maxIntegerDigits:12,maxFractionDigits:6)],
            keyboardType:const TextInputType.numberWithOptions(decimal:true),
            decoration:InputDecoration(labelText:
              'Số thực xuất theo ${row['baseUnit']} (0 để bỏ qua)')),
          if((scopes[row['productId'].toString()]?['locations'] as List?)?.isNotEmpty==true||
             (scopes[row['productId'].toString()]?['policy'] as Map?)?['requireLocation']==true)
            DropdownButtonFormField<String>(
              initialValue:selectedLocation[(row['lineNo'] as num).toInt()]??'',
              isExpanded:true,decoration:const InputDecoration(labelText:'Vị trí kho'),
              items:[const DropdownMenuItem(value:'',child:Text('Chưa chọn vị trí')),
                for(final x in scopes[row['productId'].toString()]!['locations'] as List)
                  DropdownMenuItem(value:(x as Map)['id'].toString(),
                    child:Text((x['code']??'').toString()+' · '+(x['name']??'').toString()))],
              onChanged:(v)=>refresh(()=>selectedLocation[(row['lineNo'] as num).toInt()]=v??'')),
          if((scopes[row['productId'].toString()]?['lots'] as List?)?.isNotEmpty==true||
             (scopes[row['productId'].toString()]?['policy'] as Map?)?['requireLot']==true)
            DropdownButtonFormField<String>(
              initialValue:selectedLot[(row['lineNo'] as num).toInt()]??'',
              isExpanded:true,decoration:const InputDecoration(labelText:'Lô hàng'),
              items:[const DropdownMenuItem(value:'',child:Text('Chưa chọn lô')),
                for(final x in scopes[row['productId'].toString()]!['lots'] as List)
                  DropdownMenuItem(value:(x as Map)['id'].toString(),
                    child:Text((x['lotCode']??'').toString()+
                      (x['expiryDate']!=null?' · HSD '+x['expiryDate'].toString().split('T').first:'')))],
              onChanged:(v)=>refresh(()=>selectedLot[(row['lineNo'] as num).toInt()]=v??'')),
          const Divider(height:24),
        ],
        if(dialogError!=null)Text(dialogError!,style:const TextStyle(color:Colors.red)),
      ])),
      actions:[TextButton(onPressed:()=>Navigator.pop(dialog),child:const Text('Đóng')),
        FilledButton(key:const ValueKey('manual-issue-confirm'),onPressed:(){
          final result=<Map<String,dynamic>>[];
          for(final row in pending){
            final n=(row['lineNo'] as num).toInt();
            final qty=erpInventoryBaseUnits(quantities[n]!.text);
            final limit=erpInventoryBaseUnits(row['remainingBase'].toString());
            if(qty==null||limit==null||qty>limit){
              refresh(()=>dialogError='Số lượng không hợp lệ hoặc vượt số còn lại.');
              return;
            }
            if(qty==BigInt.zero)continue;
            final policy=scopes[row['productId'].toString()]?['policy'];
            if(policy is Map&&
              ((policy['requireLocation']==true&&(selectedLocation[n]??'').isEmpty)||
               (policy['requireLot']==true&&(selectedLot[n]??'').isEmpty))){
              refresh(()=>dialogError='Chưa chọn đầy đủ lô hoặc vị trí kho.');
              return;
            }
            result.add({'lineNo':n,'quantityBase':erpInventoryFormatUnits(qty),
             if((selectedLocation[n]??'').isNotEmpty)'locationId':selectedLocation[n],
             if((selectedLot[n]??'').isNotEmpty)'lotId':selectedLot[n]});
          }
          if(result.isEmpty){refresh(()=>dialogError='Nhập ít nhất một dòng cần xuất.');return;}
          Navigator.pop(dialog,result);
        },child:const Text('Xác nhận xuất kho'))],
  )));
 }finally{
  for(final controller in quantities.values)controller.dispose();
 }
 if(accepted==null||!context.mounted)return;
 await onSubmit({'branchId':branchId,'warehouseId':warehouseId,'orderId':chosen,
  'version':detail['version'],'lines':accepted,'allowNegative':false},
   (detail['revision'] as num).toInt());
}
