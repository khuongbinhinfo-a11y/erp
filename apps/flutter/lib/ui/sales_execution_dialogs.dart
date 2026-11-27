import 'package:material_ui/material_ui.dart';
import 'identity_client.dart';
import 'erp_display.dart';
import 'erp_number_input.dart';
import 'manual_stock_issue.dart';

/// T5-A is a view/controller only. All amounts, issued quantities, returnable
/// lots and paid balance are read from canonical server facts. The UI never
/// acknowledges a movement or money transfer before the server's receipt.
void _notice(BuildContext context,String message,{bool error=false}){
 if(!context.mounted)return;
 ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(message),
   backgroundColor:error?Colors.red.shade700:null));
}
Future<Map<String,dynamic>?> erpManualExecutionRead({
 required BuildContext context,required ErpIdentityClient client,
 required IdentitySession session,required Map<String,dynamic> order,
 required String branchId,
})async{
 final shipping=order['shipping'];
 if(shipping is! Map||shipping['deliveryChoice']!='MANUAL'||
    shipping['warehouseId'] is! String||order['id'] is! String)return null;
 try{
  final result=await client.salesExecutionRead(session.token,
    branchId:branchId,warehouseId:shipping['warehouseId'].toString(),
    orderId:order['id'].toString());
  return result;
 }on ErpApiError catch(e){
  if(e.status!=503)_notice(context,
    'Không đối chiếu được chứng từ: '+e.message,error:true);
  return null;
 }catch(_){
  _notice(context,'Không tải được trạng thái giao/thu tiền.',error:true);
  return null;
 }
}
Future<bool> erpManualOrderAction({
 required BuildContext context,required ErpIdentityClient client,
 required IdentitySession session,required Map<String,dynamic> order,
 required String branchId,required String action,
})async{
 final shipping=order['shipping'];
 if(shipping is! Map||shipping['deliveryChoice']!='MANUAL'||
   shipping['warehouseId'] is! String||order['id'] is! String){
  _notice(context,'Chỉ áp dụng cho đơn giao thủ công.',error:true);return false;
 }
 final warehouse=shipping['warehouseId'].toString(),orderId=order['id'].toString();
 // Direct issue uses existing T3-B scoped stock dialog, never an invented
 // quantity. The recorded issue is the only source of subsequent delivery.
 if(action=='issue'){
  final pending=client.pendingInventory('direct-issue:'+orderId);
  if(pending!=null){
   _notice(context,'Có chứng từ xuất kho chờ xác nhận. Hãy đối soát tại Kho trước.',
     error:true);return false;
  }
  var posted=false;
  await showManualStockIssue(context:context,client:client,session:session,
    branchId:branchId,warehouseId:warehouse,orderId:orderId,
    onSubmit:(body,revision)async{
      final key='t5a-issue-'+DateTime.now().microsecondsSinceEpoch.toString();
      client.retainInventory('direct-issue:'+orderId,body,key,
        action:'direct-issues',revision:revision);
      try{
        await client.inventoryAction(session.token,'direct-issues',body,
          revision:revision,key:key);
        client.clearInventory('direct-issue:'+orderId);
        posted=true;
      }on ErpApiError catch(e){
        if(e.status>=400&&e.status<500&&e.status!=408&&e.status!=424)
          client.clearInventory('direct-issue:'+orderId);
        rethrow;
      }
    });
  if(posted)_notice(context,'Đã ghi nhận xuất kho trên máy chủ.');
  return posted;
 }
 try{
  // An unresolved prior intent may have committed. Do not issue a new
  // payment/fulfillment/return before read-only receipt reconciliation.
  await client.reconcileSalesExecution(session,
    branchId:branchId,warehouseId:warehouse,orderId:orderId);
  final scope=client.localScope(session,branchId,warehouse:warehouse);
  if(scope!=null&&await client.localStore?.executionPending(scope,orderId)!=null){
    _notice(context,'Còn thao tác chưa đối soát. Không gửi lệnh mới.',
      error:true);return false;
  }
  final state=await client.salesExecutionRead(session.token,
    branchId:branchId,warehouseId:warehouse,orderId:orderId);
  if(!context.mounted)return false;
  final revision=(state['revision'] as num).toInt();
  Map<String,dynamic>? fields;
  if(action=='return'){
    if(state['completed']==true){
      _notice(context,'Đơn đã hoàn thành. Nhập trả phải dùng chứng từ điều chỉnh.',
        error:true);return false;
    }
    fields=await _askReturn(context,state,branchId,warehouse,orderId);
  }else if(action=='complete'){
    fields=await _askComplete(context,state,branchId,warehouse,orderId);
  }else if(action=='payment'||action=='fullPayment'){
    fields=await _askPayment(context,state,branchId,warehouse,orderId,
      full:action=='fullPayment');
  }
  if(fields==null||!context.mounted)return false;
  final command=action=='return'?'return':action=='complete'?'complete':'payment';
  final result=await client.postSalesExecution(session,command,fields,revision);
  if(!context.mounted)return true;
  if(command=='payment'){
    _notice(context,result['recorded']==true?
      'Đã ghi thu tiền '+erpVndText(result['amount'])+
        ' · Còn phải thu '+erpVndText(result['remaining']):
      'Đã ghi nợ '+erpVndText(result['remaining'])+'; không phát sinh phiếu thu 0 đồng.');
  }else if(command=='return'){
    _notice(context,'Đã nhập trả kho và ghi sổ tồn; chưa phát sinh công nợ.');
  }else{
    _notice(context,'Đã xác nhận lượng giao thực tế và ghi nhận công nợ.');
  }
  return true;
 }on ErpApiError catch(e){
  _notice(context,e.code=='T5A_MIGRATION_REQUIRED'?
    'Máy chủ chưa nâng cấp migration 0026. Không thể ghi chứng từ.':
    e.message,error:true);
  return false;
 }catch(_){
  _notice(context,'Chưa xác minh được phản hồi của máy chủ. Kiểm tra chứng từ chờ trước khi thử lại.',
    error:true);
  return false;
 }
}

Future<Map<String,dynamic>?> _askComplete(BuildContext context,
 Map<String,dynamic> state,String branch,String warehouse,String order)async{
 if(state['completed']==true){
  _notice(context,'Đơn này đã hoàn thành.',error:true);return null;
 }
 if(state['hasIssuedDelivery']!=true){
  _notice(context,'Đơn chưa có hàng thực xuất. Cần xuất kho trước.',
    error:true);return null;
 }
 final rows=state['lines'] is List?state['lines'] as List:const [];
 final accepted=await showDialog<bool>(context:context,builder:(c)=>AlertDialog(
  title:const Text('Hoàn thành giao hàng'),
  content:SizedBox(width:540,child:ConstrainedBox(
   constraints:const BoxConstraints(maxHeight:440),child:SingleChildScrollView(
    child:Column(mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.start,
     children:[
      const Text('Chỉ ghi nhận hàng thực giao = hàng đã xuất – hàng nhập trả.',
        style:TextStyle(fontWeight:FontWeight.w600)),
      const SizedBox(height:10),
      const Divider(),
      for(final raw in rows)
       if(raw is Map)Padding(padding:const EdgeInsets.symmetric(vertical:5),
        child:Row(children:[
         Expanded(child:Text('Dòng '+raw['lineNo'].toString())),
         Text(erpNumberText(raw['issuedBase'])+' − '+
          erpNumberText(raw['returnedBase'])+' = '+
          erpNumberText(raw['deliverableBase']),
          style:const TextStyle(fontWeight:FontWeight.w700)),
        ])),
      const Divider(),
      Row(children:[
       const Expanded(child:Text('Tiền hàng thực giao',
        style:TextStyle(fontWeight:FontWeight.w700))),
       Text(erpVndText(state['expectedDeliveryTotal']),
         style:const TextStyle(fontSize:16,fontWeight:FontWeight.w800)),
      ]),
      const SizedBox(height:10),
      Text(state['isFullDelivery']==true?'Giao đủ số lượng đặt.':
       'Giao thiếu: số chưa giao không được tính công nợ.'),
     ]),
   ))),
  actions:[
   TextButton(onPressed:()=>Navigator.pop(c,false),child:const Text('Hủy')),
   FilledButton(onPressed:()=>Navigator.pop(c,true),
     child:const Text('Xác nhận thực giao')),
  ],
 ));
 if(accepted!=true)return null;
 return {'branchId':branch,'warehouseId':warehouse,'orderId':order,
   'version':state['version']};
}
Future<Map<String,dynamic>?> _askReturn(BuildContext context,
 Map<String,dynamic> state,String branch,String warehouse,String order)async{
 final sources=(state['sources'] as List? ??const [])
   .whereType<Map>().where((r)=>
     (erpInventoryBaseUnits((r['returnableBase']??'0').toString())??BigInt.zero)>BigInt.zero)
   .toList();
 if(sources.isEmpty){
  _notice(context,'Không có lượng đã xuất cần nhập trả.',error:true);return null;
 }
 if(sources.length>100){
  _notice(context,'Số nguồn xuất quá nhiều; hãy đối soát/chia chứng từ nhập trả.',
    error:true);return null;
 }
 final reason=TextEditingController();
 final controllers=List<TextEditingController>.generate(
   sources.length,(_)=>TextEditingController(text:'0'));
 String? fault;
 Map<String,dynamic>? selected;
 try{
  selected=await showDialog<Map<String,dynamic>>(context:context,
   builder:(c)=>StatefulBuilder(builder:(c,update)=>AlertDialog(
    title:const Text('Nhập trả hàng chưa giao'),
    content:SizedBox(width:600,child:ConstrainedBox(
      constraints:const BoxConstraints(maxHeight:480),
      child:ListView(shrinkWrap:true,children:[
       const Text('Chọn chính xác dòng xuất và số trả theo đơn vị gốc. '
        'Lô, vị trí được khôi phục từ chứng từ xuất; không nhập tùy ý.'),
       const SizedBox(height:12),
       for(var i=0;i<sources.length;i++)...[
        Row(children:[
         Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          Text('Dòng '+sources[i]['lineNo'].toString(),
           style:const TextStyle(fontWeight:FontWeight.w700)),
          Text('Có thể trả: '+erpNumberText(sources[i]['returnableBase']),
           style:const TextStyle(fontSize:12)),
         ])),
         SizedBox(width:160,child:TextField(controller:controllers[i],
          inputFormatters:const [ErpGroupedNumberFormatter(maxIntegerDigits:12,maxFractionDigits:6)],
          keyboardType:const TextInputType.numberWithOptions(decimal:true),
          decoration:const InputDecoration(isDense:true,labelText:'Số trả'))),
        ]),
        const Divider(height:16),
       ],
       TextField(controller:reason,maxLength:500,
        decoration:const InputDecoration(labelText:'Lý do trả (bắt buộc)')),
       if(fault!=null)Text(fault!,style:const TextStyle(color:Colors.red)),
      ]))),
    actions:[
     TextButton(onPressed:()=>Navigator.pop(c),child:const Text('Hủy')),
     FilledButton(onPressed:(){
      if(reason.text.trim().length<3){update(()=>fault='Cần ghi lý do trả hàng.');return;}
      final lines=<Map<String,dynamic>>[];
      for(var i=0;i<sources.length;i++){
       final q=erpInventoryBaseUnits(controllers[i].text),
        max=erpInventoryBaseUnits(sources[i]['returnableBase'].toString());
       if(q==null||max==null||q>max){
        update(()=>fault='Lượng trả vượt lượng có thể trả hoặc sai định dạng.');
        return;
       }
       if(q==BigInt.zero)continue;
       lines.add({'issueId':sources[i]['issueId'],'sourceLine':sources[i]['sourceLine'],
        'quantityBase':erpInventoryFormatUnits(q)});
      }
      if(lines.isEmpty){update(()=>fault='Chọn ít nhất một số lượng cần nhập trả.');return;}
      Navigator.pop(c,{'branchId':branch,'warehouseId':warehouse,'orderId':order,
       'version':state['version'],'reason':reason.text.trim(),'lines':lines});
     },child:const Text('Xác nhận nhập trả')),
    ],
   )));
 }finally{
  reason.dispose();
  for(final controller in controllers)controller.dispose();
 }
 return selected;
}
Future<Map<String,dynamic>?> _askPayment(BuildContext context,
 Map<String,dynamic> state,String branch,String warehouse,String order,
 {required bool full})async{
 if(state['completed']!=true){
  _notice(context,'Chỉ được thu tiền sau khi đã xác nhận hàng giao thực tế.',
    error:true);return null;
 }
 final remaining=BigInt.tryParse(state['remaining'].toString())??BigInt.zero;
 if(remaining<=BigInt.zero){
  _notice(context,'Đơn không còn công nợ cần thu.',error:true);return null;
 }
 final controller=TextEditingController(
  text:full?erpNumberText(remaining.toString()):'0');
 String method='CASH';String? fault;
 Map<String,dynamic>? result;
 try{
  result=await showDialog<Map<String,dynamic>>(context:context,
    builder:(c)=>StatefulBuilder(builder:(c,update)=>AlertDialog(
      title:Text(full?'Thu đủ công nợ':'Thu tiền / ghi nợ'),
      content:SizedBox(width:420,child:Column(mainAxisSize:MainAxisSize.min,
       crossAxisAlignment:CrossAxisAlignment.stretch,children:[
        _paymentFact('Tổng tiền',state['grandTotal']),
        _paymentFact('Đã thu',state['paid']),
        const Divider(),
        _paymentFact('Còn phải thu',state['remaining'],strong:true),
        const SizedBox(height:15),
        TextField(controller:controller,
         inputFormatters:const [ErpGroupedNumberFormatter(maxIntegerDigits:16,maxFractionDigits:0)],
         keyboardType:TextInputType.number,
         decoration:const InputDecoration(labelText:'Số tiền thu (VND)',
           helperText:'Nhập 0 để ghi nợ, không tạo phiếu thu 0 đồng')),
        const SizedBox(height:8),
        DropdownButtonFormField<String>(initialValue:method,
          decoration:const InputDecoration(labelText:'Phương thức'),
          items:const [DropdownMenuItem(value:'CASH',child:Text('Tiền mặt')),
           DropdownMenuItem(value:'BANK_TRANSFER',child:Text('Chuyển khoản'))],
          onChanged:(v)=>update(()=>method=v??'CASH')),
        if(fault!=null)Padding(padding:const EdgeInsets.only(top:8),
          child:Text(fault!,style:const TextStyle(color:Colors.red))),
       ])),
      actions:[
       TextButton(onPressed:()=>Navigator.pop(c),child:const Text('Hủy')),
       FilledButton(onPressed:(){
        final raw=erpNumberCanonical(controller.text);
        final value=RegExp(r'^(0|[1-9][0-9]{0,15})$').hasMatch(raw)?
          BigInt.tryParse(raw):null;
        if(value==null||value>remaining){
          update(()=>fault='Số thu không hợp lệ hoặc lớn hơn công nợ.');
          return;
        }
        Navigator.pop(c,{'branchId':branch,'warehouseId':warehouse,
          'orderId':order,'amount':raw,'method':method});
       },child:Text(full?'Thu đủ':'Xác nhận')),
      ],
    )));
 }finally{controller.dispose();}
 return result;
}
Widget _paymentFact(String label,Object? amount,{bool strong=false})=>
 Padding(padding:const EdgeInsets.symmetric(vertical:4),child:Row(children:[
  Expanded(child:Text(label,style:TextStyle(
   fontWeight:strong?FontWeight.w800:FontWeight.w500))),
  Text(erpVndText(amount),style:TextStyle(
   fontSize:strong?17:13,fontWeight:FontWeight.w800)),
 ]));
