import 'dart:convert';
import 'package:material_ui/material_ui.dart';
import 'erp_tokens.dart';
import 'erp_toast.dart';
import 'identity_client.dart';

class _MoveInput {
  String product;
  final qty=TextEditingController();
  _MoveInput(this.product);
  void dispose()=>qty.dispose();
}

/// A transfer has separate source dispatch, in-transit, and destination receipt facts.
class TransferWorkspace extends StatefulWidget{
  final ErpIdentityClient client;
  final IdentitySession session;
  const TransferWorkspace({super.key,required this.client,required this.session});
  @override State<TransferWorkspace> createState()=>_TransferWorkspaceState();
}
class _TransferWorkspaceState extends State<TransferWorkspace>{
  List<Map<String,dynamic>> branches=[],warehouses=[],items=[];
  String? branchId,warehouseId,error;
  bool loading=true,busy=false,hasMore=false,loadingMore=false;
  int epoch=0;
  final whSearch=TextEditingController();
  @override void initState(){super.initState();loadBranches();}
  @override void didUpdateWidget(covariant TransferWorkspace old){
    super.didUpdateWidget(old);
    if(old.session.token!=widget.session.token||old.client!=widget.client){
      epoch++;branches=[];warehouses=[];items=[];branchId=null;warehouseId=null;
      loadBranches();
    }
  }
  @override void dispose(){epoch++;whSearch.dispose();super.dispose();}
  bool can(String code,String? wh)=>widget.session.grants.any((g)=>
    g.permission==code&&g.branchId==branchId&&g.warehouseId==wh);
  void info(String message,{bool bad=false}){
    if(mounted)ErpToast.show(context,message,isError:bad);
  }
  String status(dynamic s)=>switch(s){
    'CREATED'=>'Đang lập','APPROVED'=>'Đã duyệt','IN_TRANSIT'=>'Đang đi đường',
    'PARTIALLY_RECEIVED'=>'Đã nhận một phần','RECEIVED'=>'Đã nhận đủ',
    'CANCELLED'=>'Đã hủy',_=>'Không xác định',
  };
  bool validQty(String v)=>RegExp(r'^(?:0|[1-9][0-9]{0,11})(?:\.[0-9]{1,6})?$')
      .hasMatch(v)&&RegExp(r'[1-9]').hasMatch(v);
  Future<void> loadBranches()async{
    final n=++epoch;setState((){loading=true;error=null;});
    try{
      final data=await widget.client.transferScopes(widget.session.token);
      if(!mounted||n!=epoch)return;
      branches=data.branches;
      branchId=branches.isEmpty?null:branches.first['id'].toString();
      if(branchId==null)setState((){loading=false;error='Chưa có quyền chuyển kho.';});
      else await loadWarehouses();
    }on ErpApiError catch(e){
      if(mounted&&n==epoch)setState((){loading=false;error=e.message;});
    }catch(_){
      if(mounted&&n==epoch)setState((){loading=false;error='Không tải được chi nhánh.';});
    }
  }
  Future<void> loadWarehouses({String query=''})async{
    final b=branchId;if(b==null)return;
    final n=++epoch;setState((){
      loading=true;loadingMore=false;hasMore=false;error=null;items=[];
    });
    try{
      final data=await widget.client.transferScopes(widget.session.token,
        branchId:b,query:query);
      if(!mounted||n!=epoch)return;
      warehouses=data.warehouses.where((x)=>
        can('inventory.transfer.read',x['id'].toString())).toList();
      warehouseId=warehouses.isEmpty?null:warehouses.first['id'].toString();
      if(warehouseId==null)setState((){
        loading=false;error='Không có kho được cấp quyền xem chuyển kho.';
      });else await reload();
    }on ErpApiError catch(e){
      if(mounted&&n==epoch)setState((){loading=false;error=e.message;});
    }catch(_){
      if(mounted&&n==epoch)setState((){loading=false;error='Không tải được kho.';});
    }
  }
  Future<void> reload()async{
    final b=branchId,w=warehouseId;
    if(b==null||w==null)return;
    final n=++epoch;setState((){loading=true;loadingMore=false;error=null;});
    try{
      final page=await widget.client.transferPage(widget.session.token,
        branchId:b,warehouseId:w);
      if(mounted&&n==epoch)setState((){
        items=page.items;hasMore=page.hasMore;loading=false;
      });
    }on ErpApiError catch(e){
      if(mounted&&n==epoch)setState((){loading=false;error=e.message;});
    }catch(_){
      if(mounted&&n==epoch)setState((){
        loading=false;error='Không tải được phiếu chuyển kho.';
      });
    }
  }
  Future<void> more()async{
    final b=branchId,w=warehouseId;
    if(b==null||w==null||busy||loading||loadingMore||!hasMore)return;
    final n=epoch,offset=items.length;setState(()=>loadingMore=true);
    try{
      final page=await widget.client.transferPage(widget.session.token,
        branchId:b,warehouseId:w,offset:offset);
      if(mounted&&n==epoch)setState((){
        items=[...items,...page.items];hasMore=page.hasMore;loadingMore=false;
      });
    }on ErpApiError catch(e){
      if(mounted&&n==epoch)setState(()=>error=e.message);
    }finally{if(mounted&&n==epoch)setState(()=>loadingMore=false);}
  }
  String transferScope(Map<String,dynamic> body){
    return '${widget.session.actorId}:${body['branchId']}:${body['sourceWarehouseId']}:${body['destinationWarehouseId']}';
  }
  Future<void> send(String path,Map<String,dynamic> body,int revision)async{
    if(busy)return;
    final b=branchId,w=warehouseId;
    if(b==null||w==null||body['branchId']!=b||
      ![body['sourceWarehouseId'],body['destinationWarehouseId']].contains(w)){
      info('Kho đã thay đổi. Hãy mở lại chứng từ.',bad:true);return;
    }
    final scope=transferScope(body);
    final pending=widget.client.pendingTransfer(scope);
    if(pending!=null&&(pending.path!=path||pending.revision!=revision||
       jsonEncode(pending.payload)!=jsonEncode(body))){
      info('Hãy xác minh chứng từ chưa rõ kết quả trước.',bad:true);return;
    }
    final key=pending?.key??'transfer-${DateTime.now().microsecondsSinceEpoch}';
    widget.client.retainTransfer(scope,body,key,path:path,revision:revision);
    setState(()=>busy=true);
    try{
      await widget.client.transferCommand(widget.session.token,path,body,
        revision:revision,key:key);
      widget.client.clearTransfer(scope);
      info('Máy chủ đã xác nhận thao tác chuyển kho.');
      await reload();
    }on ErpApiError catch(e){
      final uncertain=e.status==0||e.status>=500||e.status==401||e.status==403;
      if(!uncertain)widget.client.clearTransfer(scope);
      info(uncertain?'Chưa xác minh kết quả máy chủ. Hãy thử đúng yêu cầu cũ.':e.message,
        bad:true);
    }catch(_){
      info('Kết quả chưa xác minh. Không lập lệnh mới để thử lại.',bad:true);
    }finally{if(mounted)setState(()=>busy=false);}
  }
  List<String> get pendingScopes{
    final b=branchId,w=warehouseId;
    if(b==null||w==null)return [];
    return widget.client.transferPendingScopes(widget.session.actorId,b,w);
  }
  bool get hasPending=>pendingScopes.isNotEmpty;
  Future<void> retry()async{
    final scope=pendingScopes.firstOrNull;if(scope==null)return;
    final saved=widget.client.pendingTransfer(scope);if(saved==null)return;
    await send(saved.path,saved.payload,saved.revision);
  }
  Future<void> create()async{
    final b=branchId,source=warehouseId;
    if(b==null||source==null||hasPending||!can('inventory.transfer.create',source))return;
    List<Map<String,dynamic>> options,products;
    try{
      final data=await Future.wait([
        widget.client.catalogItems(widget.session.token,'warehouses',branchId:b),
        widget.client.catalogItems(widget.session.token,'products',branchId:b),
      ]);
      options=data[0].where((x)=>x['id']!=source&&
        can('inventory.read',x['id'].toString())).toList();
      products=data[1].where((x)=>x['active']!=false).toList();
    }on ErpApiError catch(e){info(e.message,bad:true);return;}
    if(!mounted||branchId!=b||warehouseId!=source)return;
    String? dest=options.isEmpty?null:options.first['id'].toString();
    final pSearch=TextEditingController(),wSearch=TextEditingController();
    final all=< _MoveInput >[],lines=< _MoveInput >[];
    void add(){final row=_MoveInput(products.isEmpty?'':products.first['id'].toString());
      all.add(row);lines.add(row);}
    add();
    Future<void> findWarehouse(StateSetter set,BuildContext ctx)async{
      try{
        final found=await widget.client.catalogItems(widget.session.token,
          'warehouses',branchId:b,query:wSearch.text.trim());
        if(!mounted||!ctx.mounted||branchId!=b||warehouseId!=source)return;
        set((){
          final known={for(final x in options)x['id'].toString():x};
          for(final x in found.where((x)=>x['id']!=source&&
             can('inventory.read',x['id'].toString()))){
            known[x['id'].toString()]=x;
          }
          options=known.values.toList();
          dest??=options.isEmpty?null:options.first['id'].toString();
        });
      }on ErpApiError catch(e){info(e.message,bad:true);}
    }
    Future<void> findProduct(StateSetter set,BuildContext ctx)async{
      try{
        final found=await widget.client.catalogItems(widget.session.token,
          'products',branchId:b,query:pSearch.text.trim());
        if(!mounted||!ctx.mounted||branchId!=b||warehouseId!=source)return;
        set((){
          final known={for(final x in products)x['id'].toString():x};
          for(final x in found.where((x)=>x['active']!=false)){
            known[x['id'].toString()]=x;
          }
          products=known.values.toList();
          for(final x in lines)if(x.product.isEmpty&&products.isNotEmpty){
            x.product=products.first['id'].toString();
          }
        });
      }on ErpApiError catch(e){info(e.message,bad:true);}
    }
    try{
      final route=DialogRoute<Map<String,dynamic>>(context:context,
        builder:(ctx)=>StatefulBuilder(builder:(ctx,set)=>AlertDialog(
          title:const Text('Lập phiếu chuyển kho'),
          content:SizedBox(width:550,child:SingleChildScrollView(child:Column(
            mainAxisSize:MainAxisSize.min,children:[
              Text('Kho xuất: '+warehouses.firstWhere((x)=>x['id']==source,
                orElse:()=>{'name':'Kho hiện tại'})['name'].toString()),
              TextField(controller:wSearch,onSubmitted:(_)=>findWarehouse(set,ctx),
                decoration:InputDecoration(labelText:'Tìm mã hoặc tên kho nhận',
                  suffixIcon:IconButton(tooltip:'Tìm kho nhận',icon:const Icon(Icons.search),
                    onPressed:()=>findWarehouse(set,ctx)))),
              DropdownButtonFormField<String>(
                key:ValueKey('transfer-dest-${dest??'none'}'),
                initialValue:dest,isExpanded:true,
                decoration:const InputDecoration(labelText:'Kho nhận'),
                items:options.map((x)=>DropdownMenuItem<String>(
                  value:x['id'].toString(),child:Text((x['name']??'').toString(),
                    overflow:TextOverflow.ellipsis))).toList(),
                onChanged:(v){if(v!=null)set(()=>dest=v);}),
              TextField(controller:pSearch,onSubmitted:(_)=>findProduct(set,ctx),
                decoration:InputDecoration(labelText:'Tìm SKU hoặc tên hàng',
                  suffixIcon:IconButton(tooltip:'Tìm sản phẩm',
                    icon:const Icon(Icons.search),onPressed:()=>findProduct(set,ctx)))),
              for(final entry in lines.asMap().entries)
                Padding(padding:const EdgeInsets.symmetric(vertical:8),
                  child:Row(children:[
                    Expanded(child:DropdownButtonFormField<String>(
                      key:ValueKey('transfer-line-${entry.key}-${entry.value.product}'),
                      initialValue:entry.value.product.isEmpty?null:entry.value.product,
                      isExpanded:true,decoration:const InputDecoration(labelText:'Sản phẩm'),
                      items:products.map((x)=>DropdownMenuItem<String>(
                        value:x['id'].toString(),child:Text(
                          (x['code']??'').toString()+' · '+(x['name']??'').toString(),
                          overflow:TextOverflow.ellipsis))).toList(),
                      onChanged:(v){if(v!=null)set(()=>entry.value.product=v);},
                    )),
                    const SizedBox(width:10),
                    SizedBox(width:110,child:TextField(
                      controller:entry.value.qty,
                      decoration:const InputDecoration(labelText:'SL gốc'),
                      keyboardType:const TextInputType.numberWithOptions(decimal:true))),
                    IconButton(onPressed:lines.length<=1?null:
                      ()=>set(()=>lines.remove(entry.value)),
                      icon:const Icon(Icons.close),tooltip:'Bỏ dòng'),
                  ])),
              Align(alignment:Alignment.centerLeft,child:TextButton.icon(
                onPressed:lines.length>=40?null:()=>set(add),
                icon:const Icon(Icons.add),label:const Text('Thêm hàng'))),
            ]))),
          actions:[
            TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('Đóng')),
            FilledButton(onPressed:dest==null||lines.any((x)=>x.product.isEmpty)
              ?null:()=>Navigator.pop(ctx,{
              'branchId':b,'sourceWarehouseId':source,
              'destinationWarehouseId':dest,'note':'',
              'lines':lines.map((x)=>{'productId':x.product,
                'quantity':x.qty.text.trim()}).toList(),
            }),child:const Text('Lưu phiếu')),
          ],
        )));
      final selected=await Navigator.of(context,rootNavigator:true).push(route);
      await route.completed;
      if(selected==null||!mounted||branchId!=b||warehouseId!=source)return;
      final parsed=(selected['lines'] as List<dynamic>)
        .map((x)=>Map<String,dynamic>.from(x as Map)).toList();
      if(parsed.any((x)=>!validQty(x['quantity'].toString()))||
        parsed.map((x)=>x['productId']).toSet().length!=parsed.length){
        info('Kiểm tra số lượng và không trùng sản phẩm.',bad:true);return;
      }
      await send('',selected,0);
    }finally{
      for(final x in all)x.dispose();
      wSearch.dispose();pSearch.dispose();
    }
  }
  Future<void> transition(Map<String,dynamic> row,String action)async{
    final b=branchId,w=warehouseId;
    if(b==null||w==null||hasPending)return;
    final s=row['sourceWarehouseId'].toString(),d=row['destinationWarehouseId'].toString();
    if(w!=s)return;
    final scope=<String,dynamic>{
      'branchId':b,'sourceWarehouseId':s,'destinationWarehouseId':d};
    final expected=(row['revision'] as num).toInt();
    final approved=await showDialog<bool>(context:context,builder:(ctx)=>
      AlertDialog(title:Text(action=='approve'?'Duyệt phiếu chuyển?':
         action=='dispatch'?'Xuất kho nguồn?':'Hủy phiếu chuyển?'),
        content:const Text('Xuất và nhận hàng là hai nghiệp vụ riêng; tồn chỉ thay đổi sau xác nhận máy chủ.'),
        actions:[
          TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('Đóng')),
          FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('Xác nhận')),
        ]));
    if(approved!=true||!mounted||branchId!=b||warehouseId!=w)return;
    await send('/${row['id']}/$action',scope,expected);
  }
  Future<void> receive(Map<String,dynamic> row)async{
    final b=branchId,w=warehouseId;
    if(b==null||w==null||hasPending||w!=row['destinationWarehouseId']||
        !can('inventory.transfer.receive',w))return;
    final s=row['sourceWarehouseId'].toString(),d=row['destinationWarehouseId'].toString();
    Map<String,dynamic> transfer;
    try{
      transfer=await widget.client.transferDetail(widget.session.token,row['id'].toString(),
        branchId:b,warehouseId:w,sourceWarehouseId:s,destinationWarehouseId:d);
    }on ErpApiError catch(e){info(e.message,bad:true);return;}
    if(!mounted||branchId!=b||warehouseId!=w)return;
    final lines=(transfer['lines'] as List<dynamic>)
      .map((x)=>Map<String,dynamic>.from(x as Map)).toList();
    final controls=<int,TextEditingController>{
      for(final x in lines)(x['lineNo'] as num).toInt():TextEditingController(),
    };
    try{
      final route=DialogRoute<List<Map<String,dynamic>>>(context:context,
        builder:(ctx)=>AlertDialog(
          title:const Text('Nhận hàng chuyển kho'),
          content:SizedBox(width:480,child:SingleChildScrollView(child:Column(
            mainAxisSize:MainAxisSize.min,children:[
              const Text('Nhập số lượng thực nhận. Phần còn lại vẫn đang đi đường.',
                style:TextStyle(color:ErpTokens.muted,fontSize:12)),
              for(final x in lines)Padding(padding:const EdgeInsets.symmetric(vertical:9),
                child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
                  Text((x['sku']??'').toString()+' · '+(x['name']??'').toString()),
                  Text('Xuất: ${x['dispatchedBase']}  ·  Đã nhận: ${x['receivedBase']}  ·  Đang đi: ${x['inTransitBase']}',
                    style:const TextStyle(fontSize:12,color:ErpTokens.muted)),
                  TextField(controller:controls[(x['lineNo'] as num).toInt()],
                    decoration:const InputDecoration(labelText:'Nhận đợt này'),
                    keyboardType:const TextInputType.numberWithOptions(decimal:true)),
                  const Divider(height:10),
                ])),
            ]))),
          actions:[
            TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('Đóng')),
            FilledButton(onPressed:()=>Navigator.pop(ctx,[
              for(final c in controls.entries)if(c.value.text.trim().isNotEmpty)
                {'transferLineNo':c.key,'quantity':c.value.text.trim()},
            ]),child:const Text('Ghi nhận hàng')),
          ],
        ));
      final accepted=await Navigator.of(context,rootNavigator:true).push(route);
      await route.completed;
      if(accepted==null||!mounted||branchId!=b||warehouseId!=w)return;
      if(accepted.isEmpty||accepted.any((x)=>!validQty(x['quantity'].toString()))){
        info('Nhập số lượng hợp lệ cho ít nhất một sản phẩm.',bad:true);return;
      }
      final payload=<String,dynamic>{
        'branchId':b,'sourceWarehouseId':s,'destinationWarehouseId':d,
        'lines':accepted};
      await send('/${row['id']}/receipts',payload,
        (transfer['revision'] as num).toInt());
    }finally{for(final v in controls.values)v.dispose();}
  }
  Widget line(Map<String,dynamic> row){
    final statusValue=row['status']?.toString()??'';
    final wh=warehouseId;
    final source=row['sourceWarehouseId'].toString(),dest=row['destinationWarehouseId'].toString();
    return Column(children:[
      Padding(padding:const EdgeInsets.symmetric(vertical:12),child:
        Row(children:[
          Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
            Text('${row['sourceWarehouseName']} → ${row['destinationWarehouseName']}',
              style:const TextStyle(fontWeight:FontWeight.w700)),
            const SizedBox(height:4),
            Text('${status(statusValue)} · ${row['lineCount']} sản phẩm · ${row['receiptCount']} lần nhận',
              style:const TextStyle(color:ErpTokens.muted,fontSize:12)),
          ])),
          if(!busy&&!hasPending&&wh==source&&statusValue=='CREATED'&&
            can('inventory.transfer.approve',source))
            TextButton(onPressed:()=>transition(row,'approve'),child:const Text('Duyệt')),
          if(!busy&&!hasPending&&wh==source&&statusValue=='APPROVED'&&
            can('inventory.transfer.dispatch',source))
            TextButton(onPressed:()=>transition(row,'dispatch'),child:const Text('Xuất kho')),
          if(!busy&&!hasPending&&wh==source&&
            ['CREATED','APPROVED'].contains(statusValue)&&
            can('inventory.transfer.create',source))
            TextButton(onPressed:()=>transition(row,'cancel'),child:const Text('Hủy')),
          if(!busy&&!hasPending&&wh==dest&&
            ['IN_TRANSIT','PARTIALLY_RECEIVED'].contains(statusValue)&&
            can('inventory.transfer.receive',dest))
            TextButton(onPressed:()=>receive(row),child:const Text('Nhận hàng')),
        ])),
      const Divider(height:1),
    ]);
  }
  @override Widget build(BuildContext context){
    final small=MediaQuery.sizeOf(context).width<680;
    return Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      Text('Chuyển kho và hàng đang đi đường',
        style:Theme.of(context).textTheme.titleLarge),
      const SizedBox(height:6),
      const Text('Duyệt → Xuất kho nguồn → Nhận tại kho đích từng lần. Không cộng tồn trước khi nhận.',
        style:TextStyle(color:ErpTokens.muted,fontSize:12)),
      const SizedBox(height:16),
      Wrap(spacing:12,runSpacing:12,children:[
        SizedBox(width:small?300:250,child:DropdownButtonFormField<String>(
          key:ValueKey('transfer-branch-${branchId??'none'}'),initialValue:branchId,
          isExpanded:true,decoration:const InputDecoration(labelText:'Chi nhánh'),
          items:branches.map((b)=>DropdownMenuItem<String>(
            value:b['id'].toString(),child:Text((b['name']??'').toString(),
              overflow:TextOverflow.ellipsis))).toList(),
          onChanged:busy?null:(v){if(v!=null){setState(()=>branchId=v);loadWarehouses();}},
        )),
        SizedBox(width:small?300:250,child:DropdownButtonFormField<String>(
          key:ValueKey('transfer-wh-${warehouseId??'none'}'),initialValue:warehouseId,
          isExpanded:true,decoration:const InputDecoration(labelText:'Kho cần xem'),
          items:warehouses.map((x)=>DropdownMenuItem<String>(
            value:x['id'].toString(),child:Text((x['name']??'').toString(),
              overflow:TextOverflow.ellipsis))).toList(),
          onChanged:busy?null:(v){if(v!=null){setState(()=>warehouseId=v);reload();}},
        )),
        SizedBox(width:small?300:250,child:TextField(controller:whSearch,
          onSubmitted:(v)=>loadWarehouses(query:v.trim()),
          decoration:InputDecoration(labelText:'Tìm kho',
            suffixIcon:IconButton(tooltip:'Tìm kho',icon:const Icon(Icons.search),
              onPressed:()=>loadWarehouses(query:whSearch.text.trim()))))),
      ]),
      const SizedBox(height:12),
      Wrap(spacing:10,runSpacing:8,children:[
        if(hasPending)OutlinedButton.icon(
          onPressed:busy?null:retry,icon:const Icon(Icons.refresh),
          label:const Text('Xác minh lệnh chuyển kho đang chờ')),
        if(can('inventory.transfer.create',warehouseId))
          OutlinedButton.icon(onPressed:busy||hasPending?null:create,
            icon:const Icon(Icons.add),label:const Text('Lập phiếu chuyển')),
        IconButton(onPressed:busy?null:reload,
          icon:const Icon(Icons.refresh),tooltip:'Tải lại chuyển kho'),
      ]),
      if(error!=null)Padding(padding:const EdgeInsets.symmetric(vertical:12),
        child:Text(error!,style:const TextStyle(color:Colors.red))),
      if(loading)const LinearProgressIndicator(),
      if(!loading&&error==null&&items.isEmpty)
        const Padding(padding:EdgeInsets.all(18),child:Text('Kho này chưa có phiếu chuyển.')),
      if(!loading&&error==null)for(final row in items)line(row),
      if(!loading&&error==null&&hasMore)
        TextButton(onPressed:busy||loadingMore?null:more,
          child:Text(loadingMore?'Đang tải...':'Tải thêm phiếu chuyển')),
    ]);
  }
}
