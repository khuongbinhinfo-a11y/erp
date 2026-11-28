import 'dart:convert';
import 'package:material_ui/material_ui.dart';
import 'erp_toast.dart';
import 'identity_client.dart';
import 'stock_scope_setup.dart';

/// Admin directory. Names shown first; technical codes stay immutable to protect documents.
class OrgDirectoryWorkspace extends StatefulWidget {
 final ErpIdentityClient client;
 final IdentitySession session;
 final Future<void> Function()? onScopesChanged;
 final bool policyOnly;
 const OrgDirectoryWorkspace({super.key,required this.client,required this.session,this.onScopesChanged,this.policyOnly=false});
 @override State<OrgDirectoryWorkspace> createState()=>_OrgDirectoryWorkspaceState();
}
class _OrgDirectoryWorkspaceState extends State<OrgDirectoryWorkspace>{
 IdentityScopes? directory;
 String? error;
 bool busy=false,loading=false;
 final Map<String,String> keys={};
 @override void initState(){super.initState();load();}
 @override void didUpdateWidget(covariant OrgDirectoryWorkspace old){
  super.didUpdateWidget(old);
  if(old.session.token!=widget.session.token){directory=null;keys.clear();load();}
 }
 String _fingerprint(String action,Object payload,int revision)=>
   '$action:$revision:${jsonEncode(payload)}';
 String requestKey(String action,Object payload,{int revision=0})=>
   keys.putIfAbsent(_fingerprint(action,payload,revision),
     ()=> 'org-${DateTime.now().microsecondsSinceEpoch}-${keys.length}');
 void acknowledgeKey(String action,Object payload,{int revision=0})=>
   keys.remove(_fingerprint(action,payload,revision));
 void notice(String message,{bool bad=false}){
  if(mounted)ErpToast.show(context,message,isError:bad);
 }
 Future<void> load()async{
  if(!mounted)return;
  setState(()=>loading=true);
  try{
   final result=widget.policyOnly
     ?await widget.client.policyScopes(widget.session.token)
     :await widget.client.scopes(widget.session.token);
   if(mounted)setState((){directory=result;error=null;});
  }on ErpApiError catch(e){if(mounted)setState(()=>error=e.message);}
  catch(_){if(mounted)setState(()=>error='Không tải được danh sách chi nhánh/kho.');}
  finally{if(mounted)setState(()=>loading=false);}
 }
 Future<({String code,String name})?> inputDialog(String title)async{
  final code=TextEditingController(),name=TextEditingController();
  try{
   final route=DialogRoute<({String code,String name})>(context:context,
    builder:(dialog)=>AlertDialog(title:Text(title),
     content:SizedBox(width:420,child:Column(mainAxisSize:MainAxisSize.min,children:[
      TextField(controller:code,textCapitalization:TextCapitalization.characters,
       decoration:const InputDecoration(labelText:'Mã nội bộ',hintText:'CN02 hoặc KHO02')),
      const SizedBox(height:10),
      TextField(controller:name,decoration:const InputDecoration(labelText:'Tên hiển thị tiếng Việt')),
      const SizedBox(height:8),
      const Text('Mã liên kết chứng từ; không đổi mã sau khi tạo.',style:TextStyle(fontSize:12)),
     ])),
     actions:[TextButton(onPressed:()=>Navigator.pop(dialog),child:const Text('Hủy')),
      FilledButton(onPressed:()=>Navigator.pop(dialog,
       (code:code.text.trim().toUpperCase(),name:name.text.trim())),
       child:const Text('Tạo'))]));
   final result=await Navigator.of(context,rootNavigator:true).push(route);
   await route.completed;
   return result;
  }finally{code.dispose();name.dispose();}
 }
 bool valid(({String code,String name}) input)=>
  RegExp(r'^[A-Z0-9][A-Z0-9_-]{0,63}$').hasMatch(input.code)&&
  input.name.isNotEmpty&&input.name.length<=160;
 Future<void> createBranch()async{
  final values=await inputDialog('Thêm chi nhánh');
  if(values==null||!mounted)return;
  if(!valid(values)){notice('Mã hoặc tên chi nhánh không hợp lệ.',bad:true);return;}
  final p={'code':values.code,'name':values.name};
  setState(()=>busy=true);
  try{
   await widget.client.createOrgBranch(widget.session.token,
     code:values.code,name:values.name,key:requestKey('branch',p));
   acknowledgeKey('branch',p);
   notice('Đã tạo chi nhánh. Quyền quản trị phạm vi mới đã gán cho quản trị viên chính.');
   await load();
   await widget.onScopesChanged?.call();
  }on ErpApiError catch(e){notice(e.message,bad:true);await load();}
  catch(_){notice('Không xác minh được lệnh tạo chi nhánh; kiểm tra danh sách trước khi thử lại.',bad:true);await load();}
  finally{if(mounted)setState(()=>busy=false);}
 }
 Future<void> createWarehouse()async{
  final branches=directory?.branches??[];
  if(branches.isEmpty){notice('Cần tạo chi nhánh trước.',bad:true);return;}
  String selected=branches.first.id;
  final branchId=await showDialog<String>(context:context,
   builder:(dialog)=>StatefulBuilder(builder:(ctx,refresh)=>AlertDialog(
    title:const Text('Kho thuộc chi nhánh nào?'),
    content:SizedBox(width:420,child:DropdownButtonFormField<String>(
     initialValue:selected,isExpanded:true,
     decoration:const InputDecoration(labelText:'Chi nhánh quản lý'),
     items:branches.map((b)=>DropdownMenuItem(value:b.id,child:Text(b.name,
      overflow:TextOverflow.ellipsis))).toList(),
     onChanged:(v)=>refresh(()=>selected=v??selected))),
    actions:[TextButton(onPressed:()=>Navigator.pop(dialog),child:const Text('Hủy')),
     FilledButton(onPressed:()=>Navigator.pop(dialog,selected),child:const Text('Tiếp tục'))])));
  if(branchId==null||!mounted)return;
  final values=await inputDialog('Thêm kho');
  if(values==null||!mounted)return;
  if(!valid(values)){notice('Mã hoặc tên kho không hợp lệ.',bad:true);return;}
  final p={'branchId':branchId,'code':values.code,'name':values.name};
  setState(()=>busy=true);
  try{
   await widget.client.createOrgWarehouse(widget.session.token,
    branchId:branchId,code:values.code,name:values.name,key:requestKey('warehouse',p));
   acknowledgeKey('warehouse',p);
   notice('Đã tạo kho. Mặc định không cho xuất âm; lô/vị trí tùy chọn theo sản phẩm.');
   await load();
   await widget.onScopesChanged?.call();
  }on ErpApiError catch(e){notice(e.message,bad:true);await load();}
  catch(_){notice('Không xác minh được lệnh tạo kho; kiểm tra danh sách trước khi thử lại.',bad:true);await load();}
  finally{if(mounted)setState(()=>busy=false);}
 }
 Future<IdentitySession?> latestSession()async{
  try{return await widget.client.restore(widget.session.token);}
  on ErpApiError catch(e){notice(e.message,bad:true);return null;}
 }
 Future<void> policy(IdentityScope warehouse)async{
  final b=warehouse.branchId;
  if(b==null)return;
  final session=await latestSession();
  if(session==null||!mounted)return;
  final canManage=session.grants.any((g)=>g.permission=='inventory.policy.manage'&&
    g.branchId==b&&g.warehouseId==warehouse.id);
  if(!canManage){notice('Chưa có quyền quản lý chính sách kho này. Hãy kiểm tra phân quyền.',bad:true);return;}
  try{
   final response=await widget.client.inventoryGuardPolicy(session.token,
    branchId:b,warehouseId:warehouse.id);
   if(!mounted)return;
   final current=Map<String,dynamic>.from(response['policy'] as Map);
   String reserve=current['reserveShortageMode']?.toString()??'WARN';
   String negative=current['negativeIssueMode']?.toString()??'BLOCK';
   final values=await showDialog<({String reserve,String negative})>(context:context,
    builder:(dialog)=>StatefulBuilder(builder:(ctx,refresh)=>AlertDialog(
     title:Text('Thiết lập kho · ${warehouse.name}'),
     content:SizedBox(width:460,child:Column(mainAxisSize:MainAxisSize.min,children:[
      DropdownButtonFormField<String>(initialValue:negative,isExpanded:true,
       decoration:const InputDecoration(labelText:'Cho phép xuất vượt tồn'),
       items:const [
        DropdownMenuItem(value:'BLOCK',child:Text('Không cho phép (mặc định)')),
        DropdownMenuItem(value:'WARN',child:Text('Cảnh báo, chưa cho xuất âm')),
        DropdownMenuItem(value:'ALLOW',child:Text('Cho phép xuất âm có kiểm soát')),
       ],onChanged:(v)=>refresh(()=>negative=v??negative)),
      const SizedBox(height:12),
      DropdownButtonFormField<String>(initialValue:reserve,isExpanded:true,
       decoration:const InputDecoration(labelText:'Thiếu tồn khi giữ hàng cho đơn'),
       items:const [
        DropdownMenuItem(value:'WARN',child:Text('Cảnh báo và ghi phần chờ hàng')),
        DropdownMenuItem(value:'ALLOW',child:Text('Cho phép ghi phần thiếu chờ hàng')),
        DropdownMenuItem(value:'BLOCK',child:Text('Chặn giữ hàng khi không đủ')),
       ],onChanged:(v)=>refresh(()=>reserve=v??reserve)),
      const SizedBox(height:10),
      const Text('Xuất âm còn yêu cầu quyền riêng, xác nhận của người xuất và không áp dụng cho hàng theo dõi lô/vị trí.',style:TextStyle(fontSize:12)),
     ])),
     actions:[TextButton(onPressed:()=>Navigator.pop(dialog),child:const Text('Hủy')),
      FilledButton(onPressed:()=>Navigator.pop(dialog,(reserve:reserve,negative:negative)),
       child:const Text('Lưu chính sách'))])));
   if(values==null||!mounted)return;
   setState(()=>busy=true);
   final body={'branchId':b,'warehouseId':warehouse.id,
    'reserveShortageMode':values.reserve,'negativeIssueMode':values.negative};
   final revision=(current['revision'] as num).toInt();
   await widget.client.inventoryAction(session.token,'guard-policy',body,
    key:requestKey('policy',body,revision:revision),revision:revision);
   acknowledgeKey('policy',body,revision:revision);
   notice('Đã lưu chính sách kho trên máy chủ.');
  }on ErpApiError catch(e){notice(e.message,bad:true);}
  catch(_){notice('Chưa xác nhận được kết quả chính sách. Tải lại trước khi thử.',bad:true);}
  finally{if(mounted)setState(()=>busy=false);}
 }
 Future<void> tracking(IdentityScope warehouse)async{
  final b=warehouse.branchId;
  if(b==null)return;
  final session=await latestSession();
  if(session==null||!mounted)return;
  bool can(String p)=>session.grants.any((g)=>g.permission==p&&
    g.branchId==b&&g.warehouseId==warehouse.id);
  if(!can('inventory.policy.manage')){
   notice('Không có quyền quản lý chính sách lô/vị trí.',bad:true);return;
  }
  try{
   await showStockScopeSetup(context:context,client:widget.client,session:session,
     branchId:b,warehouseId:warehouse.id,
     // Stock quantity assignment is intentionally kept in InventoryWorkspace,
     // which persists in-flight intents across navigation to prevent double posting.
     canManagePolicy:true,canAssign:false,
     onSubmit:(action,payload,revision)async{
      await widget.client.inventoryAction(session.token,action,payload,
       key:requestKey('tracking/$action',payload,revision:revision),revision:revision);
      acknowledgeKey('tracking/$action',payload,revision:revision);
      notice('Đã lưu chính sách lô/vị trí cho sản phẩm.');
     });
  }on ErpApiError catch(e){notice(e.message,bad:true);}
  catch(_){notice('Không thiết lập được lô/vị trí.',bad:true);}
 }
 @override Widget build(BuildContext context){
  final branches=directory?.branches??[];
  final warehouses=directory?.warehouses??[];
  return Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
   Text(widget.policyOnly?'Chính sách kho':'Tổ chức · Chi nhánh và Kho',
    style:const TextStyle(fontSize:18,fontWeight:FontWeight.w700)),
   const SizedBox(height:8),
   Text(widget.policyOnly
    ?'Chỉ hiển thị kho có quyền quản lý chính sách. Tồn kho và chứng từ nằm tại Công Ty → Kho.'
    :'Danh mục dùng chung cho vận hành kho. Mã nội bộ không đổi để bảo toàn chứng từ.'),
   const SizedBox(height:12),
   Wrap(spacing:10,runSpacing:8,children:[
    if(!widget.policyOnly)FilledButton.icon(onPressed:busy||loading?null:createBranch,
     icon:const Icon(Icons.add_business_outlined),label:const Text('Thêm chi nhánh')),
    if(!widget.policyOnly)FilledButton.icon(onPressed:busy||loading||branches.isEmpty?null:createWarehouse,
     icon:const Icon(Icons.warehouse_outlined),label:const Text('Thêm kho')),
    IconButton(onPressed:busy?null:load,tooltip:'Tải lại chi nhánh/kho',
     icon:const Icon(Icons.refresh)),
   ]),
   if(loading)const LinearProgressIndicator(),
   if(error!=null)Padding(padding:const EdgeInsets.only(top:8),
     child:Text(error!,style:const TextStyle(color:Colors.red))),
   const SizedBox(height:16),
   if(!widget.policyOnly)const Text('Danh sách chi nhánh',style:TextStyle(fontWeight:FontWeight.bold)),
   if(!widget.policyOnly)...branches.map((b)=>ListTile(dense:true,leading:const Icon(Icons.business_outlined),
    title:Text(b.name),subtitle:Text(b.code=='MAIN'?'Chi nhánh mặc định':'Mã: ${b.code}'))),
   if(!widget.policyOnly)const Divider(),
   Text(widget.policyOnly?'Kho được cấp quyền':'Kho trực thuộc',
    style:const TextStyle(fontWeight:FontWeight.bold)),
   if(warehouses.isEmpty)const Padding(padding:EdgeInsets.all(12),child:Text('Chưa có kho.')),
   ...warehouses.map((w){
    final branch=branches.where((b)=>b.id==w.branchId).firstOrNull;
    final canTrack=widget.session.grants.any((g)=>g.permission=='catalog.read'&&g.branchId==w.branchId)
      &&widget.session.grants.any((g)=>g.permission=='inventory.read'&&
        g.branchId==w.branchId&&g.warehouseId==w.id);
    return Padding(padding:const EdgeInsets.symmetric(vertical:4),
     child:Card(child:Padding(padding:const EdgeInsets.all(10),child:Column(
      crossAxisAlignment:CrossAxisAlignment.start,children:[
       Text(w.name,style:const TextStyle(fontWeight:FontWeight.w700)),
       Text('${w.code=='MAIN'?'Kho mặc định':'Mã ${w.code}'} · ${branch?.name??"Chi nhánh chưa xác định"}',
        style:const TextStyle(fontSize:12)),
       const SizedBox(height:6),
       if(widget.policyOnly)Wrap(spacing:8,runSpacing:6,children:[
        OutlinedButton.icon(onPressed:busy?null:()=>policy(w),
         icon:const Icon(Icons.tune_outlined),label:const Text('Xuất âm / giữ hàng')),
        OutlinedButton.icon(onPressed:busy||!canTrack?null:()=>tracking(w),
         icon:const Icon(Icons.layers_outlined),label:const Text('Lô / vị trí theo sản phẩm')),
       ]),
       if(widget.policyOnly&&!canTrack)
         const Text('Lô/vị trí cần thêm quyền xem danh mục và tồn kho của kho này.',
           style:TextStyle(fontSize:12)),
      ]))));
   }),
   const SizedBox(height:12),
   if(widget.policyOnly)const Text('Không dùng lô/vị trí: mở “Lô / vị trí theo sản phẩm” → chọn sản phẩm → “Chính sách yêu cầu lô/vị trí” → bỏ hai dấu bắt buộc. Kho mới mặc định không bắt buộc.',
    style:TextStyle(fontSize:12)),
  ]);
 }
}
