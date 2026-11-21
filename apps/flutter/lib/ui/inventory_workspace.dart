import 'dart:convert';
import 'package:material_ui/material_ui.dart';
import 'erp_tokens.dart';
import 'erp_toast.dart';
import 'identity_client.dart';

/// Kho workspace: server-sourced facts, never a client-owned stock balance.
class InventoryWorkspace extends StatefulWidget {
  final ErpIdentityClient client;
  final IdentitySession session;
  const InventoryWorkspace({super.key,required this.client,required this.session});
  @override State<InventoryWorkspace> createState()=>_InventoryWorkspaceState();
}
class _InventoryWorkspaceState extends State<InventoryWorkspace> {
  List<Map<String,dynamic>> branches=[],warehouses=[],rows=[];
  String? branchId,warehouseId,error;
  String tab='balances';
  bool busy=false,loading=true;
  int serial=0;
  @override void initState(){super.initState();loadBranches();}
  @override void didUpdateWidget(covariant InventoryWorkspace old){
    super.didUpdateWidget(old);
    if(old.session.token!=widget.session.token || old.client!=widget.client){
      ++serial;branches=[];warehouses=[];rows=[];branchId=null;warehouseId=null;
      loadBranches();
    }
  }
  @override void dispose(){++serial;super.dispose();}
  bool can(String permission)=>widget.session.grants.any((g)=>
    g.permission==permission&&g.branchId==branchId&&g.warehouseId==warehouseId);
  void notify(String message,{bool bad=false}){
    if(mounted)ErpToast.show(context,message,isError:bad);
  }
  Future<void> loadBranches() async {
    final n=++serial;setState((){loading=true;error=null;});
    try {
      final data=await widget.client.catalogItems(widget.session.token,'branches');
      if(!mounted||n!=serial)return;
      branches=data.where((b)=>widget.session.grants.any((g)=>
        g.branchId==b['id']&&g.permission.startsWith('inventory.'))).toList();
      branchId=branches.isEmpty?null:branches.first['id'].toString();
      if(branchId==null)setState((){loading=false;error='Chưa có quyền kho.';});
      else await loadWarehouses();
    }on ErpApiError catch(e){
      if(mounted&&n==serial)setState((){loading=false;error=e.message;});
    }catch(_){
      if(mounted&&n==serial)setState((){loading=false;error='Không tải được chi nhánh.';});
    }
  }
  Future<void> loadWarehouses()async{
    final b=branchId;if(b==null)return;
    final n=++serial;setState((){loading=true;error=null;rows=[];});
    try {
      final data=await widget.client.catalogItems(
        widget.session.token,'warehouses',branchId:b);
      if(!mounted||n!=serial)return;
      warehouses=data.where((w)=>widget.session.grants.any((g)=>
        g.branchId==b&&g.warehouseId==w['id']&&g.permission.startsWith('inventory.'))).toList();
      warehouseId=warehouses.isEmpty?null:warehouses.first['id'].toString();
      if(warehouseId==null)setState((){loading=false;error='Không có kho được cấp quyền.';});
      else await reload();
    }on ErpApiError catch(e){
      if(mounted&&n==serial)setState((){loading=false;error=e.message;});
    }catch(_){
      if(mounted&&n==serial)setState((){loading=false;error='Không tải được kho.';});
    }
  }
  Future<void> reload()async{
    final b=branchId,w=warehouseId;if(b==null||w==null)return;
    final n=++serial;setState((){loading=true;error=null;});
    try{
      final data=await widget.client.inventoryItems(widget.session.token,tab,
        branchId:b,warehouseId:w);
      if(mounted&&n==serial)setState((){rows=data;loading=false;});
    }on ErpApiError catch(e){
      if(mounted&&n==serial)setState((){loading=false;error=e.message;});
    }catch(_){
      if(mounted&&n==serial)setState((){loading=false;error='Không tải được số liệu kho.';});
    }
  }
  Future<void> send(String action,Map<String,dynamic> body,
      {required String intent,int revision=0})async{
    if(busy)return;
    final scope=widget.session.actorId+':'+(warehouseId??'')+':'+intent;
    final held=widget.client.pendingInventory(scope);
    if(held!=null&&jsonEncode(held.payload)!=jsonEncode(body)){
      notify('Còn yêu cầu chưa xác minh. Không tạo yêu cầu khác.',bad:true);return;
    }
    final key=held?.key??'stock-'+DateTime.now().microsecondsSinceEpoch.toString();
    widget.client.retainInventory(scope,body,key);
    setState(()=>busy=true);
    try{
      await widget.client.inventoryAction(widget.session.token,action,body,
        key:key,revision:revision);
      widget.client.clearInventory(scope);
      notify('Máy chủ đã xác nhận chứng từ.');
      await reload();
    }on ErpApiError catch(e){
      // Any 5xx may mean COMMIT succeeded but the ACK was lost: retain exact key/body.
      final uncertain=e.status==0||e.status>=500;
      if(!uncertain)widget.client.clearInventory(scope);
      notify(uncertain
        ?'Chưa xác minh kết quả máy chủ. Gửi lại đúng yêu cầu trước.':e.message,bad:true);
    }catch(_){
      notify('Chưa xác minh kết quả máy chủ. Không ghi thêm yêu cầu mới.',bad:true);
    }finally{if(mounted)setState(()=>busy=false);}
  }
  Future<void> openStock()async{
    final b=branchId,w=warehouseId;if(b==null||w==null||!can('inventory.post'))return;
    List<Map<String,dynamic>> products;
    try {products=await widget.client.catalogItems(widget.session.token,'products',branchId:b);}
    on ErpApiError catch(e){notify(e.message,bad:true);return;}
    if(products.isEmpty){notify('Cần tạo sản phẩm trước.',bad:true);return;}
    final qty=TextEditingController();
    String product=products.first['id'].toString();
    try{
      final selection=await showDialog<Map<String,String>>(context:context,
        builder:(dctx)=>StatefulBuilder(builder:(dctx,refresh)=>AlertDialog(
          title:const Text('Ghi tồn đầu kỳ'),
          content:SizedBox(width:400,child:Column(mainAxisSize:MainAxisSize.min,children:[
            DropdownButtonFormField<String>(initialValue:product,isExpanded:true,
              decoration:const InputDecoration(labelText:'Sản phẩm'),
              items:products.map((p)=>DropdownMenuItem<String>(
                value:p['id'].toString(),
                child:Text((p['code']??'').toString()+' · '+(p['name']??'').toString(),
                  overflow:TextOverflow.ellipsis))).toList(),
              onChanged:(v){if(v!=null)refresh(()=>product=v);}),
            const SizedBox(height:12),
            TextField(controller:qty,
              keyboardType:const TextInputType.numberWithOptions(decimal:true),
              decoration:const InputDecoration(labelText:'Số lượng theo đơn vị gốc',
                helperText:'Chỉ ghi một lần trước khi kho phát sinh chứng từ.')),
          ])),
          actions:[TextButton(onPressed:()=>Navigator.pop(dctx),child:const Text('Đóng')),
            FilledButton(onPressed:()=>Navigator.pop(dctx,{
              'product':product,'quantity':qty.text.trim()}),
              child:const Text('Xác nhận'))],
        )));
      if(selection==null)return;
      final amount=selection['quantity']??'';
      if(!RegExp(r'^(?:0|[1-9][0-9]{0,11})(?:\.[0-9]{1,6})?$').hasMatch(amount)||
         !RegExp(r'[1-9]').hasMatch(amount)){
        notify('Số lượng phải lớn hơn 0, tối đa 6 số lẻ.',bad:true);return;
      }
      await send('openings',{'branchId':b,'warehouseId':w,
        'productId':selection['product'],'quantity':amount},
        intent:'opening:'+selection['product']!);
    }finally{qty.dispose();}
  }
  Future<void> reserve()async{
    final b=branchId,w=warehouseId;if(b==null||w==null||!can('inventory.reserve'))return;
    List<Map<String,dynamic>> orders;
    try{
      orders=(await widget.client.salesOrders(widget.session.token,b))
        .where((o)=>o['status']=='CONFIRMED'&&o['versionStatus']=='CONFIRMED').toList();
    }on ErpApiError catch(e){
      notify('Cần quyền xem đơn đã xác nhận. '+e.message,bad:true);return;
    }
    if(orders.isEmpty){notify('Không có đơn đã xác nhận.',bad:true);return;}
    String chosen=orders.first['id'].toString();
    final picked=await showDialog<String>(context:context,builder:(ctx)=>
      StatefulBuilder(builder:(ctx,refresh)=>AlertDialog(
        title:const Text('Chọn đơn để giữ hàng'),
        content:SizedBox(width:440,child:DropdownButtonFormField<String>(
          initialValue:chosen,isExpanded:true,decoration:const InputDecoration(labelText:'Đơn bán'),
          items:orders.map((o)=>DropdownMenuItem<String>(
            value:o['id'].toString(),child:Text((o['documentNo']??'').toString()+
              ' · '+(o['customerName']??'').toString(),overflow:TextOverflow.ellipsis))).toList(),
          onChanged:(v){if(v!=null)refresh(()=>chosen=v);},
        )),
        actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('Đóng')),
          FilledButton(onPressed:()=>Navigator.pop(ctx,chosen),child:const Text('Tiếp tục'))],
      )));
    if(picked==null)return;
    Map<String,dynamic> detail;
    try{detail=await widget.client.salesOrder(widget.session.token,picked,b);}
    on ErpApiError catch(e){notify(e.message,bad:true);return;}
    final lines=(detail['lines'] as List<dynamic>).map((v)=>
      Map<String,dynamic>.from(v as Map)).toList();
    if(lines.isEmpty){notify('Đơn không có dòng hàng.',bad:true);return;}
    int line=(lines.first['lineNo'] as num).toInt();
    final selected=await showDialog<int>(context:context,builder:(ctx)=>
      StatefulBuilder(builder:(ctx,refresh)=>AlertDialog(
        title:const Text('Chọn hàng cần giữ'),
        content:SizedBox(width:440,child:DropdownButtonFormField<int>(
          initialValue:line,isExpanded:true,decoration:const InputDecoration(labelText:'Dòng sản phẩm'),
          items:lines.map((x)=>DropdownMenuItem<int>(
            value:(x['lineNo'] as num).toInt(),
            child:Text((x['sku']??'').toString()+' · '+(x['productName']??'').toString(),
              overflow:TextOverflow.ellipsis))).toList(),
          onChanged:(v){if(v!=null)refresh(()=>line=v);},
        )),
        actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('Đóng')),
          FilledButton(onPressed:()=>Navigator.pop(ctx,line),child:const Text('Giữ hàng'))],
      )));
    if(selected==null)return;
    await send('reservations',{'branchId':b,'warehouseId':w,
      'orderId':picked,'version':detail['version'],'lineNo':selected},
      intent:'hold:'+picked+':'+selected.toString());
  }
  Future<void> release(Map<String,dynamic> row)async{
    final b=branchId,w=warehouseId;if(b==null||w==null||!can('inventory.reserve'))return;
    final ok=await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(
      title:const Text('Giải phóng hàng đã giữ?'),
      content:Text('Đơn '+(row['documentNo']??'').toString()+' sẽ không còn giữ số hàng này.'),
      actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('Đóng')),
        FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('Giải phóng'))]));
    if(ok!=true)return;
    final id=row['id'].toString();
    await send('reservations/'+id+'/release',{'branchId':b,'warehouseId':w},
      intent:'release:'+id,revision:int.tryParse(row['revision'].toString())??0);
  }
  Widget line(Map<String,dynamic> row){
    final title=tab=='balances'
      ?(row['sku']??'').toString()+' · '+(row['name']??'').toString()
      :tab=='movements'?(row['sku']??'').toString()+' · '+(row['kind']??'').toString()
      :(row['documentNo']??'').toString()+' · '+(row['sku']??'').toString();
    final details=tab=='balances'?'Tồn: '+(row['onHand']??'0').toString()+
        '  |  Đã giữ: '+(row['reserved']??'0').toString()+
        '  |  Khả dụng: '+(row['available']??'0').toString()
      :tab=='movements'?'Biến động: '+(row['deltaBase']??'0').toString()
      :'Số lượng: '+(row['quantityBase']??'0').toString()+
        ' · '+(row['state']=='ACTIVE'?'Đang giữ':'Đã giải phóng');
    return Column(children:[
      Padding(padding:const EdgeInsets.symmetric(vertical:12),child:Row(children:[
        Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          Text(title,style:const TextStyle(fontWeight:FontWeight.w600)),
          const SizedBox(height:5),
          Text(details,style:const TextStyle(color:ErpTokens.muted,fontSize:12)),
        ])),
        if(tab=='reservations'&&row['state']=='ACTIVE'&&can('inventory.reserve'))
          TextButton(onPressed:busy?null:()=>release(row),child:const Text('Giải phóng')),
      ])),
      const Divider(height:1),
    ]);
  }
  @override Widget build(BuildContext context){
    final small=MediaQuery.sizeOf(context).width<680;
    return Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      Text('Kho và tồn khả dụng',style:Theme.of(context).textTheme.titleLarge),
      const SizedBox(height:6),
      const Text('Tồn, giữ hàng và chứng từ được đối soát trên máy chủ.',
        style:TextStyle(color:ErpTokens.muted,fontSize:12)),
      const SizedBox(height:18),
      Wrap(spacing:12,runSpacing:12,children:[
        SizedBox(width:small?300:260,child:DropdownButtonFormField<String>(
          key:ValueKey('inv-branch-'+(branchId??'')),initialValue:branchId,isExpanded:true,decoration:const InputDecoration(labelText:'Chi nhánh'),
          items:branches.map((b)=>DropdownMenuItem<String>(value:b['id'].toString(),
            child:Text((b['name']??'').toString(),overflow:TextOverflow.ellipsis))).toList(),
          onChanged:busy?null:(v){if(v!=null){setState(()=>branchId=v);loadWarehouses();}},
        )),
        SizedBox(width:small?300:260,child:DropdownButtonFormField<String>(
          key:ValueKey('inv-warehouse-'+(warehouseId??'')),initialValue:warehouseId,isExpanded:true,decoration:const InputDecoration(labelText:'Kho'),
          items:warehouses.map((w)=>DropdownMenuItem<String>(value:w['id'].toString(),
            child:Text((w['name']??'').toString(),overflow:TextOverflow.ellipsis))).toList(),
          onChanged:busy?null:(v){if(v!=null){setState(()=>warehouseId=v);reload();}},
        )),
      ]),
      const SizedBox(height:16),
      Wrap(spacing:10,runSpacing:10,children:[
        for(final t in const [('balances','Tồn kho'),
          ('movements','Sổ kho'),('reservations','Hàng đã giữ')])
          TextButton(onPressed:busy?null:(){setState(()=>tab=t.$1);reload();},
            child:Text(t.$2,style:TextStyle(
              fontWeight:tab==t.$1?FontWeight.bold:FontWeight.normal,
              decoration:tab==t.$1?TextDecoration.underline:TextDecoration.none))),
        if(can('inventory.post'))OutlinedButton.icon(
          onPressed:busy?null:openStock,icon:const Icon(Icons.add),
          label:const Text('Tồn đầu kỳ')),
        if(can('inventory.reserve'))OutlinedButton.icon(
          onPressed:busy?null:reserve,
          icon:const Icon(Icons.inventory_2_outlined),label:const Text('Giữ hàng')),
        IconButton(onPressed:busy?null:reload,
          tooltip:'Tải lại dữ liệu kho',icon:const Icon(Icons.refresh)),
      ]),
      const SizedBox(height:8),
      if(error!=null)Padding(padding:const EdgeInsets.symmetric(vertical:12),
        child:Text(error!,style:const TextStyle(color:Colors.red))),
      if(loading)const LinearProgressIndicator(),
      if(!loading&&error==null&&rows.isEmpty)
        const Padding(padding:EdgeInsets.all(18),child:Text('Chưa có chứng từ ở mục này.')),
      if(!loading&&error==null)
        for(final row in rows)line(row),
    ]);
  }
}
