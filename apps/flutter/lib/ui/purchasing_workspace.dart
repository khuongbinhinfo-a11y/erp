import 'dart:convert';
import 'package:material_ui/material_ui.dart';
import 'identity_client.dart';
import 'erp_toast.dart';
import 'erp_tokens.dart';

class _PurchaseLineInput{
 String productId;
 final TextEditingController quantity=TextEditingController();
 final TextEditingController unitCost=TextEditingController();
 _PurchaseLineInput(this.productId);
 void dispose(){quantity.dispose();unitCost.dispose();}
}

/// Purchases: transactional server documents; confirmation != receipt or payment.
class PurchasingWorkspace extends StatefulWidget{
 final ErpIdentityClient client;
 final IdentitySession session;
 const PurchasingWorkspace({super.key,required this.client,required this.session});
 @override State<PurchasingWorkspace> createState()=>_PurchasingWorkspaceState();
}
class _PurchasingWorkspaceState extends State<PurchasingWorkspace>{
 List<Map<String,dynamic>> branches=[],warehouses=[],orders=[];
 String? branchId,warehouseId,error;
 bool loading=true,busy=false;
 int generation=0;
 @override void initState(){super.initState();loadBranches();}
 @override void didUpdateWidget(covariant PurchasingWorkspace old){
  super.didUpdateWidget(old);
  if(old.client!=widget.client||old.session.token!=widget.session.token){
   generation++;branches=[];warehouses=[];orders=[];branchId=null;warehouseId=null;
   loadBranches();
  }
 }
 @override void dispose(){generation++;super.dispose();}
 bool hasBranch(String code)=>widget.session.grants.any((g)=>
   g.permission==code&&g.branchId==branchId);
 bool hasWarehouse(String code)=>widget.session.grants.any((g)=>
   g.permission==code&&g.branchId==branchId&&g.warehouseId==warehouseId);
 bool get canRead=>hasBranch('purchase.read')&&hasWarehouse('inventory.read');
 void inform(String message,{bool bad=false}){
  if(mounted)ErpToast.show(context,message,isError:bad);
 }
 Future<void> loadBranches()async{
  final n=++generation;setState((){loading=true;error=null;});
  try{
   final data=await widget.client.catalogItems(widget.session.token,'branches');
   if(!mounted||n!=generation)return;
   branches=data.where((b)=>widget.session.grants.any((g)=>
     g.branchId==b['id']&&g.permission.startsWith('purchase.'))).toList();
   branchId=branches.isEmpty?null:branches.first['id'].toString();
   if(branchId==null)setState((){loading=false;error='Chưa có quyền xem mua hàng.';});
   else await loadWarehouses();
  }on ErpApiError catch(e){
   if(mounted&&n==generation)setState((){loading=false;error=e.message;});
  }catch(_){
   if(mounted&&n==generation)setState((){loading=false;error='Không tải được chi nhánh.';});
  }
 }
 Future<void> loadWarehouses()async{
  final b=branchId;if(b==null)return;
  final n=++generation;setState((){loading=true;error=null;orders=[];});
  try{
   final data=await widget.client.catalogItems(
     widget.session.token,'warehouses',branchId:b);
   if(!mounted||n!=generation)return;
   warehouses=data.where((w)=>widget.session.grants.any((g)=>
     g.branchId==b&&g.warehouseId==w['id']&&g.permission=='inventory.read')).toList();
   warehouseId=warehouses.isEmpty?null:warehouses.first['id'].toString();
   if(warehouseId==null)setState((){loading=false;error='Chưa được cấp quyền tại kho nào.';});
   else await reload();
  }on ErpApiError catch(e){
   if(mounted&&n==generation)setState((){loading=false;error=e.message;});
  }catch(_){
   if(mounted&&n==generation)setState((){loading=false;error='Không tải được kho nhận hàng.';});
  }
 }
 Future<void> reload()async{
  final b=branchId,w=warehouseId;if(b==null||w==null)return;
  final n=++generation;setState((){loading=true;error=null;});
  try{
   final list=await widget.client.purchasingOrders(widget.session.token,b,w);
   if(mounted&&n==generation)setState((){orders=list;loading=false;});
  }on ErpApiError catch(e){
   if(mounted&&n==generation)setState((){loading=false;error=e.message;});
  }catch(_){
   if(mounted&&n==generation)setState((){loading=false;error='Không tải được đơn mua.';});
  }
 }
 bool validQuantity(String v)=>RegExp(r'^(?:0|[1-9][0-9]{0,11})(?:\.[0-9]{1,6})?$').hasMatch(v)
   &&RegExp(r'[1-9]').hasMatch(v);
 bool validCost(String v)=>RegExp(r'^(?:0|[1-9][0-9]{0,11})(?:\.[0-9]{1,4})?$').hasMatch(v);
 String status(String? value)=>switch(value){
   'DRAFT'=>'Đang lập','CONFIRMED'=>'Đã xác nhận',
   'PARTIALLY_RECEIVED'=>'Đã nhận một phần','RECEIVED'=>'Đã nhận đủ',
   'CANCELLED'=>'Đã hủy',_=>'Chưa xác định',
 };
 Future<void> submit(String path,Map<String,dynamic> payload,
     {required String intent,required int revision})async{
  if(busy)return;
  final scope=widget.session.actorId+':'+(warehouseId??'')+':'+intent;
  final held=widget.client.pendingPurchase(scope);
  if(held!=null&&jsonEncode(held.payload)!=jsonEncode(payload)){
   inform('Yêu cầu trước chưa xác minh. Vui lòng không tạo chứng từ khác.',bad:true);return;
  }
  final key=held?.key??'purchase-'+DateTime.now().microsecondsSinceEpoch.toString();
  widget.client.retainPurchase(scope,payload,key);
  setState(()=>busy=true);
  try{
   await widget.client.purchasingCommand(widget.session.token,path,payload,
     revision:revision,key:key);
   widget.client.clearPurchase(scope);
   inform('Máy chủ đã xác nhận nghiệp vụ mua hàng.');
   await reload();
  }on ErpApiError catch(e){
   final unknown=e.status==0||e.status>=500;
   if(!unknown)widget.client.clearPurchase(scope);
   inform(unknown?'Chưa xác minh máy chủ đã xử lý. Hãy thử lại đúng yêu cầu.':e.message,
     bad:true);
  }catch(_){
   inform('Kết quả chưa xác minh. Không tạo chứng từ mới để thử lại.',bad:true);
  }finally{if(mounted)setState(()=>busy=false);}
 }
 Future<void> createOrder()async{
  final b=branchId,w=warehouseId;
  if(b==null||w==null||!hasBranch('purchase.create')||!hasWarehouse('inventory.read'))return;
  List<Map<String,dynamic>> suppliers,products;
  try{
   final lists=await Future.wait([
    widget.client.catalogItems(widget.session.token,'suppliers',branchId:b),
    widget.client.catalogItems(widget.session.token,'products',branchId:b),
   ]);
   suppliers=lists[0].where((x)=>x['active']==true).toList();
   products=lists[1].where((x)=>x['active']==true).toList();
  }on ErpApiError catch(e){inform(e.message,bad:true);return;}
  catch(_){inform('Không tải được nhà cung cấp và sản phẩm.',bad:true);return;}
  if(!mounted)return;
  if(suppliers.isEmpty||products.isEmpty){
   inform('Cần có nhà cung cấp và sản phẩm đang hoạt động trước khi lập đơn mua.',bad:true);
   return;
  }
  String supplier=suppliers.first['id'].toString();
  final all=< _PurchaseLineInput >[];
  final rows=< _PurchaseLineInput >[];
  void addLine(){final line=_PurchaseLineInput(products.first['id'].toString());
    rows.add(line);all.add(line);}
  addLine();
  try{
   final selected=await showDialog<Map<String,dynamic>>(context:context,
    builder:(ctx)=>StatefulBuilder(builder:(ctx,refresh)=>AlertDialog(
      title:const Text('Lập đơn mua hàng'),
      content:SizedBox(width:560,child:SingleChildScrollView(child:
        Column(mainAxisSize:MainAxisSize.min,children:[
          DropdownButtonFormField<String>(initialValue:supplier,isExpanded:true,
           decoration:const InputDecoration(labelText:'Nhà cung cấp'),
           items:suppliers.map((s)=>DropdownMenuItem<String>(
             value:s['id'].toString(),
             child:Text((s['code']??'').toString()+' · '+(s['name']??'').toString(),
               overflow:TextOverflow.ellipsis))).toList(),
           onChanged:(v){if(v!=null)refresh(()=>supplier=v);}),
          const SizedBox(height:14),
          for(final item in rows.asMap().entries)
            Padding(padding:const EdgeInsets.only(bottom:12),
              child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
                Row(children:[
                  Expanded(child:DropdownButtonFormField<String>(
                    key:ValueKey('po-new-product-${item.key}-${item.value.productId}'),
                    initialValue:item.value.productId,isExpanded:true,
                    decoration:InputDecoration(labelText:'Hàng số ${item.key+1}'),
                    items:products.map((p)=>DropdownMenuItem<String>(
                     value:p['id'].toString(),
                     child:Text((p['code']??'').toString()+' · '+(p['name']??'').toString(),
                       overflow:TextOverflow.ellipsis))).toList(),
                    onChanged:(v){if(v!=null)refresh(()=>item.value.productId=v);},
                  )),
                  IconButton(tooltip:'Bỏ dòng',onPressed:rows.length<=1?null:
                    ()=>refresh(()=>rows.remove(item.value)),
                    icon:const Icon(Icons.close)),
                ]),
                const SizedBox(height:6),
                Wrap(spacing:10,runSpacing:8,children:[
                  SizedBox(width:150,child:TextField(
                    controller:item.value.quantity,
                    keyboardType:const TextInputType.numberWithOptions(decimal:true),
                    decoration:const InputDecoration(labelText:'SL đơn vị gốc'))),
                  SizedBox(width:180,child:TextField(
                    controller:item.value.unitCost,
                    keyboardType:const TextInputType.numberWithOptions(decimal:true),
                    decoration:const InputDecoration(labelText:'Giá mua / đơn vị gốc'))),
                ]),
                const Divider(height:18),
              ])),
          Align(alignment:Alignment.centerLeft,
            child:TextButton.icon(onPressed:rows.length>=40?null:()=>refresh(addLine),
             icon:const Icon(Icons.add),label:const Text('Thêm dòng hàng'))),
        ]))),
      actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('Đóng')),
        FilledButton(onPressed:()=>Navigator.pop(ctx,{
           'supplierId':supplier,
           'lines':rows.map((item)=><String,dynamic>{
            'productId':item.productId,'quantity':item.quantity.text.trim(),
            'unitCost':item.unitCost.text.trim(),
           }).toList(),
         }),child:const Text('Lưu đơn mua'))],
    )));
   if(!mounted||selected==null)return;
   final selectedLines=(selected['lines'] as List<dynamic>)
      .map((x)=>Map<String,dynamic>.from(x as Map)).toList();
   if(selectedLines.any((x)=>!validQuantity(x['quantity'] as String)||
      !validCost(x['unitCost'] as String))){
    inform('Số lượng phải dương và giá mua phải không âm, dùng dấu chấm thập phân.',
      bad:true);return;
   }
   if(selectedLines.map((x)=>x['productId']).toSet().length!=selectedLines.length){
    inform('Mỗi sản phẩm chỉ được xuất hiện một lần trên đơn mua.',bad:true);return;
   }
   await submit('orders',{'branchId':b,'warehouseId':w,
       'supplierId':selected['supplierId'],'note':'','lines':selectedLines},
       intent:'create',revision:0);
  }finally{for(final line in all)line.dispose();}
 }
 Future<void> changeOrder(Map<String,dynamic> row,String action)async{
  final b=branchId,w=warehouseId;if(b==null||w==null)return;
  final permission=action=='confirm'?'purchase.confirm':'purchase.create';
  if(!hasBranch(permission))return;
  final next=action=='confirm'?'Xác nhận':'Hủy';
  final approved=await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(
    title:Text('$next đơn mua?'),
    content:Text('Đơn '+(row['documentNo']??row['id']).toString()+
      ' sẽ được xử lý và lưu lịch sử trên máy chủ.'),
    actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('Đóng')),
      FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:Text(next))]));
  if(approved!=true||!mounted)return;
  final id=row['id'].toString(),revision=(row['revision'] as num).toInt();
  await submit('orders/$id/$action',{'branchId':b,'warehouseId':w},
    intent:'$action:$id:$revision',revision:revision);
 }
 Future<void> receiveOrder(Map<String,dynamic> row)async{
  final b=branchId,w=warehouseId;
  if(b==null||w==null||!hasWarehouse('purchase.receive'))return;
  Map<String,dynamic> order;
  try{
   order=await widget.client.purchasingOrder(
      widget.session.token,row['id'].toString(),b,w);
  }on ErpApiError catch(e){inform(e.message,bad:true);return;}
  if(!mounted)return;
  final items=(order['lines'] as List<dynamic>)
    .map((x)=>Map<String,dynamic>.from(x as Map)).toList();
  final controllers=<int,TextEditingController>{
    for(final x in items)(x['lineNo'] as num).toInt():TextEditingController(),
  };
  try{
   final selected=await showDialog<List<Map<String,dynamic>>>(context:context,
     builder:(ctx)=>AlertDialog(
      title:const Text('Ghi nhận hàng từ nhà cung cấp'),
      content:SizedBox(width:540,child:SingleChildScrollView(child:
       Column(mainAxisSize:MainAxisSize.min,children:[
        const Align(alignment:Alignment.centerLeft,child:Text(
          'Nhập số lượng thực nhận theo đơn vị gốc. Bỏ trống hàng chưa nhận.',
          style:TextStyle(color:ErpTokens.muted,fontSize:12))),
        const SizedBox(height:12),
        for(final item in items)
         Padding(padding:const EdgeInsets.only(bottom:14),child:Column(
          crossAxisAlignment:CrossAxisAlignment.start,children:[
           Text((item['sku']??'').toString()+' · '+(item['name']??'').toString(),
             style:const TextStyle(fontWeight:FontWeight.w700)),
           Text('Đặt '+(item['orderedBase']??'').toString()+
             ' · Đã nhận '+(item['receivedBase']??'').toString(),
             style:const TextStyle(color:ErpTokens.muted,fontSize:12)),
           TextField(controller:controllers[(item['lineNo'] as num).toInt()],
             keyboardType:const TextInputType.numberWithOptions(decimal:true),
             decoration:const InputDecoration(labelText:'Thực nhận đợt này')),
           const Divider(height:12),
          ])),
       ]))),
      actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('Đóng')),
       FilledButton(onPressed:()=>Navigator.pop(ctx,[
        for(final e in controllers.entries)
         if(e.value.text.trim().isNotEmpty)<String,dynamic>{
          'orderLineNo':e.key,'quantity':e.value.text.trim(),
         },
       ]),child:const Text('Ghi nhận nhập kho'))],
     ));
   if(!mounted||selected==null)return;
   if(selected.isEmpty){inform('Cần nhập ít nhất một dòng có số lượng.',bad:true);return;}
   if(selected.any((x)=>!validQuantity(x['quantity'] as String))){
    inform('Số lượng thực nhận không hợp lệ.',bad:true);return;
   }
   final id=order['id'].toString(),revision=(order['revision'] as num).toInt();
   await submit('orders/$id/receipts',{'branchId':b,'warehouseId':w,
    'lines':selected},intent:'receipt:$id:$revision',revision:revision);
  }finally{for(final c in controllers.values)c.dispose();}
 }
 Widget orderLine(Map<String,dynamic> row){
  final statusValue=row['status']?.toString();
  final title=(row['documentNo']??'Đơn chưa xác nhận').toString();
  return Column(children:[
   Padding(padding:const EdgeInsets.symmetric(vertical:13),
    child:Row(crossAxisAlignment:CrossAxisAlignment.start,children:[
     Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      Text(title,style:const TextStyle(fontWeight:FontWeight.w700)),
      const SizedBox(height:4),
      Text((row['supplierName']??'').toString()+' · '+status(statusValue)+
       ' · '+(row['lineCount']??'').toString()+' mặt hàng',
       style:const TextStyle(color:ErpTokens.muted,fontSize:12)),
     ])),
     if(!busy&&statusValue=='DRAFT'&&hasBranch('purchase.confirm'))
      TextButton(onPressed:()=>changeOrder(row,'confirm'),child:const Text('Xác nhận')),
     if(!busy&&['DRAFT','CONFIRMED'].contains(statusValue)&&
       hasBranch('purchase.create'))
      TextButton(onPressed:()=>changeOrder(row,'cancel'),child:const Text('Hủy')),
     if(!busy&&['CONFIRMED','PARTIALLY_RECEIVED'].contains(statusValue)&&
       hasWarehouse('purchase.receive'))
      TextButton(onPressed:()=>receiveOrder(row),child:const Text('Nhận hàng')),
    ])),
   const Divider(height:1),
  ]);
 }
 @override Widget build(BuildContext context){
  final narrow=MediaQuery.sizeOf(context).width<680;
  return Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
   Text('Đơn mua và nhận hàng',style:Theme.of(context).textTheme.titleLarge),
   const SizedBox(height:6),
   const Text('Tạo đơn → xác nhận → nhận từng đợt. Tồn chỉ tăng sau khi máy chủ ghi sổ.',
     style:TextStyle(color:ErpTokens.muted,fontSize:12)),
   const SizedBox(height:16),
   Wrap(spacing:12,runSpacing:12,children:[
    SizedBox(width:narrow?300:255,child:DropdownButtonFormField<String>(
      key:ValueKey('purchase-branch-'+(branchId??'')),initialValue:branchId,
      isExpanded:true,decoration:const InputDecoration(labelText:'Chi nhánh'),
      items:branches.map((b)=>DropdownMenuItem<String>(
       value:b['id'].toString(),child:Text((b['name']??'').toString(),
         overflow:TextOverflow.ellipsis))).toList(),
      onChanged:busy?null:(v){if(v!=null){setState(()=>branchId=v);loadWarehouses();}},
    )),
    SizedBox(width:narrow?300:255,child:DropdownButtonFormField<String>(
      key:ValueKey('purchase-warehouse-'+(warehouseId??'')),initialValue:warehouseId,
      isExpanded:true,decoration:const InputDecoration(labelText:'Kho nhận'),
      items:warehouses.map((w)=>DropdownMenuItem<String>(
       value:w['id'].toString(),child:Text((w['name']??'').toString(),
         overflow:TextOverflow.ellipsis))).toList(),
      onChanged:busy?null:(v){if(v!=null){setState(()=>warehouseId=v);reload();}},
    )),
   ]),
   const SizedBox(height:16),
   Wrap(spacing:10,runSpacing:8,children:[
    if(hasBranch('purchase.create')&&hasWarehouse('inventory.read'))
      OutlinedButton.icon(onPressed:busy?null:createOrder,
       icon:const Icon(Icons.add),label:const Text('Lập đơn mua')),
    IconButton(onPressed:busy?null:reload,icon:const Icon(Icons.refresh),
      tooltip:'Tải lại đơn mua'),
   ]),
   if(error!=null)Padding(padding:const EdgeInsets.symmetric(vertical:12),
    child:Text(error!,style:const TextStyle(color:Colors.red))),
   if(loading)const LinearProgressIndicator(),
   if(!loading&&error==null&&orders.isEmpty)const Padding(
    padding:EdgeInsets.all(18),child:Text('Chưa có đơn mua tại kho này.')),
   if(!loading&&error==null)for(final row in orders)orderLine(row),
  ]);
 }
}
