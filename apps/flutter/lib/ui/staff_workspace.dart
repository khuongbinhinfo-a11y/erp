import 'package:material_ui/material_ui.dart';
import 'identity_client.dart';
import 'erp_tokens.dart';

/// IA-A: canonical company-owned personnel. Does not create login accounts or drivers.
class StaffWorkspace extends StatefulWidget{
 final ErpIdentityClient client;
 final IdentitySession session;
 const StaffWorkspace({super.key,required this.client,required this.session});
 @override State<StaffWorkspace> createState()=>_StaffWorkspaceState();
}
class _StaffWorkspaceState extends State<StaffWorkspace>{
 List<IdentityScope> branches=[];
 List<Map<String,dynamic>> items=[];
 String? branch,error;
 bool loading=true,busy=false,hasMore=false;
 int offset=0,generation=0;
 String query='',status='all';
 final search=TextEditingController();
 bool get canWrite=>branch!=null&&widget.session.grants.any((g)=>
   g.permission=='org.employees.manage'&&g.branchId==branch);
 @override void initState(){super.initState();_initial();}
 @override void dispose(){generation++;search.dispose();super.dispose();}
 Future<void> _initial()async{
  final epoch=++generation;
  setState((){loading=true;error=null;});
  try{
   final loaded=await widget.client.staffBranches(widget.session.token);
   if(!mounted||epoch!=generation)return;
   branches=loaded;
   branch=loaded.where((b)=>b.id==branch).firstOrNull?.id??loaded.firstOrNull?.id;
   if(branch==null){setState(()=>loading=false);return;}
   await _load();
  }on ErpApiError catch(e){
   if(mounted&&epoch==generation)setState((){error=e.message;loading=false;});
  }catch(_){
   if(mounted&&epoch==generation)setState((){
    error='Không tải được chi nhánh được cấp quyền nhân sự.';loading=false;});
  }
 }
 Future<void> _load()async{
  final b=branch,epoch=++generation;
  if(b==null)return;
  setState((){loading=true;error=null;});
  try{
   final rows=await widget.client.staffItems(widget.session.token,b,
    search:query,active:status=='all'?null:status=='active');
   if(!mounted||epoch!=generation||b!=branch)return;
   setState((){
    items=rows;offset=rows.length;hasMore=rows.length==200;loading=false;
   });
  }on ErpApiError catch(e){
   if(mounted&&epoch==generation)setState((){error=e.message;loading=false;});
  }catch(_){
   if(mounted&&epoch==generation)setState((){
    error='Không tải được danh sách nhân viên.';loading=false;});
  }
 }
 Future<void> _more()async{
  final b=branch,epoch=generation,at=offset;
  if(b==null||!hasMore||loading||busy)return;
  setState(()=>busy=true);
  try{
   final page=await widget.client.staffItems(widget.session.token,b,offset:at,
    search:query,active:status=='all'?null:status=='active');
   if(!mounted||epoch!=generation||b!=branch)return;
   setState((){
    final seen=items.map((e)=>e['id']).toSet();
    items=[...items,...page.where((e)=>seen.add(e['id']))];
    offset=at+page.length;hasMore=page.length==200;
   });
  }on ErpApiError catch(e){
   if(mounted)setState(()=>error=e.message);
  }finally{if(mounted)setState(()=>busy=false);}
 }
 Future<void> _save(String path,Map<String,dynamic> fields,int revision)async{
  final b=branch;
  if(b==null||busy||!canWrite)return;
  setState((){busy=true;error=null;});
  try{
   await widget.client.staffWrite(widget.session,path,{'branchId':b,...fields},revision);
   if(!mounted)return;
   setState(()=>busy=false);
   await _load();
  }on ErpApiError catch(e){
   if(mounted)setState((){error=e.message;busy=false;});
  }catch(_){
   if(mounted)setState((){
    error='Chưa xác minh được kết quả lưu. Tải lại danh sách trước khi thử lại.';
    busy=false;
   });
  }
 }
 Future<void> _edit([Map<String,dynamic>? employee])async{
  if(!canWrite||busy)return;
  final isNew=employee==null;
  var code=employee?['code']?.toString()??'',
   name=employee?['fullName']?.toString()??'',
   department=employee?['department']?.toString()??'',
   jobTitle=employee?['jobTitle']?.toString()??'',
   phone=employee?['phone']?.toString()??'',
   active=employee?['active']==true||isNew;
  final accepted=await showDialog<bool>(context:context,builder:(c)=>
   StatefulBuilder(builder:(ctx,refresh)=>AlertDialog(
    title:Text(isNew?'Thêm nhân viên':'Sửa nhân viên · '+code),
    content:SizedBox(width:450,child:SingleChildScrollView(child:Column(
     mainAxisSize:MainAxisSize.min,children:[
      if(isNew)TextFormField(onChanged:(v)=>code=v,
       decoration:const InputDecoration(labelText:'Mã nhân viên')),
      TextFormField(initialValue:name,onChanged:(v)=>name=v,
       decoration:const InputDecoration(labelText:'Họ và tên')),
      TextFormField(initialValue:department,onChanged:(v)=>department=v,
       decoration:const InputDecoration(labelText:'Bộ phận (tùy chọn)')),
      TextFormField(initialValue:jobTitle,onChanged:(v)=>jobTitle=v,
       decoration:const InputDecoration(labelText:'Chức vụ (tùy chọn)')),
      TextFormField(initialValue:phone,onChanged:(v)=>phone=v,
       keyboardType:TextInputType.phone,
       decoration:const InputDecoration(labelText:'Số điện thoại (tùy chọn)')),
      if(!isNew)SwitchListTile(value:active,title:const Text('Đang hoạt động'),
       onChanged:(v)=>refresh(()=>active=v)),
      if(!isNew)const Text(
       'Ngừng hoạt động không xóa lịch sử. Không ngừng nhân viên có chuyến chưa kết thúc.',
       style:TextStyle(fontSize:12)),
     ]))),
    actions:[
     TextButton(onPressed:()=>Navigator.pop(c,false),child:const Text('Hủy')),
     FilledButton(onPressed:()=>Navigator.pop(c,true),child:const Text('Lưu')),
    ],
   )));
  if(accepted!=true||!mounted)return;
  final fields=<String,dynamic>{
   if(isNew)'code':code.trim().toUpperCase(),
   'fullName':name.trim(),
   'department':department.trim(),
   'jobTitle':jobTitle.trim(),
   if(phone.trim().isNotEmpty)'phone':phone.trim(),
   if(!isNew)'active':active,
  };
  await _save(isNew?'employees':'employees/'+employee['id'].toString(),
   fields,isNew?0:(employee['revision'] as int));
 }
 @override Widget build(BuildContext context){
  final p=ErpPalette.of(context);
  return Padding(padding:const EdgeInsets.all(10),child:Column(
   crossAxisAlignment:CrossAxisAlignment.stretch,children:[
    Wrap(alignment:WrapAlignment.spaceBetween,spacing:8,runSpacing:8,children:[
     Text('Nhân viên Công Ty',style:TextStyle(fontSize:18,
       fontWeight:FontWeight.w800,color:p.ink)),
     Wrap(spacing:8,children:[
      OutlinedButton.icon(onPressed:busy||loading?null:_load,
       icon:const Icon(Icons.refresh),label:const Text('Làm mới')),
      FilledButton.icon(key:const ValueKey('staff-create'),
       onPressed:busy||loading||!canWrite?null:()=>_edit(),
       icon:const Icon(Icons.person_add_alt_1_outlined),label:const Text('Thêm nhân viên')),
     ]),
    ]),
    const SizedBox(height:10),
    if(branches.isNotEmpty)ConstrainedBox(constraints:const BoxConstraints(maxWidth:360),
     child:DropdownButtonFormField<String>(
      key:ValueKey('staff-branch-$branch'),initialValue:branch,
      isExpanded:true,decoration:const InputDecoration(labelText:'Chi nhánh'),
      items:branches.map((b)=>DropdownMenuItem(value:b.id,
       child:Text(b.name,overflow:TextOverflow.ellipsis))).toList(),
      onChanged:busy?(v){}:(v){if(v==null)return;
       setState(()=>branch=v);_load();
      })),
    const SizedBox(height:8),
    Wrap(spacing:8,runSpacing:8,crossAxisAlignment:WrapCrossAlignment.center,children:[
     ConstrainedBox(constraints:const BoxConstraints(maxWidth:350),
      child:TextField(controller:search,
       decoration:InputDecoration(isDense:true,labelText:'Tìm mã, tên, bộ phận',
        prefixIcon:const Icon(Icons.search),
        suffixIcon:IconButton(icon:const Icon(Icons.search),tooltip:'Tìm nhân viên',
         onPressed:(){query=search.text.trim();_load();})),
       onSubmitted:(v){query=v.trim();_load();})),
     DropdownButton<String>(value:status,
      items:const [
       DropdownMenuItem(value:'all',child:Text('Tất cả')),
       DropdownMenuItem(value:'active',child:Text('Đang làm việc')),
       DropdownMenuItem(value:'inactive',child:Text('Ngừng hoạt động')),
      ],onChanged:(v){if(v==null)return;
        setState(()=>status=v);_load();
      }),
    ]),
    if(error!=null)Padding(padding:const EdgeInsets.symmetric(vertical:8),
     child:Text(error!,style:TextStyle(color:p.danger))),
    if(loading)const Padding(padding:EdgeInsets.all(20),
     child:Center(child:CircularProgressIndicator())),
    if(!loading&&branches.isEmpty)
     const Padding(padding:EdgeInsets.all(12),
      child:Text('Chưa có chi nhánh được cấp quyền quản lý nhân viên.')),
    if(!loading&&branch!=null&&items.isEmpty)
     const Padding(padding:EdgeInsets.all(20),
      child:Text('Chưa có nhân viên phù hợp.')),
    ...items.map((e)=>ListTile(
     key:ValueKey('staff-row-'+e['id'].toString()),
     dense:true,
     title:Text((e['fullName']??'').toString(),maxLines:1,
      overflow:TextOverflow.ellipsis),
     subtitle:Text([
       (e['code']??'').toString(),
       if((e['department']??'').toString().isNotEmpty)e['department'].toString(),
       if((e['jobTitle']??'').toString().isNotEmpty)e['jobTitle'].toString(),
       e['active']==true?'Đang làm việc':'Đã ngừng',
       if(e['linkedDriver']==true)'Tài xế',
       if(e['accountUserId']!=null)'Có tài khoản',
      ].join(' · '),maxLines:2,overflow:TextOverflow.ellipsis),
     trailing:canWrite?IconButton(tooltip:'Sửa nhân viên',
       onPressed:busy?null:()=>_edit(e),icon:const Icon(Icons.edit_outlined)):null,
    )),
    if(hasMore)TextButton(onPressed:busy||loading?null:_more,
     child:const Text('Tải thêm nhân viên')),
   ]));
 }
}
