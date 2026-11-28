import 'package:material_ui/material_ui.dart';
import 'identity_client.dart';
import 'erp_tokens.dart';

/// T5-C: canonical staff-linked drivers in trip planning; no inventory, AR or COD posting.
class DeliveryTripWorkspace extends StatefulWidget{
 final ErpIdentityClient client;final IdentitySession session;
 const DeliveryTripWorkspace({super.key,required this.client,required this.session});
 @override State<DeliveryTripWorkspace> createState()=>_DeliveryTripWorkspaceState();
}
class _DeliveryTripWorkspaceState extends State<DeliveryTripWorkspace>{
 List<IdentityScope> warehouses=[];
 List<Map<String,dynamic>> trips=[],drivers=[],vehicles=[],eligible=[],employees=[];
 Map<String,dynamic>? detail;
 String? warehouse,branch,error;
 bool busy=false,loading=true,_loadingMoreTrips=false,_hasMoreTrips=false;
 int generation=0,_nextTripOffset=0;
 @override void initState(){super.initState();_start();}
 String get today{
  final d=DateTime.now();
  String n(int x)=>x.toString().padLeft(2,'0');
  return '${d.year}-${n(d.month)}-${n(d.day)}';
 }
 bool get canManage=>branch!=null&&widget.session.grants.any((g)=>
   g.permission=='delivery.update'&&g.branchId==branch);
 bool canWarehouse(IdentityScope w)=>w.branchId!=null&&
  widget.session.grants.any((g)=>g.permission=='inventory.read'&&
    g.branchId==w.branchId&&g.warehouseId==w.id)&&
  widget.session.grants.any((g)=>g.permission=='delivery.read'&&g.branchId==w.branchId);
 Future<void> _start()async{
  final epoch=++generation;
  setState((){loading=true;error=null;});
  try{
   final scopes=await widget.client.scopes(widget.session.token);
   if(!mounted||generation!=epoch)return;
   final allowed=scopes.warehouses.where(canWarehouse).toList();
   final current=allowed.where((x)=>x.id==warehouse).firstOrNull??allowed.firstOrNull;
   setState((){
    warehouses=allowed;warehouse=current?.id;branch=current?.branchId;
   });
   if(current==null)setState(()=>loading=false);
   else await _load();
  }on ErpApiError catch(e){
   if(mounted&&generation==epoch)setState((){loading=false;error=e.message;});
  }catch(_){
   if(mounted&&generation==epoch)setState((){
    loading=false;error='Không tải được kho được cấp quyền.';
   });
  }
 }
 Future<void> _load({String? chosen})async{
  final b=branch,w=warehouse,epoch=++generation,priorRows=trips.length;
  if(b==null||w==null)return;
  setState((){loading=true;error=null;_loadingMoreTrips=false;});
  try{
   final rows=await Future.wait([
    widget.client.deliveryTripItems(widget.session.token,'trips',b,w),
    widget.client.deliveryTripItems(widget.session.token,'drivers',b,w),
    widget.client.deliveryTripItems(widget.session.token,'vehicles',b,w),
    widget.client.deliveryTripItems(widget.session.token,'trips/eligible',b,w),
    widget.client.deliveryTripItems(widget.session.token,'employees',b,w),
   ]);
   if(!mounted||generation!=epoch)return;
   final refreshed=<Map<String,dynamic>>[...rows[0]];
   var lastPage=rows[0],nextOffset=100;
   // Preserve loaded pages after writes; older draft trips must not disappear.
   while(lastPage.length==100&&refreshed.length<priorRows&&nextOffset<=100000){
    lastPage=await widget.client.deliveryTripItems(widget.session.token,
      'trips',b,w,offset:nextOffset);
    if(!mounted||generation!=epoch)return;
    final seen=refreshed.map((o)=>o['id']).toSet();
    refreshed.addAll(lastPage.where((o)=>seen.add(o['id'])));
    nextOffset+=100;
   }
   final tid=chosen??detail?['id']?.toString();
   Map<String,dynamic>? selected;
   if(tid!=null){
    selected=await widget.client.deliveryTripDetail(widget.session.token,b,w,tid);
   }
   if(!mounted||generation!=epoch)return;
   setState((){
    trips=refreshed;drivers=rows[1];vehicles=rows[2];eligible=rows[3];employees=rows[4];
    detail=selected;loading=false;
    _nextTripOffset=nextOffset;_hasMoreTrips=lastPage.length==100&&nextOffset<=100000;
   });
  }on ErpApiError catch(e){
   if(mounted&&generation==epoch)setState((){error=e.message;loading=false;});
  }catch(_){
   if(mounted&&generation==epoch)setState((){
    error='Không thể tải điều phối. Kiểm tra backend/migration T5-B.';loading=false;
   });
  }
 }
 Future<void> _loadMoreTrips()async{
  final b=branch,w=warehouse,epoch=generation,offset=_nextTripOffset;
  if(b==null||w==null||loading||busy||_loadingMoreTrips||
     !_hasMoreTrips||offset>100000)return;
  setState(()=>_loadingMoreTrips=true);
  try{
   final page=await widget.client.deliveryTripItems(
     widget.session.token,'trips',b,w,offset:offset);
   if(!mounted||generation!=epoch||b!=branch||w!=warehouse)return;
   setState((){
    final seen=trips.map((o)=>o['id']).toSet();
    trips=[...trips,...page.where((o)=>seen.add(o['id']))];
    _nextTripOffset=offset+100;
    _hasMoreTrips=page.length==100&&_nextTripOffset<=100000;
   });
  }on ErpApiError catch(e){
   if(mounted&&generation==epoch)setState(()=>error=e.message);
  }catch(_){
   if(mounted&&generation==epoch)setState(()=>error='Không tải được trang chuyến tiếp theo.');
  }finally{if(mounted&&generation==epoch)setState(()=>_loadingMoreTrips=false);}
 }
 Future<void> _choose(Map<String,dynamic> trip)async{
  final b=branch,w=warehouse,epoch=++generation;
  if(b==null||w==null)return;
  setState((){loading=true;_loadingMoreTrips=false;});
  try{
   final x=await widget.client.deliveryTripDetail(
    widget.session.token,b,w,trip['id'] as String);
   if(mounted&&generation==epoch)setState((){detail=x;loading=false;});
  }on ErpApiError catch(e){
   if(mounted&&generation==epoch)setState((){error=e.message;loading=false;});
  }
 }
 Future<void> _write(String path,Map<String,dynamic> payload,int revision,
    {String? chosen})async{
  final b=branch,w=warehouse;
  if(b==null||w==null||busy||!canManage)return;
  setState((){busy=true;error=null;});
  try{
   final result=await widget.client.deliveryTripWrite(widget.session,path,
    {'branchId':b,'warehouseId':w,...payload},revision);
   if(!mounted)return;
   setState(()=>busy=false);
   await _load(chosen:chosen??result['id']?.toString()??detail?['id']?.toString());
  }on ErpApiError catch(e){
   if(mounted)setState((){error=e.message;busy=false;});
  }catch(_){
   if(mounted)setState((){
    error='Chưa có ACK máy chủ. Tải lại chuyến để đối chiếu trước khi thử lại.';
    busy=false;
   });
  }
 }
 Future<void> _newTrip()async{
  // Controller-free fields outlive dialog pop animations safely.
  var day=today,note='';
  final ok=await showDialog<bool>(context:context,builder:(c)=>AlertDialog(
   title:const Text('Tạo chuyến giao'),
   content:SizedBox(width:380,child:Column(mainAxisSize:MainAxisSize.min,children:[
    TextFormField(initialValue:day,onChanged:(value)=>day=value,
     decoration:const InputDecoration(labelText:'Ngày giao YYYY-MM-DD')),
    TextFormField(initialValue:note,onChanged:(value)=>note=value,maxLength:500,
     decoration:const InputDecoration(labelText:'Ghi chú (không bắt buộc)')),
   ])),
   actions:[TextButton(onPressed:()=>Navigator.pop(c,false),child:const Text('Hủy')),
    FilledButton(onPressed:()=>Navigator.pop(c,true),child:const Text('Tạo chuyến'))],
  ));
  if(ok==true&&mounted)await _write('trips',
   {'plannedDate':day.trim(),'note':note.trim()},0,chosen:null);
 }
 Future<void> _newEmployee()async{
  var code='',fullName='',phone='',jobTitle='';
  final ok=await showDialog<bool>(context:context,builder:(c)=>AlertDialog(
   title:const Text('Thêm nhân viên'),
   content:SizedBox(width:410,child:Column(mainAxisSize:MainAxisSize.min,children:[
    TextFormField(onChanged:(v)=>code=v,
     decoration:const InputDecoration(labelText:'Mã nhân viên')),
    TextFormField(onChanged:(v)=>fullName=v,
     decoration:const InputDecoration(labelText:'Họ và tên')),
    TextFormField(onChanged:(v)=>jobTitle=v,
     decoration:const InputDecoration(labelText:'Chức vụ (tùy chọn)')),
    TextFormField(onChanged:(v)=>phone=v,keyboardType:TextInputType.phone,
     decoration:const InputDecoration(labelText:'Số điện thoại (tùy chọn)')),
   ])),
   actions:[TextButton(onPressed:()=>Navigator.pop(c,false),child:const Text('Hủy')),
    FilledButton(onPressed:()=>Navigator.pop(c,true),child:const Text('Tạo nhân viên'))],
  ));
  if(ok==true&&mounted)await _write('employees',{
   'code':code.trim().toUpperCase(),'fullName':fullName.trim(),
   if(phone.trim().isNotEmpty)'phone':phone.trim(),
   if(jobTitle.trim().isNotEmpty)'jobTitle':jobTitle.trim(),
  },0);
 }
 Future<void> _editEmployee(Map<String,dynamic> employee)async{
  var fullName=employee['fullName']?.toString()??'',
   phone=employee['phone']?.toString()??'',
   jobTitle=employee['jobTitle']?.toString()??'',
   active=employee['active']==true;
  final result=await showDialog<bool>(context:context,builder:(c)=>
   StatefulBuilder(builder:(c,refresh)=>AlertDialog(
    title:Text('Nhân viên · ${employee['code']}'),
    content:SizedBox(width:410,child:Column(mainAxisSize:MainAxisSize.min,children:[
     TextFormField(initialValue:fullName,onChanged:(v)=>fullName=v,
      decoration:const InputDecoration(labelText:'Họ và tên')),
     TextFormField(initialValue:jobTitle,onChanged:(v)=>jobTitle=v,
      decoration:const InputDecoration(labelText:'Chức vụ')),
     TextFormField(initialValue:phone,onChanged:(v)=>phone=v,
      decoration:const InputDecoration(labelText:'Số điện thoại')),
     SwitchListTile(value:active,title:const Text('Đang hoạt động'),
      onChanged:(v)=>refresh(()=>active=v)),
     const Text('Ngừng hoạt động không xóa lịch sử. Nhân viên còn chuyến chưa kết thúc không thể ngừng.',
      style:TextStyle(fontSize:12)),
    ])),
    actions:[TextButton(onPressed:()=>Navigator.pop(c,false),child:const Text('Hủy')),
     FilledButton(onPressed:()=>Navigator.pop(c,true),child:const Text('Lưu'))],
   )));
  if(result==true&&mounted)await _write(
   'employees/${employee['id']}/update',{
    'fullName':fullName.trim(),'active':active,
    if(phone.trim().isNotEmpty)'phone':phone.trim(),
    if(jobTitle.trim().isNotEmpty)'jobTitle':jobTitle.trim(),
   },employee['revision'] as int);
 }
 Future<void> _manageEmployees()async{
  if(!mounted)return;
  final chosen=await showDialog<Map<String,dynamic>>(context:context,
   builder:(c)=>AlertDialog(title:const Text('Nhân viên chi nhánh'),
    content:SizedBox(width:500,height:450,
     child:ListView(children:employees.map((e)=>ListTile(
      title:Text(e['fullName']?.toString()??''),
      subtitle:Text('${e['code']} · ${e['active']==true?'Đang làm việc':'Đã ngừng'}'
       '${e['linkedDriver']==true?' · Đã liên kết tài xế':''}'),
      trailing:const Icon(Icons.edit_outlined),
      onTap:()=>Navigator.pop(c,e),
     )).toList())),
    actions:[TextButton(onPressed:()=>Navigator.pop(c),child:const Text('Đóng'))]));
  if(chosen!=null&&mounted)await _editEmployee(chosen);
 }
 Future<void> _newResource(bool driver)async{
  if(driver){
   final available=employees.where((e)=>
     e['active']==true&&e['linkedDriver']!=true).toList();
   if(available.isEmpty){
    if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
     content:Text('Chưa có nhân viên đang hoạt động chưa liên kết. Hãy tạo nhân viên trước.')));
    return;
   }
   String chosen=available.first['id'] as String;
   final ok=await showDialog<bool>(context:context,builder:(c)=>
    StatefulBuilder(builder:(ctx,refresh)=>AlertDialog(
     title:const Text('Liên kết tài xế từ nhân viên'),
     content:SizedBox(width:410,child:DropdownButtonFormField<String>(
      initialValue:chosen,isExpanded:true,
      decoration:const InputDecoration(labelText:'Nhân viên đang hoạt động'),
      items:available.map((e)=>DropdownMenuItem<String>(value:e['id'] as String,
       child:Text('${e['code']} · ${e['fullName']}',
        overflow:TextOverflow.ellipsis))).toList(),
      onChanged:(v)=>refresh(()=>chosen=v??chosen))),
     actions:[TextButton(onPressed:()=>Navigator.pop(c,false),child:const Text('Hủy')),
      FilledButton(onPressed:()=>Navigator.pop(c,true),child:const Text('Liên kết'))],
    )));
   if(ok==true&&mounted)await _write('drivers',{'employeeId':chosen},0);
   return;
  }
  var code='',name='',plate='';
  final ok=await showDialog<bool>(context:context,builder:(c)=>AlertDialog(
   title:const Text('Thêm xe'),
   content:SizedBox(width:380,child:Column(mainAxisSize:MainAxisSize.min,children:[
    TextFormField(onChanged:(value)=>code=value,
     decoration:const InputDecoration(labelText:'Mã xe')),
    TextFormField(onChanged:(value)=>name=value,
     decoration:const InputDecoration(labelText:'Tên phương tiện')),
    TextFormField(onChanged:(value)=>plate=value,
     decoration:const InputDecoration(labelText:'Biển số xe')),
   ])),
   actions:[TextButton(onPressed:()=>Navigator.pop(c,false),child:const Text('Hủy')),
    FilledButton(onPressed:()=>Navigator.pop(c,true),child:const Text('Lưu'))],
  ));
  if(ok==true&&mounted)await _write('vehicles',{
   'code':code.trim(),'name':name.trim(),'licensePlate':plate.trim(),
  },0);
 }
 Future<void> _assign()async{
  final d=detail,b=branch,w=warehouse,token=widget.session.token;
  if(d==null||b==null||w==null||eligible.isEmpty)return;
  final chosen=<String>{};
  // Dialog owns only plain text, avoiding controller disposal during pop animation.
  var searchTerm='';
  var displayed=<Map<String,dynamic>>[...eligible];
  var nextOffset=200,hasMore=eligible.length==200,queryBusy=false;
  var submittedQuery='';
  String? queryError;
  BuildContext? dialogContext;
  Future<void> fetchEligible(StateSetter refresh,{bool append=false})async{
   if(queryBusy||!mounted||dialogContext?.mounted!=true)return;
   final requested=append?nextOffset:0,
    term=append?submittedQuery:searchTerm.trim();
   refresh((){queryBusy=true;queryError=null;});
   try{
    final result=await widget.client.deliveryTripItems(token,
      'trips/eligible',b,w,offset:requested,search:term);
    if(!mounted||dialogContext?.mounted!=true||
       branch!=b||warehouse!=w)return;
    refresh((){
     if(append){
      final seen=displayed.map((o)=>o['id']).toSet();
      displayed.addAll(result.where((o)=>seen.add(o['id'])));
     }else{
      displayed=<Map<String,dynamic>>[...result];
      submittedQuery=term;
     }
     nextOffset=requested+200;
     hasMore=result.length==200&&nextOffset<=100000;
     queryBusy=false;
    });
   }on ErpApiError catch(e){
    if(dialogContext?.mounted==true)refresh((){
      queryError=e.message;queryBusy=false;
    });
   }catch(_){
    if(dialogContext?.mounted==true)refresh((){
      queryError='Chưa tải được danh sách đơn giao. Vui lòng thử lại.';
      queryBusy=false;
    });
   }
  }
  final ok=await showDialog<bool>(context:context,builder:(dialog){
   dialogContext=dialog;
   return StatefulBuilder(builder:(c,update)=>AlertDialog(
    title:const Text('Chọn đơn giao theo chuyến'),
    content:SizedBox(
     width:(MediaQuery.sizeOf(c).width-48).clamp(280.0,520.0).toDouble(),
     height:(MediaQuery.sizeOf(c).height*.58).clamp(260.0,480.0).toDouble(),
     child:Column(children:[
      TextField(key:const ValueKey('trip-eligible-search'),
       onChanged:(value)=>searchTerm=value,
       textInputAction:TextInputAction.search,
       onSubmitted:(_)=>fetchEligible(update),
       decoration:InputDecoration(
        labelText:'Tìm mã đơn, khách hoặc địa chỉ',
        isDense:true,prefixIcon:const Icon(Icons.search),
        suffixIcon:IconButton(tooltip:'Tìm đơn chờ gán',
         onPressed:queryBusy?null:()=>fetchEligible(update),
         icon:const Icon(Icons.arrow_forward)),
       )),
      const SizedBox(height:8),
      Wrap(spacing:8,runSpacing:6,crossAxisAlignment:WrapCrossAlignment.center,
       children:[
        Text('Đã chọn ${chosen.length} đơn',
         style:const TextStyle(fontWeight:FontWeight.w700)),
        TextButton.icon(key:const ValueKey('trip-select-all-orders'),
         onPressed:queryBusy||displayed.isEmpty?null:()=>update((){
          final first=displayed.take(100).map((x)=>x['id'] as String).toList();
          if(first.length==chosen.length&&first.every(chosen.contains)){
           chosen.clear();
          }else{
           chosen..clear()..addAll(first);
          }
         }),
         icon:const Icon(Icons.select_all,size:16),
         label:const Text('Chọn tất cả (tối đa 100)')),
       ]),
      if(queryError!=null)Text(queryError!,
       style:TextStyle(color:ErpPalette.of(c).danger,fontSize:12)),
      Expanded(child:queryBusy?
       const Center(child:CircularProgressIndicator()):
       displayed.isEmpty?
       const Center(child:Text('Không có đơn giao phù hợp.')):
       ListView(children:displayed.map((o)=>
        CheckboxListTile(
         dense:true,controlAffinity:ListTileControlAffinity.leading,
         value:chosen.contains(o['id']),
         onChanged:(v)=>update((){
          if(v==true&&chosen.length<100)chosen.add(o['id'] as String);
          else if(v!=true)chosen.remove(o['id']);
         }),
         title:Text('${o['documentNo']} · ${o['customerName']}',
          maxLines:1,overflow:TextOverflow.ellipsis),
         subtitle:Text(o['deliveryAddress']?.toString()??'',maxLines:2,
          overflow:TextOverflow.ellipsis),
        )).toList())),
      if(hasMore)Align(alignment:Alignment.center,
       child:TextButton.icon(
        key:const ValueKey('trip-eligible-load-more'),
        onPressed:queryBusy?null:()=>fetchEligible(update,append:true),
        icon:const Icon(Icons.expand_more),
        label:const Text('Tải thêm 200 đơn'),
       )),
     ])),
    actions:[
     TextButton(onPressed:()=>Navigator.pop(c,false),child:const Text('Hủy')),
     FilledButton(onPressed:chosen.isEmpty||queryBusy?null:()=>Navigator.pop(c,true),
      child:Text('Thêm ${chosen.length} đơn')),
    ],
   ));
  });
  if(ok==true&&mounted&&chosen.isNotEmpty&&branch==b&&warehouse==w){
   await _write('trips/${d['id']}/assign',{'orderIds':chosen.toList()},
    d['revision'] as int);
  }
 }
 Future<void> _plan()async{
  final d=detail;
  if(d==null)return;
  final ds=drivers.where((x)=>x['active']==true).toList(),
   vs=vehicles.where((x)=>x['active']==true).toList();
  if(ds.isEmpty||vs.isEmpty){
   setState(()=>error='Phải khai báo tài xế và xe đang hoạt động trước khi phân chuyến.');
   return;
  }
  // Reopened plans retain their existing assignments. Never silently change
  // a driver or vehicle just because the user edits only the delivery date.
  final savedDriver=d['driverId']?.toString(),savedVehicle=d['vehicleId']?.toString();
  String? driver=savedDriver==null?ds.first['id'] as String:
    (ds.any((x)=>x['id']==savedDriver)?savedDriver:null);
  String? vehicle=savedVehicle==null?vs.first['id'] as String:
    (vs.any((x)=>x['id']==savedVehicle)?savedVehicle:null);
  var day=d['plannedDate']?.toString()??today;
  var note=d['note']?.toString()??'';
  final ok=await showDialog<bool>(context:context,builder:(c)=>StatefulBuilder(
   builder:(c,refresh)=>AlertDialog(
    title:const Text('Phân xe và tài xế'),
    content:SizedBox(width:400,child:Column(mainAxisSize:MainAxisSize.min,children:[
     DropdownButtonFormField<String>(initialValue:driver,isExpanded:true,
      decoration:const InputDecoration(labelText:'Tài xế chính'),
      items:ds.map((x)=>DropdownMenuItem(value:x['id'] as String,
       child:Text(x['name'].toString()))).toList(),
      onChanged:(x)=>refresh(()=>driver=x)),
     DropdownButtonFormField<String>(initialValue:vehicle,isExpanded:true,
      decoration:const InputDecoration(labelText:'Xe'),
      items:vs.map((x)=>DropdownMenuItem(value:x['id'] as String,
       child:Text('${x['licensePlate']} · ${x['name']}'))).toList(),
      onChanged:(x)=>refresh(()=>vehicle=x)),
     if(savedDriver!=null&&driver==null)const Text(
      'Tài xế cũ đã ngừng hoạt động. Chọn tài xế thay thế.'),
     if(savedVehicle!=null&&vehicle==null)const Text(
      'Xe cũ đã ngừng hoạt động. Chọn xe thay thế.'),
     TextFormField(initialValue:day,onChanged:(value)=>day=value,
      decoration:const InputDecoration(labelText:'Ngày giao')),
     TextFormField(initialValue:note,onChanged:(value)=>note=value,maxLength:500,
      decoration:const InputDecoration(labelText:'Ghi chú')),
    ])),
    actions:[TextButton(onPressed:()=>Navigator.pop(c,false),child:const Text('Hủy')),
     FilledButton(onPressed:driver==null||vehicle==null?null:
       ()=>Navigator.pop(c,true),
      child:const Text('Lưu kế hoạch'))],
   )));
  if(ok==true&&mounted)await _write('trips/${d['id']}/plan',{
   'driverId':driver,'vehicleId':vehicle,'plannedDate':day.trim(),
   'note':note.trim()},d['revision'] as int);
 }
 Future<void> _reorder(int index,int delta)async{
  final d=detail,stops=(detail?['stops'] as List?)??[];
  final other=index+delta;if(d==null||other<0||other>=stops.length)return;
  final ids=stops.map((x)=>x['orderId'] as String).toList();
  final item=ids[index];ids[index]=ids[other];ids[other]=item;
  await _write('trips/${d['id']}/reorder',{'orderIds':ids},d['revision'] as int);
 }
 Future<void> _transition(String action)async{
  final d=detail;if(d==null)return;
  final ok=await showDialog<bool>(context:context,builder:(c)=>AlertDialog(
   title:Text(action=='lock'?'Khóa chuyến giao?':'Mở lại chuyến?'),
   content:Text(action=='lock'?
    'Khóa xe, tài xế, đơn và thứ tự điểm. Chưa xuất kho, chưa ghi giao hay thu tiền.':
    'Chuyển kế hoạch về nháp để điều chỉnh.'),
   actions:[TextButton(onPressed:()=>Navigator.pop(c,false),child:const Text('Hủy')),
    FilledButton(onPressed:()=>Navigator.pop(c,true),child:const Text('Xác nhận'))],
  ));
  if(ok==true&&mounted)await _write('trips/${d['id']}/$action',{},d['revision'] as int);
 }
 String status(Object? v)=>switch(v){
  'DRAFT'=>'Nháp','PLANNED'=>'Đã lên kế hoạch','LOCKED'=>'Đã khóa',_=>'Chưa rõ'};
 Widget tripList(){
  final p=ErpPalette.of(context);
  if(trips.isEmpty)return const Text('Chưa có chuyến. Bấm Tạo chuyến.');
  return Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
   const Text('Danh sách chuyến',style:TextStyle(fontWeight:FontWeight.w700)),
   for(final t in trips)InkWell(
    key:ValueKey('trip-row-${t['id']}'),onTap:busy?null:()=>_choose(t),
    child:Container(
     padding:const EdgeInsets.symmetric(vertical:10,horizontal:6),
     decoration:BoxDecoration(
      border:Border(bottom:BorderSide(color:p.border)),
      color:detail?['id']==t['id']?p.mint:null),
     child:Row(children:[Expanded(child:Column(
      crossAxisAlignment:CrossAxisAlignment.start,children:[
       Text(t['tripNo']?.toString()??'',style:const TextStyle(fontWeight:FontWeight.w700)),
       Text('${t['plannedDate']} · ${t['stopCount']} điểm · ${status(t['status'])}',
        style:TextStyle(fontSize:12,color:p.muted)),
       if(t['driverName']!=null)Text('${t['driverName']} · ${t['licensePlate']??''}',
        maxLines:1,overflow:TextOverflow.ellipsis),
     ])),const Icon(Icons.chevron_right,size:18)]),
    )),
   if(_hasMoreTrips)Padding(padding:const EdgeInsets.only(top:12),
    child:OutlinedButton.icon(
      key:const ValueKey('trip-load-more'),
      onPressed:_loadingMoreTrips||busy?null:_loadMoreTrips,
      icon:_loadingMoreTrips?
       const SizedBox(width:16,height:16,child:CircularProgressIndicator(strokeWidth:2)):
       const Icon(Icons.expand_more),
      label:Text(_loadingMoreTrips?'Đang tải':'Tải thêm 100 chuyến'),
    )),
  ]);
 }
 Widget tripDetail(){
  final p=ErpPalette.of(context),d=detail,stops=(detail?['stops'] as List?)??[];
  if(d==null)return const Text('Chọn chuyến để xem điểm giao.');
  final editable=d['status']=='DRAFT'&&canManage&&!busy;
  return Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
   Row(children:[
    Expanded(child:Text('${d['tripNo']} · ${status(d['status'])}',
     style:const TextStyle(fontWeight:FontWeight.w800))),
    Text('${stops.length} điểm',style:TextStyle(color:p.muted)),
   ]),
   const SizedBox(height:8),
   if(d['driverName']!=null)Text('Tài xế: ${d['driverName']} · ${d['licensePlate']??''}'),
   if(editable)Wrap(spacing:8,runSpacing:8,children:[
    FilledButton.icon(key:const ValueKey('trip-add-orders'),
     onPressed:eligible.isEmpty?null:_assign,
     icon:const Icon(Icons.playlist_add),label:const Text('Thêm nhiều đơn')),
    OutlinedButton.icon(key:const ValueKey('trip-plan'),
     onPressed:stops.isEmpty?null:_plan,icon:const Icon(Icons.route),
     label:const Text('Phân xe, tài xế')),
   ]),
   if(d['status']=='PLANNED'&&canManage)Wrap(spacing:8,children:[
    FilledButton(key:const ValueKey('trip-lock'),
     onPressed:busy?null:()=>_transition('lock'),
     child:const Text('Khóa kế hoạch')),
    TextButton(onPressed:busy?null:()=>_transition('reopen'),
     child:const Text('Mở lại để sửa')),
   ]),
   if(d['status']=='LOCKED')Padding(padding:const EdgeInsets.symmetric(vertical:8),
    child:Text('Đã khóa. Xuất kho, xác nhận giao và COD thuộc bước tiếp theo.',
     style:TextStyle(color:p.muted))),
   const SizedBox(height:10),
   if(stops.isEmpty)const Text('Chưa có điểm giao.')
   else for(int i=0;i<stops.length;i++)
    Container(key:ValueKey('trip-stop-${stops[i]['orderId']}'),
     padding:const EdgeInsets.symmetric(vertical:9,horizontal:5),
     decoration:BoxDecoration(border:Border(bottom:BorderSide(color:p.border))),
     child:Row(children:[
      SizedBox(width:26,child:Text('${i+1}')),
      Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
       Text('${stops[i]['customerName']} · ${stops[i]['documentNo']}',
        maxLines:1,overflow:TextOverflow.ellipsis,
        style:const TextStyle(fontWeight:FontWeight.w700)),
       Text(stops[i]['deliveryAddress']?.toString()??'',
        maxLines:2,overflow:TextOverflow.ellipsis,
        style:TextStyle(fontSize:12,color:p.muted)),
      ])),
      if(editable)...[
       IconButton(tooltip:'Đưa lên',onPressed:i==0?null:()=>_reorder(i,-1),
        icon:const Icon(Icons.keyboard_arrow_up)),
       IconButton(tooltip:'Đưa xuống',onPressed:i==stops.length-1?null:
        ()=>_reorder(i,1),icon:const Icon(Icons.keyboard_arrow_down)),
       IconButton(tooltip:'Bỏ đơn',onPressed:()=>_write(
        'trips/${d['id']}/unassign',{'orderIds':[stops[i]['orderId']]},
        d['revision'] as int),icon:const Icon(Icons.close,size:18)),
      ],
     ])),
  ]);
 }
 @override Widget build(BuildContext context){
  final p=ErpPalette.of(context),narrow=MediaQuery.sizeOf(context).width<850;
  return Padding(padding:const EdgeInsets.all(10),child:Column(
   crossAxisAlignment:CrossAxisAlignment.stretch,children:[
    Wrap(alignment:WrapAlignment.spaceBetween,spacing:8,runSpacing:8,children:[
     Text('Điều phối giao hàng',style:TextStyle(fontSize:18,
      fontWeight:FontWeight.w800,color:p.ink)),
     Wrap(spacing:8,children:[
      OutlinedButton.icon(onPressed:busy||loading?null:()=>_load(),
       icon:const Icon(Icons.refresh),label:const Text('Làm mới')),
      FilledButton.icon(key:const ValueKey('trip-create'),
       onPressed:busy||loading||!canManage?null:_newTrip,
       icon:const Icon(Icons.add),label:const Text('Tạo chuyến')),
     ]),
    ]),
    const SizedBox(height:12),
    if(warehouses.isNotEmpty)ConstrainedBox(constraints:const BoxConstraints(maxWidth:350),
     child:DropdownButtonFormField<String>(
      key:ValueKey('trip-warehouse-$warehouse'),initialValue:warehouse,
      decoration:const InputDecoration(labelText:'Kho xuất phát',isDense:true),
      items:warehouses.map((w)=>DropdownMenuItem(value:w.id,
       child:Text('${w.name} · ${w.code}'))).toList(),
      onChanged:busy?null:(w){
       if(w==null)return;final x=warehouses.firstWhere((a)=>a.id==w);
       setState((){warehouse=w;branch=x.branchId;detail=null;trips=[];
        _nextTripOffset=0;_hasMoreTrips=false;});_load();
      })),
    if(error!=null)Padding(padding:const EdgeInsets.all(10),
     child:Text(error!,style:TextStyle(color:p.danger))),
    if(loading)const Padding(padding:EdgeInsets.all(30),
     child:Center(child:CircularProgressIndicator()))
    else if(warehouse==null)const Text('Không có kho được cấp quyền điều phối.')
    else ...[
     const SizedBox(height:10),
     Wrap(spacing:8,runSpacing:8,children:[
      OutlinedButton.icon(onPressed:busy||!canManage?null:_newEmployee,
       icon:const Icon(Icons.person_add_alt_1_outlined),label:const Text('Thêm nhân viên')),
      OutlinedButton.icon(onPressed:busy||!canManage?null:_manageEmployees,
       icon:const Icon(Icons.groups_outlined),label:const Text('Nhân viên')),
      OutlinedButton.icon(onPressed:busy||!canManage?null:()=>_newResource(true),
       icon:const Icon(Icons.badge_outlined),label:const Text('Liên kết tài xế')),
      OutlinedButton.icon(onPressed:busy||!canManage?null:()=>_newResource(false),
       icon:const Icon(Icons.local_shipping_outlined),label:const Text('Thêm xe')),
      Text('${trips.length} chuyến · ${eligible.length} đơn sẵn sàng',
       style:TextStyle(color:p.muted)),
     ]),
     const SizedBox(height:12),
     Flex(direction:narrow?Axis.vertical:Axis.horizontal,
      crossAxisAlignment:CrossAxisAlignment.start,children:[
       if(narrow)tripList()else Expanded(flex:4,child:tripList()),
       if(narrow)const SizedBox(height:16)else const SizedBox(width:16),
       if(narrow)tripDetail()else Expanded(flex:6,child:tripDetail()),
     ]),
    ],
   ]));
 }
}
