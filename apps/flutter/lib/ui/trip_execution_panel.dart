import 'package:material_ui/material_ui.dart';
import 'identity_client.dart';

/// Chuyến đã khóa: chỉ đọc số lượng server, không giả lập chứng từ/offline ACK.
class TripExecutionPanel extends StatefulWidget{
 final ErpIdentityClient client;final IdentitySession session;
 final String branchId,warehouseId,tripId;
 const TripExecutionPanel({super.key,required this.client,required this.session,
  required this.branchId,required this.warehouseId,required this.tripId});
 @override State<TripExecutionPanel> createState()=>_TripExecutionPanelState();
}
class _TripExecutionPanelState extends State<TripExecutionPanel>{
 Map<String,dynamic>? execution;
 bool loading=true,busy=false;String? error;
 int epoch=0;
 bool has(String permission,{bool warehouse=false})=>widget.session.grants.any((g)=>
  g.permission==permission&&g.branchId==widget.branchId&&
  (!warehouse||g.warehouseId==widget.warehouseId));
 bool get manager=>has('delivery.update')&&has('inventory.read',warehouse:true);
 bool get driver=>has('delivery.execute')&&has('inventory.read',warehouse:true);
 bool get warehouseStaff=>has('delivery.update')&&has('inventory.post',warehouse:true);
 bool get collector=>has('delivery.cod.handover')&&has('finance.payments.record')&&
  has('inventory.read',warehouse:true);
 @override void initState(){super.initState();_load();}
 @override void didUpdateWidget(covariant TripExecutionPanel old){
  super.didUpdateWidget(old);
  if(old.tripId!=widget.tripId||old.branchId!=widget.branchId||
   old.warehouseId!=widget.warehouseId||old.session.actorId!=widget.session.actorId||
   old.session.token!=widget.session.token){execution=null;_load();}
 }
 Future<void> _load()async{
  final current=++epoch;
  if(mounted)setState((){loading=true;error=null;});
  try{
   final data=await widget.client.deliveryExecutionRead(widget.session,
    branchId:widget.branchId,warehouseId:widget.warehouseId,tripId:widget.tripId);
   if(mounted&&epoch==current)setState((){execution=data;loading=false;});
  }on ErpApiError catch(e){
   if(mounted&&epoch==current)setState((){loading=false;
    error=e.status==503?'Chức năng thực thi chuyến chưa được kích hoạt.':e.message;});
  }catch(_){
   if(mounted&&epoch==current)setState((){loading=false;
    error='Không tải được kết quả giao. Kiểm tra kết nối rồi tải lại.';});
  }
 }
 Future<void> _write(String action,Map<String,dynamic> payload,int revision)async{
  if(busy)return;
  setState((){busy=true;error=null;});
  try{
   await widget.client.deliveryExecutionWrite(widget.session,action,{
    'branchId':widget.branchId,'warehouseId':widget.warehouseId,
    'tripId':widget.tripId,...payload},revision);
   if(!mounted)return;
   ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
    content:Text('Đã ghi nhận trên hệ thống.'),duration:Duration(seconds:2)));
   await _load();
  }on ErpApiError catch(e){
   if(mounted)setState(()=>error=e.status==504||e.status==503?
    'Chưa rõ kết quả ghi nhận. Tải lại dữ liệu để đối chiếu rồi mới thử lại.':
    e.message);
  }catch(_){
   if(mounted)setState(()=>error=
    'Chưa có xác nhận từ máy chủ. Tải lại điểm giao trước khi thử lại.');
  }finally{if(mounted)setState(()=>busy=false);}
 }
 String _stamp(DateTime dt){
  final value=dt.toUtc().toIso8601String();
  return value.contains('.')?value:value.replaceFirst('Z','.000Z');
 }
 List<Map<String,dynamic>> available(Map<String,dynamic> stop){
  final lines=(stop['lines'] as List?)??[];
  return lines.map((x)=>Map<String,dynamic>.from(x as Map))
   .where((x){
    final s=x['onVehicleBase']?.toString()??'0';
    return double.tryParse(s)!=null&&double.parse(s)>0;
   }).toList();
 }
 Future<void> _attempt(Map<String,dynamic> stop)async{
  final lines=available(stop);if(lines.isEmpty)return;
  String result='DELIVERED_FULL',reason='CUSTOMER_ABSENT';
  DateTime next=DateTime.now().add(const Duration(days:1));
  final controls=[for(final x in lines)
   TextEditingController(text:x['onVehicleBase']?.toString()??'0')];
  try{
   final payload=await showModalBottomSheet<Map<String,dynamic>>(context:context,
    isScrollControlled:true,showDragHandle:true,builder:(sheetContext)=>
    StatefulBuilder(builder:(sheetContext,refresh)=>Padding(
     padding:EdgeInsets.fromLTRB(16,4,16,
      MediaQuery.viewInsetsOf(sheetContext).bottom+16),
     child:SingleChildScrollView(child:Column(
      mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.stretch,
      children:[
       Text('Kết quả giao · ${stop['documentNo']}',
        style:Theme.of(sheetContext).textTheme.titleMedium),
       const SizedBox(height:12),
       DropdownButtonFormField<String>(
        initialValue:result,decoration:const InputDecoration(
         labelText:'Kết quả thực tế',isDense:true),
        items:const [
         DropdownMenuItem(value:'DELIVERED_FULL',child:Text('Giao đủ hàng xuất')),
         DropdownMenuItem(value:'DELIVERED_PARTIAL',child:Text('Giao một phần')),
         DropdownMenuItem(value:'FAILED',child:Text('Giao thất bại')),
         DropdownMenuItem(value:'RESCHEDULED',child:Text('Hẹn giao lại')),
        ],
        onChanged:(v)=>refresh(()=>result=v??result)),
       if(result=='DELIVERED_PARTIAL')...[
        const SizedBox(height:10),
        for(int i=0;i<lines.length;i++)Padding(
         padding:const EdgeInsets.only(bottom:8),
         child:TextFormField(controller:controls[i],
          keyboardType:const TextInputType.numberWithOptions(decimal:true),
          decoration:InputDecoration(isDense:true,
           labelText:'${lines[i]['productName']} · ${lines[i]['baseUnit']}',
           helperText:'Còn trên xe: ${lines[i]['onVehicleBase']}'))),
       ],
       if(result=='FAILED'||result=='RESCHEDULED')...[
        const SizedBox(height:10),
        DropdownButtonFormField<String>(initialValue:reason,
         isExpanded:true,decoration:const InputDecoration(labelText:'Lý do'),
         items:const [
          DropdownMenuItem(value:'CUSTOMER_ABSENT',child:Text('Không gặp khách')),
          DropdownMenuItem(value:'CUSTOMER_REFUSED',child:Text('Khách không nhận')),
          DropdownMenuItem(value:'ADDRESS_ERROR',child:Text('Sai địa chỉ')),
          DropdownMenuItem(value:'REQUESTED_NEW_TIME',child:Text('Khách hẹn giờ khác')),
          DropdownMenuItem(value:'OTHER',child:Text('Lý do khác')),
         ],onChanged:(v)=>refresh(()=>reason=v??reason)),
       ],
       if(result=='RESCHEDULED')TextButton.icon(
        icon:const Icon(Icons.event),
        label:Text('Ngày giao lại: ${next.day}/${next.month}/${next.year}'),
        onPressed:()async{
         final date=await showDatePicker(context:sheetContext,
          firstDate:DateTime.now().add(const Duration(days:1)),
          lastDate:DateTime.now().add(const Duration(days:365)),
          initialDate:next);
         if(date!=null)refresh(()=>next=DateTime(date.year,date.month,date.day,12));
        }),
       const SizedBox(height:12),
       FilledButton(onPressed:busy?null:(){
        Navigator.of(sheetContext).pop(<String,dynamic>{
         'orderId':stop['orderId'],'result':result,
         if(result=='DELIVERED_PARTIAL')'lines':[
          for(int i=0;i<lines.length;i++){
           'dispatchId':lines[i]['dispatchId'],
           'sourceLine':lines[i]['sourceLine'],
           'deliveredBase':controls[i].text.trim()
          }],
         if(result=='FAILED'||result=='RESCHEDULED')'reasonCode':reason,
         if(result=='RESCHEDULED')'rescheduledFor':_stamp(next)
        });
       },child:const Text('Xác nhận kết quả giao')),
      ]))),
    ));
   if(payload!=null)await _write('attempt',payload,stop['revision'] as int);
  }finally{for(final c in controls){c.dispose();}}
 }
 Future<void> _returnGoods(Map<String,dynamic> stop)async{
  final lines=available(stop);if(lines.isEmpty)return;
  final reason=TextEditingController();
  final controls=[for(int i=0;i<lines.length;i++)TextEditingController(text:'0')];
  try{
   final payload=await showModalBottomSheet<Map<String,dynamic>>(
    context:context,isScrollControlled:true,showDragHandle:true,
    builder:(sheetContext)=>Padding(
     padding:EdgeInsets.fromLTRB(16,4,16,MediaQuery.viewInsetsOf(sheetContext).bottom+16),
     child:SingleChildScrollView(child:Column(
      mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.stretch,
      children:[
       Text('Nhập trả hàng chưa giao · ${stop['documentNo']}',
        style:Theme.of(sheetContext).textTheme.titleMedium),
       const SizedBox(height:10),
       for(int i=0;i<lines.length;i++)TextFormField(
        controller:controls[i],keyboardType:const TextInputType.numberWithOptions(decimal:true),
        decoration:InputDecoration(isDense:true,
         labelText:'${lines[i]['productName']} · ${lines[i]['baseUnit']}',
         helperText:'Còn trên xe: ${lines[i]['onVehicleBase']}')),
       const SizedBox(height:8),
       TextFormField(controller:reason,decoration:const InputDecoration(
        isDense:true,labelText:'Lý do nhập trả')),
       const SizedBox(height:12),
       FilledButton(onPressed:()=>Navigator.of(sheetContext).pop({
        'orderId':stop['orderId'],'reason':reason.text.trim(),
        'lines':[for(int i=0;i<lines.length;i++)
         if(controls[i].text.trim()!='0'&&controls[i].text.trim()!='0.000000')
          {'dispatchId':lines[i]['dispatchId'],
           'sourceLine':lines[i]['sourceLine'],
           'quantityBase':controls[i].text.trim()}]
       }),child:const Text('Xác nhận đã nhập trả kho'))
      ]))),
   );
   if(payload!=null)await _write('return',payload,stop['revision'] as int);
  }finally{reason.dispose();for(final c in controls){c.dispose();}}
 }
 Future<void> _collect(Map<String,dynamic> stop)async{
  final amount=TextEditingController(text:stop['remaining']?.toString()??'0');
  String method='CASH';
  try{
   final payload=await showModalBottomSheet<Map<String,dynamic>>(
    context:context,isScrollControlled:true,showDragHandle:true,
    builder:(sheetContext)=>StatefulBuilder(builder:(sheetContext,refresh)=>
     Padding(padding:EdgeInsets.fromLTRB(16,8,16,MediaQuery.viewInsetsOf(sheetContext).bottom+16),
     child:SingleChildScrollView(child:Column(
      mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.stretch,
      children:[
       Text('Thu tiền · ${stop['documentNo']}',style:Theme.of(sheetContext).textTheme.titleMedium),
       Text('Còn phải thu: ${stop['remaining']} đ'),
       const SizedBox(height:12),
       TextFormField(controller:amount,keyboardType:TextInputType.number,
        decoration:const InputDecoration(labelText:'Tiền thực nhận (0 = ghi nợ)',isDense:true)),
       const SizedBox(height:8),
       DropdownButtonFormField<String>(initialValue:method,
        decoration:const InputDecoration(labelText:'Phương thức',isDense:true),
        items:const [
         DropdownMenuItem(value:'CASH',child:Text('Tiền mặt')),
         DropdownMenuItem(value:'BANK_TRANSFER',child:Text('Chuyển khoản')),
        ],onChanged:(v)=>refresh(()=>method=v??method)),
       const SizedBox(height:12),
       FilledButton(onPressed:()=>Navigator.of(sheetContext).pop({
        'orderId':stop['orderId'],'amount':amount.text.trim(),'method':method}),
        child:const Text('Ghi nhận thực thu')),
      ]))),
    ));
   if(payload!=null)await _write('collect',payload,stop['revision'] as int);
  }finally{amount.dispose();}
 }
 Future<void> _handover()async{
  final collections=(execution?['collections'] as List?)??[];
  final selected=<Map<String,dynamic>>[];
  for(final x in collections){
   final row=Map<String,dynamic>.from(x as Map);
   final amount=int.tryParse(row['amount']?.toString()??'0')??0;
   final handed=int.tryParse(row['handed']?.toString()??'0')??0;
   if(amount>handed)selected.add({'collectionId':row['id'],
    'amount':(amount-handed).toString()});
  }
  if(selected.isEmpty)return;
  final confirmed=await showDialog<bool>(context:context,builder:(dialogContext)=>AlertDialog(
   title:const Text('Bàn giao COD'),
   content:Text('Xác nhận đã nhận ${selected.fold<int>(0,(s,x)=>s+
    (int.tryParse(x['amount'] as String)??0))} đ tiền mặt từ tài xế?'),
   actions:[
    TextButton(onPressed:()=>Navigator.of(dialogContext).pop(false),child:const Text('Hủy')),
    FilledButton(onPressed:()=>Navigator.of(dialogContext).pop(true),child:const Text('Đã thực nhận')),
   ],
  ));
  if(confirmed==true)await _write('handover',{'collectionLines':selected},
   execution?['revision'] as int? ??0);
 }
 @override Widget build(BuildContext context){
  final data=execution;
  return Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
   const Divider(),
   Wrap(alignment:WrapAlignment.spaceBetween,crossAxisAlignment:WrapCrossAlignment.center,
    spacing:8,runSpacing:8,children:[
     const Text('Thực thi giao hàng',style:TextStyle(fontWeight:FontWeight.w800,fontSize:16)),
     TextButton.icon(onPressed:busy||loading?null:_load,
      icon:const Icon(Icons.refresh,size:18),label:const Text('Đối chiếu')),
   ]),
   if(error!=null)Padding(padding:const EdgeInsets.symmetric(vertical:8),
    child:Text(error!,style:TextStyle(color:Theme.of(context).colorScheme.error))),
   if(loading)const Padding(padding:EdgeInsets.all(20),child:Center(child:CircularProgressIndicator())),
   if(!loading&&data!=null)...[
    Wrap(spacing:8,runSpacing:8,children:[
     Text(data['status']=='DEPARTED'?'Đã xuất phát':'Chưa xuất phát'),
     if(data['status']=='LOCKED'&&manager)
      FilledButton.icon(key:const ValueKey('trip-depart'),onPressed:busy?null:()=>
       _write('start',{},data['revision'] as int),
       icon:const Icon(Icons.local_shipping_outlined),label:const Text('Xác nhận xuất phát')),
     if(data['status']=='DEPARTED'&&collector)
      OutlinedButton.icon(key:const ValueKey('trip-cod-handover'),
       onPressed:busy?null:_handover,icon:const Icon(Icons.payments_outlined),
       label:const Text('Bàn giao COD')),
    ]),
    if(data['status']=='DEPARTED')
     for(final item in (data['stops'] as List? ?? []))
      Builder(builder:(context){
       final stop=Map<String,dynamic>.from(item as Map),left=available(stop);
       final attempts=(stop['attempts'] as List?)??[];
       final last=attempts.isEmpty?null:attempts.last as Map;
       return Card(margin:const EdgeInsets.symmetric(vertical:4),
        child:ExpansionTile(key:ValueKey('exec-stop-${stop['orderId']}'),
         title:Text('${stop['sequenceNo']}. ${stop['customerName']}',
          maxLines:1,overflow:TextOverflow.ellipsis,
          style:const TextStyle(fontWeight:FontWeight.w700)),
         subtitle:Text('${stop['documentNo']} · Nợ: ${stop['remaining']} đ',
          maxLines:1,overflow:TextOverflow.ellipsis),
         children:[Padding(padding:const EdgeInsets.fromLTRB(12,0,12,12),
          child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
           Text(stop['deliveryAddress']?.toString()??''),
           const SizedBox(height:8),
           for(final x in (stop['lines'] as List? ?? []))
            Padding(padding:const EdgeInsets.symmetric(vertical:3),
             child:Text('${(x as Map)['productName']}: xuất ${x['issuedBase']} · giao ${x['deliveredBase']} · trả ${x['returnedBase']} · trên xe ${x['onVehicleBase']} ${x['baseUnit']}',
              style:const TextStyle(fontSize:12))),
           if(last!=null)Text('Lần giao gần nhất: ${last['result']}',
            style:const TextStyle(fontSize:12,fontWeight:FontWeight.w600)),
           const SizedBox(height:8),
           Wrap(spacing:7,runSpacing:7,children:[
            if(driver&&left.isNotEmpty)
             FilledButton.icon(onPressed:busy?null:()=>_attempt(stop),
              icon:const Icon(Icons.fact_check_outlined),
              label:const Text('Xác nhận giao')),
            if(warehouseStaff&&left.isNotEmpty)
             OutlinedButton.icon(onPressed:busy?null:()=>_returnGoods(stop),
              icon:const Icon(Icons.assignment_return_outlined),
              label:const Text('Nhập trả')),
            if(driver&&(int.tryParse(stop['remaining']?.toString()??'0')??0)>0)
             OutlinedButton.icon(onPressed:busy?null:()=>_collect(stop),
              icon:const Icon(Icons.payments_outlined),
              label:const Text('Thu COD')),
           ]),
          ]))]));
      }),
   ],
  ]);
 }
}
