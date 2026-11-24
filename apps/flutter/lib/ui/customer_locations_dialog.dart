import 'package:material_ui/material_ui.dart';
import 'identity_client.dart';
import 'erp_tokens.dart';
import 'erp_toast.dart';

/// One customer can have multiple named stores / delivery destinations.
/// Mutations are confirmed only after server ACK. No local address is treated as saved.
class CustomerLocationsDialog extends StatefulWidget {
  final ErpIdentityClient client;
  final IdentitySession session;
  final String branchId;
  final String customerId;
  final String customerName;
  final bool canWrite;
  const CustomerLocationsDialog({super.key,required this.client,
    required this.session,required this.branchId,required this.customerId,
    required this.customerName,required this.canWrite});
  @override State<CustomerLocationsDialog> createState()=>_CustomerLocationsDialogState();
}
class _CustomerLocationsDialogState extends State<CustomerLocationsDialog>{
  List<Map<String,dynamic>> locations=[];
  bool loading=true,saving=false;
  String? error;
  @override void initState(){super.initState();reload();}
  Future<void> reload()async{
    if(mounted)setState((){loading=true;error=null;});
    try{
      final data=await widget.client.customerLocations(widget.session.token,
        widget.branchId,widget.customerId);
      if(mounted)setState((){locations=data;loading=false;});
    }on ErpApiError catch(e){
      if(mounted)setState((){loading=false;error=e.message;});
    }catch(_){
      if(mounted)setState((){loading=false;error='Không tải được danh sách địa chỉ.';});
    }
  }
  Future<void> edit([Map<String,dynamic>? old])async{
    if(saving||!widget.canWrite)return;
    final code=TextEditingController(text:(old?['code']??'').toString());
    final name=TextEditingController(text:(old?['name']??'').toString());
    final address=TextEditingController(text:(old?['address']??'').toString());
    final phone=TextEditingController(text:(old?['phone']??'').toString());
    var isDefault=old?['isDefault']==true;
    var active=old?['active']!=false;
    final keyPart=(old?['id']??'create').toString();
    final kind='catalog.customer-location.${widget.customerId}.$keyPart';
    ModalRoute<dynamic>? editRoute;
    try{
      final payload=await showDialog<Map<String,dynamic>>(
        context:context,builder:(dialog){editRoute=ModalRoute.of(dialog);
          return StatefulBuilder(builder:(ctx,refresh)=>
          AlertDialog(
            title:Text(old==null?'Thêm cửa hàng / địa chỉ':'Sửa địa chỉ giao hàng'),
            content:SizedBox(width:440,child:SingleChildScrollView(
              child:Column(mainAxisSize:MainAxisSize.min,children:[
                TextField(key:const ValueKey('location-code'),controller:code,
                  readOnly:old!=null,
                  decoration:const InputDecoration(
                    labelText:'Mã cửa hàng',hintText:'CH01')),
                const SizedBox(height:10),
                TextField(key:const ValueKey('location-name'),controller:name,
                  decoration:const InputDecoration(labelText:'Tên cửa hàng / địa điểm')),
                const SizedBox(height:10),
                TextField(key:const ValueKey('location-address'),controller:address,
                  maxLines:2,decoration:const InputDecoration(labelText:'Địa chỉ giao hàng')),
                const SizedBox(height:10),
                TextField(key:const ValueKey('location-phone'),controller:phone,
                  keyboardType:TextInputType.phone,
                  decoration:const InputDecoration(labelText:'Số điện thoại (tùy chọn)')),
                CheckboxListTile(
                  title:const Text('Địa chỉ mặc định'),
                  value:isDefault,onChanged:(v)=>refresh(()=>isDefault=v??false)),
                if(old!=null)CheckboxListTile(
                  title:const Text('Đang sử dụng'),
                  value:active,onChanged:(v)=>refresh(()=>active=v??false)),
              ]))),
            actions:[
              TextButton(onPressed:()=>Navigator.pop(dialog),
                child:const Text('Hủy')),
              FilledButton(key:const ValueKey('location-save'),
                onPressed:()=>Navigator.pop(dialog,<String,dynamic>{
                  'branchId':widget.branchId,
                  if(old==null)'code':code.text.trim(),
                  'name':name.text.trim(),'address':address.text.trim(),
                  'phone':phone.text.trim().isEmpty?null:phone.text.trim(),
                  'isDefault':isDefault,if(old!=null)'active':active,
                }),child:const Text('Lưu địa chỉ')),
            ],
          ));});
      if(payload==null||!mounted)return;
      final pending=widget.client.pendingR1(widget.session.actorId,widget.branchId,kind);
      // Keep the exact old revision inside the pending intent; it is part of
      // the server idempotency fingerprint even after an ACK is lost.
      final stored=pending?.payload??<String,dynamic>{
        ...payload,if(old!=null)'_erpExpectedRevision':old['revision'] as int,
      };
      final outgoing=Map<String,dynamic>.from(stored)..remove('_erpExpectedRevision');
      if(pending!=null&&outgoing.toString()!=payload.toString()){
        ErpToast.show(context,'Đang có yêu cầu chưa xác nhận. Kiểm tra lại trước khi đổi dữ liệu.',isError:true);
        return;
      }
      final expected=(stored['_erpExpectedRevision'] as int?)??(old?['revision'] as int?)??0;
      final key=pending?.key??'location-${DateTime.now().microsecondsSinceEpoch}';
      if(pending==null)widget.client.retainR1(
        widget.session.actorId,widget.branchId,kind,stored,key);
      setState(()=>saving=true);
      try{
        if(old==null){
          await widget.client.createCustomerLocation(
            widget.session.token,widget.customerId,outgoing,key:key);
        }else{
          await widget.client.updateCustomerLocation(
            widget.session.token,widget.customerId,old['id'].toString(),
            expected,outgoing,key:key);
        }
        widget.client.clearR1(widget.session.actorId,widget.branchId,kind);
        if(mounted){
          ErpToast.show(context,'Địa chỉ đã được máy chủ xác nhận.');
          await reload();
        }
      }on ErpApiError catch(e){
        if(e.status==400||e.status==404||e.status==409)
          widget.client.clearR1(widget.session.actorId,widget.branchId,kind);
        if(mounted)ErpToast.show(context,e.message,isError:true);
      }catch(_){
        if(mounted)ErpToast.show(context,
          'Chưa có xác nhận máy chủ; hãy thử lại cùng yêu cầu.',isError:true);
      }finally{if(mounted)setState(()=>saving=false);}
    }finally{
      if(editRoute!=null)await editRoute!.completed;
      code.dispose();name.dispose();address.dispose();phone.dispose();
    }
  }
  @override Widget build(BuildContext context){
    return AlertDialog(
      title:Text('Cửa hàng / địa chỉ · ${widget.customerName}'),
      content:SizedBox(width:620,height:400,child:Column(children:[
        if(loading)const LinearProgressIndicator(),
        if(error!=null)Text(error!,style:const TextStyle(color:ErpTokens.danger)),
        Expanded(child:ListView(children:[
          for(final row in locations)
            ListTile(
              key:ValueKey('customer-location-${row['id']}'),
              dense:true,
              title:Text('${row['code']} · ${row['name']}',
                style:const TextStyle(fontWeight:FontWeight.w700)),
              subtitle:Text('${row['address']}${row['phone']!=null?' · ${row['phone']}':''}'),
              trailing:Row(mainAxisSize:MainAxisSize.min,children:[
                if(row['isDefault']==true)const Text('Mặc định',
                  style:TextStyle(fontWeight:FontWeight.w700,color:ErpTokens.primary)),
                if(row['active']==false)const Text('Ngừng sử dụng',
                  style:TextStyle(color:ErpTokens.danger)),
                if(widget.canWrite)IconButton(
                  tooltip:'Sửa địa chỉ',onPressed:saving?null:()=>edit(row),
                  icon:const Icon(Icons.edit_outlined,size:18)),
              ]),
            ),
        ])),
      ])),
      actions:[
        TextButton(onPressed:()=>Navigator.pop(context),child:const Text('Đóng')),
        if(widget.canWrite)FilledButton.icon(
          onPressed:saving?null:()=>edit(),icon:const Icon(Icons.add),
          label:const Text('Thêm địa chỉ')),
      ],
    );
  }
}
