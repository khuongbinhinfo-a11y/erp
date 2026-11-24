import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'erp_navigation_ui.dart';
import 'erp_tokens.dart';
import 'erp_display.dart';
import 'erp_toast.dart';
import 'identity_client.dart';
import 'r1_catalog_workspace.dart';
import 'catalog_bulk_workspace.dart';
import 'price_list_assignments_panel.dart';
import 'price_sku_batch_panel.dart';
import 'customer_locations_dialog.dart';

/// Live, branch-scoped catalog. No offline confirmation and no fabricated rows.
class CatalogWorkspace extends StatefulWidget {
  final String area;
  final ErpIdentityClient client;
  final IdentitySession session;
  const CatalogWorkspace({
    super.key, required this.area, required this.client, required this.session,
  });
  @override State<CatalogWorkspace> createState()=>_CatalogWorkspaceState();
}

class _CatalogWorkspaceState extends State<CatalogWorkspace> {
  late String resource;
  List<Map<String,dynamic>> branches=[],items=[];
  String? branchId;
  bool loading=true,saving=false,productWriteReady=false;
  String? error;
  int requestSerial=0;
  final search=TextEditingController();
  final inlineAmount=TextEditingController(),inlineDiscount=TextEditingController();
  String? inlinePriceId,assignmentListId,priceSkuListId,selectedPriceListId;
  String? priceEditorMode; // Closed unless a price-list action is explicitly selected.
  final selectedProducts=<String,Map<String,dynamic>>{};

  static const tabs=<String,List<ErpSectionTab<String>>>{
    'customers':[
      ErpSectionTab('customers','Khách hàng'),
      ErpSectionTab('customer-groups','Nhóm khách'),
      ErpSectionTab('customer-regions','Khu vực'),
      ErpSectionTab('suppliers','Nhà cung cấp'),
      ErpSectionTab('bulk','Nhập Excel/CSV'),
    ],
    'products':[
      ErpSectionTab('products','Sản phẩm'),
      ErpSectionTab('groups','Nhóm hàng'),
      ErpSectionTab('brands','Nhãn hàng'),
      ErpSectionTab('categories','Danh mục'),
      ErpSectionTab('unit-definitions','Đơn vị tính'),
      ErpSectionTab('units','Đơn vị và quy đổi'),
      ErpSectionTab('skus','SKU bán hàng'),
      ErpSectionTab('barcodes','Mã vạch'),
      ErpSectionTab('bulk','Nhập Excel/CSV'),
    ],
    'price-lists':[
      ErpSectionTab('price-lists','Bảng giá'),
      ErpSectionTab('prices','Lịch sử đơn giá'),
      ErpSectionTab('channels','Kênh bán'),
      ErpSectionTab('rules','Chính sách giá'),
      ErpSectionTab('quote','Tra giá theo khách'),
      ErpSectionTab('bulk','Nhập Excel/CSV'),
    ],
    'warehouses':[
      ErpSectionTab('warehouses','Kho được cấp quyền'),
    ],
  };
  static const titles=<String,String>{
    'customers':'Khách hàng','customer-groups':'Nhóm khách',
    'customer-regions':'Khu vực','suppliers':'Nhà cung cấp',
    'products':'Sản phẩm','brands':'Nhãn hàng',
    'groups':'Nhóm hàng','categories':'Danh mục',
    'unit-definitions':'Đơn vị tính',
    'price-lists':'Bảng giá','prices':'Lịch sử đơn giá',
    'warehouses':'Kho hàng','bulk':'Nhập Excel/CSV',
  };

  static const r1Kinds={'units','skus','barcodes','channels','rules','quote'};
  bool get isR1=>r1Kinds.contains(resource);
  bool get canWrite => resource!='warehouses' &&
    (resource!='products'||productWriteReady) &&
    widget.session.grants.any(
    (g)=>g.permission=='catalog.write'&&g.branchId==branchId);
  @override void initState(){
    super.initState();resource=widget.area;_loadBranches();
  }
  @override void didUpdateWidget(covariant CatalogWorkspace oldWidget){
    super.didUpdateWidget(oldWidget);
    if(oldWidget.session.token!=widget.session.token ||
      oldWidget.client!=widget.client || oldWidget.area!=widget.area){
      requestSerial++;items=[];branches=[];branchId=null;inlinePriceId=null;assignmentListId=null;priceSkuListId=null;selectedPriceListId=null;priceEditorMode=null;
      productWriteReady=false;resource=widget.area;search.clear();selectedProducts.clear();
      _loadBranches();
    }
  }
  @override void dispose(){
    requestSerial++;search.dispose();inlineAmount.dispose();inlineDiscount.dispose();
    super.dispose();
  }
  Future<void> _loadBranches() async {
    final stamp=++requestSerial;
    setState((){loading=true;error=null;items=[];});
    try{
      final data=await widget.client.catalogItems(widget.session.token,'branches');
      if(!mounted||stamp!=requestSerial)return;
      setState((){
        branches=data;
        branchId=data.any((v)=>v['id']==branchId) ? branchId :
          (data.isEmpty?null:data.first['id'] as String);
      });
      if(branchId==null){
        setState((){loading=false;error='Tài khoản chưa được cấp quyền tại chi nhánh nào.';});
      }else{
        await _loadRecords();
      }
    }on ErpApiError catch(e){
      if(mounted&&stamp==requestSerial)setState((){
        loading=false;error=_errorMessage(e);
      });
    }catch(_){
      if(mounted&&stamp==requestSerial)setState((){
        loading=false;error='Không tải được chi nhánh.';
      });
    }
  }
  Widget _priceScopeChips(String title,String keyPrefix,
      List<Map<String,dynamic>> options,Set<String> chosen,StateSetter refresh){
    return Padding(padding:const EdgeInsets.only(top:10),child:Column(
      crossAxisAlignment:CrossAxisAlignment.start,children:[
        Text(title,style:const TextStyle(fontSize:12,
          fontWeight:FontWeight.w700,color:ErpTokens.ink)),
        const SizedBox(height:5),
        if(options.isEmpty)const Text('Chưa có danh mục áp dụng.',
          style:TextStyle(fontSize:12,color:ErpTokens.muted))
        else Wrap(spacing:5,runSpacing:3,children:[
          for(final option in options.where((x)=>x['active']!=false))
            FilterChip(
              key:ValueKey('$keyPrefix-${option['id']}'),
              label:Text((option['name']??option['code']).toString(),
                style:const TextStyle(fontSize:12)),
              selected:chosen.contains(option['id'].toString()),
              onSelected:(enabled)=>refresh((){
                if(enabled){chosen.add(option['id'].toString());}
                else{chosen.remove(option['id'].toString());}
              })),
        ]),
      ]));
  }
  String _dateLabel(DateTime? day,String none){
    if(day==null)return none;
    final local=day.toLocal();
    return '${local.day.toString().padLeft(2,'0')}/'
      '${local.month.toString().padLeft(2,'0')}/${local.year}';
  }
  DateTime? _priceListEndExclusive(DateTime? endDay){
    if(endDay==null)return null;
    final local=endDay.toLocal();
    return DateTime(local.year,local.month,local.day+1).toUtc();
  }
  Future<DateTime?> _pickPriceDay(BuildContext context,DateTime? old,
      String label)async{
    final d=await showDatePicker(context:context,
      initialDate:old?.toLocal()??DateTime.now(),
      firstDate:DateTime(2020),lastDate:DateTime(2100),
      helpText:label);
    return d==null?null:DateTime(d.year,d.month,d.day).toUtc();
  }
  String _errorMessage(ErpApiError e) => e.status==503
    ? 'Danh mục đang tạm gián đoạn. Vui lòng thử lại.'
    : e.message;

  Future<void> _loadRecords()async{
    if(isR1||resource=='bulk'){if(mounted)setState(()=>loading=false);return;}
    final currentBranch=branchId;
    if(currentBranch==null)return;
    final stamp=++requestSerial;
    setState((){loading=true;error=null;items=[];});
    try{
      final productResult=resource=='products'
        ? await widget.client.catalogProducts(widget.session.token,
            branchId:currentBranch,query:search.text)
        : null;
      final result=resource=='unit-definitions'
        ? await widget.client.catalogUnitDefinitionsAll(
            widget.session.token,branchId:currentBranch,query:search.text)
        : productResult?.items ?? await widget.client.catalogItems(
            widget.session.token,resource,branchId:currentBranch,query:search.text);
      if(!mounted||requestSerial!=stamp)return;
      setState((){
        items=result;loading=false;
        if(resource=='price-lists'){
          selectedPriceListId=result.any((x)=>x['id']==selectedPriceListId)
            ?selectedPriceListId:(result.isEmpty?null:result.first['id'].toString());
        }
        productWriteReady=resource=='products'&&productResult?.writeReady==true;
      });
    }on ErpApiError catch(e){
      if(mounted&&requestSerial==stamp)setState((){
        loading=false;error=_errorMessage(e);
      });
    }catch(_){
      if(mounted&&requestSerial==stamp)setState((){
        loading=false;error='Không tải được danh mục.';
      });
    }
  }
  void _changeResource(String next){
    if(next==resource)return;
    setState((){
      resource=next;search.clear();items=[];selectedProducts.clear();productWriteReady=false;inlinePriceId=null;assignmentListId=null;priceSkuListId=null;selectedPriceListId=null;priceEditorMode=null;
    });
    _loadRecords();
  }

  Future<void> _bulkEditProducts()async{
    if(saving||!canWrite||resource!='products'||selectedProducts.isEmpty||branchId==null)return;
    final selected=selectedProducts.values.toList();
    final groups=await widget.client.catalogDirectoryAll(widget.session.token,'groups',branchId:branchId!);
    List<Map<String,dynamic>> categories=[];
    try{
      categories=await widget.client.catalogItems(widget.session.token,
        'categories',branchId:branchId);
    }on ErpApiError catch(e){if(e.status!=503)rethrow;}
    if(!mounted)return;
    String action='active',value='true';
    String? groupId,categoryId;
    final approved=await showDialog<bool>(context:context,
      builder:(dialog)=>StatefulBuilder(builder:(ctx,refresh)=>AlertDialog(
        title:Text('Chỉnh ${selected.length} sản phẩm'),
        content:SizedBox(width:420,child:Column(mainAxisSize:MainAxisSize.min,children:[
          DropdownButtonFormField<String>(
            key:const ValueKey('catalog-product-bulk-field'),
            initialValue:action,isExpanded:true,
            decoration:const InputDecoration(labelText:'Chỉ chọn một loại thay đổi'),
            items:const [
              DropdownMenuItem(value:'active',child:Text('Trạng thái')),
              DropdownMenuItem(value:'group',child:Text('Nhóm sản phẩm')),
              DropdownMenuItem(value:'category',child:Text('Danh mục')),
            ],onChanged:(v)=>refresh((){action=v??'active';groupId=null;categoryId=null;})),
          const SizedBox(height:10),
          if(action=='active')DropdownButtonFormField<String>(
            key:const ValueKey('catalog-product-bulk-value'),
            initialValue:value,isExpanded:true,
            items:const [
              DropdownMenuItem(value:'true',child:Text('Hoạt động')),
              DropdownMenuItem(value:'false',child:Text('Ngừng sử dụng')),
            ],onChanged:(v)=>refresh(()=>value=v??'true')),
          if(action=='group')DropdownButtonFormField<String?>(
            key:const ValueKey('catalog-product-bulk-value'),
            initialValue:groupId,isExpanded:true,
            items:[
              const DropdownMenuItem<String?>(value:null,child:Text('Bỏ nhóm')),
              ...groups.where((x)=>x['active']!=false).map((x)=>DropdownMenuItem<String?>(
                value:x['id'] as String,child:Text('${x['code']} · ${x['name']}'))),
            ],onChanged:(v)=>refresh(()=>groupId=v)),
          if(action=='category')DropdownButtonFormField<String?>(
            key:const ValueKey('catalog-product-bulk-value'),
            initialValue:categoryId,isExpanded:true,
            items:[
              const DropdownMenuItem<String?>(value:null,child:Text('Bỏ danh mục')),
              ...categories.where((x)=>x['active']!=false).map((x)=>DropdownMenuItem<String?>(
                value:x['id'] as String,child:Text('${x['code']} · ${x['name']}'))),
            ],onChanged:(v)=>refresh(()=>categoryId=v)),
          const SizedBox(height:8),
          const Text('Chỉ thay một loại thuộc tính. Mã SKU và lịch sử đơn không bị sửa.',
            style:TextStyle(color:ErpTokens.muted,fontSize:12)),
        ])),
        actions:[
          TextButton(onPressed:()=>Navigator.pop(dialog,false),child:const Text('Hủy')),
          FilledButton(key:const ValueKey('catalog-product-bulk-confirm'),
            onPressed:()=>Navigator.pop(dialog,true),child:const Text('Xác nhận')),
        ],
      )));
    if(approved!=true||!mounted)return;
    setState(()=>saving=true);
    var done=0,failed=0;
    for(final product in selected){
      if(!mounted)return;
      final id=product['id'] as String;
      final kind='catalog.batch.product.$id';
      final pending=widget.client.pendingR1(widget.session.actorId,branchId!,kind);
      final body=<String,dynamic>{'branchId':branchId};
      if(action=='active')body['active']=value=='true';
      if(action=='group'){
        body['groupId']=groupId;
        if(product['categoryId']!=null)body['categoryId']=null;
      }
      if(action=='category'){
        final target=categories.where((x)=>x['id']==categoryId);
        if(target.isNotEmpty&&target.first['groupId']!=product['groupId']){
          failed++;continue;
        }
        body['categoryId']=categoryId;
      }
      final stored=pending?.payload??<String,dynamic>{
        ...body,'_erpExpectedRevision':product['revision'] as int,
      };
      final outgoing=Map<String,dynamic>.from(stored)..remove('_erpExpectedRevision');
      if(pending!=null&&outgoing.toString()!=body.toString()){
        failed++;continue; // Unresolved command must not silently change its body.
      }
      final expected=(stored['_erpExpectedRevision'] as int?)??product['revision'] as int;
      final key=pending?.key??'batch-product-${DateTime.now().microsecondsSinceEpoch}-$id';
      if(pending==null)widget.client.retainR1(widget.session.actorId,branchId!,kind,stored,key);
      try{
        await widget.client.updateCatalogWithKey(widget.session.token,'products',id,
          expected,outgoing,key:key);
        widget.client.clearR1(widget.session.actorId,branchId!,kind);
        selectedProducts.remove(id);done++;
      }on ErpApiError catch(e){
        if([400,403,404,409,422].contains(e.status)){
          widget.client.clearR1(widget.session.actorId,branchId!,kind);
          selectedProducts.remove(id); // Force reselection with a fresh revision.
        }
        failed++;
      }catch(_){failed++;}
    }
    if(!mounted)return;
    setState(()=>saving=false);
    ErpToast.show(context,'Đã sửa $done sản phẩm; $failed cần kiểm tra.',isError:failed>0);
    await _loadRecords();
  }

  Future<void> _add()async{
    if(!canWrite||saving||branchId==null)return;
    final actor=widget.session.actorId,branch=branchId!;
    final pendingKind='catalog.create.$resource';
    final previous=widget.client.pendingR1(actor,branch,pendingKind);
    final code=TextEditingController(),name=TextEditingController();
    final unit=TextEditingController();
    final phone=TextEditingController(),deliveryAddress=TextEditingController();
    final paymentTerms=TextEditingController(text:'0');
    final listPriority=TextEditingController(text:'0');
    String listStacking='EXCLUSIVE';bool listStop=false;
    DateTime? listStart,listEnd;
    final selectedChannels=<String>{},selectedGroups=<String>{},selectedCustomers=<String>{};
    bool assignDefault=false,priceScopesLoaded=false;
    List<Map<String,dynamic>> priceChannels=[],priceGroups=[],priceCustomers=[];
    final altUnit=TextEditingController(),conversion=TextEditingController();
    final baseBarcode=TextEditingController(),altSku=TextEditingController(),
      altBarcode=TextEditingController();
    final extraUnits=<({TextEditingController unit,TextEditingController factor,
      TextEditingController sku,TextEditingController barcode})>[];
    final amount=TextEditingController(),discount=TextEditingController(text:'0');
    final newGroupCode=TextEditingController(),newGroupName=TextEditingController();
    final newRegionCode=TextEditingController(),newRegionName=TextEditingController();
    final newUnitCode=TextEditingController(),newUnitName=TextEditingController();
    String? groupError,regionError,unitError;
    bool groupBusy=false,regionBusy=false,unitBusy=false,unitDictionaryReady=false;
    Uint8List? selectedImage;
    String? selectedImageType,selectedImageName;
    String? productId,priceListId,groupId,customerGroupId,customerRegionId;
    String? brandId,categoryId,parentId;
    List<Map<String,dynamic>> availableProducts=[],availableLists=[],availableGroups=[],
      availableUnits=[],availableCustomerGroups=[],availableCustomerRegions=[],
      availableBrands=[],availableCategories=[];
    ModalRoute<dynamic>? formRoute;
    Future<void> saveCustomerDirectory(String kind,StateSetter refresh)async{
      final group=kind=='customer-groups';
      final codeField=group?newGroupCode:newRegionCode;
      final nameField=group?newGroupName:newRegionName;
      final existing=group?availableCustomerGroups:availableCustomerRegions;
      if((group?groupBusy:regionBusy)||!mounted)return;
      final command='catalog.create.$kind';
      final pending=widget.client.pendingR1(actor,branch,command);
      final codeValue=codeField.text.trim().toUpperCase();
      final nameValue=nameField.text.trim();
      if(pending==null&&(codeValue.isEmpty||nameValue.isEmpty)){
        refresh((){
          if(group)groupError='Cần nhập mã và tên nhóm khách.';
          else regionError='Cần nhập mã và tên khu vực.';
        });
        return;
      }
      final body=pending?.payload??<String,dynamic>{
        'branchId':branch,'code':codeValue,'name':nameValue,
      };
      final key=pending?.key??
        'catalog-$kind-${DateTime.now().microsecondsSinceEpoch}';
      if(pending==null)widget.client.retainR1(actor,branch,command,body,key);
      refresh((){
        if(group){groupBusy=true;groupError=null;}
        else{regionBusy=true;regionError=null;}
      });
      try{
        final created=await widget.client.createCatalogWithKey(
          widget.session.token,kind,body,key:key);
        widget.client.clearR1(actor,branch,command);
        if(!mounted||formRoute?.isCurrent!=true)return;
        refresh((){
          final id=created['id'];
          if(id is String&&!existing.any((x)=>x['id']==id)){
            existing.add({'id':id,'code':body['code'],
              'name':body['name'],'active':true});
          }
          if(group){
            customerGroupId=id as String?;groupBusy=false;groupError=null;
          }else{
            customerRegionId=id as String?;regionBusy=false;regionError=null;
          }
          codeField.clear();nameField.clear();
        });
      }on ErpApiError catch(e){
        if(e.status==400||e.status==404||e.code=='DUPLICATE')
          widget.client.clearR1(actor,branch,command);
        if(mounted&&formRoute?.isCurrent==true)refresh((){
          if(group){groupBusy=false;groupError=_errorMessage(e);}
          else{regionBusy=false;regionError=_errorMessage(e);}
        });
      }catch(_){
        if(mounted&&formRoute?.isCurrent==true)refresh((){
          if(group){
            groupBusy=false;
            groupError='Chưa xác nhận. Thử lại để kiểm tra yêu cầu trước.';
          }else{
            regionBusy=false;
            regionError='Chưa xác nhận. Thử lại để kiểm tra yêu cầu trước.';
          }
        });
      }
    }

    try{
      if(resource=='price-lists'&&previous==null){
        try{
          final loaded=await Future.wait([
            widget.client.r1CatalogItems(widget.session.token,'channels',branchId:branch),
            widget.client.catalogDirectoryAll(widget.session.token,
              'customer-groups',branchId:branch),
            widget.client.catalogItems(widget.session.token,'customers',branchId:branch),
          ]);
          priceChannels=loaded[0];priceGroups=loaded[1];priceCustomers=loaded[2];
          priceScopesLoaded=true;
        }catch(_){
          priceScopesLoaded=false;
          if(mounted)ErpToast.show(context,
            'Chưa tải được kênh và nhóm khách. Có thể tạo bảng giá trước rồi phân bổ sau.',
            isError:true);
        }
      }
      if(resource=='prices'&&previous==null){
        availableProducts=await widget.client.catalogItems(widget.session.token,'products',branchId:branchId);
        availableLists=await widget.client.catalogItems(widget.session.token,'price-lists',branchId:branchId);
        if(availableProducts.isEmpty||availableLists.isEmpty){
          if(mounted)ErpToast.show(context,'Cần tạo sản phẩm và bảng giá trước khi thêm đơn giá.',isError:true);
          return;
        }
        productId=availableProducts.first['id'] as String;
        priceListId=availableLists.first['id'] as String;
      }
      if(resource=='customers'&&previous==null){
        final result=await Future.wait([
          widget.client.catalogDirectoryAll(widget.session.token,
            'customer-groups',branchId:branch),
          widget.client.catalogDirectoryAll(widget.session.token,
            'customer-regions',branchId:branch),
        ]);
        availableCustomerGroups=result[0];
        availableCustomerRegions=result[1];
      }
      if((resource=='products'||resource=='groups'||resource=='categories')&&previous==null){
        try{
          availableBrands=await widget.client.catalogDirectoryAll(
            widget.session.token,'brands',branchId:branchId);
          availableCategories=await widget.client.catalogDirectoryAll(
            widget.session.token,'categories',branchId:branchId);
        }on ErpApiError catch(e){if(e.status!=503)rethrow;}
      }
      if((resource=='products'||resource=='categories')&&previous==null){
        availableGroups=await widget.client.catalogItems(
          widget.session.token,'groups',branchId:branchId);
      }
      if(resource=='products'&&previous==null){
        availableGroups=await widget.client.catalogItems(
          widget.session.token,'groups',branchId:branchId);
        try{
          availableUnits=await widget.client.catalogUnitDefinitionsAll(
            widget.session.token,branchId:branch);
          unitDictionaryReady=true;
        }on ErpApiError catch(e){
          // Pre-0015 installations still display an explicit text UOM
          // rather than pretending the shared catalog was loaded.
          if(e.status!=503)rethrow;
        }
      }
      if(!mounted)return;
      final payload=previous?.payload ?? await showDialog<Map<String,dynamic>>(
        context:context,builder:(dialog){
          formRoute=ModalRoute.of(dialog);
          return StatefulBuilder(builder:(ctx,refresh)=>AlertDialog(
          title:Text(resource=='prices'?'Thêm phiên bản đơn giá':'Thêm ${titles[resource]!.toLowerCase()}'),
          content:SizedBox(
            width:(MediaQuery.sizeOf(dialog).width-80)
              .clamp(260.0,resource=='products'?920.0:430.0).toDouble(),
            child:SingleChildScrollView(child:Column(
            mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.stretch,children:[
              if(resource=='prices')...[
                DropdownButtonFormField<String>(
                  key:const ValueKey('catalog-price-list-select'),
                  initialValue:priceListId,isExpanded:true,
                  decoration:const InputDecoration(labelText:'Bảng giá'),
                  items:availableLists.map((x)=>DropdownMenuItem<String>(
                    value:x['id'] as String,child:Text(x['name'] as String,
                      overflow:TextOverflow.ellipsis))).toList(),
                  onChanged:(v)=>refresh(()=>priceListId=v)),
                const SizedBox(height:12),
                DropdownButtonFormField<String>(
                  initialValue:productId,isExpanded:true,
                  decoration:const InputDecoration(labelText:'Sản phẩm'),
                  items:availableProducts.map((x)=>DropdownMenuItem<String>(
                    value:x['id'] as String,child:Text(x['name'] as String,
                      overflow:TextOverflow.ellipsis))).toList(),
                  onChanged:(v)=>refresh(()=>productId=v)),
                const SizedBox(height:12),
                TextField(controller:amount,keyboardType:TextInputType.number,
                  decoration:const InputDecoration(labelText:'Đơn giá (₫)',
                    hintText:'12500.0000')),
                const SizedBox(height:12),
                TextField(controller:discount,keyboardType:TextInputType.number,
                  decoration:const InputDecoration(labelText:'Chiết khấu (%)',hintText:'0')),
                const SizedBox(height:12),
                const Text('Đơn giá có hiệu lực theo ngày áp dụng. Lịch sử giá được giữ lại.',
                  style:TextStyle(color:ErpTokens.muted,fontSize:12)),
              ]else...[
                TextField(key:const ValueKey('catalog-create-code'),
                  controller:code,decoration:InputDecoration(
                    labelText:resource=='products'?'Mã hàng / SKU gốc':'Mã',
                    hintText:resource=='products'?'SKU-001':'MA-001')),
                const SizedBox(height:12),
                TextField(key:const ValueKey('catalog-create-name'),
                  controller:name,maxLength:resource=='unit-definitions'?80:160,
                  decoration:const InputDecoration(labelText:'Tên')),
                if(resource=='price-lists')...[
                  const SizedBox(height:12),
                  TextField(controller:listPriority,
                    key:const ValueKey('r1c-create-list-priority'),
                    keyboardType:TextInputType.number,
                    onChanged:(_)=>refresh((){}),
                    decoration:const InputDecoration(labelText:'Mức ưu tiên bảng giá',
                      helperText:'Số lớn được ưu tiên trong cùng phạm vi')),
                  const SizedBox(height:8),
                  DropdownButtonFormField<String>(
                    key:const ValueKey('price-create-stacking'),
                    initialValue:listStacking,isExpanded:true,
                    decoration:const InputDecoration(labelText:'Cách kết hợp giá'),
                    items:const [
                      DropdownMenuItem(value:'EXCLUSIVE',
                        child:Text('Độc lập: dùng mức giá này')),
                      DropdownMenuItem(value:'STACKABLE',
                        child:Text('Cộng dồn chính sách phù hợp')),
                    ],
                    onChanged:(v){if(v!=null)refresh(()=>listStacking=v);}),
                  SwitchListTile(
                    key:const ValueKey('price-create-stop'),
                    contentPadding:EdgeInsets.zero,
                    title:const Text('Ngừng xét bảng giá tiếp theo'),
                    value:listStop,onChanged:(v)=>refresh(()=>listStop=v)),
                  const SizedBox(height:8),
                  Wrap(spacing:8,runSpacing:6,children:[
                    OutlinedButton.icon(
                      key:const ValueKey('r1c-create-list-from'),
                      onPressed:()async{
                        final picked=await _pickPriceDay(ctx,listStart,'Có hiệu lực từ');
                        if(picked!=null&&ctx.mounted)refresh(()=>listStart=picked);
                      },icon:const Icon(Icons.event,size:16),
                      label:Text(_dateLabel(listStart,'Bắt đầu ngay'))),
                    if(listStart!=null)IconButton(
                      tooltip:'Không đặt ngày bắt đầu',
                      onPressed:()=>refresh(()=>listStart=null),
                      icon:const Icon(Icons.close,size:16)),
                    OutlinedButton.icon(
                      key:const ValueKey('r1c-create-list-to'),
                      onPressed:()async{
                        final picked=await _pickPriceDay(ctx,listEnd,'Đến hết ngày');
                        if(picked!=null&&ctx.mounted)refresh(()=>listEnd=picked);
                      },icon:const Icon(Icons.event_busy,size:16),
                      label:Text(_dateLabel(listEnd,'Không giới hạn'))),
                    if(listEnd!=null)IconButton(
                      tooltip:'Không đặt ngày kết thúc',
                      onPressed:()=>refresh(()=>listEnd=null),
                      icon:const Icon(Icons.close,size:16)),
                  ]),
                  if(priceScopesLoaded)...[
                    const SizedBox(height:10),
                    SwitchListTile(
                      key:const ValueKey('price-create-default'),
                      contentPadding:EdgeInsets.zero,
                      title:const Text('Áp dụng mặc định'),
                      value:assignDefault,
                      onChanged:(v)=>refresh(()=>assignDefault=v)),
                    _priceScopeChips('Kênh bán','price-create-channel',
                      priceChannels,selectedChannels,refresh),
                    _priceScopeChips('Nhóm khách','price-create-group',
                      priceGroups,selectedGroups,refresh),
                    _priceScopeChips('Khách hàng riêng','price-create-customer',
                      priceCustomers,selectedCustomers,refresh),
                    const Padding(padding:EdgeInsets.only(top:8),
                      child:Text('Khi chọn cả kênh bán và nhóm khách: áp dụng theo KÊNH VÀ NHÓM.',
                        style:TextStyle(fontSize:12,color:ErpTokens.muted))),
                  ],
                ],
                if(resource=='customers')...[
                  const SizedBox(height:12),
                  DropdownButtonFormField<String?>(
                    key:ValueKey('catalog-create-customer-group-$customerGroupId'),
                    initialValue:customerGroupId,isExpanded:true,
                    decoration:const InputDecoration(
                      labelText:'Nhóm khách hàng',
                      helperText:'Chọn mã danh mục; tạo nhóm mới ở tab Nhóm khách'),
                    items:[
                      const DropdownMenuItem<String?>(
                        value:null,child:Text('Chưa phân nhóm')),
                      ...availableCustomerGroups.where((x)=>x['active']!=false)
                        .map((x)=>DropdownMenuItem<String?>(
                          value:x['id'] as String,
                          child:Text("${x['code']} · ${x['name']}",
                            overflow:TextOverflow.ellipsis))),
                    ],
                    onChanged:(v)=>refresh(()=>customerGroupId=v)),
                  const SizedBox(height:8),
                  const Text('Tạo nhanh nhóm khách hàng (danh mục dùng chung)',
                    style:TextStyle(color:ErpTokens.muted,fontSize:12)),
                  const SizedBox(height:8),
                  Wrap(spacing:8,runSpacing:8,
                    crossAxisAlignment:WrapCrossAlignment.center,children:[
                    SizedBox(width:126,child:TextField(
                      key:const ValueKey('catalog-quick-customer-group-code'),
                      controller:newGroupCode,enabled:!groupBusy,
                      decoration:const InputDecoration(labelText:'Mã nhóm'))),
                    SizedBox(width:180,child:TextField(
                      key:const ValueKey('catalog-quick-customer-group-name'),
                      controller:newGroupName,enabled:!groupBusy,
                      decoration:const InputDecoration(labelText:'Tên nhóm'))),
                    TextButton.icon(
                      key:const ValueKey('catalog-quick-customer-group-save'),
                      onPressed:groupBusy?null:()=>
                        saveCustomerDirectory('customer-groups',refresh),
                      icon:const Icon(Icons.add),label:const Text('Tạo nhóm')),
                  ]),
                  if(groupError!=null)Text(groupError!,
                    style:const TextStyle(color:ErpTokens.danger,fontSize:12)),
                  const SizedBox(height:12),
                  DropdownButtonFormField<String?>(
                    key:ValueKey('catalog-create-customer-region-$customerRegionId'),
                    initialValue:customerRegionId,isExpanded:true,
                    decoration:const InputDecoration(
                      labelText:'Khu vực bán hàng',
                      helperText:'Khác địa chỉ hành chính; tạo mã ở tab Khu vực'),
                    items:[
                      const DropdownMenuItem<String?>(
                        value:null,child:Text('Chưa phân khu vực')),
                      ...availableCustomerRegions.where((x)=>x['active']!=false)
                        .map((x)=>DropdownMenuItem<String?>(
                          value:x['id'] as String,
                          child:Text("${x['code']} · ${x['name']}",
                            overflow:TextOverflow.ellipsis))),
                    ],
                    onChanged:(v)=>refresh(()=>customerRegionId=v)),
                  const SizedBox(height:8),
                  const Text('Tạo nhanh khu vực bán hàng',
                    style:TextStyle(color:ErpTokens.muted,fontSize:12)),
                  const SizedBox(height:8),
                  Wrap(spacing:8,runSpacing:8,
                    crossAxisAlignment:WrapCrossAlignment.center,children:[
                    SizedBox(width:126,child:TextField(
                      key:const ValueKey('catalog-quick-customer-region-code'),
                      controller:newRegionCode,enabled:!regionBusy,
                      decoration:const InputDecoration(labelText:'Mã khu vực'))),
                    SizedBox(width:180,child:TextField(
                      key:const ValueKey('catalog-quick-customer-region-name'),
                      controller:newRegionName,enabled:!regionBusy,
                      decoration:const InputDecoration(labelText:'Tên khu vực'))),
                    TextButton.icon(
                      key:const ValueKey('catalog-quick-customer-region-save'),
                      onPressed:regionBusy?null:()=>
                        saveCustomerDirectory('customer-regions',refresh),
                      icon:const Icon(Icons.add),label:const Text('Tạo khu vực')),
                  ]),
                  if(regionError!=null)Text(regionError!,
                    style:const TextStyle(color:ErpTokens.danger,fontSize:12)),
                  const SizedBox(height:12),
                  TextField(controller:phone,
                    keyboardType:TextInputType.phone,
                    decoration:const InputDecoration(labelText:'Số điện thoại',hintText:'+849xxxxxxxx')),
                  const SizedBox(height:12),
                  TextField(controller:deliveryAddress,maxLines:2,
                    decoration:const InputDecoration(labelText:'Địa chỉ giao hàng')),
                  const SizedBox(height:12),
                  TextField(controller:paymentTerms,
                    keyboardType:TextInputType.number,
                    decoration:const InputDecoration(labelText:'Số ngày thanh toán')),
                ],
                if(resource=='groups')...[
                  const SizedBox(height:10),
                  DropdownButtonFormField<String?>(
                    key:const ValueKey('catalog-group-brand'),
                    initialValue:brandId,isExpanded:true,
                    decoration:const InputDecoration(labelText:'Nhãn hàng'),
                    items:[
                      const DropdownMenuItem<String?>(value:null,child:Text('Chưa gắn nhãn hàng')),
                      ...availableBrands.where((b)=>b['active']!=false).map(
                        (b)=>DropdownMenuItem<String?>(value:b['id'] as String,
                          child:Text('${b['code']} · ${b['name']}'))),
                    ],
                    onChanged:(v)=>refresh(()=>brandId=v)),
                ],
                if(resource=='categories')...[
                  const SizedBox(height:10),
                  DropdownButtonFormField<String?>(
                    key:const ValueKey('catalog-category-group'),
                    initialValue:groupId,isExpanded:true,
                    decoration:const InputDecoration(labelText:'Nhóm sản phẩm *'),
                    items:availableGroups.where((g)=>g['active']!=false).map(
                      (g)=>DropdownMenuItem<String?>(
                        value:g['id'] as String,child:Text('${g['code']} · ${g['name']}'))).toList(),
                    onChanged:(v)=>refresh((){groupId=v;parentId=null;code.clear();})),
                  const SizedBox(height:10),
                  DropdownButtonFormField<String?>(
                    key:ValueKey('catalog-category-parent-$groupId'),
                    initialValue:parentId,isExpanded:true,
                    decoration:const InputDecoration(labelText:'Danh mục cha'),
                    items:[
                      const DropdownMenuItem<String?>(value:null,child:Text('Danh mục cấp đầu')),
                      ...availableCategories.where((c)=>c['groupId']==groupId&&
                        c['active']!=false).map((c)=>DropdownMenuItem<String?>(
                          value:c['id'] as String,child:Text('${c['code']} · ${c['name']}'))),
                    ],
                    onChanged:(v)=>refresh((){
                      parentId=v;
                      final parent=availableCategories.where((c)=>c['id']==v);
                      if(parent.isNotEmpty)code.text=parent.first['code'].toString();
                    })),
                  const SizedBox(height:6),
                  const Text('Tạo danh mục con: chọn danh mục cha rồi thêm ký tự vào cuối mã gợi ý.',
                    style:TextStyle(fontSize:12,color:ErpTokens.muted)),
                ],
                if(resource=='products')...[
                  const SizedBox(height:18),
                  const Text('1. Thông tin sản phẩm',style:TextStyle(
                    fontWeight:FontWeight.w800,fontSize:16,color:ErpTokens.primary)),
                  const SizedBox(height:6),
                  const Text('Mã hàng là mã của sản phẩm. SKU bán và mã vạch đặt riêng ở phần quy cách.',
                    style:TextStyle(color:ErpTokens.muted,fontSize:12)),
                  const SizedBox(height:12),
                  if(availableUnits.isEmpty)
                    TextField(key:const ValueKey('catalog-base-unit-raw'),
                      controller:unit,
                      decoration:const InputDecoration(
                        labelText:'Mã đơn vị tồn kho gốc *',
                        hintText:'CHAI (chưa có danh mục ĐVT)'))
                  else DropdownButtonFormField<String>(
                    key:ValueKey('catalog-base-unit-${unit.text}'),
                    initialValue:availableUnits.any((x)=>x['code']==unit.text)
                      ?unit.text:null,
                    isExpanded:true,
                    decoration:const InputDecoration(
                      labelText:'Đơn vị tồn kho gốc *',
                      helperText:'Chọn theo mã và tên đơn vị tính dùng chung'),
                    items:availableUnits.where((x)=>x['active']==true)
                      .map((x)=>DropdownMenuItem<String>(
                        value:x['code'] as String,
                        child:Text("${x['name']} · ${x['code']}",
                          overflow:TextOverflow.ellipsis))).toList(),
                    onChanged:(value)=>refresh(()=>unit.text=value??'')),
                  const SizedBox(height:8),
                  Text(unitDictionaryReady
                    ? 'Thêm đơn vị tính mới (mã và tên dùng chung)'
                    : 'Danh mục ĐVT chưa sẵn sàng trên server; cần migration 0015.',
                    style:const TextStyle(fontSize:12,
                      fontWeight:FontWeight.w700)),
                  const SizedBox(height:8),
                  Wrap(spacing:8,runSpacing:8,children:[
                    SizedBox(width:160,child:TextField(
                      key:const ValueKey('catalog-quick-unit-code'),
                      controller:newUnitCode,enabled:unitDictionaryReady&&!unitBusy,
                      decoration:const InputDecoration(labelText:'Mã ĐVT',hintText:'CHAI'))),
                    SizedBox(width:210,child:TextField(
                      key:const ValueKey('catalog-quick-unit-name'),
                      controller:newUnitName,enabled:unitDictionaryReady&&!unitBusy,
                      decoration:const InputDecoration(labelText:'Tên đơn vị',hintText:'Chai'))),
                    TextButton.icon(
                      key:const ValueKey('catalog-quick-unit-save'),
                      onPressed:unitBusy||!unitDictionaryReady?null:()async{
                        final kind='catalog.create.unit-definitions';
                        final old=widget.client.pendingR1(actor,branch,kind);
                        final codeText=newUnitCode.text.trim().toUpperCase();
                        final nameText=newUnitName.text.trim();
                        if(old==null&&(codeText.isEmpty||nameText.isEmpty)){
                          refresh(()=>unitError='Nhập mã và tên đơn vị tính.');
                          return;
                        }
                        final body=old?.payload??<String,dynamic>{
                          'branchId':branch,'code':codeText,'name':nameText,
                        };
                        final key=old?.key??
                          'catalog-uom-${DateTime.now().microsecondsSinceEpoch}';
                        if(old==null)widget.client.retainR1(actor,branch,kind,body,key);
                        refresh((){unitBusy=true;unitError=null;});
                        try{
                          final created=await widget.client.createCatalogWithKey(
                            widget.session.token,'unit-definitions',body,key:key);
                          if(!ctx.mounted)return;
                          widget.client.clearR1(actor,branch,kind);
                          refresh((){
                            final savedCode=created['code'] as String;
                            if(!availableUnits.any((x)=>x['code']==savedCode)){
                              availableUnits.add({
                                'id':created['id'],'code':savedCode,
                                'name':body['name'],'active':true,
                              });
                            }
                            unit.text=savedCode;
                            unitBusy=false;newUnitCode.clear();newUnitName.clear();
                          });
                        }on ErpApiError catch(e){
                          if(!ctx.mounted)return;
                          if(e.status==400||e.status==404||e.code=='DUPLICATE'){
                            widget.client.clearR1(actor,branch,kind);
                          }
                          refresh((){
                            unitBusy=false;
                            unitError=e.code=='DUPLICATE'
                              ?'Mã ĐVT đã tồn tại. Chọn từ danh mục hoặc đổi mã.'
                              :e.message;
                          });
                        }catch(_){
                          if(ctx.mounted)refresh((){
                            unitBusy=false;
                            unitError='Chưa xác nhận tạo ĐVT. Nhấn lại để kiểm tra.';
                          });
                        }
                      },
                      icon:const Icon(Icons.add),label:const Text('Lưu đơn vị')),
                  ]),
                  if(unitError!=null)
                    Text(unitError!,style:const TextStyle(color:ErpTokens.danger)),
                  const SizedBox(height:12),
                  TextField(key:const ValueKey('catalog-base-barcode'),
                    controller:baseBarcode,
                    decoration:const InputDecoration(labelText:'Mã vạch SKU gốc (nếu có)',
                      hintText:'893...')),
                  const SizedBox(height:16),
                  const Text('2. Nhóm hàng',style:TextStyle(
                    fontWeight:FontWeight.w800,fontSize:16,color:ErpTokens.primary)),
                  const SizedBox(height:4),
                  const Text('Chọn nhãn hàng rồi nhóm/danh mục; mọi trường lưu vào một sản phẩm.',
                    style:TextStyle(color:ErpTokens.muted,fontSize:12)),
                  if(availableBrands.isNotEmpty)...[
                    const SizedBox(height:10),
                    DropdownButtonFormField<String?>(
                      key:const ValueKey('catalog-product-brand'),
                      initialValue:brandId,isExpanded:true,
                      decoration:const InputDecoration(labelText:'Nhãn hàng'),
                      items:[
                        const DropdownMenuItem<String?>(value:null,child:Text('Tất cả nhãn hàng')),
                        ...availableBrands.where((b)=>b['active']!=false).map(
                          (b)=>DropdownMenuItem<String?>(
                            value:b['id'] as String,
                            child:Text('${b['code']} · ${b['name']}'))),
                      ],
                      onChanged:(v)=>refresh((){brandId=v;groupId=null;categoryId=null;})),
                  ],
                  if(availableGroups.isNotEmpty)...[
                    const SizedBox(height:12),
                    DropdownButtonFormField<String?>(
                      key:ValueKey('catalog-product-group-$groupId'),
                      initialValue:groupId,isExpanded:true,
                      decoration:const InputDecoration(labelText:'Nhóm hàng (tùy chọn)'),
                      items:[
                        const DropdownMenuItem<String?>(value:null,child:Text('Chưa phân nhóm')),
                        ...availableGroups.where((g)=>brandId==null||
                          g['brandId']==brandId).map((g)=>DropdownMenuItem<String?>(
                          value:g['id'] as String,
                          child:Text(g['name'].toString(),overflow:TextOverflow.ellipsis))),
                      ],
                      onChanged:(v)=>refresh((){groupId=v;categoryId=null;})),
                  ],
                  const SizedBox(height:10),
                  DropdownButtonFormField<String?>(
                    key:ValueKey('catalog-product-category-$groupId'),
                    initialValue:categoryId,isExpanded:true,
                    decoration:const InputDecoration(labelText:'Danh mục sản phẩm'),
                    items:[
                      const DropdownMenuItem<String?>(value:null,child:Text('Chưa chọn danh mục')),
                      ...availableCategories.where((c)=>c['groupId']==groupId&&
                        c['active']!=false).map((c)=>DropdownMenuItem<String?>(
                          value:c['id'] as String,child:Text('${c['code']} · ${c['name']}'))),
                    ],
                    onChanged:(v)=>refresh(()=>categoryId=v)),
                  const SizedBox(height:6),
                  Wrap(spacing:8,runSpacing:8,children:[
                    SizedBox(width:160,child:TextField(
                      key:const ValueKey('catalog-quick-group-code'),
                      controller:newGroupCode,enabled:!groupBusy,
                      decoration:const InputDecoration(labelText:'Mã nhóm'))),
                    SizedBox(width:260,child:TextField(
                      key:const ValueKey('catalog-quick-group-name'),
                      controller:newGroupName,enabled:!groupBusy,
                      decoration:const InputDecoration(labelText:'Tên nhóm'))),
                    TextButton.icon(
                      key:const ValueKey('catalog-quick-group-save'),
                      onPressed:groupBusy?null:()async{
                        final kind='catalog.create.groups';
                        final old=widget.client.pendingR1(actor,branch,kind);
                        final groupCode=newGroupCode.text.trim();
                        final groupName=newGroupName.text.trim();
                        if(old==null&&(groupCode.isEmpty||groupName.isEmpty)){
                          refresh(()=>groupError='Cần nhập mã và tên nhóm hàng.');
                          return;
                        }
                        final body=old?.payload??<String,dynamic>{
                          'branchId':branch,'code':groupCode,'name':groupName,
                          if(brandId!=null)'brandId':brandId,
                        };
                        final key=old?.key??
                          'catalog-groups-${DateTime.now().microsecondsSinceEpoch}';
                        if(old==null)widget.client.retainR1(actor,branch,kind,body,key);
                        refresh((){groupBusy=true;groupError=null;});
                        try{
                          final created=await widget.client.createCatalogWithKey(
                            widget.session.token,'groups',body,key:key);
                          if(!ctx.mounted)return;
                          widget.client.clearR1(actor,branch,kind);
                          refresh((){
                            // After a lost ACK, re-opening this form can load the
                            // committed group before the original command replays.
                            // Reuse that row; dropdown values must stay unique.
                            final savedId=created['id'] as String;
                            if(!availableGroups.any((g)=>g['id']==savedId)){
                              availableGroups.add({
                                'id':savedId,'code':body['code'],'name':body['name'],
                              });
                            }
                            groupId=savedId;
                            groupBusy=false;newGroupCode.clear();newGroupName.clear();
                          });
                        }on ErpApiError catch(e){
                          if(!ctx.mounted)return;
                          if(e.status==400||e.status==404||e.code=='DUPLICATE'){
                            widget.client.clearR1(actor,branch,kind);
                          }
                          refresh((){
                            groupBusy=false;
                            groupError=e.code=='DUPLICATE'
                              ?'Mã nhóm đã có. Sửa mã rồi thử lại.'
                              :e.message;
                          });
                        }catch(_){
                          if(ctx.mounted)refresh((){
                            groupBusy=false;
                            groupError='Chưa có xác nhận tạo nhóm. Nhấn lại để kiểm tra.';
                          });
                        }
                      },
                      icon:const Icon(Icons.add),
                      label:const Text('Lưu nhóm')),
                  ]),
                  if(groupError!=null)Padding(
                    padding:const EdgeInsets.only(top:6),
                    child:Text(groupError!,
                      style:const TextStyle(color:ErpTokens.danger))),

                  const SizedBox(height:18),
                  const Divider(),
                  const SizedBox(height:12),
                  const Text('3. SKU, đơn vị quy đổi và mã vạch',
                    style:TextStyle(fontWeight:FontWeight.w800,fontSize:16,
                      color:ErpTokens.primary)),
                  const SizedBox(height:4),
                  const Text('Ví dụ: 1 THUNG = 24 CHAI. Mã đơn vị THUNG khác mã SKU bán SP001-THUNG và khác mã vạch.',
                    style:TextStyle(fontSize:12,color:ErpTokens.muted)),
                  const SizedBox(height:9),
                  Wrap(spacing:10,runSpacing:10,children:[
                    SizedBox(width:210,child:availableUnits.isEmpty
                      ?TextField(key:const ValueKey('catalog-conversion-unit-0'),
                        controller:altUnit,
                        decoration:const InputDecoration(
                          labelText:'Mã đơn vị quy đổi',hintText:'THUNG'))
                      :DropdownButtonFormField<String>(
                        key:const ValueKey('catalog-conversion-unit-0'),
                        initialValue:availableUnits.any((x)=>x['code']==altUnit.text)
                          ?altUnit.text:null,
                        isExpanded:true,
                        decoration:const InputDecoration(labelText:'Đơn vị quy đổi'),
                        items:availableUnits.where((x)=>x['active']==true)
                          .map((x)=>DropdownMenuItem<String>(
                            value:x['code'] as String,
                            child:Text("${x['name']} · ${x['code']}",
                              overflow:TextOverflow.ellipsis))).toList(),
                        onChanged:(value)=>refresh(()=>altUnit.text=value??''))),
                    SizedBox(width:145,child:TextField(
                      key:const ValueKey('catalog-conversion-factor-0'),
                      controller:conversion,keyboardType:TextInputType.number,
                      decoration:const InputDecoration(labelText:'Số đơn vị gốc',hintText:'24'))),
                    SizedBox(width:210,child:TextField(
                      key:const ValueKey('catalog-conversion-sku-0'),
                      controller:altSku,
                      decoration:const InputDecoration(labelText:'Mã SKU bán',hintText:'SP-THUNG'))),
                    SizedBox(width:145,child:TextField(
                      key:const ValueKey('catalog-conversion-barcode-0'),
                      controller:altBarcode,
                      decoration:const InputDecoration(labelText:'Mã vạch',hintText:'893...'))),
                    for(var idx=0;idx<extraUnits.length;idx++)...[
                      SizedBox(width:(MediaQuery.sizeOf(ctx).width-80)
                        .clamp(220.0,580.0).toDouble(),child:const Divider()),
                      SizedBox(width:210,child:availableUnits.isEmpty
                        ?TextField(key:ValueKey('catalog-conversion-unit-${idx+1}'),
                          controller:extraUnits[idx].unit,
                          decoration:InputDecoration(labelText:'Mã đơn vị quy đổi ${idx+2}'))
                        :DropdownButtonFormField<String>(
                          key:ValueKey('catalog-conversion-unit-${idx+1}'),
                          initialValue:availableUnits.any(
                            (x)=>x['code']==extraUnits[idx].unit.text)
                            ?extraUnits[idx].unit.text:null,
                          isExpanded:true,
                          decoration:InputDecoration(labelText:'Đơn vị quy đổi ${idx+2}'),
                          items:availableUnits.where((x)=>x['active']==true)
                            .map((x)=>DropdownMenuItem<String>(
                              value:x['code'] as String,
                              child:Text("${x['name']} · ${x['code']}",
                                overflow:TextOverflow.ellipsis))).toList(),
                          onChanged:(value)=>refresh(
                            ()=>extraUnits[idx].unit.text=value??''))),
                      SizedBox(width:145,child:TextField(
                        key:ValueKey('catalog-conversion-factor-${idx+1}'),
                        controller:extraUnits[idx].factor,
                        keyboardType:TextInputType.number,
                        decoration:const InputDecoration(labelText:'Số đơn vị gốc'))),
                      SizedBox(width:210,child:TextField(
                        key:ValueKey('catalog-conversion-sku-${idx+1}'),
                        controller:extraUnits[idx].sku,
                        decoration:const InputDecoration(labelText:'Mã SKU bán'))),
                      SizedBox(width:145,child:TextField(
                        key:ValueKey('catalog-conversion-barcode-${idx+1}'),
                        controller:extraUnits[idx].barcode,
                        decoration:const InputDecoration(labelText:'Mã vạch'))),
                    ],
                  ]),
                  const SizedBox(height:9),
                  TextButton.icon(
                    key:const ValueKey('catalog-add-unit-row'),
                    onPressed:extraUnits.length>=11?null:()=>refresh((){
                      extraUnits.add((unit:TextEditingController(),
                        factor:TextEditingController(),sku:TextEditingController(),
                        barcode:TextEditingController()));
                    }),
                    icon:const Icon(Icons.add),
                    label:const Text('Thêm quy cách bán')),
                  const SizedBox(height:18),
                  const Divider(),
                  const SizedBox(height:12),
                  const Text('4. Ảnh sản phẩm',style:TextStyle(
                    fontWeight:FontWeight.w800,fontSize:16,color:ErpTokens.primary)),
                  const SizedBox(height:5),
                  const Text('Chọn ảnh để gửi vào kho R2 riêng sau khi sản phẩm được tạo. '
                    'Tối đa 5 MB, PNG/JPG/WebP. Ảnh không được công khai.',
                    style:TextStyle(color:ErpTokens.muted,fontSize:12)),
                  const SizedBox(height:9),
                  Wrap(spacing:12,runSpacing:12,crossAxisAlignment:WrapCrossAlignment.center,
                    children:[
                    OutlinedButton.icon(
                      key:const ValueKey('catalog-product-pick-image'),
                      icon:const Icon(Icons.add_photo_alternate_outlined),
                      label:Text(selectedImageName??'Chọn ảnh sản phẩm'),
                      onPressed:()async{
                        try{
                          final file=await FilePicker.platform.pickFiles(
                            type:FileType.custom,
                            allowedExtensions:['png','jpg','jpeg','webp'],
                            withData:true);
                          if(file==null||file.files.isEmpty)return;
                          final first=file.files.first;
                          final ext=first.extension?.toLowerCase();
                          final mime=ext=='png'?'image/png':
                            ext=='webp'?'image/webp':
                            ext=='jpg'||ext=='jpeg'?'image/jpeg':null;
                          if(mime==null||first.bytes==null||
                            first.bytes!.isEmpty||first.bytes!.length>5242880){
                            refresh(()=>unitError='Ảnh phải là PNG/JPG/WebP và dưới 5 MB.');
                            return;
                          }
                          if(ctx.mounted)refresh((){
                            selectedImage=first.bytes;
                            selectedImageName=first.name;
                            selectedImageType=mime;
                          });
                        }catch(_){
                          if(ctx.mounted)refresh(
                            ()=>unitError='Không mở được ảnh từ thiết bị.');
                        }
                      }),
                    if(selectedImage!=null)ClipRRect(
                      borderRadius:BorderRadius.circular(8),
                      child:Image.memory(selectedImage!,height:90,width:90,
                        fit:BoxFit.cover)),
                  ]),
                ],
              ],
            ]))),
          actions:[
            TextButton(onPressed:()=>Navigator.pop(dialog),child:const Text('Hủy')),
            FilledButton(
              key:const ValueKey('catalog-create-confirm'),
              onPressed:groupBusy||regionBusy||unitBusy||
                resource=='customers'&&(
                  widget.client.pendingR1(actor,branch,'catalog.create.customer-groups')!=null||
                  widget.client.pendingR1(actor,branch,'catalog.create.customer-regions')!=null)||
                resource=='products'&&(
                  widget.client.pendingR1(actor,branch,'catalog.create.groups')!=null||
                  widget.client.pendingR1(actor,branch,'catalog.create.unit-definitions')!=null)||
                resource=='price-lists'&&(
                  int.tryParse(listPriority.text.trim())==null||
                  (int.tryParse(listPriority.text.trim())??0).abs()>100000||
                  (listStart!=null&&listEnd!=null&&listEnd!.isBefore(listStart!)))
                ?null:(){
                final body=<String,dynamic>{'branchId':branchId};
                if(resource=='prices'){
                  body.addAll({
                    'priceListId':priceListId,
                    'productId':productId,
                    'amount':amount.text.trim(),
                    'discountRate':discount.text.trim(),
                    'effectiveAt':DateTime.now().toUtc().toIso8601String(),
                  });
                }else{
                  body.addAll({'code':code.text.trim(),'name':name.text.trim()});
                  if(resource=='price-lists'){
                    body.addAll({
                      'effectiveFrom':listStart?.toIso8601String(),
                      'effectiveTo':_priceListEndExclusive(listEnd)?.toIso8601String(),
                      'priority':int.parse(listPriority.text.trim()),
                      'stackingMode':listStacking,'stopProcessing':listStop,
                      if(priceScopesLoaded)...{
                        'channelIds':selectedChannels.toList(),
                        'customerGroupIds':selectedGroups.toList(),
                        'customerIds':selectedCustomers.toList(),
                        'defaultAssignment':assignDefault,
                      },
                    });
                  }
                  if(resource=='groups')body['brandId']=brandId;
                  if(resource=='categories'){
                    body['groupId']=groupId;body['parentId']=parentId;
                  }
                  if(resource=='customers'){
                    body.addAll({
                      'customerGroupId':customerGroupId,
                      'customerRegionId':customerRegionId,
                      'phone':phone.text.trim().isEmpty?null:phone.text.trim(),
                      'deliveryAddress':deliveryAddress.text.trim().isEmpty
                        ?null:deliveryAddress.text.trim(),
                      'paymentTermsDays':int.tryParse(paymentTerms.text.trim())??-1,
                    });
                  }
                  if(resource=='products'){
                    final firstUnit=<String,String>{
                      'unitCode':altUnit.text.trim(),'toBase':conversion.text.trim(),
                      if(altSku.text.trim().isNotEmpty)'sku':altSku.text.trim(),
                      if(altBarcode.text.trim().isNotEmpty)'barcode':altBarcode.text.trim(),
                    };
                    final rows=<Map<String,String>>[
                      if(firstUnit.values.any((v)=>v.isNotEmpty))firstUnit,
                      for(final extra in extraUnits)
                        if([extra.unit.text,extra.factor.text,extra.sku.text,
                          extra.barcode.text].any((v)=>v.trim().isNotEmpty))
                          {
                            'unitCode':extra.unit.text.trim(),
                            'toBase':extra.factor.text.trim(),
                            if(extra.sku.text.trim().isNotEmpty)
                              'sku':extra.sku.text.trim(),
                            if(extra.barcode.text.trim().isNotEmpty)
                              'barcode':extra.barcode.text.trim(),
                          },
                    ];
                    body.addAll({'baseUnit':unit.text.trim(),'groupId':groupId,'categoryId':categoryId,
                      if(baseBarcode.text.trim().isNotEmpty)
                        'barcode':baseBarcode.text.trim(),
                      'units':rows});
                  }
                }
                Navigator.pop(dialog,body);
              },
              child:Text(resource=='products'?'Lưu sản phẩm và SKU':'Lưu trên server')),
          ],
        ));});
      if(payload==null||!mounted)return;
      final key=previous?.key ??
        'catalog-$resource-${DateTime.now().microsecondsSinceEpoch}';
      if(previous==null)widget.client.retainR1(
        actor,branch,pendingKind,payload,key);
      setState(()=>saving=true);
      try{
        final created=await widget.client.createCatalogWithKey(
          widget.session.token,resource,payload,key:key);
        widget.client.clearR1(actor,branch,pendingKind);
        if(!mounted)return;
        ErpToast.show(context,'Đã lưu ${titles[resource]!.toLowerCase()} sau xác nhận server.');
        await _loadRecords();
        if(resource=='products'&&selectedImage!=null&&selectedImageType!=null){
          try{
            await widget.client.uploadProductPhoto(
              widget.session.token,actor,branch,
              created['id'] as String,selectedImage!,selectedImageType!);
            if(mounted)ErpToast.show(context,'Ảnh sản phẩm đã lưu vào R2.');
          }on ErpApiError catch(_){
            if(mounted)ErpToast.show(context,
              'Đã lưu sản phẩm nhưng ảnh chưa được xác nhận. '
              'Mở biểu tượng hình ảnh tại sản phẩm để kiểm tra.',
              isError:true);
          }
        }
      }on ErpApiError catch(e){
        // Authentication failures, timeouts and conflicts cannot establish
        // that the first attempt did not commit. Replay the original command.
        if(e.status==400||e.status==404||e.status==413||
            e.status==415||e.code=='DUPLICATE')
          widget.client.clearR1(actor,branch,pendingKind);
        if(mounted){
          ErpToast.show(context,_errorMessage(e),isError:true);
          await _loadRecords();
        }
      }catch(_){
        if(mounted){
          ErpToast.show(context,
            'Chưa có xác nhận server. Nhấn Kiểm tra yêu cầu để gửi lại đúng thao tác.',
            isError:true);
          await _loadRecords();
        }
      }finally{if(mounted)setState(()=>saving=false);}
    }on ErpApiError catch(e){
      if(mounted)ErpToast.show(context,_errorMessage(e),isError:true);
    }finally{
      // showDialog's result arrives when pop begins, BEFORE its reverse
      // animation finishes. TextFields still listen to these controllers.
      if(formRoute!=null)await formRoute!.completed;
      code.dispose();name.dispose();unit.dispose();
      phone.dispose();deliveryAddress.dispose();paymentTerms.dispose();
      altUnit.dispose();conversion.dispose();altSku.dispose();altBarcode.dispose();
      baseBarcode.dispose();
      for(final extra in extraUnits){
        extra.unit.dispose();extra.factor.dispose();extra.sku.dispose();
        extra.barcode.dispose();
      }
      amount.dispose();discount.dispose();
      newGroupCode.dispose();newGroupName.dispose();
      newRegionCode.dispose();newRegionName.dispose();
      newUnitCode.dispose();newUnitName.dispose();
    }
  }

  Future<void> _productImages(Map<String,dynamic> product)async{
    if(branchId==null)return;
    final productId=product['id'] as String;
    final branch=branchId!;
    List<Map<String,dynamic>> images=[];
    String? galleryError;
    bool galleryBusy=false;
    try{
      images=await widget.client.productPhotos(
        widget.session.token,branch,productId);
    }on ErpApiError catch(e){galleryError=_errorMessage(e);}
    if(!mounted)return;
    await showDialog<void>(context:context,builder:(dialog)=>
      StatefulBuilder(builder:(ctx,refresh)=>AlertDialog(
        title:Text('Ảnh · ${product['name']}'),
        content:SizedBox(
          width:(MediaQuery.sizeOf(dialog).width-70).clamp(250.0,620.0).toDouble(),
          child:SingleChildScrollView(child:Column(
            mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.start,
            children:[
              const Text('Ảnh lưu riêng trên R2, chỉ người có quyền mới xem '
                'được qua liên kết có thời hạn.',
                style:TextStyle(fontSize:12,color:ErpTokens.muted)),
              const SizedBox(height:14),
              if(galleryBusy)const LinearProgressIndicator(),
              if(galleryError!=null)Padding(
                padding:const EdgeInsets.only(bottom:12),
                child:Text(galleryError!,style:const TextStyle(
                  color:ErpTokens.danger))),
              if(images.isEmpty&&galleryError==null)
                const Padding(padding:EdgeInsets.symmetric(vertical:20),
                  child:Text('Chưa có hình ảnh cho sản phẩm này.')),
              Wrap(spacing:10,runSpacing:10,children:[
                for(final image in images)
                  ClipRRect(borderRadius:BorderRadius.circular(8),
                    child:Stack(children:[
                      Image.network(image['downloadUrl'] as String,
                        width:124,height:124,fit:BoxFit.cover,
                        errorBuilder:(_,__,___)=>Container(
                          width:124,height:124,color:ErpTokens.mint,
                          child:const Icon(Icons.broken_image_outlined))),
                      if(image['isPrimary']==true)
                        const Positioned(left:3,top:3,
                          child:Chip(label:Text('Ảnh chính'))),
                    ])),
              ]),
            ]))),
        actions:[
          TextButton(onPressed:galleryBusy?null:()=>Navigator.pop(dialog),
            child:const Text('Đóng')),
          if(canWrite)FilledButton.icon(
            key:const ValueKey('catalog-product-upload-image'),
            icon:const Icon(Icons.add_photo_alternate_outlined),
            onPressed:galleryBusy?null:()async{
              try{
                final selected=await FilePicker.platform.pickFiles(
                  type:FileType.custom,
                  allowedExtensions:['png','jpg','jpeg','webp'],
                  withData:true);
                if(selected==null||selected.files.isEmpty)return;
                final first=selected.files.first;
                final ext=first.extension?.toLowerCase();
                final type=ext=='png'?'image/png':ext=='webp'?'image/webp':
                  ext=='jpg'||ext=='jpeg'?'image/jpeg':null;
                if(type==null||first.bytes==null||
                  first.bytes!.isEmpty||first.bytes!.length>5242880){
                  if(ctx.mounted)refresh(()=>galleryError=
                    'Chọn PNG/JPG/WebP tối đa 5 MB.');
                  return;
                }
                if(ctx.mounted)refresh((){
                  galleryBusy=true;galleryError=null;
                });
                await widget.client.uploadProductPhoto(
                  widget.session.token,widget.session.actorId,
                  branch,productId,first.bytes!,type);
                images=await widget.client.productPhotos(
                  widget.session.token,branch,productId);
                if(ctx.mounted)refresh((){
                  galleryBusy=false;galleryError=null;
                });
              }on ErpApiError catch(e){
                if(ctx.mounted)refresh((){
                  galleryBusy=false;galleryError=_errorMessage(e);
                });
              }catch(_){
                if(ctx.mounted)refresh((){
                  galleryBusy=false;
                  galleryError='Chưa xác nhận ảnh. Chọn lại đúng ảnh để thử lại.';
                });
              }
            },
            label:const Text('Thêm ảnh')),
        ],
      )));
  }

  Future<void> _customerLocations(Map<String,dynamic> customer)async{
    final id=customer['id'];
    if(id is! String||branchId==null)return;
    await showDialog<void>(context:context,builder:(_)=>CustomerLocationsDialog(
      client:widget.client,session:widget.session,branchId:branchId!,
      customerId:id,customerName:customer['name'].toString(),canWrite:canWrite));
  }
  void _beginInlinePrice(Map<String,dynamic> row){
    if(resource!='prices'||!canWrite||saving||branchId==null)return;
    final listId=row['priceListId'],productId=row['productId'],id=row['id'];
    if(listId is! String||productId is! String||id is! String)return;
    final pending=widget.client.pendingR1(widget.session.actorId,branchId!,
      'catalog.create.prices.'+listId+'.'+productId);
    setState((){
      inlinePriceId=id;
      inlineAmount.text=(pending?.payload['amount']??row['amount']).toString();
      inlineDiscount.text=(pending?.payload['discountRate']??row['discountRate']).toString();
    });
  }
  Future<void> _saveInlinePrice(Map<String,dynamic> row)async{
    if(resource!='prices'||!canWrite||saving||branchId==null||
       inlinePriceId!=row['id'])return;
    final listId=row['priceListId'],productId=row['productId'];
    if(listId is! String||productId is! String)return;
    final branch=branchId!,actor=widget.session.actorId;
    final kind='catalog.create.prices.'+listId+'.'+productId;
    final pending=widget.client.pendingR1(actor,branch,kind);
    final payload=pending?.payload??<String,dynamic>{
      'branchId':branch,'priceListId':listId,'productId':productId,
      'amount':inlineAmount.text.trim(),'discountRate':inlineDiscount.text.trim(),
      'effectiveAt':DateTime.now().toUtc().toIso8601String(),
    };
    final key=pending?.key??('r1c-inline-price-'+
      DateTime.now().microsecondsSinceEpoch.toString());
    if(pending==null)widget.client.retainR1(actor,branch,kind,payload,key);
    setState(()=>saving=true);
    try{
      await widget.client.createCatalogWithKey(
        widget.session.token,'prices',payload,key:key);
      widget.client.clearR1(actor,branch,kind);
      if(!mounted)return;
      setState(()=>inlinePriceId=null);
      ErpToast.show(context,'Đã ghi giá hiệu lực mới, lịch sử cũ được giữ nguyên.');
      await _loadRecords();
    }on ErpApiError catch(e){
      if(e.status==400||e.status==404||e.code=='EFFECTIVE_PRICE_EXISTS'||
          e.code=='INVALID_DECIMAL_STRING')
        widget.client.clearR1(actor,branch,kind);
      if(mounted)ErpToast.show(context,_errorMessage(e),isError:true);
    }catch(_){
      if(mounted)ErpToast.show(context,
        'Chưa có xác nhận server. Bấm Lưu lại để kiểm tra đúng yêu cầu trước.',
        isError:true);
    }finally{if(mounted)setState(()=>saving=false);}
  }

  Future<void> _cloneList(Map<String,dynamic> row)async{
    if(resource!='price-lists'||!canWrite||saving||branchId==null)return;
    final sourceId=row['id'],revision=row['revision'];
    if(sourceId is! String||revision is! int)return;
    final branch=branchId!,actor=widget.session.actorId;
    final kind='catalog.clone.price-lists.'+sourceId;
    final pending=widget.client.pendingR1(actor,branch,kind);
    Map<String,dynamic>? payload=pending?.payload;
    if(payload==null){
      var code=row['code'].toString()+'-COPY';
      var name='Bản sao '+row['name'].toString();
      payload=await showDialog<Map<String,dynamic>>(context:context,
        builder:(dialog)=>StatefulBuilder(builder:(ctx,refresh)=>AlertDialog(
          key:const ValueKey('catalog-price-list-clone-dialog'),
          title:const Text('Sao chép bảng giá'),
          content:SizedBox(
            width:(MediaQuery.sizeOf(ctx).width-70).clamp(220.0,460.0).toDouble(),
            child:Column(mainAxisSize:MainAxisSize.min,
              crossAxisAlignment:CrossAxisAlignment.stretch,children:[
                const Text('Sao chép giá hiệu lực và chính sách chưa hết hạn. '
                  'Bảng giá mới độc lập; lịch sử bảng nguồn không đổi.',
                  style:TextStyle(fontSize:12,color:ErpTokens.muted)),
                const SizedBox(height:12),
                TextFormField(key:const ValueKey('catalog-clone-code'),
                  initialValue:code,onChanged:(v)=>refresh(()=>code=v.trim()),
                  decoration:const InputDecoration(labelText:'Mã bảng giá mới')),
                const SizedBox(height:12),
                TextFormField(key:const ValueKey('catalog-clone-name'),
                  initialValue:name,onChanged:(v)=>refresh(()=>name=v.trim()),
                  decoration:const InputDecoration(labelText:'Tên bảng giá mới')),
              ])),
          actions:[
            TextButton(onPressed:()=>Navigator.pop(dialog),
              child:const Text('Hủy')),
            FilledButton(
              key:const ValueKey('catalog-clone-confirm'),
              onPressed:code.length>=2&&code.length<=64&&
                RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*').stringMatch(code)==code&&
                name.isNotEmpty&&name.length<=160
                ?()=>Navigator.pop(dialog,<String,dynamic>{
                  'branchId':branch,'sourceRevision':revision,
                  'code':code,'name':name,
                }):null,
              child:const Text('Sao chép')),
          ],
        )));
    }
    if(payload==null||!mounted)return;
    final key=pending?.key??('catalog-clone-'+sourceId+'-'+
      DateTime.now().microsecondsSinceEpoch.toString());
    if(pending==null)widget.client.retainR1(actor,branch,kind,payload,key);
    setState(()=>saving=true);
    try{
      final result=await widget.client.clonePriceList(
        widget.session.token,sourceId,payload,key:key);
      widget.client.clearR1(actor,branch,kind);
      if(!mounted)return;
      ErpToast.show(context,'Đã sao chép '+result['copiedPrices'].toString()+
        ' giá và '+result['copiedRules'].toString()+' chính sách.');
      await _loadRecords();
    }on ErpApiError catch(e){
      if(e.status==400||e.status==404||e.code=='DUPLICATE'||
          e.code=='REVISION_CONFLICT')
        widget.client.clearR1(actor,branch,kind);
      if(mounted)ErpToast.show(context,_errorMessage(e),isError:true);
    }catch(_){
      if(mounted)ErpToast.show(context,
        'Chưa có xác nhận server. Chọn sao chép lần nữa để kiểm tra đúng yêu cầu.',
        isError:true);
    }finally{if(mounted)setState(()=>saving=false);}
  }

  bool get canEdit => canWrite && resource!='prices' && resource!='warehouses';
  Future<void> _edit(Map<String,dynamic> row)async{
    if(!canEdit||saving||branchId==null)return;
    final id=row['id'],revision=row['revision'];
    if(id is! String||revision is! int)return;
    final branch=branchId!;
    var name=(row['name']??'').toString();
    var phone=(row['phone']??'').toString();
    var deliveryAddress=(row['deliveryAddress']??'').toString();
    var paymentTermsDays=(row['paymentTermsDays']??0).toString();
    var listPriority=(row['priority']??0).toString();
    var listStacking=(row['stackingMode']??'EXCLUSIVE').toString();
    bool listStop=row['stopProcessing']==true;
    bool assignDefault=false,priceScopesLoaded=false;
    final selectedChannels=<String>{},selectedGroups=<String>{},selectedCustomers=<String>{};
    List<Map<String,dynamic>> priceChannels=[],priceGroups=[],priceCustomers=[];
    DateTime? listStart=DateTime.tryParse(row['effectiveFrom']?.toString()??'');
    DateTime? listEnd=DateTime.tryParse(row['effectiveTo']?.toString()??'')
      ?.toLocal().subtract(const Duration(microseconds:1));
    final oldGroupId=row['customerGroupId'] as String?;
    final oldRegionId=row['customerRegionId'] as String?;
    final oldProductGroupId=row['groupId'] as String?;
    String? customerGroupId=oldGroupId,customerRegionId=oldRegionId;
    String? productGroupId=oldProductGroupId;
    final oldBrandId=row['brandId'] as String?;
    final oldCategoryId=row['categoryId'] as String?;
    final oldParentId=row['parentId'] as String?;
    String? brandId=oldBrandId,categoryId=oldCategoryId,parentId=oldParentId;
    bool active=row['active'] as bool? ?? true;
    List<Map<String,dynamic>> customerGroups=[],customerRegions=[],productGroups=[],
      brands=[],categories=[];
    try{
      if(resource=='customers'){
        final lookup=await Future.wait([
          widget.client.catalogDirectoryAll(widget.session.token,
            'customer-groups',branchId:branch),
          widget.client.catalogDirectoryAll(widget.session.token,
            'customer-regions',branchId:branch),
        ]);
        customerGroups=lookup[0];
        customerRegions=lookup[1];
      }else if(resource=='price-lists'){
        try{
          final loaded=await Future.wait([
            widget.client.r1CatalogItems(widget.session.token,'channels',branchId:branch),
            widget.client.catalogDirectoryAll(widget.session.token,
              'customer-groups',branchId:branch),
            widget.client.catalogItems(widget.session.token,'customers',branchId:branch),
            widget.client.priceListAssignments(widget.session.token,branch,priceListId:id),
          ]);
          priceChannels=loaded[0];priceGroups=loaded[1];priceCustomers=loaded[2];
          for(final assignment in loaded[3].where((x)=>x['active']==true)){
            final target=assignment['scopeKind'];
            if(target=='DEFAULT')assignDefault=true;
            if(target=='CHANNEL')selectedChannels.add(assignment['channelId'].toString());
            if(target=='CUSTOMER_GROUP')selectedGroups.add(assignment['customerGroupId'].toString());
            if(target=='CUSTOMER')selectedCustomers.add(assignment['customerId'].toString());
          }
          priceScopesLoaded=true;
        }catch(_){
          priceScopesLoaded=false;
          if(mounted)ErpToast.show(context,
            'Không tải được phân bổ. Đang giữ nguyên các phạm vi hiện có.',
            isError:true);
        }
      }else if(resource=='products'||resource=='groups'||resource=='categories'){
        // An installation on schema 0019 must still allow old name/status edits.
        productGroups=await widget.client.catalogItems(
          widget.session.token,'groups',branchId:branch);
        try{
          final taxonomy=await Future.wait([
            widget.client.catalogDirectoryAll(widget.session.token,'brands',branchId:branch),
            widget.client.catalogDirectoryAll(widget.session.token,'categories',branchId:branch),
          ]);
          brands=taxonomy[0];categories=taxonomy[1];
        }on ErpApiError catch(e){if(e.status!=503)rethrow;}
        // Do not drop assigned IDs merely because dropdown pages stop at 100.
        Future<void> includeAssigned(String kind,String? assigned,
            List<Map<String,dynamic>> options)async{
          if(assigned==null||options.any((x)=>x['id']==assigned))return;
          final found=await widget.client.catalogItems(widget.session.token,
            kind,branchId:branch,itemId:assigned);
          options.addAll(found);
        }
        await includeAssigned('groups',resource=='categories'
          ?row['groupId'] as String?:productGroupId,productGroups);
        if(brands.isNotEmpty||oldBrandId!=null){
          await includeAssigned('brands',oldBrandId,brands);
        }
        if(categories.isNotEmpty||oldCategoryId!=null||oldParentId!=null){
          await includeAssigned('categories',oldCategoryId,categories);
          await includeAssigned('categories',oldParentId,categories);
        }
      }
    }on ErpApiError catch(e){
      if(mounted)ErpToast.show(context,_errorMessage(e),isError:true);
      return;
    }
    if(!mounted)return;
    final size=MediaQuery.sizeOf(context);
    final formWidth=(size.width-56).clamp(220.0,620.0).toDouble();
    final formHeight=(size.height-205).clamp(120.0,580.0).toDouble();
    final body=await showDialog<Map<String,dynamic>>(
      context:context,
      builder:(dialog)=>StatefulBuilder(builder:(context,refresh)=>AlertDialog(
        key:const ValueKey('catalog-edit-dialog'),
        insetPadding:const EdgeInsets.symmetric(horizontal:12,vertical:12),
        contentPadding:const EdgeInsets.fromLTRB(16,8,16,8),
        title:Text('Sửa ${titles[resource]??'danh mục'}',
          style:const TextStyle(fontWeight:FontWeight.w700)),
        content:SizedBox(width:formWidth,
          child:ConstrainedBox(
            constraints:BoxConstraints(maxHeight:formHeight),
            child:SingleChildScrollView(
              key:const ValueKey('catalog-edit-scroll'),
              child:Column(mainAxisSize:MainAxisSize.min,
                crossAxisAlignment:CrossAxisAlignment.stretch,
                children:[
                  Text('Mã: ${row['code']??'—'}',
                    style:const TextStyle(fontSize:12,color:ErpTokens.muted)),
                  const SizedBox(height:12),
                  TextFormField(key:const ValueKey('catalog-edit-name'),
                    initialValue:name,onChanged:(value)=>name=value,
                    maxLength:resource=='unit-definitions'?80:160,
                    decoration:const InputDecoration(labelText:'Tên')),
                  if(resource=='price-lists')...[
                    const SizedBox(height:12),
                    TextFormField(
                      key:const ValueKey('r1c-edit-list-priority'),
                      initialValue:listPriority,
                      keyboardType:TextInputType.number,
                      decoration:const InputDecoration(labelText:'Ưu tiên bảng giá'),
                      onChanged:(v)=>refresh(()=>listPriority=v)),
                    const SizedBox(height:8),
                    DropdownButtonFormField<String>(
                      key:const ValueKey('price-edit-stacking'),
                      initialValue:listStacking,isExpanded:true,
                      decoration:const InputDecoration(labelText:'Cách kết hợp giá'),
                      items:const [
                        DropdownMenuItem(value:'EXCLUSIVE',
                          child:Text('Độc lập: dùng mức giá này')),
                        DropdownMenuItem(value:'STACKABLE',
                          child:Text('Cộng dồn chính sách phù hợp')),
                      ],
                      onChanged:(v){if(v!=null)refresh(()=>listStacking=v);}),
                    SwitchListTile(
                      key:const ValueKey('price-edit-stop'),
                      contentPadding:EdgeInsets.zero,
                      title:const Text('Ngừng xét bảng giá tiếp theo'),
                      value:listStop,onChanged:(v)=>refresh(()=>listStop=v)),
                    const SizedBox(height:8),
                    Wrap(spacing:8,runSpacing:6,children:[
                      OutlinedButton.icon(
                        key:const ValueKey('r1c-edit-list-from'),
                        onPressed:()async{
                          final picked=await _pickPriceDay(context,listStart,
                            'Có hiệu lực từ');
                          if(picked!=null&&context.mounted)
                            refresh(()=>listStart=picked);
                        },icon:const Icon(Icons.event,size:16),
                        label:Text(_dateLabel(listStart,'Bắt đầu ngay'))),
                      if(listStart!=null)IconButton(
                        tooltip:'Bỏ ngày bắt đầu',
                        onPressed:()=>refresh(()=>listStart=null),
                        icon:const Icon(Icons.close,size:16)),
                      OutlinedButton.icon(
                        key:const ValueKey('r1c-edit-list-to'),
                        onPressed:()async{
                          final picked=await _pickPriceDay(context,listEnd,
                            'Đến hết ngày');
                          if(picked!=null&&context.mounted)
                            refresh(()=>listEnd=picked);
                        },icon:const Icon(Icons.event_busy,size:16),
                        label:Text(_dateLabel(listEnd,'Không giới hạn'))),
                      if(listEnd!=null)IconButton(
                        tooltip:'Bỏ ngày kết thúc',
                        onPressed:()=>refresh(()=>listEnd=null),
                        icon:const Icon(Icons.close,size:16)),
                    ]),
                    if(priceScopesLoaded)...[
                      const SizedBox(height:8),
                      SwitchListTile(
                        key:const ValueKey('price-edit-default'),
                        contentPadding:EdgeInsets.zero,
                        title:const Text('Áp dụng mặc định'),
                        value:assignDefault,
                        onChanged:(v)=>refresh(()=>assignDefault=v)),
                      _priceScopeChips('Kênh bán','price-edit-channel',
                        priceChannels,selectedChannels,refresh),
                      _priceScopeChips('Nhóm khách','price-edit-group',
                        priceGroups,selectedGroups,refresh),
                      _priceScopeChips('Khách hàng riêng','price-edit-customer',
                        priceCustomers,selectedCustomers,refresh),
                      const Padding(padding:EdgeInsets.only(top:8),
                        child:Text('Kênh bán VÀ nhóm khách phải cùng khớp.',
                          style:TextStyle(fontSize:12,color:ErpTokens.muted))),
                    ],
                  ],
                  if(resource=='groups')...[
                    const SizedBox(height:12),
                    DropdownButtonFormField<String?>(
                      key:const ValueKey('catalog-edit-group-brand'),
                      initialValue:brandId,isExpanded:true,
                      decoration:const InputDecoration(labelText:'Nhãn hàng'),
                      items:[
                        const DropdownMenuItem<String?>(value:null,child:Text('Chưa gắn nhãn hàng')),
                        ...brands.where((v)=>v['active']!=false||v['id']==brandId).map(
                          (v)=>DropdownMenuItem<String?>(
                            value:v['id'] as String,child:Text('${v['code']} · ${v['name']}'))),
                      ],onChanged:(v)=>refresh(()=>brandId=v)),
                  ],
                  if(resource=='categories')...[
                    const SizedBox(height:12),
                    DropdownButtonFormField<String?>(
                      key:const ValueKey('catalog-edit-category-parent'),
                      initialValue:parentId,isExpanded:true,
                      decoration:const InputDecoration(labelText:'Danh mục cha'),
                      items:[
                        const DropdownMenuItem<String?>(value:null,child:Text('Danh mục cấp đầu')),
                        ...categories.where((c)=>c['groupId']==row['groupId']&&
                          c['id']!=id&&c['active']!=false).map(
                          (c)=>DropdownMenuItem<String?>(
                            value:c['id'] as String,
                            child:Text('${c['code']} · ${c['name']}'))),
                      ],onChanged:(v)=>refresh(()=>parentId=v)),
                  ],
                  if(resource=='products')...[
                    const SizedBox(height:12),
                    DropdownButtonFormField<String?>(
                      key:const ValueKey('catalog-edit-product-group'),
                      initialValue:productGroups.any((g)=>g['id']==productGroupId)
                        ?productGroupId:null,
                      isExpanded:true,
                      decoration:const InputDecoration(labelText:'Nhóm sản phẩm'),
                      items:[
                        const DropdownMenuItem<String?>(
                          value:null,child:Text('Chưa phân nhóm')),
                        ...productGroups.where((g)=>g['active']!=false||
                          g['id']==productGroupId).map((g)=>
                          DropdownMenuItem<String?>(
                            value:g['id'] as String,
                            child:Text("${g['code']} · ${g['name']}",
                              overflow:TextOverflow.ellipsis))),
                      ],
                      onChanged:(v)=>refresh((){productGroupId=v;categoryId=null;})),
                    const SizedBox(height:12),
                    DropdownButtonFormField<String?>(
                      key:ValueKey('catalog-edit-product-category-$productGroupId'),
                      initialValue:categoryId,isExpanded:true,
                      decoration:const InputDecoration(labelText:'Danh mục sản phẩm'),
                      items:[
                        const DropdownMenuItem<String?>(value:null,child:Text('Chưa phân danh mục')),
                        ...categories.where((c)=>c['groupId']==productGroupId&&
                          (c['active']!=false||c['id']==categoryId)).map(
                          (c)=>DropdownMenuItem<String?>(
                            value:c['id'] as String,
                            child:Text('${c['code']} · ${c['name']}'))),
                      ],onChanged:(v)=>refresh(()=>categoryId=v)),
                    const SizedBox(height:8),
                    const Text('Mã hàng, ĐVT gốc, SKU và mã vạch đã phát sinh là định danh. '+
                      'Thay đổi SKU/đơn vị qua tab SKU bán hàng và Đơn vị tính; ảnh qua nút ảnh sản phẩm.',
                      style:TextStyle(color:ErpTokens.muted,fontSize:12)),
                  ],
                  if(resource=='customers')...[
                    const SizedBox(height:12),
                    DropdownButtonFormField<String?>(
                      key:const ValueKey('catalog-edit-customer-group'),
                      initialValue:customerGroups.any((g)=>g['id']==customerGroupId)
                        ?customerGroupId:null,
                      isExpanded:true,
                      decoration:const InputDecoration(labelText:'Nhóm khách hàng'),
                      items:[
                        const DropdownMenuItem<String?>(
                          value:null,child:Text('Chưa phân nhóm')),
                        ...customerGroups.where((g)=>g['active']!=false||
                          g['id']==customerGroupId).map((g)=>
                          DropdownMenuItem<String?>(
                            value:g['id'] as String,
                            child:Text("${g['code']} · ${g['name']}",
                              overflow:TextOverflow.ellipsis))),
                      ],
                      onChanged:(v)=>refresh(()=>customerGroupId=v)),
                    const SizedBox(height:12),
                    DropdownButtonFormField<String?>(
                      key:const ValueKey('catalog-edit-customer-region'),
                      initialValue:customerRegions.any((r)=>r['id']==customerRegionId)
                        ?customerRegionId:null,
                      isExpanded:true,
                      decoration:const InputDecoration(labelText:'Khu vực bán hàng'),
                      items:[
                        const DropdownMenuItem<String?>(
                          value:null,child:Text('Chưa phân khu vực')),
                        ...customerRegions.where((r)=>r['active']!=false||
                          r['id']==customerRegionId).map((r)=>
                          DropdownMenuItem<String?>(
                            value:r['id'] as String,
                            child:Text("${r['code']} · ${r['name']}",
                              overflow:TextOverflow.ellipsis))),
                      ],
                      onChanged:(v)=>refresh(()=>customerRegionId=v)),
                    const SizedBox(height:12),
                    TextFormField(initialValue:phone,onChanged:(v)=>phone=v,
                      keyboardType:TextInputType.phone,
                      decoration:const InputDecoration(labelText:'Điện thoại')),
                    const SizedBox(height:12),
                    TextFormField(initialValue:deliveryAddress,
                      onChanged:(v)=>deliveryAddress=v,maxLines:2,
                      decoration:const InputDecoration(labelText:'Địa chỉ giao hàng')),
                    const SizedBox(height:12),
                    TextFormField(initialValue:paymentTermsDays,
                      onChanged:(v)=>paymentTermsDays=v,
                      keyboardType:TextInputType.number,
                      decoration:const InputDecoration(labelText:'Số ngày thanh toán')),
                  ],
                  const SizedBox(height:8),
                  SwitchListTile(key:const ValueKey('catalog-edit-active'),
                    contentPadding:EdgeInsets.zero,
                    title:const Text('Đang sử dụng'),value:active,
                    onChanged:(v)=>refresh(()=>active=v)),
                ]))),
        ),
        actions:[
          TextButton(onPressed:()=>Navigator.pop(dialog),child:const Text('Hủy')),
          FilledButton(key:const ValueKey('catalog-edit-save'),
            onPressed:resource=='price-lists'&&(
              int.tryParse(listPriority.trim())==null||
              (int.tryParse(listPriority.trim())??0).abs()>100000||
              (listStart!=null&&listEnd!=null&&listEnd!.isBefore(listStart!)))
              ?null:()=>Navigator.pop(dialog,{
              'branchId':branchId,'name':name.trim(),'active':active,
              if(resource=='price-lists')...{
                'effectiveFrom':listStart?.toIso8601String(),
                'effectiveTo':_priceListEndExclusive(listEnd)?.toIso8601String(),
                'priority':int.parse(listPriority.trim()),
                'stackingMode':listStacking,'stopProcessing':listStop,
                if(priceScopesLoaded)...{
                  'channelIds':selectedChannels.toList(),
                  'customerGroupIds':selectedGroups.toList(),
                  'customerIds':selectedCustomers.toList(),
                  'defaultAssignment':assignDefault,
                },
              },
              if(resource=='products'&&productGroupId!=oldProductGroupId)
                'groupId':productGroupId,
              if(resource=='products'&&categoryId!=oldCategoryId)
                'categoryId':categoryId,
              if(resource=='groups'&&brandId!=oldBrandId)'brandId':brandId,
              if(resource=='categories'&&parentId!=oldParentId)'parentId':parentId,
              if(resource=='customers')...{
                if(customerGroupId!=oldGroupId)'customerGroupId':customerGroupId,
                if(customerRegionId!=oldRegionId)'customerRegionId':customerRegionId,
                'phone':phone.trim().isEmpty?null:phone.trim(),
                'deliveryAddress':deliveryAddress.trim().isEmpty
                  ?null:deliveryAddress.trim(),
                'paymentTermsDays':int.tryParse(paymentTermsDays.trim())??-1,
              },
            }),child:const Text('Lưu thay đổi')),
        ],
      )));
    if(body==null||!mounted)return;
    setState(()=>saving=true);
    try{
      await widget.client.updateCatalog(widget.session.token,resource,id,revision,body);
      if(!mounted)return;
      ErpToast.show(context,'Đã cập nhật trên server.');
      await _loadRecords();
    }on ErpApiError catch(e){
      if(mounted){
        ErpToast.show(context,_errorMessage(e),isError:true);
        await _loadRecords();
      }
    }finally{if(mounted)setState(()=>saving=false);}
  }
  Future<void> _quote()async{
    final branch=branchId;
    if(branch==null||loading)return;
    try{
      final lists=await widget.client.catalogItems(widget.session.token,'price-lists',branchId:branch);
      final products=await widget.client.catalogItems(widget.session.token,'products',branchId:branch);
      if(!mounted)return;
      final liveLists=lists.where((x)=>x['active']!=false).toList();
      final liveProducts=products.where((x)=>x['active']!=false).toList();
      if(liveLists.isEmpty||liveProducts.isEmpty){
        ErpToast.show(context,'Cần bảng giá và sản phẩm đang hoạt động.',isError:true);
        return;
      }
      String list=liveLists.first['id'] as String;
      String product=liveProducts.first['id'] as String;
      final choice=await showDialog<List<String>>(context:context,
        builder:(dialog)=>StatefulBuilder(builder:(context,refresh)=>AlertDialog(
          title:const Text('Tra giá hiệu lực'),
          content:SizedBox(width:400,child:Column(mainAxisSize:MainAxisSize.min,children:[
            DropdownButtonFormField<String>(initialValue:list,isExpanded:true,
              decoration:const InputDecoration(labelText:'Bảng giá'),
              items:liveLists.map((x)=>DropdownMenuItem<String>(
                value:x['id'] as String,
                child:Text(x['name'] as String,overflow:TextOverflow.ellipsis))).toList(),
              onChanged:(v){if(v!=null)refresh(()=>list=v);}),
            const SizedBox(height:12),
            DropdownButtonFormField<String>(initialValue:product,isExpanded:true,
              decoration:const InputDecoration(labelText:'Sản phẩm'),
              items:liveProducts.map((x)=>DropdownMenuItem<String>(
                value:x['id'] as String,
                child:Text(x['name'] as String,overflow:TextOverflow.ellipsis))).toList(),
              onChanged:(v){if(v!=null)refresh(()=>product=v);}),
          ])),
          actions:[
            TextButton(onPressed:()=>Navigator.pop(dialog),child:const Text('Hủy')),
            FilledButton(onPressed:()=>Navigator.pop(dialog,[list,product]),
              child:const Text('Tra giá')),
          ],
        )));
      if(choice==null||!mounted)return;
      final value=await widget.client.catalogPriceQuote(widget.session.token,
        branchId:branch,priceListId:choice.first,productId:choice.last);
      if(!mounted)return;
      final q=value['quote'] as Map<String,dynamic>?;
      await showDialog<void>(context:context,builder:(dialog)=>AlertDialog(
        title:const Text('Giá hiện hành'),
        content:Column(mainAxisSize:MainAxisSize.min,
          crossAxisAlignment:CrossAxisAlignment.start,children:[
            Text(q==null?'Chưa có giá hiệu lực':
              erpNumberText(q['amount'])+' '+q['currency'].toString(),
              key:const ValueKey('catalog-quote-result'),
              style:const TextStyle(fontSize:22,fontWeight:FontWeight.w800)),
            if(q!=null)...[
              const SizedBox(height:8),
              Text('Chiết khấu: '+erpNumberText(q['discountRate'])+'%'),
              Text('Hiệu lực: '+erpDateTimeText(q['effectiveAt'])),
            ],
            const SizedBox(height:12),
            const Text('Tồn kho chưa xác minh; chưa được xác nhận đơn hàng.',
              style:TextStyle(fontSize:12,color:ErpTokens.muted)),
          ]),
        actions:[TextButton(onPressed:()=>Navigator.pop(dialog),child:const Text('Đóng'))],
      ));
    }on ErpApiError catch(e){
      if(mounted)ErpToast.show(context,_errorMessage(e),isError:true);
    }
  }

  String _cell(Map<String,dynamic> item,String key){
    final value=item[key];
    if(value==null)return '—';
    if(value is bool)return value?'Hoạt động':'Ngừng';
    if(key=='amount'||key=='discountRate'||key=='quantity')
      return erpNumberText(value);
    if(key=='effectiveAt')return erpDateTimeText(value);
    if(key=='effectiveFrom'||key=='effectiveTo'){
      final day=DateTime.tryParse(value.toString())?.toLocal();
      if(day==null)return '—';
      final display=key=='effectiveTo'?day.subtract(const Duration(microseconds:1)):day;
      return '${display.day.toString().padLeft(2,'0')}/'
        '${display.month.toString().padLeft(2,'0')}/${display.year}';
    }
    return value.toString();
  }
  List<(String,String)> get columns=>switch(resource){
    'customers'=>const [('code','Mã'),('name','Khách hàng'),
      ('customerGroupCode','Mã nhóm'),('customerRegionCode','Mã khu vực'),
      ('phone','Điện thoại'),('deliveryAddress','Địa chỉ giao'),
      ('paymentTermsDays','Ngày hạn'),('active','Trạng thái')],
    'customer-groups'=>const [('code','Mã nhóm'),('name','Tên nhóm'),('active','Trạng thái')],
    'customer-regions'=>const [('code','Mã khu vực'),('name','Tên khu vực'),('active','Trạng thái')],
    'suppliers'=>const [('code','Mã'),('name','Nhà cung cấp'),('active','Trạng thái')],
    'brands'=>const [('code','Mã nhãn hàng'),('name','Nhãn hàng'),('active','Trạng thái')],
    'groups'=>const [('code','Mã nhóm'),('name','Tên nhóm'),('brandName','Nhãn hàng'),('active','Trạng thái')],
    'categories'=>const [('code','Mã danh mục'),('name','Danh mục'),('parentCode','Danh mục cha'),('active','Trạng thái')],
    'unit-definitions'=>const [
      ('code','Mã đơn vị'),('name','Tên đơn vị'),('active','Trạng thái')],
    'products'=>const [('code','Mã hàng'),('name','Sản phẩm'),
      ('groupName','Nhóm hàng'),('categoryName','Danh mục'),('baseUnit','Đơn vị tồn kho'),
      ('sellSkuCount','SKU bán'),('barcode','Mã vạch gốc'),
      ('active','Trạng thái')],
    'price-lists'=>const [('code','Mã bảng giá'),('name','Bảng giá'),
      ('effectiveFrom','Từ ngày'),('effectiveTo','Đến hết ngày'),
      ('priority','Ưu tiên'),('active','Trạng thái')],
    'prices'=>const [('priceListCode','Bảng giá'),('productCode','Mã hàng'),
      ('productName','Sản phẩm'),('amount','Đơn giá'),('discountRate','CK %'),
      ('effectiveAt','Hiệu lực')],
    _=>const [('code','Mã kho'),('name','Kho hàng'),('branchId','Chi nhánh (ID)')],
  };
  @override Widget build(BuildContext context){
    return Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
      if((tabs[widget.area]??[]).length>1)
        ErpSectionTabs<String>(
          keyPrefix:'catalog-inner',selected:resource,
          items:tabs[widget.area]!,onSelected:_changeResource),
      const SizedBox(height:16),
      if(resource=='bulk')Column(
        crossAxisAlignment:CrossAxisAlignment.stretch,children:[
          if(branches.isNotEmpty)
            Padding(padding:const EdgeInsets.only(bottom:12),
              child:Align(alignment:Alignment.centerLeft,
                child:SizedBox(width:280,child:DropdownButtonFormField<String>(
                  key:const ValueKey('catalog-bulk-branch'),
                  isExpanded:true,initialValue:branchId,
                  decoration:const InputDecoration(labelText:'Chi nhánh'),
                  items:branches.map((b)=>DropdownMenuItem<String>(
                    value:b['id'] as String,
                    child:Text(b['code'].toString()+' · '+b['name'].toString(),
                      overflow:TextOverflow.ellipsis))).toList(),
                  onChanged:(v){if(v!=null)setState(()=>branchId=v);}
                )))),
          CatalogBulkWorkspace(
            key:ValueKey('bulk-'+widget.area+'-'+branchId.toString()),
            client:widget.client,session:widget.session,branchId:branchId,
            canWrite:canWrite,initialArea:widget.area),
        ]),
      if(isR1)R1CatalogWorkspace(
        key:ValueKey('r1-workspace-'+resource+'-'+branchId.toString()),
        kind:resource,branchId:branchId,branches:branches,
        client:widget.client,session:widget.session,
        changeBranch:(next){setState(()=>branchId=next);},
      ),
      if(!isR1&&resource!='bulk')Card(clipBehavior:Clip.antiAlias,
        child:Padding(padding:const EdgeInsets.all(18),child:Column(
          crossAxisAlignment:CrossAxisAlignment.start,children:[
            Wrap(spacing:12,runSpacing:10,crossAxisAlignment:WrapCrossAlignment.center,children:[
              Text(titles[resource]??'Danh mục',style:const TextStyle(
                color:ErpTokens.ink,fontSize:18,fontWeight:FontWeight.w800)),
              if(branches.isNotEmpty)
                SizedBox(
                  width:(MediaQuery.sizeOf(context).width-96)
                    .clamp(160.0,260.0).toDouble(),
                  child:DropdownButton<String>(
                    key:const ValueKey('catalog-branch-picker'),
                    isExpanded:true,
                    value:branchId,
                    items:branches.map((b)=>DropdownMenuItem<String>(
                      value:b['id'] as String,
                      child:Text('${b['code']} · ${b['name']}',
                        maxLines:1,overflow:TextOverflow.ellipsis))).toList(),
                    onChanged:(next){
                      if(next==null||next==branchId)return;
                      setState((){branchId=next;inlinePriceId=null;assignmentListId=null;priceSkuListId=null;});_loadRecords();
                    })),
              IconButton(
                key:const ValueKey('catalog-refresh'),
                tooltip:'Làm mới danh sách',
                onPressed:loading?null:_loadRecords,
                icon:const Icon(Icons.refresh,color:ErpTokens.primary)),
              if(resource=='price-lists'||resource=='prices')
                OutlinedButton.icon(
                  key:const ValueKey('catalog-quote'),
                  onPressed:loading?null:_quote,
                  icon:const Icon(Icons.price_check,size:18),
                  label:const Text('Tra giá')),
              if(resource=='products'&&canWrite&&selectedProducts.isNotEmpty)
                OutlinedButton.icon(
                  key:const ValueKey('catalog-product-bulk-action'),
                  onPressed:saving?null:_bulkEditProducts,
                  icon:const Icon(Icons.edit_note,size:18),
                  label:Text('Chỉnh ${selectedProducts.length} sản phẩm')),
              if(canWrite)FilledButton.icon(
                key:const ValueKey('catalog-create'),
                onPressed:saving||loading?null:_add,
                icon:const Icon(Icons.add,size:18),
                label:Text(branchId!=null&&widget.client.pendingR1(
                  widget.session.actorId,branchId!,'catalog.create.$resource')!=null
                  ? 'Kiểm tra yêu cầu trước':resource=='price-lists'?'Tạo bảng giá':'Tạo mới')),
            ]),
            if(resource=='unit-definitions')
              const Padding(padding:EdgeInsets.only(top:8),child:Text(
                'Mã ĐVT là mã chung (CHAI, THUNG, HOP); mỗi sản phẩm có hệ số quy đổi riêng. '
                'Mã SKU và mã vạch không phải mã ĐVT.',
                style:TextStyle(color:ErpTokens.muted,fontSize:12))),
            const SizedBox(height:12),
            LayoutBuilder(builder:(context,constraints){
              final compact=constraints.maxWidth<700;
              final searchField=TextField(
                key:const ValueKey('catalog-search'),
                controller:search,onSubmitted:(_)=>_loadRecords(),
                decoration:InputDecoration(
                  labelText:'Tìm trong ${titles[resource]!.toLowerCase()}',
                  prefixIcon:const Icon(Icons.search),
                  suffixIcon:IconButton(tooltip:'Tìm kiếm',
                    onPressed:_loadRecords,icon:const Icon(Icons.arrow_forward))));
              final selector=DropdownButtonFormField<String>(
                key:ValueKey('price-workspace-selected-${selectedPriceListId.toString()}'),
                initialValue:items.any((x)=>x['id']==selectedPriceListId)
                  ?selectedPriceListId:null,
                isExpanded:true,
                decoration:const InputDecoration(labelText:'Bảng giá',
                  prefixIcon:Icon(Icons.price_change_outlined)),
                items:items.map((x)=>DropdownMenuItem<String>(
                  value:x['id'].toString(),
                  child:Text((x['name']??x['code']).toString(),
                    overflow:TextOverflow.ellipsis))).toList(),
                onChanged:(id)=>setState((){
                  selectedPriceListId=id;
                  priceEditorMode=null;
                }));
              if(resource!='price-lists'||items.isEmpty)return searchField;
              if(compact)return Column(children:[
                searchField,const SizedBox(height:8),selector,
              ]);
              return Row(children:[
                Expanded(child:searchField),const SizedBox(width:10),
                SizedBox(width:270,child:selector),
              ]);
            }),
            if(resource=='price-lists'&&priceEditorMode!=null&&
                selectedPriceListId!=null&&items.any((x)=>x['id']==selectedPriceListId))...[
              const SizedBox(height:12),
              Row(children:[
                Expanded(child:Text(
                  priceEditorMode=='sku'?'Chỉnh giá theo SKU':
                  priceEditorMode=='assignment'?'Áp dụng bảng giá':'Nhập / xuất giá',
                  style:const TextStyle(fontWeight:FontWeight.w700))),
                IconButton(
                  tooltip:'Đóng thao tác',
                  onPressed:()=>setState(()=>priceEditorMode=null),
                  icon:const Icon(Icons.close)),
              ]),
              if(priceEditorMode=='sku')
                PriceSkuBatchPanel(
                  key:ValueKey('price-skus-'+branchId!+'-'+selectedPriceListId!),
                  client:widget.client,session:widget.session,branchId:branchId!,
                  priceList:items.firstWhere((x)=>x['id']==selectedPriceListId),
                  canWrite:canWrite,onClose:()=>setState(()=>priceEditorMode=null)),
              if(priceEditorMode=='assignment')
                PriceListAssignmentsPanel(
                  key:ValueKey('assign-'+branchId!+'-'+selectedPriceListId!),
                  client:widget.client,session:widget.session,branchId:branchId!,
                  priceList:items.firstWhere((x)=>x['id']==selectedPriceListId),
                  canWrite:canWrite,onClose:()=>setState(()=>priceEditorMode=null)),
              if(priceEditorMode=='import')
                CatalogBulkWorkspace(
                  key:ValueKey('price-import-'+branchId!+'-'+selectedPriceListId!),
                  client:widget.client,session:widget.session,
                  branchId:branchId,canWrite:canWrite,
                  initialArea:'price-lists',initialPriceListId:selectedPriceListId),
            ],
            if(loading)const Center(child:Padding(
              padding:EdgeInsets.all(20),child:CircularProgressIndicator()))
            else if(error!=null)Padding(
              padding:const EdgeInsets.all(15),child:Text(error!,
                key:const ValueKey('catalog-error'),
                style:const TextStyle(color:ErpTokens.danger)))
            else if(items.isEmpty)const Padding(
              padding:EdgeInsets.symmetric(vertical:28),
              child:Center(child:Text('Không có dữ liệu trên server trong phạm vi này.',
                key:ValueKey('catalog-empty'),style:TextStyle(color:ErpTokens.muted))))
            else SingleChildScrollView(scrollDirection:Axis.horizontal,
              child:DataTable(
                key:const ValueKey('catalog-live-table'),
                headingRowColor:const WidgetStatePropertyAll(ErpTokens.mint),
                columns:[if(resource=='products')const DataColumn(label:Text('Chọn')),
                  ...columns.map((entry)=>DataColumn(
                  label:Text(entry.$2))).toList()]+
                  [if(canEdit||resource=='prices')
                    const DataColumn(label:Text('Thao tác'))],
                rows:items.map((entry)=>DataRow(cells:[
                  if(resource=='products')DataCell(Checkbox(
                    key:ValueKey('catalog-product-select-${entry['id']}'),
                    value:selectedProducts.containsKey(entry['id'].toString()),
                    onChanged:canWrite&&!saving?(v)=>setState((){
                      if(v==true)selectedProducts[entry['id'].toString()]=entry;
                      else selectedProducts.remove(entry['id'].toString());
                    }):null)),
                  for(final c in columns)DataCell(
                    resource=='prices'&&inlinePriceId==entry['id']&&
                      c.$1=='amount'
                      ? SizedBox(width:132,child:TextField(
                          key:const ValueKey('r1c-inline-price-amount'),
                          controller:inlineAmount,
                          keyboardType:const TextInputType.numberWithOptions(decimal:true),
                          decoration:const InputDecoration(
                            labelText:'Giá mới',isDense:true)))
                    : resource=='prices'&&inlinePriceId==entry['id']&&
                      c.$1=='discountRate'
                      ? SizedBox(width:102,child:TextField(
                          key:const ValueKey('r1c-inline-price-discount'),
                          controller:inlineDiscount,
                          keyboardType:const TextInputType.numberWithOptions(decimal:true),
                          decoration:const InputDecoration(
                            labelText:'CK %',isDense:true)))
                    : Text(_cell(entry,c.$1),
                        style:c.$1=='active'?TextStyle(
                          fontWeight:FontWeight.w700,
                          color:entry['active']==true
                            ?ErpTokens.primary:ErpTokens.danger):null)),
                  if(canEdit||resource=='prices')DataCell(
                    resource=='prices'
                      ? (!canWrite?const Text('—'):
                        inlinePriceId==entry['id']
                          ? Row(mainAxisSize:MainAxisSize.min,children:[
                            IconButton(key:const ValueKey('r1c-inline-price-save'),
                              tooltip:'Lưu giá mới',icon:const Icon(Icons.check),
                              onPressed:saving?null:()=>_saveInlinePrice(entry)),
                            IconButton(tooltip:'Hủy sửa giá',
                              icon:const Icon(Icons.close),
                              onPressed:saving?null:()=>setState(()=>inlinePriceId=null)),
                          ])
                          : TextButton.icon(
                            key:ValueKey('r1c-inline-price-edit-'+entry['id'].toString()),
                            onPressed:saving?null:()=>_beginInlinePrice(entry),
                            icon:const Icon(Icons.edit_outlined,size:16),
                            label:Text(widget.client.pendingR1(widget.session.actorId,
                              branchId!,'catalog.create.prices.'+
                              entry['priceListId'].toString()+'.'+entry['productId'].toString())!=null
                              ?'Kiểm tra yêu cầu':'Giá mới')))
                      : Row(mainAxisSize:MainAxisSize.min,children:[
                          IconButton(
                            key:ValueKey('catalog-edit-'+entry['id'].toString()),
                            icon:const Icon(Icons.edit_outlined,size:18),
                            tooltip:'Sửa/ngừng sử dụng',
                            onPressed:saving?null:()=>_edit(entry)),
                          if(resource=='price-lists')PopupMenuButton<String>(
                            key:ValueKey('catalog-price-list-actions-'+entry['id'].toString()),
                            tooltip:'Tác vụ bảng giá',
                            icon:const Icon(Icons.more_horiz,size:20),
                            onSelected:(mode)=>setState((){
                              selectedPriceListId=entry['id'] as String;
                              priceEditorMode=mode;
                            }),
                            itemBuilder:(_)=>const [
                              PopupMenuItem(value:'sku',child:Text('Giá bán')),
                              PopupMenuItem(value:'assignment',child:Text('Áp dụng cho')),
                              PopupMenuItem(value:'import',child:Text('Nhập / xuất')),
                            ]),
                          if(resource=='price-lists')IconButton(
                            key:ValueKey('catalog-price-list-clone-'+entry['id'].toString()),
                            icon:const Icon(Icons.content_copy_outlined,size:18),
                            tooltip:'Sao chép bảng giá cùng chính sách',
                            onPressed:saving?null:()=>_cloneList(entry)),
                          if(resource=='customers')IconButton(
                            key:ValueKey('catalog-customer-locations-'+entry['id'].toString()),
                            icon:const Icon(Icons.storefront_outlined,size:18),
                            tooltip:'Các cửa hàng / địa chỉ giao hàng',
                            onPressed:saving?null:()=>_customerLocations(entry)),
                          if(resource=='products')IconButton(
                            key:ValueKey('catalog-product-images-'+entry['id'].toString()),
                            icon:const Icon(Icons.photo_library_outlined,size:18),
                            tooltip:'Thêm và xem ảnh sản phẩm',
                            onPressed:saving?null:()=>_productImages(entry)),
                        ])),
                ])).toList())),
            if(resource=='products'&&!productWriteReady&&!loading)
              const Padding(padding:EdgeInsets.only(top:12),
                child:Text('Đã xem được danh mục, nhưng chưa cập nhật đủ cấu trúc SKU để thêm sản phẩm.',
                  style:TextStyle(fontSize:12,color:ErpTokens.muted))),

          ]))),
    ]);
  }
}
