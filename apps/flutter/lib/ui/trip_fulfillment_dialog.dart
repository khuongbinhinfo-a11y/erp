import 'package:material_ui/material_ui.dart';
import 'erp_number_input.dart';
import 'identity_client.dart';

/// A requested server command, not a completed warehouse posting.
/// Parent inventory workspace executes it with persistent idempotency retry.
class TripCommand {
  final String action;
  final Map<String,dynamic> body;
  final int revision;
  const TripCommand(this.action,this.body,this.revision);
}

class TripFulfillmentDialog extends StatefulWidget {
  final ErpIdentityClient client;
  final IdentitySession session;
  final String branchId,warehouseId,mode;
  final String? initialOrderId;
  const TripFulfillmentDialog({super.key,required this.client,required this.session,
    required this.branchId,required this.warehouseId,required this.mode,this.initialOrderId});
  @override State<TripFulfillmentDialog> createState()=>_TripFulfillmentDialogState();
}

class _TripFulfillmentDialogState extends State<TripFulfillmentDialog> {
  bool loading=true;
  String? error,orderId;
  Map<String,dynamic>? work;
  List<Map<String,dynamic>> orders=[],records=[];
  final Map<String,Map<String,dynamic>> scopes={};
  final Map<int,String?> chosenLocation={},chosenLot={};
  final picks=<TextEditingController>[],packs=<TextEditingController>[];
  int nonce=0;
  bool get preparing=>widget.mode=='prepare';
  @override void initState(){super.initState();orderId=widget.initialOrderId;load();}
  @override void dispose(){
    nonce++;
    clearEditors();
    super.dispose();
  }
  void clearEditors(){
    for(final c in picks){c.dispose();}
    for(final c in packs){c.dispose();}
    picks.clear();packs.clear();scopes.clear();chosenLocation.clear();chosenLot.clear();
  }
  Future<void> load()async{
    final n=++nonce;
    setState((){loading=true;error=null;work=null;});
    try{
      if(orders.isEmpty&&widget.initialOrderId==null){
        orders=(await widget.client.salesOrders(widget.session.token,widget.branchId))
          .where((x)=>x['status']=='CONFIRMED'&&
            (x['deliveryChoice']==null||x['deliveryChoice']=='TRIP')).toList();
        orderId ??= orders.isNotEmpty?orders.first['id'].toString():null;
      }
      if(orderId==null)throw const ErpApiError(409,'Không có đơn theo chuyến phù hợp.');
      final detail=await widget.client.salesOrder(
        widget.session.token,orderId!,widget.branchId);
      final shipping=detail['shipping'];
      if(shipping is! Map||shipping['deliveryChoice']!='TRIP'||
          shipping['warehouseId']!=widget.warehouseId)
        throw const ErpApiError(409,'Đơn không thuộc kho giao theo chuyến.');
      final version=int.tryParse(detail['version'].toString());
      if(version==null||version<1)throw const ErpApiError(409,'Đơn đã thay đổi phiên bản.');
      final data=await widget.client.inventoryTripWork(widget.session.token,
        branchId:widget.branchId,warehouseId:widget.warehouseId,
        orderId:orderId!,version:version);
      if(!mounted||n!=nonce)return;
      clearEditors();
      final lines=(data['lines'] as List<dynamic>)
        .map((x)=>Map<String,dynamic>.from(x as Map)).toList();
      final entries=<Map<String,dynamic>>[];
      if(preparing){
        entries.addAll(lines.where((x)=>x['reservationId']!=null));
        for(final x in entries){
          final productId=x['productId'].toString();
          if(!scopes.containsKey(productId)){
            scopes[productId]=await widget.client.inventoryStockScopes(
              widget.session.token,branchId:widget.branchId,
              warehouseId:widget.warehouseId,productId:productId);
          }
        }
      }else{
        for(final x in lines){
          for(final item in (x['preparations'] as List<dynamic>)){
            final p=Map<String,dynamic>.from(item as Map);
            final ready=p['readyBase'].toString();
            if(RegExp(r'^0(?:\.0+)?$').hasMatch(ready))continue;
            entries.add({...p,'productName':x['productName'],'sku':x['sku']});
          }
        }
      }
      if(!mounted||n!=nonce)return;
      for(final x in entries){
        picks.add(TextEditingController());
        packs.add(TextEditingController(text:preparing?'':erpGroupedDecimalText(x['readyBase'])));
      }
      setState((){records=entries;work=data;loading=false;});
    }on ErpApiError catch(e){
      if(mounted&&n==nonce)setState((){error=e.message;loading=false;});
    }catch(_){
      if(mounted&&n==nonce)setState((){error='Không tải được công việc kho. Hãy kiểm tra kết nối.';loading=false;});
    }
  }
  bool validQty(String text)=>RegExp(r'^(?:0|[1-9][0-9]{0,17})(?:\.[0-9]{1,6})?$').hasMatch(text);
  void submit(){
    final data=work,id=orderId;
    if(data==null||id==null||loading)return;
    final result=<Map<String,dynamic>>[];
    for(var i=0;i<records.length;i++){
      final picked=erpNumberCanonical(picks[i].text);
      final packed=erpNumberCanonical(packs[i].text);
      if(preparing){
        final a=picked.isEmpty?'0':picked,b=packed.isEmpty?'0':packed;
        if(!validQty(a)||!validQty(b)){
          setState(()=>error='Số soạn/đóng không hợp lệ. Tối đa 6 chữ số thập phân.');
          return;
        }
        if(RegExp(r'^0(?:\.0+)?$').hasMatch(a)&&
           RegExp(r'^0(?:\.0+)?$').hasMatch(b))continue;
        result.add({'lineNo':records[i]['lineNo'],'pickedBase':a,'packedBase':b,
          if(chosenLocation[i]!=null)'locationId':chosenLocation[i],
          if(chosenLot[i]!=null)'lotId':chosenLot[i]});
      }else{
        if(packed.isEmpty||RegExp(r'^0(?:\.0+)?$').hasMatch(packed))continue;
        if(!validQty(packed)){
          setState(()=>error='Số lượng xuất không hợp lệ.');return;
        }
        result.add({'preparationId':records[i]['preparationId'],
          'sourceLine':records[i]['sourceLine'],'quantityBase':packed});
      }
    }
    if(result.isEmpty){setState(()=>error='Hãy nhập ít nhất một số lượng.');return;}
    final v=int.tryParse(data['version'].toString()),rev=int.tryParse(data['revision'].toString());
    if(v==null||rev==null){setState(()=>error='Đơn đã thay đổi, vui lòng tải lại.');return;}
    Navigator.pop(context,TripCommand(
      preparing?'trips/prepare':'trips/dispatch',
      {'branchId':widget.branchId,'warehouseId':widget.warehouseId,
        'orderId':id,'version':v,'lines':result},rev));
  }
  Widget number(String label,TextEditingController c)=>SizedBox(width:145,
    child:TextField(controller:c,
      keyboardType:const TextInputType.numberWithOptions(decimal:true),
      inputFormatters:const [ErpGroupedNumberFormatter(maxFractionDigits:6)],
      decoration:InputDecoration(labelText:label,isDense:true)));
  @override Widget build(BuildContext context){
    return AlertDialog(
      title:Text(preparing?'Soạn & đóng hàng theo chuyến':'Xuất hàng theo chuyến'),
      content:SizedBox(
        width:(MediaQuery.sizeOf(context).width-140).clamp(150.0,730.0).toDouble(),
        height:(MediaQuery.sizeOf(context).height*.56).clamp(260.0,500.0).toDouble(),
        child:Column(
        crossAxisAlignment:CrossAxisAlignment.stretch,children:[
        if(widget.initialOrderId==null)Row(children:[
          Expanded(child:DropdownButtonFormField<String>(
            initialValue:orderId,isExpanded:true,
            decoration:const InputDecoration(labelText:'Đơn theo chuyến',isDense:true),
            items:orders.map((o)=>DropdownMenuItem(value:o['id'].toString(),
              child:Text((o['documentNo']??'').toString()+' · '+
                (o['customerName']??'').toString(),
                overflow:TextOverflow.ellipsis))).toList(),
            onChanged:(v){if(v!=null){orderId=v;load();}})),
        ]),
        if(!preparing)const Padding(padding:EdgeInsets.symmetric(vertical:8),
          child:Text('Chỉ xác nhận khi hàng thực sự rời kho. Chưa ghi giao thành công hoặc thu tiền.')),
        if(error!=null)Padding(padding:const EdgeInsets.symmetric(vertical:8),
          child:Text(error!,style:const TextStyle(color:Colors.red))),
        if(loading)const LinearProgressIndicator(),
        if(!loading&&records.isEmpty)const Padding(
          padding:EdgeInsets.all(12),child:Text('Chưa có hàng đủ điều kiện xử lý.')),
        Expanded(child:ListView(children:[
          for(var i=0;i<records.length;i++)...[
            const Divider(height:20),
            Text((records[i]['productName']??records[i]['sku']??'').toString(),
              style:const TextStyle(fontWeight:FontWeight.w700)),
            const SizedBox(height:5),
            Text(preparing
              ?'Giữ: '+erpGroupedDecimalText(records[i]['reservedBase'])+
                 ' · Chờ: '+erpGroupedDecimalText(records[i]['backorderedBase'])+
                 ' · Soạn: '+erpGroupedDecimalText(records[i]['pickedBase'])+
                 ' · Đóng: '+erpGroupedDecimalText(records[i]['packedBase'])
              :'Đã đóng: '+erpGroupedDecimalText(records[i]['packedBase'])+
                 ' · Còn xuất: '+erpGroupedDecimalText(records[i]['readyBase']),
              style:Theme.of(context).textTheme.bodySmall),
            const SizedBox(height:7),
            Wrap(spacing:10,runSpacing:9,children:[
              if(preparing)number('Số soạn thêm',picks[i]),
              number(preparing?'Số đóng thêm':'Số thực xuất',packs[i]),
              if(preparing)...[
                SizedBox(width:170,child:DropdownButtonFormField<String?>(
                  initialValue:chosenLocation[i],isExpanded:true,
                  decoration:const InputDecoration(labelText:'Vị trí',isDense:true),
                  items:[
                    const DropdownMenuItem<String?>(value:null,child:Text('Không phân vị trí')),
                    for(final x in (scopes[records[i]['productId'].toString()]?['locations']
                      as List<dynamic>? ?? const []))
                      DropdownMenuItem<String?>(
                        value:(x as Map)['id'].toString(),
                        child:Text((x['code']??'').toString(),overflow:TextOverflow.ellipsis)),
                  ],
                  onChanged:(v)=>setState(()=>chosenLocation[i]=v))),
                SizedBox(width:170,child:DropdownButtonFormField<String?>(
                  initialValue:chosenLot[i],isExpanded:true,
                  decoration:const InputDecoration(labelText:'Lô hàng',isDense:true),
                  items:[
                    const DropdownMenuItem<String?>(value:null,child:Text('Không phân lô')),
                    for(final x in (scopes[records[i]['productId'].toString()]?['lots']
                      as List<dynamic>? ?? const []))
                      DropdownMenuItem<String?>(
                        value:(x as Map)['id'].toString(),
                        child:Text((x['lotCode']??'').toString(),overflow:TextOverflow.ellipsis)),
                  ],
                  onChanged:(v)=>setState(()=>chosenLot[i]=v))),
              ],
            ]),
          ],
        ])),
      ])),
      actions:[
        TextButton(onPressed:()=>Navigator.pop(context),child:const Text('Đóng')),
        if(!loading)TextButton(onPressed:load,child:const Text('Tải lại')),
        FilledButton(
          key:ValueKey(preparing?'trip-prepare-submit':'trip-dispatch-submit'),
          onPressed:loading||records.isEmpty?null:submit,
          child:Text(preparing?'Lưu số đã soạn & đóng':'Xác nhận xuất thực tế')),
      ],
    );
  }
}
