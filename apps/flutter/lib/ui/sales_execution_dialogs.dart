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
  final recovered=await client.reconcileSalesExecution(session,
    branchId:branchId,warehouseId:warehouse,orderId:orderId);
  if(recovered!=null){
    _notice(context,'Đã đối soát chứng từ chờ. Tải lại đơn để kiểm tra số liệu.');
    return true;
  }
  final scope=client.localScope(session,branchId,warehouse:warehouse);
  final pending=scope==null?null:await client.localStore?.executionPending(scope,orderId);
  if(pending!=null){
    final previousAction=pending['action'],previousRevision=pending['revision'],
      previousKey=pending['key'],previousBody=pending['body'];
    if(previousAction is! String||previousRevision is! int||
       previousKey is! String||previousBody is! Map){
      _notice(context,'Chứng từ chờ không hợp lệ. Cần đối soát trước.',error:true);
      return false;
    }
    if(!context.mounted)return false;
    final oldBody=Map<String,dynamic>.from(previousBody);
    final label=previousAction=='return'?'Nhập trả kho':
      previousAction=='complete'?'Hoàn thành giao hàng':
      previousAction=='payment'?'Thu tiền':null;
    if(label==null){
      _notice(context,'Lệnh chờ không hợp lệ. Cần đối soát thủ công.',error:true);
      return false;
    }
    final yes=await showDialog<bool>(context:context,builder:(c)=>AlertDialog(
      title:const Text('Khôi phục thao tác chờ'),
      content:Column(mainAxisSize:MainAxisSize.min,
        crossAxisAlignment:CrossAxisAlignment.start,children:[
         const Text('Máy chủ chưa có biên nhận cho lệnh trước. '
           'Không gửi lệnh mới khi chưa đối soát xong.'),
         const SizedBox(height:10),
         Text('Lệnh gốc: '+label,style:const TextStyle(fontWeight:FontWeight.w700)),
         if(previousAction=='payment')
           Text('Số thu cũ: '+erpVndText(oldBody['amount'])),
         const SizedBox(height:8),
         const Text('Thử lại đúng nội dung, revision và Idempotency-Key đã lưu. '
           'Ứng dụng kiểm tra biên nhận trước khi gửi lại.'),
        ]),
      actions:[
        TextButton(onPressed:()=>Navigator.pop(c,false),
          child:const Text('Giữ lệnh')),
        FilledButton(onPressed:()=>Navigator.pop(c,true),
          child:const Text('Thử lại lệnh gốc')),
      ]));
    if(yes!=true||!context.mounted)return false;
    final receipt=await client.postSalesExecution(session,previousAction,
      oldBody,previousRevision);
    if(context.mounted)_notice(context,previousAction=='payment'?
      'Đã xác nhận thu '+erpVndText(receipt['amount'])+
        ' · Còn phải thu '+erpVndText(receipt['remaining']):
      'Đã xác nhận thao tác '+label.toLowerCase()+'.');
    return true;
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
    fields=await _askReturn(context,state,branchId,warehouse,orderId,client,session);
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
 if(state['hasIssuedHistory']!=true){
  _notice(context,'Đơn chưa có lịch sử xuất kho. Cần xuất kho trước.',
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
      Text(state['hasIssuedDelivery']!=true?
        'Đã nhập trả toàn bộ: đóng đơn Trả hết, không phát sinh công nợ.':
        state['isFullDelivery']==true?'Giao đủ số lượng đặt.':
        'Giao thiếu: số chưa giao không được tính công nợ.'),
     ]),
   ))),
  actions:[
   TextButton(onPressed:()=>Navigator.pop(c,false),child:const Text('Hủy')),
   FilledButton(onPressed:()=>Navigator.pop(c,true),
     child:Text(state['hasIssuedDelivery']==true?'Xác nhận thực giao':
       'Đóng đơn đã trả hết')),
  ],
 ));
 if(accepted!=true)return null;
 return {'branchId':branch,'warehouseId':warehouse,'orderId':order,
   'version':state['version']};
}
Future<Map<String,dynamic>?> _askReturn(BuildContext context,
 Map<String,dynamic> state,String branch,String warehouse,String order,
 ErpIdentityClient client,IdentitySession session)async{
 // Server returns deterministic pages of 100 source rows. Only checked
 // quantities (up to 100 TOTAL across loaded pages) are ever posted.
 final pages=<List<Map<String,dynamic>>>[
   (state['sources'] as List? ??const [])
     .whereType<Map>().map((r)=>Map<String,dynamic>.from(r)).toList()
 ];
 final nextOffsets=<int?>[
   (state['nextSourceOffset'] as num?)?.toInt()
 ];
 final controllers=<List<TextEditingController>>[
   List.generate(pages[0].length,(_)=>TextEditingController(text:'0'))
 ];
 final reason=TextEditingController();
 int page=0;
 bool loading=false;
 String? fault;
 Map<String,dynamic>? selected;
 try{
  selected=await showDialog<Map<String,dynamic>>(context:context,
   builder:(dialogContext)=>StatefulBuilder(builder:(c,update){
    final current=pages[page],fields=controllers[page];
    var selectedCount=0;
    for(final batch in controllers){
      for(final ctrl in batch){
        final q=erpInventoryBaseUnits(ctrl.text);
        if(q!=null&&q>BigInt.zero)selectedCount++;
      }
    }
    Future<void> showNext()async{
      if(loading||nextOffsets[page]==null)return;
      final fromPage=page;
      if(fromPage+1<pages.length){
        update(()=>page=fromPage+1);
        return;
      }
      final offset=nextOffsets[fromPage]!;
      update(()=>loading=true);
      try{
        final result=await client.salesExecutionRead(session.token,
          branchId:branch,warehouseId:warehouse,orderId:order,
          sourceOffset:offset);
        if(!c.mounted)return;
        if(result['revision']!=state['revision']){
          update(()=>fault='Đơn thay đổi trong khi chọn hàng. Hãy đóng và tải lại.');
          return;
        }
        final incoming=(result['sources'] as List? ??const [])
          .whereType<Map>().map((v)=>Map<String,dynamic>.from(v)).toList();
        pages.add(incoming);
        controllers.add(List.generate(incoming.length,
           (_)=>TextEditingController(text:'0')));
        nextOffsets.add((result['nextSourceOffset'] as num?)?.toInt());
        update((){
          page=fromPage+1;
          fault=null;
        });
      }on ErpApiError catch(e){
        if(c.mounted)update(()=>fault='Không tải được trang hàng: '+e.message);
      }catch(_){
        if(c.mounted)update(()=>fault='Chưa tải được trang hàng; chưa ghi chứng từ.');
      }finally{
        if(c.mounted)update(()=>loading=false);
      }
    }
    void submit(){
      if(loading)return;
      if(reason.text.trim().length<3){
        update(()=>fault='Cần ghi rõ lý do nhập trả.');return;
      }
      final lines=<Map<String,dynamic>>[];
      for(var p=0;p<pages.length;p++){
        for(var i=0;i<pages[p].length;i++){
          final source=pages[p][i];
          final q=erpInventoryBaseUnits(controllers[p][i].text);
          final max=erpInventoryBaseUnits((source['returnableBase']??'0').toString());
          if(q==null||max==null||q< BigInt.zero||q>max){
            update((){
              page=p;
              fault='Dòng ở trang '+(p+1).toString()+
                ' có số trả sai hoặc vượt số còn có thể trả.';
            });
            return;
          }
          if(q==BigInt.zero)continue;
          lines.add({'issueId':source['issueId'],
             'sourceLine':source['sourceLine'],
             'quantityBase':erpInventoryFormatUnits(q)});
        }
      }
      if(lines.isEmpty){
        update(()=>fault='Chọn ít nhất một lượng cần nhập trả.');return;
      }
      if(lines.length>100){
        update(()=>fault='Một phiếu tối đa 100 nguồn xuất. Hãy chia làm nhiều lần nhập trả.');
        return;
      }
      Navigator.pop(c,{'branchId':branch,'warehouseId':warehouse,'orderId':order,
        'version':state['version'],'reason':reason.text.trim(),'lines':lines});
    }
    return AlertDialog(
     title:const Text('Nhập trả hàng chưa giao'),
     content:SizedBox(width:600,
       height:MediaQuery.sizeOf(c).height>720?480:MediaQuery.sizeOf(c).height*0.62,
       child:Column(mainAxisSize:MainAxisSize.min,
         crossAxisAlignment:CrossAxisAlignment.stretch,children:[
         const Text('Đối chiếu dòng xuất và lượng trả theo đơn vị gốc. '
           'Lô, vị trí sẽ khôi phục từ chứng từ xuất.',
           style:TextStyle(fontSize:12)),
         const SizedBox(height:6),
         Row(children:[
          Expanded(child:Text('Trang '+(page+1).toString()+
            ' · Đã chọn '+selectedCount.toString()+'/100 nguồn',
            style:const TextStyle(fontWeight:FontWeight.w700,fontSize:12))),
          IconButton(tooltip:'Trang trước',onPressed:loading||page==0?
            null:()=>update(()=>page--),
            icon:const Icon(Icons.chevron_left)),
          IconButton(tooltip:'Trang sau',
            onPressed:loading||nextOffsets[page]==null?null:showNext,
            icon:const Icon(Icons.chevron_right)),
         ]),
         if(loading)const LinearProgressIndicator(),
         const Divider(height:10),
         Expanded(child:ListView.builder(itemCount:current.length,
            itemBuilder:(listContext,i){
              final row=current[i],q=erpInventoryBaseUnits(
                (row['returnableBase']??'0').toString())??BigInt.zero;
              if(q<=BigInt.zero)return const SizedBox.shrink();
              final issueId=(row['issueId']??'').toString();
              final when=DateTime.tryParse((row['issuedAt']??'').toString())?.toLocal();
              final timestamp=when==null?'Chưa có thời gian xuất':
                '${when.day.toString().padLeft(2,'0')}/${when.month.toString().padLeft(2,'0')} '
                '${when.hour.toString().padLeft(2,'0')}:${when.minute.toString().padLeft(2,'0')}';
              final lotCode=(row['lotCode']??'').toString().trim();
              final locCode=(row['locationCode']??'').toString().trim();
              final locName=(row['locationName']??'').toString().trim();
              final lot=lotCode.isEmpty?'Không gắn lô':lotCode;
              final location=locCode.isEmpty?'Không gắn vị trí':
                locName.isEmpty?locCode:'$locCode · $locName';
              final shortId=issueId.length>=8?issueId.substring(issueId.length-8):issueId;
              return Padding(padding:const EdgeInsets.symmetric(vertical:6),
                child:Row(crossAxisAlignment:CrossAxisAlignment.start,children:[
                  Expanded(child:Column(
                    crossAxisAlignment:CrossAxisAlignment.start,children:[
                    Text((row['productName']??'Sản phẩm').toString()+
                      ' · '+(row['productSku']??'').toString(),
                      style:const TextStyle(fontWeight:FontWeight.w700)),
                    Tooltip(message:'Mã chứng từ xuất: '+issueId,
                      child:Text('PX $shortId · Nguồn '+row['sourceLine'].toString()+
                        ' · $timestamp',style:const TextStyle(fontSize:11))),
                    Text('Lô: $lot · Vị trí: $location',
                      style:const TextStyle(fontSize:12,fontWeight:FontWeight.w600)),
                    Text('Dòng '+row['lineNo'].toString()+
                      ' · Có thể trả: '+erpNumberText(row['returnableBase'])+
                      ' '+(row['baseUnit']??'').toString(),
                      style:const TextStyle(fontSize:12)),
                  ])),
                  const SizedBox(width:8),
                  SizedBox(width:138,child:TextField(controller:fields[i],
                    onChanged:(_)=>update((){}),
                    inputFormatters:const [
                      ErpGroupedNumberFormatter(maxIntegerDigits:12,maxFractionDigits:6)],
                    keyboardType:const TextInputType.numberWithOptions(decimal:true),
                    decoration:const InputDecoration(
                      isDense:true,labelText:'Số lượng trả'))),
                ]));
            })),
         const SizedBox(height:8),
         TextField(controller:reason,maxLength:500,
           decoration:const InputDecoration(
             isDense:true,labelText:'Lý do trả (bắt buộc)')),
         if(fault!=null)Text(fault!,
           style:const TextStyle(color:Colors.red,fontSize:12)),
       ])),
     actions:[
       TextButton(onPressed:loading?null:()=>Navigator.pop(c),
         child:const Text('Hủy')),
       FilledButton(onPressed:loading?null:submit,
         child:const Text('Xác nhận nhập trả')),
     ]);
   }));
 }finally{
  reason.dispose();
  for(final batch in controllers){
    for(final controller in batch)controller.dispose();
  }
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
