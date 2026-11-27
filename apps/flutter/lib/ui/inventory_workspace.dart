import 'dart:convert';
import 'package:material_ui/material_ui.dart';
import 'erp_tokens.dart';
import 'erp_display.dart';
import 'erp_number_input.dart';
import 'erp_toast.dart';
import 'identity_client.dart';
import 'manual_stock_issue.dart';
import 'trip_fulfillment_dialog.dart';
import 'stock_scope_setup.dart';

/// Kho workspace: server-sourced facts, never a client-owned stock balance.
class InventoryWorkspace extends StatefulWidget {
  final ErpIdentityClient client;
  final IdentitySession session;
  final Map<String,dynamic>? initialOrder;
  const InventoryWorkspace({super.key,required this.client,required this.session,this.initialOrder});
  @override State<InventoryWorkspace> createState()=>_InventoryWorkspaceState();
}
class _InventoryWorkspaceState extends State<InventoryWorkspace> {
  List<Map<String,dynamic>> branches=[],warehouses=[],rows=[];
  String? branchId,warehouseId,error;
  Map<String,dynamic>? _linkedOrder;
  String? get _linkedWarehouse=>_linkedOrder?['shipping'] is Map?
    (_linkedOrder!['shipping'] as Map)['warehouseId'] as String?:null;
  bool get _linkedScope=>_linkedOrder!=null&&branchId==_linkedOrder!['branchId']&&warehouseId==_linkedWarehouse;
  String tab='balances',reservationState='ACTIVE';
  bool busy=false,loading=true,loadingMore=false,hasMore=false;
  int serial=0;
  final warehouseLookup=TextEditingController();
  @override void initState(){super.initState();_linkedOrder=widget.initialOrder;
    if(_linkedOrder!=null)tab=
      (_linkedOrder?['shipping'] is Map&&
       (_linkedOrder!['shipping'] as Map)['deliveryChoice']=='MANUAL')
         ?'balances':'reservations';
    loadBranches();}
  @override void didUpdateWidget(covariant InventoryWorkspace old){
    super.didUpdateWidget(old);
    if(old.session.token!=widget.session.token || old.client!=widget.client){
      ++serial;branches=[];warehouses=[];rows=[];branchId=null;warehouseId=null;_linkedOrder=null;
      loadBranches();
    }
  }
  @override void dispose(){++serial;warehouseLookup.dispose();super.dispose();}
  String? get pendingScope=>branchId==null||warehouseId==null?null:
    '${widget.session.actorId}:${branchId!}:${warehouseId!}';
  bool get hasPending=>pendingScope!=null&&
    widget.client.pendingInventory(pendingScope!)!=null;
  Future<void> retryPending()async{
    final scope=pendingScope;if(scope==null)return;
    final saved=widget.client.pendingInventory(scope);
    if(saved==null||saved.action==null||saved.revision==null)return;
    await send(saved.action!,saved.payload,intent:'replay',revision:saved.revision!);
  }
  bool can(String permission)=>widget.session.grants.any((g)=>
    g.permission==permission&&g.branchId==branchId&&g.warehouseId==warehouseId);
  void notify(String message,{bool bad=false}){
    if(mounted)ErpToast.show(context,message,isError:bad);
  }
  Future<void> loadBranches() async {
    final n=++serial;setState((){loading=true;error=null;loadingMore=false;});
    try {
      final data=await widget.client.catalogItems(widget.session.token,'branches');
      if(!mounted||n!=serial)return;
      branches=data.where((b)=>widget.session.grants.any((g)=>
        g.branchId==b['id']&&g.permission.startsWith('inventory.'))).toList();
      final linkedBranch=_linkedOrder?['branchId'];
      branchId=linkedBranch!=null?(branches.any((b)=>b['id']==linkedBranch)?linkedBranch.toString():null):
        branches.isEmpty?null:branches.first['id'].toString();
      if(branchId==null)setState((){loading=false;error='Chưa có quyền kho.';});
      else await loadWarehouses();
    }on ErpApiError catch(e){
      if(mounted&&n==serial)setState((){loading=false;error=e.message;});
    }catch(_){
      if(mounted&&n==serial)setState((){loading=false;error='Không tải được chi nhánh.';});
    }
  }
  Future<void> loadWarehouses({String query=''})async{
    final b=branchId;if(b==null)return;
    final n=++serial;setState((){loading=true;error=null;loadingMore=false;hasMore=false;rows=[];});
    try {
      final data=await widget.client.catalogItems(
        widget.session.token,'warehouses',branchId:b,query:query);
      if(!mounted||n!=serial)return;
      warehouses=data.where((w)=>widget.session.grants.any((g)=>
        g.branchId==b&&g.warehouseId==w['id']&&g.permission.startsWith('inventory.'))).toList();
      final linkedWarehouse=_linkedWarehouse;
      warehouseId=linkedWarehouse!=null?(warehouses.any((w)=>w['id']==linkedWarehouse)?linkedWarehouse:null):
        warehouses.isEmpty?null:warehouses.first['id'].toString();
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
    final n=++serial;setState((){loading=true;error=null;loadingMore=false;});
    try{
      final page=await widget.client.inventoryPage(widget.session.token,tab,
        branchId:b,warehouseId:w,state:reservationState,offset:0);
      if(mounted&&n==serial)setState((){
        rows=page.items;hasMore=page.hasMore;loading=false;
      });
    }on ErpApiError catch(e){
      if(mounted&&n==serial)setState((){loading=false;error=e.message;});
    }catch(_){
      if(mounted&&n==serial)setState((){loading=false;error='Không tải được số liệu kho.';});
    }
  }
  Future<void> loadMore()async{
    final b=branchId,w=warehouseId;
    if(b==null||w==null||!hasMore||loadingMore||loading)return;
    final n=serial,scopeTab=tab,scopeState=reservationState,offset=rows.length;
    setState(()=>loadingMore=true);
    try{
      final page=await widget.client.inventoryPage(widget.session.token,scopeTab,
        branchId:b,warehouseId:w,state:scopeState,offset:offset);
      if(mounted&&n==serial&&tab==scopeTab&&scopeState==reservationState){
        setState((){
          rows=[...rows,...page.items];hasMore=page.hasMore;loadingMore=false;
        });
      }
    }on ErpApiError catch(e){
      if(mounted&&n==serial)setState(()=>error=e.message);
    }finally{if(mounted&&n==serial)setState(()=>loadingMore=false);}
  }
  Future<void> send(String action,Map<String,dynamic> body,
      {required String intent,int revision=0})async{
    if(busy)return;
    // Always bind the pending operation to its captured scope, not a later selection.
    final b=body['branchId'],w=body['warehouseId'];
    if(b is! String||w is! String)return;
    if(branchId!=b||warehouseId!=w){
      notify('Kho đã thay đổi. Hãy mở lại thao tác.',bad:true);
      return;
    }
    final scope='${widget.session.actorId}:$b:$w';
    final held=widget.client.pendingInventory(scope);
    if(held!=null&&(jsonEncode(held.payload)!=jsonEncode(body)||
      held.action!=action||held.revision!=revision)){
      notify('Hãy xác minh lệnh kho cũ trước khi tạo chứng từ mới.',bad:true);return;
    }
    final key=held?.key??'stock-'+DateTime.now().microsecondsSinceEpoch.toString();
    widget.client.retainInventory(scope,body,key,action:action,revision:revision);
    setState(()=>busy=true);
    try{
      final result=await widget.client.inventoryAction(widget.session.token,action,body,
        key:key,revision:revision);
      widget.client.clearInventory(scope);
      if(action=='trip-holds'){
        notify(result['hasBackorder']==true
          ?'Đã cập nhật giữ hàng. Đơn còn hàng chờ bổ sung.'
          :'Đã giữ đủ hàng cho đơn.');
        if(mounted&&branchId==b&&warehouseId==w)
          setState((){tab='reservations';reservationState='ACTIVE';});
      }else{
        notify('Máy chủ đã xác nhận chứng từ.');
      }
      await reload();
    }on ErpApiError catch(e){
      // Any 5xx may mean COMMIT succeeded but the ACK was lost: retain exact key/body.
      // Authentication challenges cannot settle a previously unknown COMMIT.
      // A server 409 is a definitive rolled-back domain/revision rejection:
      // executeMutation replays committed receipts before domain checks.
      // Keep the exact command only for transport/5xx and pre-replay auth errors.
      final uncertain=e.status==0||e.status>=500||e.status==401||
        e.status==403;
      if(!uncertain)widget.client.clearInventory(scope);
      notify(uncertain
        ?'Chưa xác minh kết quả máy chủ. Gửi lại đúng yêu cầu trước.':e.message,bad:true);
    }catch(_){
      notify('Chưa xác minh kết quả máy chủ. Không ghi thêm yêu cầu mới.',bad:true);
    }finally{if(mounted)setState(()=>busy=false);}
  }
  Future<void> openStock()async{
    final b=branchId,w=warehouseId;
    if(b==null||w==null||hasPending||!can('inventory.post'))return;
    List<Map<String,dynamic>> products;
    try{
      products=await widget.client.catalogItems(
        widget.session.token,'products',branchId:b);
    }on ErpApiError catch(e){notify(e.message,bad:true);return;}
    if(!mounted||branchId!=b||warehouseId!=w)return;
    if(products.isEmpty){notify('Cần tạo sản phẩm trước.',bad:true);return;}
    final qty=TextEditingController(),lookupText=TextEditingController();
    String? product=products.first['id'].toString();
    Future<void> searchProduct(StateSetter refresh,BuildContext dctx)async{
      try{
        final found=await widget.client.catalogItems(widget.session.token,
          'products',branchId:b,query:lookupText.text.trim());
        if(!mounted||!dctx.mounted)return;
        refresh((){
          products=found.where((x)=>x['active']!=false).toList();
          product=products.isEmpty?null:products.first['id'].toString();
        });
      }on ErpApiError catch(e){notify(e.message,bad:true);}
      catch(_){notify('Không tìm được sản phẩm. Vui lòng thử lại.',bad:true);}
    }
    try{
      final route=DialogRoute<Map<String,String>>(context:context,
        builder:(dctx)=>StatefulBuilder(builder:(dctx,refresh)=>AlertDialog(
          title:const Text('Ghi tồn đầu kỳ'),
          content:SizedBox(width:420,child:Column(mainAxisSize:MainAxisSize.min,children:[
            TextField(key:const ValueKey('inventory-product-search'),
              controller:lookupText,
              onSubmitted:(_)=>searchProduct(refresh,dctx),
              decoration:InputDecoration(labelText:'Tìm SKU hoặc tên sản phẩm',
                suffixIcon:IconButton(tooltip:'Tìm sản phẩm',
                  icon:const Icon(Icons.search),
                  onPressed:()=>searchProduct(refresh,dctx)))),
            const SizedBox(height:10),
            if(products.isEmpty)const Text('Không tìm thấy sản phẩm phù hợp.'),
            DropdownButtonFormField<String>(
              key:ValueKey('inventory-opening-product-'+(product??'none')),
              initialValue:product,isExpanded:true,
              decoration:const InputDecoration(labelText:'Sản phẩm'),
              items:products.map((p)=>DropdownMenuItem<String>(
                value:p['id'].toString(),
                child:Text((p['code']??'').toString()+' · '+(p['name']??'').toString(),
                  overflow:TextOverflow.ellipsis))).toList(),
              onChanged:(v){if(v!=null)refresh(()=>product=v);}),
            const SizedBox(height:12),
            TextField(key:const ValueKey('inventory-opening-qty'),controller:qty,
              keyboardType:const TextInputType.numberWithOptions(decimal:true),
              inputFormatters:const [ErpGroupedNumberFormatter(maxIntegerDigits:12,maxFractionDigits:6)],
              decoration:const InputDecoration(labelText:'Số lượng theo đơn vị gốc',
                helperText:'Chỉ ghi một lần trước khi kho phát sinh chứng từ.')),
          ])),
          actions:[TextButton(onPressed:()=>Navigator.pop(dctx),child:const Text('Đóng')),
            FilledButton(onPressed:product==null?null:()=>Navigator.pop(dctx,{
              'product':product!,'quantity':erpNumberCanonical(qty.text)}),
              child:const Text('Xác nhận'))],
        )));
      final selection=await Navigator.of(context,rootNavigator:true).push(route);
      await route.completed; // Release controllers only after the dialog's exit animation.
      if(selection==null||!mounted||branchId!=b||warehouseId!=w)return;
      final amount=selection['quantity']??'';
      if(!RegExp(r'^(?:0|[1-9][0-9]{0,11})(?:\.[0-9]{1,6})?$').hasMatch(amount)||
         !RegExp(r'[1-9]').hasMatch(amount)){
        notify('Số lượng phải lớn hơn 0, tối đa 6 số lẻ.',bad:true);return;
      }
      await send('openings',{'branchId':b,'warehouseId':w,
        'productId':selection['product'],'quantity':amount},
        intent:'opening:'+selection['product']!);
    }finally{qty.dispose();lookupText.dispose();}
  }
  Future<void> configureStockScopes()async{
    final b=branchId,w=warehouseId,token=widget.session.token;
    if(b==null||w==null||busy||hasPending||
       (!can('inventory.policy.manage')&&!can('inventory.post')))return;
    try{
      await showStockScopeSetup(context:context,client:widget.client,
        session:widget.session,branchId:b,warehouseId:w,
        canManagePolicy:can('inventory.policy.manage'),canAssign:can('inventory.post'),
        onSubmit:(action,body,revision)async{
          if(!mounted||branchId!=b||warehouseId!=w||widget.session.token!=token)return;
          await send(action,body,intent:'t3b-stock-scope',revision:revision);
        });
    }on ErpApiError catch(e){notify(e.message,bad:true);}
    catch(_){notify('Không mở được quản lý lô và vị trí.',bad:true);}
  }
  Future<void> issueDirect({String? orderId})async{
    final b=branchId,w=warehouseId,token=widget.session.token;
    if(b==null||w==null||hasPending||busy||!can('inventory.post'))return;
    try{
      await showManualStockIssue(context:context,client:widget.client,session:widget.session,
       branchId:b,warehouseId:w,orderId:orderId,
       onSubmit:(body,revision)async{
        if(!mounted||branchId!=b||warehouseId!=w||widget.session.token!=token)return;
        await send('direct-issues',body,intent:'manual-direct-issue',revision:revision);
       });
    }on ErpApiError catch(e){notify(e.message,bad:true);}
    catch(_){notify('Không mở được phiếu xuất kho. Hãy kiểm tra kết nối.',bad:true);}
  }
  Future<void> reserve({String? orderId})async{
    final b=branchId,w=warehouseId,token=widget.session.token;
    if(b==null||w==null||hasPending||!can('inventory.reserve'))return;
    String? picked=orderId;
    if(picked==null){
    List<Map<String,dynamic>> orders;
    try{
      orders=(await widget.client.salesOrders(widget.session.token,b))
        .where((o)=>o['status']=='CONFIRMED'&&o['versionStatus']=='CONFIRMED'&&
          (o['deliveryChoice']==null||o['deliveryChoice']=='TRIP')).toList();
    }on ErpApiError catch(e){
      notify('Cần quyền xem đơn đã xác nhận. '+e.message,bad:true);return;
    }
    if(!mounted||branchId!=b||warehouseId!=w)return;
    final search=TextEditingController();
    String? chosen=orders.isEmpty?null:orders.first['id'].toString();
    Future<void> searchOrders(StateSetter refresh,BuildContext ctx)async{
      try{
        final found=await widget.client.salesOrders(widget.session.token,b,
          query:search.text.trim());
        if(!mounted||!ctx.mounted)return;
        refresh((){
          orders=found.where((x)=>x['status']=='CONFIRMED'&&
             x['versionStatus']=='CONFIRMED'&&
             (x['deliveryChoice']==null||x['deliveryChoice']=='TRIP')).toList();
          chosen=orders.isEmpty?null:orders.first['id'].toString();
        });
      }on ErpApiError catch(e){notify(e.message,bad:true);}
      catch(_){notify('Không tra cứu được đơn bán.',bad:true);}
    }
    try{
      final route=DialogRoute<String>(context:context,builder:(ctx)=>
        StatefulBuilder(builder:(ctx,refresh)=>AlertDialog(
          title:const Text('Chọn đơn để giữ hàng'),
          content:SizedBox(width:440,child:Column(
            mainAxisSize:MainAxisSize.min,children:[
            TextField(key:const ValueKey('inventory-order-search'),
              controller:search,
              onSubmitted:(_)=>searchOrders(refresh,ctx),
              decoration:InputDecoration(labelText:'Tìm số đơn hoặc khách hàng',
                suffixIcon:IconButton(tooltip:'Tìm đơn bán',
                  icon:const Icon(Icons.search),
                  onPressed:()=>searchOrders(refresh,ctx)))),
            const SizedBox(height:10),
            if(orders.isEmpty)const Text('Không có đơn phù hợp. Nhập số đơn để tìm thêm.'),
            DropdownButtonFormField<String>(
              key:ValueKey('inventory-reserve-order-'+(chosen??'none')),
              initialValue:chosen,isExpanded:true,
              decoration:const InputDecoration(labelText:'Đơn bán đã xác nhận'),
              items:orders.map((o)=>DropdownMenuItem<String>(
                value:o['id'].toString(),
                child:Text((o['documentNo']??'').toString()+
                  ' · '+(o['customerName']??'').toString(),
                  overflow:TextOverflow.ellipsis))).toList(),
              onChanged:(v){if(v!=null)refresh(()=>chosen=v);},
            ),
          ])),
          actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('Đóng')),
            FilledButton(onPressed:chosen==null?null:()=>Navigator.pop(ctx,chosen),
              child:const Text('Tiếp tục'))],
        )));
      picked=await Navigator.of(context,rootNavigator:true).push(route);
      await route.completed; // The search field is no longer mounted.
    }finally{search.dispose();}
    }
    if(picked==null||!mounted||branchId!=b||warehouseId!=w||widget.session.token!=token)return;
    Map<String,dynamic> detail;
    try{detail=await widget.client.salesOrder(widget.session.token,picked,b);}
    on ErpApiError catch(e){notify(e.message,bad:true);return;}
    if(!mounted||branchId!=b||warehouseId!=w||widget.session.token!=token)return;
    final shipping=detail['shipping'];
    if(shipping is Map&&shipping['deliveryChoice']!=null&&shipping['deliveryChoice']!='TRIP'){
      notify('Đơn giao thủ công hoặc tại quầy không cần giữ hàng. '
        'Xuất kho trực tiếp sẽ thực hiện trên đơn hàng.',bad:true);
      return;
    }
    if(detail['status']!='CONFIRMED'||detail['versionStatus']!='CONFIRMED'||
      (shipping is Map&&shipping['warehouseId']!=w)){
      notify('Đơn đã thay đổi trạng thái hoặc kho. Hãy mở lại đơn hàng.',bad:true);return;
    }
    final lines=(detail['lines'] as List<dynamic>).map((v)=>
      Map<String,dynamic>.from(v as Map)).toList();
    if(lines.isEmpty){notify('Đơn không có dòng hàng.',bad:true);return;}
    if(shipping is Map&&shipping['deliveryChoice']=='TRIP'){
      if(detail['fulfillmentStatus']=='COMPLETED'||
          detail['deliveryStatus']!='NOT_DISPATCHED'||
          detail['paymentStatus']!='NOT_DUE'){
        notify('Đơn đã chuyển sang xử lý kho hoặc giao nhận.',bad:true);return;
      }
      final revision=int.tryParse(detail['revision'].toString());
      if(revision==null){notify('Không đọc được phiên bản đơn. Hãy tải lại.',bad:true);return;}
      final approved=await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(
        title:const Text('Giữ hàng toàn đơn'),
        content:SizedBox(width:480,child:Column(mainAxisSize:MainAxisSize.min,
          crossAxisAlignment:CrossAxisAlignment.stretch,children:[
            Text((detail['documentNo']??'Đơn bán').toString(),
              style:const TextStyle(fontWeight:FontWeight.w700)),
            const SizedBox(height:8),
            Text('${lines.length} dòng hàng · Giữ phần khả dụng, bổ sung phần còn thiếu khi có tồn.'),
            const SizedBox(height:8),
            ConstrainedBox(constraints:const BoxConstraints(maxHeight:240),
              child:ListView(shrinkWrap:true,children:[
                for(final row in lines)Padding(padding:const EdgeInsets.symmetric(vertical:5),
                  child:Row(children:[
                    Expanded(child:Text((row['productName']??row['sku']??'').toString())),
                    Text(erpNumberText(row['quantity'])+' '+(row['unitCode']??'').toString()),
                  ])),
              ])),
          ])),
        actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('Đóng')),
          FilledButton(key:const ValueKey('inventory-trip-hold-all'),
            onPressed:()=>Navigator.pop(ctx,true),child:const Text('Giữ / bổ sung hàng'))],
      ));
      if(approved!=true||!mounted||branchId!=b||warehouseId!=w||widget.session.token!=token)return;
      await send('trip-holds',{'branchId':b,'warehouseId':w,
        'orderId':picked,'version':detail['version']},
        intent:'trip-hold:'+picked,revision:revision);
      return;
    }
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
    if(selected==null||!mounted||branchId!=b||warehouseId!=w||widget.session.token!=token)return;
    await send('reservations',{'branchId':b,'warehouseId':w,
      'orderId':picked,'version':detail['version'],'lineNo':selected},
      intent:'hold:'+picked+':'+selected.toString());
  }
  Future<void> openTrip(String mode)async{
    final b=branchId,w=warehouseId,token=widget.session.token;
    if(b==null||w==null||busy||hasPending)return;
    final shipping=_linkedOrder?['shipping'];
    final linked=_linkedScope&&shipping is Map&&shipping['deliveryChoice']=='TRIP'
      ?_linkedOrder!['id'] as String?:null;
    final command=await showDialog<TripCommand>(context:context,
      builder:(ctx)=>TripFulfillmentDialog(
        client:widget.client,session:widget.session,branchId:b,
        warehouseId:w,mode:mode,initialOrderId:linked));
    if(command==null||!mounted||branchId!=b||warehouseId!=w||
      widget.session.token!=token)return;
    await send(command.action,command.body,
      intent:mode+':'+(command.body['orderId']??'').toString(),
      revision:command.revision);
  }

  Future<void> release(Map<String,dynamic> row)async{
    final b=branchId,w=warehouseId;
    if(b==null||w==null||hasPending||!can('inventory.reserve'))return;
    final ok=await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(
      title:const Text('Giải phóng hàng đã giữ?'),
      content:Text('Đơn '+(row['documentNo']??'').toString()+' sẽ không còn giữ số hàng này.'),
      actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('Đóng')),
        FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('Giải phóng'))]));
    if(ok!=true||!mounted||branchId!=b||warehouseId!=w)return;
    final id=row['id'].toString();
    await send('reservations/'+id+'/release',{'branchId':b,'warehouseId':w},
      intent:'release:'+id,revision:int.tryParse(row['revision'].toString())??0);
  }
  Widget line(Map<String,dynamic> row){
    final title=tab=='balances'
      ?(row['sku']??'').toString()+' · '+(row['name']??'').toString()
      :tab=='movements'?(row['sku']??'').toString()+' · '+(row['kind']??'').toString()
      :(row['documentNo']??'').toString()+' · '+(row['sku']??'').toString();
    final details=tab=='balances'?'Tồn: '+erpNumberText(row['onHand'])+
        '  |  Đã giữ: '+erpNumberText(row['reserved'])+
        '  |  Khả dụng: '+erpNumberText(row['available'])
      :tab=='movements'?'Biến động: '+erpNumberText(row['deltaBase'])
      :'Đã giữ: '+erpNumberText(row['quantityBase'])+
        (row['backorderedBase']!=null?'  |  Chờ hàng: '+erpNumberText(row['backorderedBase']):'')+
        ' · '+(row['state']=='ACTIVE'?'Đang giữ':'Đã giải phóng');
    return Column(children:[
      Padding(padding:const EdgeInsets.symmetric(vertical:12),child:Row(children:[
        Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          Text(title,style:const TextStyle(fontWeight:FontWeight.w600)),
          const SizedBox(height:5),
          Text(details,style:TextStyle(color:ErpPalette.of(context).muted,fontSize:12)),
        ])),
        if(tab=='reservations'&&row['state']=='ACTIVE'&&can('inventory.reserve'))
          TextButton(onPressed:busy||hasPending?null:()=>release(row),
            child:const Text('Giải phóng')),
      ])),
      const Divider(height:1),
    ]);
  }
  @override Widget build(BuildContext context){
    final small=MediaQuery.sizeOf(context).width<680;
    return Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      Text('Kho và tồn khả dụng',style:Theme.of(context).textTheme.titleLarge),
      const SizedBox(height:6),
      Text('Tồn, giữ hàng và chứng từ được đối soát trên máy chủ.',
        style:TextStyle(color:ErpPalette.of(context).muted,fontSize:12)),
      const SizedBox(height:18),
      Wrap(spacing:12,runSpacing:12,children:[
        SizedBox(width:small?300:204,child:DropdownButtonFormField<String>(
          key:ValueKey('inv-branch-'+(branchId??'')),initialValue:branchId,isExpanded:true,decoration:const InputDecoration(labelText:'Chi nhánh'),
          items:branches.map((b)=>DropdownMenuItem<String>(value:b['id'].toString(),
            child:Text((b['name']??'').toString(),overflow:TextOverflow.ellipsis))).toList(),
          onChanged:busy?null:(v){if(v!=null){setState((){branchId=v;_linkedOrder=null;});loadWarehouses();}},
        )),
        SizedBox(width:small?300:204,child:DropdownButtonFormField<String>(
          key:ValueKey('inv-warehouse-'+(warehouseId??'')),initialValue:warehouseId,isExpanded:true,decoration:const InputDecoration(labelText:'Kho'),
          items:warehouses.map((w)=>DropdownMenuItem<String>(value:w['id'].toString(),
            child:Text((w['name']??'').toString(),overflow:TextOverflow.ellipsis))).toList(),
          onChanged:busy?null:(v){if(v!=null){setState((){warehouseId=v;_linkedOrder=null;});reload();}},
        )),
        SizedBox(width:small?300:236,child:TextField(
          key:const ValueKey('inventory-warehouse-search'),
          controller:warehouseLookup,
          onSubmitted:(value)=>loadWarehouses(query:value.trim()),
          decoration:InputDecoration(labelText:'Tìm mã hoặc tên kho',
            suffixIcon:IconButton(tooltip:'Tìm kho',icon:const Icon(Icons.search),
              onPressed:()=>loadWarehouses(query:warehouseLookup.text.trim()))))),
      ]),
      const SizedBox(height:16),
      Wrap(spacing:10,runSpacing:10,children:[
        for(final t in const [('balances','Tồn kho'),
          ('movements','Sổ kho'),('reservations','Hàng đã giữ')])
          TextButton(onPressed:busy?null:(){setState(()=>tab=t.$1);reload();},
            child:Text(t.$2,style:TextStyle(
              fontWeight:tab==t.$1?FontWeight.bold:FontWeight.normal,
              decoration:tab==t.$1?TextDecoration.underline:TextDecoration.none))),
        if(tab=='reservations')
          TextButton(onPressed:busy||loading?null:(){
            setState(()=>reservationState=reservationState=='ACTIVE'?'RELEASED':'ACTIVE');
            reload();
          },child:Text(reservationState=='ACTIVE'?'Xem lịch sử đã giải phóng':'Xem hàng đang giữ')),
        if(hasPending)OutlinedButton.icon(
          onPressed:busy?null:retryPending,icon:const Icon(Icons.refresh),
          label:const Text('Xác minh lệnh kho đang chờ')),
        if(can('inventory.post'))OutlinedButton.icon(
          onPressed:busy||hasPending?null:openStock,icon:const Icon(Icons.add),
          label:const Text('Tồn đầu kỳ')),
        if(_linkedScope&&can('inventory.reserve')&&
          (_linkedOrder!['shipping'] is! Map ||
            (_linkedOrder!['shipping'] as Map)['deliveryChoice']==null ||
            (_linkedOrder!['shipping'] as Map)['deliveryChoice']=='TRIP'))FilledButton.icon(
          key:const ValueKey('inventory-linked-order-hold'),
          onPressed:busy||loading||hasPending?null:()=>reserve(orderId:_linkedOrder!['id'] as String),
          icon:const Icon(Icons.inventory_2_outlined),label:Text('Giữ hàng · ${_linkedOrder!['documentNo']}')),
        if(_linkedScope&&_linkedOrder?['shipping'] is Map&&
            (_linkedOrder!['shipping'] as Map)['deliveryChoice']=='MANUAL'&&
            can('inventory.post'))FilledButton.icon(
          key:const ValueKey('inventory-linked-manual-issue'),
          onPressed:busy||loading||hasPending?null:()=>issueDirect(orderId:_linkedOrder!['id'] as String),
          icon:const Icon(Icons.local_shipping_outlined),
          label:Text('Xuất kho · ${_linkedOrder!['documentNo']}')),
        if(can('inventory.policy.manage')||can('inventory.post'))OutlinedButton.icon(
          key:const ValueKey('inventory-stock-scope-setup'),
          onPressed:busy||hasPending?null:configureStockScopes,
          icon:const Icon(Icons.layers_outlined),
          label:const Text('Lô và vị trí')),
        if(can('inventory.post'))OutlinedButton.icon(
          key:const ValueKey('inventory-manual-issue'),
          onPressed:busy||hasPending?null:()=>issueDirect(),
          icon:const Icon(Icons.local_shipping_outlined),
          label:const Text('Xuất kho thủ công')),
        if(can('inventory.reserve'))OutlinedButton.icon(
          key:const ValueKey('inventory-trip-prepare'),
          onPressed:busy||hasPending?null:()=>openTrip('prepare'),
          icon:const Icon(Icons.inventory_2_outlined),
          label:const Text('Soạn & đóng theo chuyến')),
        if(can('inventory.post'))OutlinedButton.icon(
          key:const ValueKey('inventory-trip-dispatch'),
          onPressed:busy||hasPending?null:()=>openTrip('dispatch'),
          icon:const Icon(Icons.local_shipping_outlined),
          label:const Text('Xuất hàng theo chuyến')),
        if(can('inventory.reserve'))OutlinedButton.icon(
          onPressed:busy||hasPending?null:()=>reserve(),
          icon:const Icon(Icons.inventory_2_outlined),label:const Text('Giữ hàng')),
        IconButton(onPressed:busy?null:reload,
          tooltip:'Tải lại dữ liệu kho',icon:const Icon(Icons.refresh)),
      ]),
      const SizedBox(height:8),
      if(error!=null)Padding(padding:const EdgeInsets.symmetric(vertical:12),
        child:Text(error!,style:TextStyle(color:ErpPalette.of(context).danger))),
      if(loading)const LinearProgressIndicator(),
      if(!loading&&error==null&&rows.isEmpty)
        const Padding(padding:EdgeInsets.all(18),child:Text('Chưa có chứng từ ở mục này.')),
      if(!loading&&error==null)
        for(final row in rows)line(row),
      if(hasMore&&!loading&&error==null)
        TextButton(onPressed:loadingMore||busy?null:loadMore,
          child:Text(loadingMore?'Đang tải thêm...':
            tab=='reservations'?'Tải thêm phiếu giữ hàng':
            tab=='balances'?'Tải thêm sản phẩm':'Tải thêm biến động')),
    ]);
  }
}
