import 'package:material_ui/material_ui.dart';
import 'erp_display.dart';
import 'erp_number_input.dart';
import 'identity_client.dart';
import 'manual_stock_issue.dart';

/// Stock classification: assigns existing stock to a bin/lot. Never posts
/// inventory_ledger or invents on-hand quantities on the client.
Future<void> showStockScopeSetup({
 required BuildContext context,required ErpIdentityClient client,
 required IdentitySession session,required String branchId,required String warehouseId,
 required bool canManagePolicy,required bool canAssign,
 required Future<void> Function(String,Map<String,dynamic>,int) onSubmit,
})async{
 if(!canManagePolicy&&!canAssign)return;
 final token=session.token;
 List<Map<String,dynamic>> products=await client.catalogItems(token,'products',branchId:branchId);
 if(!context.mounted)return;
 final lookup=TextEditingController();
 String? product=products.where((p)=>p['active']!=false).firstOrNull?['id'] as String?;
 try{
  final route=DialogRoute<String>(context:context,builder:(dialog)=>
   StatefulBuilder(builder:(dialog,refresh)=>AlertDialog(
    title:const Text('Quản lý lô và vị trí kho'),
    content:SizedBox(width:450,child:Column(mainAxisSize:MainAxisSize.min,children:[
      TextField(controller:lookup,
        decoration:InputDecoration(labelText:'Tìm sản phẩm hoặc SKU',
          suffixIcon:IconButton(icon:const Icon(Icons.search),onPressed:()async{
            try{
              final found=await client.catalogItems(token,'products',branchId:branchId,
                query:lookup.text.trim());
              if(!dialog.mounted)return;
              refresh((){
                products=found.where((x)=>x['active']!=false).toList();
                product=products.isEmpty?null:products.first['id'].toString();
              });
            }on ErpApiError catch(_){if(dialog.mounted)refresh(()=>products=[]);}
          })),
        onSubmitted:(term)async{
          try{
            final found=await client.catalogItems(token,'products',branchId:branchId,
              query:term.trim());
            if(!dialog.mounted)return;
            refresh((){
              products=found.where((x)=>x['active']!=false).toList();
              product=products.isEmpty?null:products.first['id'].toString();
            });
          }on ErpApiError catch(_){if(dialog.mounted)refresh(()=>products=[]);}
        }),
      const SizedBox(height:12),
      DropdownButtonFormField<String>(
        key:ValueKey('t3b-product-${product??"none"}'),
        isExpanded:true,initialValue:product,
        decoration:const InputDecoration(labelText:'Sản phẩm'),
        items:products.where((x)=>x['active']!=false).map((x)=>
         DropdownMenuItem<String>(value:x['id'].toString(),
          child:Text((x['code']??'').toString()+' · '+(x['name']??'').toString(),
            overflow:TextOverflow.ellipsis))).toList(),
        onChanged:(v)=>refresh(()=>product=v)),
    ])),
    actions:[TextButton(onPressed:()=>Navigator.pop(dialog),child:const Text('Đóng')),
      FilledButton(onPressed:product==null?null:()=>Navigator.pop(dialog,product),
       child:const Text('Tiếp tục'))])));
  product=await Navigator.of(context,rootNavigator:true).push(route);
  await route.completed;
 }finally{lookup.dispose();}
 if(product==null||!context.mounted)return;
 final scopes=await client.inventoryStockScopes(token,
   branchId:branchId,warehouseId:warehouseId,productId:product!);
 if(!context.mounted)return;
 final code=TextEditingController(),name=TextEditingController(),
  expiry=TextEditingController(),qty=TextEditingController();
 String mode=canManagePolicy?'location':'assign';
 String location='',lot='';
 final current=scopes['policy'];
 var requireLocation=current is Map&&current['requireLocation']==true,
  requireLot=current is Map&&current['requireLot']==true;
 String? error;
 ({String action,Map<String,dynamic> body,int revision})? selected;
 try{
  final route=DialogRoute<({String action,Map<String,dynamic> body,int revision})>(
   context:context,builder:(dialog)=>StatefulBuilder(builder:(dialog,refresh)=>AlertDialog(
    title:const Text('Thiết lập lô/vị trí'),
    content:SizedBox(width:480,child:Column(mainAxisSize:MainAxisSize.min,children:[
      DropdownButtonFormField<String>(initialValue:mode,
       decoration:const InputDecoration(labelText:'Nghiệp vụ'),
       isExpanded:true,items:[
        if(canManagePolicy)...[
          const DropdownMenuItem(value:'location',child:Text('Thêm vị trí kho')),
          const DropdownMenuItem(value:'lot',child:Text('Thêm lô sản phẩm')),
          const DropdownMenuItem(value:'tracking',child:Text('Chính sách yêu cầu lô/vị trí')),
        ],
        if(canAssign)const DropdownMenuItem(value:'assign',child:Text('Phân loại tồn có sẵn vào lô/vị trí')),
       ],onChanged:(v)=>refresh((){if(v!=null){mode=v;error=null;}})),
      const SizedBox(height:10),
      if(mode=='location')...[
        TextField(controller:code,decoration:const InputDecoration(labelText:'Mã vị trí')),
        TextField(controller:name,decoration:const InputDecoration(labelText:'Tên vị trí')),
      ],
      if(mode=='lot')...[
        TextField(controller:code,decoration:const InputDecoration(labelText:'Mã lô')),
        TextField(controller:expiry,decoration:const InputDecoration(
          labelText:'Hạn sử dụng (YYYY-MM-DD, không bắt buộc)')),
      ],
      if(mode=='tracking')...[
        CheckboxListTile(value:requireLocation,
          title:const Text('Bắt buộc chọn vị trí khi xuất'),
          onChanged:(v)=>refresh(()=>requireLocation=v??false)),
        CheckboxListTile(value:requireLot,
          title:const Text('Bắt buộc chọn lô khi xuất'),
          onChanged:(v)=>refresh(()=>requireLot=v??false)),
      ],
      if(mode=='assign')...[
        const Text('Chỉ phân loại tồn đang có. Không làm tăng số lượng tồn kho.'),
        DropdownButtonFormField<String>(initialValue:location,isExpanded:true,
         decoration:const InputDecoration(labelText:'Vị trí'),
         items:[const DropdownMenuItem(value:'',child:Text('Không chọn')),
           for(final x in (scopes['locations'] as List? ??const []))
             DropdownMenuItem(value:(x as Map)['id'].toString(),
              child:Text((x['code']??'').toString()+' · '+(x['name']??'').toString()))],
         onChanged:(v)=>refresh(()=>location=v??'')),
        DropdownButtonFormField<String>(initialValue:lot,isExpanded:true,
         decoration:const InputDecoration(labelText:'Lô'),
         items:[const DropdownMenuItem(value:'',child:Text('Không chọn')),
           for(final x in (scopes['lots'] as List? ??const []))
             DropdownMenuItem(value:(x as Map)['id'].toString(),
              child:Text((x['lotCode']??'').toString()))],
         onChanged:(v)=>refresh(()=>lot=v??'')),
        TextField(controller:qty,
          inputFormatters:const [ErpGroupedNumberFormatter(maxIntegerDigits:12,maxFractionDigits:6)],
          keyboardType:const TextInputType.numberWithOptions(decimal:true),
          decoration:const InputDecoration(labelText:'Số lượng tồn cần phân loại')),
      ],
      if(error!=null)Text(error!,style:const TextStyle(color:Colors.red)),
    ])),
    actions:[TextButton(onPressed:()=>Navigator.pop(dialog),child:const Text('Đóng')),
      FilledButton(key:const ValueKey('t3b-scope-confirm'),onPressed:(){
        final common=<String,dynamic>{
          'branchId':branchId,'warehouseId':warehouseId,'productId':product};
        late String action;
        late Map<String,dynamic> body;
        var revision=0;
        switch(mode){
          case 'location':
            if(code.text.trim().isEmpty||name.text.trim().isEmpty){
              refresh(()=>error='Cần mã và tên vị trí.');return;
            }
            action='locations';
            body={'branchId':branchId,'warehouseId':warehouseId,
             'code':code.text.trim(),'name':name.text.trim()};
          case 'lot':
            if(code.text.trim().isEmpty){
              refresh(()=>error='Cần mã lô.');return;
            }
            action='lots';
            body={...common,'lotCode':code.text.trim(),
              if(expiry.text.trim().isNotEmpty)'expiryDate':expiry.text.trim()};
          case 'tracking':
            action='tracking-policy';
            body={...common,'requireLocation':requireLocation,'requireLot':requireLot};
            revision=int.tryParse((current is Map?current['revision']:null)?.toString()??'0')??0;
          case 'assign':
            if(location.isEmpty&&lot.isEmpty){
              refresh(()=>error='Chọn ít nhất một lô hoặc vị trí.');return;
            }
            final value=erpNumberCanonical(qty.text),
              parsed=erpInventoryBaseUnits(value);
            if(parsed==null||parsed<=BigInt.zero){
              refresh(()=>error='Số lượng phải lớn hơn 0.');return;
            }
            action='stock-scopes/assign';
            body={...common,'quantityBase':erpInventoryFormatUnits(parsed),
             if(location.isNotEmpty)'locationId':location,
             if(lot.isNotEmpty)'lotId':lot};
          default:
            refresh(()=>error='Nghiệp vụ không hợp lệ.');return;
        }
        Navigator.pop(dialog,(action:action,body:body,revision:revision));
      },child:const Text('Xác nhận'))],
   )));
  selected=await Navigator.of(context,rootNavigator:true).push(route);
  await route.completed;
 }finally{
  code.dispose();name.dispose();expiry.dispose();qty.dispose();
 }
 if(selected==null||!context.mounted)return;
 await onSubmit(selected.action,selected.body,selected.revision);
}
