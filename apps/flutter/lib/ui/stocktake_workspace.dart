import 'dart:convert';
import 'package:material_ui/material_ui.dart';
import 'identity_client.dart';
import 'erp_tokens.dart';
import 'erp_toast.dart';
import 'erp_number_input.dart';
import 'erp_display.dart';

/// Physical count is an immutable business document. Only server-posted variance
/// changes ledger stock; the client never owns or overwrites a balance.
class StocktakeWorkspace extends StatefulWidget{
  final ErpIdentityClient client;
  final IdentitySession session;
  const StocktakeWorkspace({super.key,required this.client,required this.session});
  @override State<StocktakeWorkspace> createState()=>_StocktakeWorkspaceState();
}
class _StocktakeWorkspaceState extends State<StocktakeWorkspace>{
  List<Map<String,dynamic>> branches=[],warehouses=[],items=[];
  String? branchId,warehouseId,error;
  bool loading=true,busy=false,hasMore=false,moreLoading=false;
  int generation=0;
  final warehouseSearch=TextEditingController();
  @override void initState(){super.initState();loadBranches();}
  @override void didUpdateWidget(covariant StocktakeWorkspace old){
    super.didUpdateWidget(old);
    if(old.session.token!=widget.session.token||old.client!=widget.client){
      generation++;branches=[];warehouses=[];items=[];branchId=null;warehouseId=null;
      loadBranches();
    }
  }
  @override void dispose(){generation++;warehouseSearch.dispose();super.dispose();}
  bool can(String code)=>widget.session.grants.any((g)=>
    g.permission==code&&g.branchId==branchId&&g.warehouseId==warehouseId);
  String get scope=>'${widget.session.actorId}:${branchId??''}:${warehouseId??''}';
  bool get hasPending=>widget.client.pendingStocktake(scope)!=null;
  void notice(String message,{bool bad=false}){
    if(mounted)ErpToast.show(context,message,isError:bad);
  }
  String stage(dynamic x)=>switch(x){
    'CREATED'=>'Vừa tạo','COUNTING'=>'Đang kiểm đếm',
    'SUBMITTED'=>'Chờ duyệt','APPROVED'=>'Đã duyệt chênh lệch',
    'POSTED'=>'Đã ghi sổ','CANCELLED'=>'Đã hủy',_=>'Chưa xác định',
  };
  Future<void> loadBranches()async{
    final n=++generation;setState((){loading=true;error=null;});
    try{
      final result=await widget.client.stocktakeScopes(widget.session.token);
      if(!mounted||n!=generation)return;
      branches=result.branches;
      branchId=branches.isEmpty?null:branches.first['id'].toString();
      if(branchId==null)setState((){loading=false;error='Chưa được cấp quyền kiểm kê.';});
      else await loadWarehouses();
    }on ErpApiError catch(e){
      if(mounted&&n==generation)setState((){loading=false;error=e.message;});
    }catch(_){
      if(mounted&&n==generation)setState((){loading=false;error='Không tải được chi nhánh.';});
    }
  }
  Future<void> loadWarehouses({String query=''})async{
    final b=branchId;if(b==null)return;
    final n=++generation;
    setState((){loading=true;error=null;hasMore=false;moreLoading=false;items=[];});
    try{
      final result=await widget.client.stocktakeScopes(widget.session.token,
        branchId:b,query:query);
      if(!mounted||n!=generation)return;
      warehouses=result.warehouses.where((x)=>
        widget.session.grants.any((g)=>g.branchId==b&&g.warehouseId==x['id']&&
          const ['inventory.stocktake.read','inventory.stocktake.create']
            .contains(g.permission))).toList();
      warehouseId=warehouses.isEmpty?null:warehouses.first['id'].toString();
      if(warehouseId==null){
        setState((){loading=false;error='Không có kho được cấp quyền kiểm kê.';});
      }else{await reload();}
    }on ErpApiError catch(e){
      if(mounted&&n==generation)setState((){loading=false;error=e.message;});
    }catch(_){
      if(mounted&&n==generation)setState((){loading=false;error='Không tải được kho.';});
    }
  }
  Future<void> reload()async{
    final b=branchId,w=warehouseId;if(b==null||w==null)return;
    // A creator can capture the count snapshot without read access to prior
    // documents. Do not perform an unauthorized list call for such a grant.
    if(!can('inventory.stocktake.read')){
      generation++;
      if(mounted)setState((){
        items=[];hasMore=false;loading=false;moreLoading=false;error=null;
      });
      return;
    }
    final n=++generation;setState((){
      loading=true;error=null;moreLoading=false;
    });
    try{
      final page=await widget.client.stocktakePage(widget.session.token,
        branchId:b,warehouseId:w);
      if(mounted&&n==generation)setState((){
        items=page.items;hasMore=page.hasMore;loading=false;
      });
    }on ErpApiError catch(e){
      if(mounted&&n==generation)setState((){loading=false;error=e.message;});
    }catch(_){
      if(mounted&&n==generation)setState((){
        loading=false;error='Không tải được phiếu kiểm kê.';
      });
    }
  }
  Future<void> loadMore()async{
    final b=branchId,w=warehouseId;
    if(b==null||w==null||!hasMore||moreLoading||busy)return;
    final n=generation,offset=items.length;setState(()=>moreLoading=true);
    try{
      final page=await widget.client.stocktakePage(widget.session.token,
        branchId:b,warehouseId:w,offset:offset);
      if(mounted&&n==generation)setState((){
        items=[...items,...page.items];hasMore=page.hasMore;moreLoading=false;
      });
    }on ErpApiError catch(e){
      if(mounted&&n==generation)setState(()=>error=e.message);
    }finally{if(mounted&&n==generation)setState(()=>moreLoading=false);}
  }
  Future<void> send(String suffix,Map<String,dynamic> payload,int revision)async{
    final b=branchId,w=warehouseId;
    if(busy||b==null||w==null||payload['branchId']!=b||payload['warehouseId']!=w){
      notice('Kho hoặc chi nhánh đã thay đổi. Hãy mở lại thao tác.',bad:true);return;
    }
    final held=widget.client.pendingStocktake(scope);
    if(held!=null&&(held.suffix!=suffix||held.revision!=revision||
        jsonEncode(held.payload)!=jsonEncode(payload))){
      notice('Phải xác minh lệnh kiểm kê cũ trước khi làm chứng từ khác.',bad:true);
      return;
    }
    final key=held?.key??'stocktake-${DateTime.now().microsecondsSinceEpoch}';
    final originalScope=scope;
    widget.client.retainStocktake(originalScope,payload,key,
      suffix:suffix,revision:revision);
    setState(()=>busy=true);
    try{
      await widget.client.stocktakeCommand(widget.session.token,suffix,payload,
        revision:revision,key:key);
      widget.client.clearStocktake(originalScope);
      notice('Máy chủ đã xác nhận chứng từ kiểm kê.');
      await reload();
    }on ErpApiError catch(e){
      final unknown=e.status==0||e.status>=500||e.status==401||e.status==403;
      if(!unknown)widget.client.clearStocktake(originalScope);
      notice(unknown?'Chưa xác minh kết quả; hãy gửi lại đúng yêu cầu cũ.':e.message,
        bad:true);
    }catch(_){
      notice('Chưa xác minh máy chủ. Không lập thêm chứng từ.',bad:true);
    }finally{if(mounted)setState(()=>busy=false);}
  }
  Future<void> retry()async{
    final p=widget.client.pendingStocktake(scope);if(p==null)return;
    await send(p.suffix,p.payload,p.revision);
  }
  Future<void> create()async{
    final b=branchId,w=warehouseId;if(b==null||w==null||hasPending||
      !can('inventory.stocktake.create'))return;
    final ok=await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(
      title:const Text('Lập phiếu kiểm kê kho'),
      content:const Text('Hệ thống sẽ chụp tồn hiện tại để đối chiếu với số kiểm đếm.'),
      actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('Đóng')),
        FilledButton(onPressed:()=>Navigator.pop(ctx,true),
          child:const Text('Chụp tồn và tạo phiếu'))],
    ));
    if(ok!=true||!mounted||branchId!=b||warehouseId!=w)return;
    await send('',{'branchId':b,'warehouseId':w,'note':''},0);
  }
  Future<void> count(Map<String,dynamic> row)async{
    final b=branchId,w=warehouseId;
    if(b==null||w==null||hasPending||!can('inventory.stocktake.count'))return;
    Map<String,dynamic> detail;
    try{
      detail=await widget.client.stocktakeDetail(widget.session.token,
        row['id'].toString(),branchId:b,warehouseId:w);
    }on ErpApiError catch(e){notice(e.message,bad:true);return;}
    if(!mounted||branchId!=b||warehouseId!=w)return;
    final lines=(detail['lines'] as List<dynamic>)
      .map((x)=>Map<String,dynamic>.from(x as Map)).toList();
    final filter=TextEditingController(),quantity=TextEditingController();
    int? line=lines.isEmpty?null:(lines.first['lineNo'] as num).toInt();
    try{
      final route=DialogRoute<Map<String,dynamic>>(context:context,
        builder:(ctx)=>StatefulBuilder(builder:(ctx,update)=>AlertDialog(
          title:const Text('Ghi kết quả kiểm đếm'),
          content:SizedBox(width:500,child:Column(mainAxisSize:MainAxisSize.min,children:[
            TextField(controller:filter,onChanged:(v)=>update((){
              final found=lines.where((x)=>
                (x['sku'].toString()+' '+x['name'].toString())
                  .toLowerCase().contains(v.trim().toLowerCase())).toList();
              line=found.isEmpty?null:(found.first['lineNo'] as num).toInt();
            }),decoration:const InputDecoration(labelText:'Tìm SKU hoặc tên sản phẩm')),
            const SizedBox(height:10),
            DropdownButtonFormField<int>(
              key:ValueKey('count-line-${line??'none'}'),
              initialValue:line,isExpanded:true,
              decoration:const InputDecoration(labelText:'Mặt hàng kiểm'),
              items:lines.where((x)=>
                (x['sku'].toString()+' '+x['name'].toString())
                  .toLowerCase().contains(filter.text.trim().toLowerCase()))
                .map((x)=>DropdownMenuItem<int>(
                  value:(x['lineNo'] as num).toInt(),
                  child:Text('${x['sku']} · ${x['name']}',
                    overflow:TextOverflow.ellipsis))).toList(),
              onChanged:(v){if(v!=null)update(()=>line=v);}),
            const SizedBox(height:8),
            if(line!=null)Text('Tồn sổ tại thời điểm chụp: ${erpNumberText(lines.firstWhere((x)=>
               x['lineNo']==line)['snapshotOnHand'])}',
              style:TextStyle(color:ErpPalette.of(context).muted,fontSize:12)),
            TextField(controller:quantity,keyboardType:
              const TextInputType.numberWithOptions(decimal:true),
              inputFormatters:const [ErpGroupedNumberFormatter(maxIntegerDigits:12,maxFractionDigits:6)],
              decoration:const InputDecoration(labelText:'Số lượng thực kiểm')),
          ])),
          actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('Đóng')),
            FilledButton(onPressed:line==null?null:()=>Navigator.pop(ctx,{
              'lineNo':line,'quantity':erpNumberCanonical(quantity.text),
            }),child:const Text('Lưu số kiểm'))],
        )));
      final selected=await Navigator.of(context,rootNavigator:true).push(route);
      await route.completed;
      if(selected==null||!mounted||branchId!=b||warehouseId!=w)return;
      final qty=selected['quantity'].toString();
      if(!RegExp(r'^(?:0|[1-9][0-9]{0,11})(?:\.[0-9]{1,6})?$').hasMatch(qty)){
        notice('Số kiểm phải không âm, tối đa 6 chữ số thập phân.',bad:true);return;
      }
      final found=lines.firstWhere((x)=>x['lineNo']==selected['lineNo']);
      final round=(found['roundNo'] as num? ?? 0).toInt()+1;
      if(round>3){notice('Mặt hàng đã đủ ba lần kiểm đếm.',bad:true);return;}
      await send('/${row['id']}/counts',{'branchId':b,'warehouseId':w,
        'lines':[{'lineNo':selected['lineNo'],'round':round,'quantity':qty}]},
        (detail['revision'] as num).toInt());
    }finally{filter.dispose();quantity.dispose();}
  }
  Future<void> transition(Map<String,dynamic> row,String action)async{
    final b=branchId,w=warehouseId;if(b==null||w==null||hasPending)return;
    final title=action=='submit'?'Gửi duyệt':action=='approve'?'Duyệt chênh lệch':
      action=='post'?'Ghi chênh lệch vào sổ kho':'Hủy kiểm kê';
    final yes=await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(
      title:Text(title),
      content:const Text('Kiểm kê chỉ thay đổi tồn sau khi máy chủ xác nhận ghi sổ.'),
      actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('Đóng')),
        FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('Xác nhận'))],
    ));
    if(yes!=true||!mounted||branchId!=b||warehouseId!=w)return;
    await send('/${row['id']}/$action',{'branchId':b,'warehouseId':w},
      (row['revision'] as num).toInt());
  }
  Widget item(Map<String,dynamic> row){
    final st=row['status'].toString();
    return Column(children:[
      Padding(padding:const EdgeInsets.symmetric(vertical:12),
        child:Row(children:[
          Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
            Text('${row['warehouseName']} · ${stage(st)}',
              style:const TextStyle(fontWeight:FontWeight.w700)),
            const SizedBox(height:5),
            Text('${row['lineCount']} sản phẩm · ${row['adjustmentCount']} điều chỉnh',
              style:TextStyle(color:ErpPalette.of(context).muted,fontSize:12)),
          ])),
          if(st=='COUNTING'&&!busy&&!hasPending&&can('inventory.stocktake.count'))
            TextButton(onPressed:()=>count(row),child:const Text('Ghi số kiểm')),
          if(st=='COUNTING'&&!busy&&!hasPending&&can('inventory.stocktake.submit'))
            TextButton(onPressed:()=>transition(row,'submit'),child:const Text('Gửi duyệt')),
          if(st=='SUBMITTED'&&!busy&&!hasPending&&can('inventory.stocktake.approve'))
            TextButton(onPressed:()=>transition(row,'approve'),child:const Text('Duyệt')),
          if(st=='APPROVED'&&!busy&&!hasPending&&can('inventory.stocktake.post'))
            TextButton(onPressed:()=>transition(row,'post'),child:const Text('Ghi sổ')),
          if(['CREATED','COUNTING'].contains(st)&&!busy&&!hasPending&&
            can('inventory.stocktake.create'))
            TextButton(onPressed:()=>transition(row,'cancel'),child:const Text('Hủy')),
        ])),
      const Divider(height:1),
    ]);
  }
  @override Widget build(BuildContext context){
    final small=MediaQuery.sizeOf(context).width<680;
    return Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      Text('Kiểm kê và chênh lệch kho',style:Theme.of(context).textTheme.titleLarge),
      const SizedBox(height:6),
      Text('Chụp tồn → kiểm đếm → gửi duyệt → người khác duyệt → ghi sổ chênh lệch.',
        style:TextStyle(fontSize:12,color:ErpPalette.of(context).muted)),
      const SizedBox(height:16),
      Wrap(spacing:12,runSpacing:12,children:[
        SizedBox(width:small?300:255,child:DropdownButtonFormField<String>(
          key:ValueKey('stocktake-branch-${branchId??''}'),initialValue:branchId,
          isExpanded:true,decoration:const InputDecoration(labelText:'Chi nhánh'),
          items:branches.map((x)=>DropdownMenuItem<String>(
            value:x['id'].toString(),child:Text(x['name'].toString(),
              overflow:TextOverflow.ellipsis))).toList(),
          onChanged:busy?null:(v){if(v!=null){setState(()=>branchId=v);loadWarehouses();}},
        )),
        SizedBox(width:small?300:255,child:DropdownButtonFormField<String>(
          key:ValueKey('stocktake-warehouse-${warehouseId??''}'),initialValue:warehouseId,
          isExpanded:true,decoration:const InputDecoration(labelText:'Kho kiểm kê'),
          items:warehouses.map((x)=>DropdownMenuItem<String>(
            value:x['id'].toString(),child:Text(x['name'].toString(),
              overflow:TextOverflow.ellipsis))).toList(),
          onChanged:busy?null:(v){if(v!=null){setState(()=>warehouseId=v);reload();}},
        )),
        SizedBox(width:small?300:255,child:TextField(
          controller:warehouseSearch,onSubmitted:(v)=>loadWarehouses(query:v.trim()),
          decoration:InputDecoration(labelText:'Tìm mã hoặc tên kho',
            suffixIcon:IconButton(onPressed:()=>loadWarehouses(
              query:warehouseSearch.text.trim()),tooltip:'Tìm kho',
              icon:const Icon(Icons.search)))),
        ),
      ]),
      const SizedBox(height:12),
      Wrap(spacing:10,runSpacing:8,children:[
        if(hasPending)OutlinedButton.icon(onPressed:busy?null:retry,
          icon:const Icon(Icons.refresh),label:const Text('Xác minh lệnh kiểm kê')),
        if(can('inventory.stocktake.create'))OutlinedButton.icon(
          onPressed:busy||hasPending?null:create,icon:const Icon(Icons.add),
          label:const Text('Lập phiếu kiểm kê')),
        IconButton(onPressed:busy?null:reload,
          tooltip:'Tải lại kiểm kê',icon:const Icon(Icons.refresh)),
      ]),
      if(error!=null)Padding(padding:const EdgeInsets.symmetric(vertical:12),
        child:Text(error!,style:TextStyle(color:ErpPalette.of(context).danger))),
      if(loading)const LinearProgressIndicator(),
      if(!loading&&error==null&&items.isEmpty)
        Padding(padding:const EdgeInsets.all(18),child:Text(
          can('inventory.stocktake.read')
            ?'Kho này chưa có phiếu kiểm kê.'
            :'Bạn có quyền lập phiếu kiểm kê nhưng không được xem danh sách phiếu.')),
      if(!loading&&error==null)for(final row in items)item(row),
      if(!loading&&error==null&&hasMore)
        TextButton(onPressed:busy||moreLoading?null:loadMore,
          child:Text(moreLoading?'Đang tải...':'Tải thêm phiếu kiểm kê')),
    ]);
  }
}
