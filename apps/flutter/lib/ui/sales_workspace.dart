import 'dart:async';
import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'sales_print_document.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'erp_tokens.dart';
import 'erp_display.dart';
import 'erp_number_input.dart';
import 'erp_toast.dart';
import 'identity_client.dart';
import '../local/local_store.dart';

/// Overlay an explicitly rejected or never-submitted edit onto the fresh
/// canonical order. No old quote signatures are reused.
Map<String,dynamic> erpSalesReconciliationOrder(
  Map<String,dynamic> latest,Map<String,dynamic> command){
  final body=Map<String,dynamic>.from(command['body'] as Map);
  final edits=body['lines'] as List<dynamic>;
  final previous=latest['lines'] is List?latest['lines'] as List:const <dynamic>[];
  final result=<Map<String,dynamic>>[];
  for(var i=0;i<edits.length;i++){
    final src=Map<String,dynamic>.from(edits[i] as Map);
    final sku=src['sellSkuId'];
    final old=previous.where((x)=>x is Map&&x['sellSkuId']==sku).firstOrNull;
    final former=old is Map?Map<String,dynamic>.from(old):<String,dynamic>{};
    final manual=src.containsKey('unitPrice');
    final discount=src.containsKey('discountRate')||src.containsKey('discountMode');
    final tax=src.containsKey('taxRate')||src.containsKey('taxMode');
    result.add({
      ...former,
      'sellSkuId':sku,'quantity':src['quantity'],
      'unitPrice':manual?src['unitPrice']:former['unitPrice']??'0',
      'discountRate':src['discountRate']??former['discountRate']??'0',
      'taxRate':src['taxRate']??former['taxRate']??'0',
      'priceSnapshot':{
        'manualOverride':manual||discount||tax,
        'manualPriceOverride':manual,
        'discountOverride':discount,
        'taxOverride':tax,
        'restoreOverride':true,
        'discountMode':src['discountMode']??'PERCENT',
        'discountValue':src['discountValue']??src['discountRate']??'0',
        'taxMode':src['taxMode']??'EXCLUSIVE',
        'overrideReason':src['overrideReason']??'',
        if(i==0&&body['documentDiscount'] is Map)
          'documentDiscount':body['documentDiscount'],
      },
    });
  }
  return {
    ...latest,
    'customerId':body['customerId'],'priceListId':body['priceListId'],
    'channelId':body['channelId'],'note':body['note'],
    if(body['shipping'] is Map)'shipping':body['shipping'],
    'lines':result,
  };
}
class SalesWorkspace extends StatefulWidget {
  final ErpIdentityClient client;
  final IdentitySession session;
  final ValueChanged<String>? onOpenCatalog;
  final ValueChanged<bool>? onNavigationLockChanged;
  const SalesWorkspace({super.key,required this.client,required this.session,
    this.onOpenCatalog,this.onNavigationLockChanged});
  @override State<SalesWorkspace> createState()=>_SalesWorkspaceState();
}
class _OrderLine {
  String sellSkuId;
  String overrideReason='',discountMode='PERCENT',taxMode='EXCLUSIVE';
  bool discountEdited=false,taxEdited=false;
  final TextEditingController quantity,unitPrice,discountRate,taxRate;
  final displayedPrice=TextEditingController();
  final priceFocus=FocusNode();
  final FocusNode quantityFocus=FocusNode();
  final FocusNode unitFocus=FocusNode();
  _OrderLine(this.sellSkuId,String value):
    quantity=TextEditingController(text:erpGroupedDecimalText(value)),
    unitPrice=TextEditingController(),
    discountRate=TextEditingController(text:'0'),
    taxRate=TextEditingController(text:'0');
  void dispose(){quantity.dispose();unitPrice.dispose();displayedPrice.dispose();priceFocus.dispose();
    discountRate.dispose();taxRate.dispose();quantityFocus.dispose();unitFocus.dispose();}
}
class _SalesWorkspaceState extends State<SalesWorkspace> {
  List<Map<String,dynamic>> branches=[],orders=[];
  String? branchId,error,missingCatalog;
  bool loading=true,saving=false;
  int generation=0,sequence=0;
  final search=TextEditingController();
  final Map<String,String> retryKeys={};
  // Keep the original canonical body AND key together until the server ACKs.
  // A lost response must be replayed with exactly the same request, never a new form.
  Map<String,dynamic>? pendingCreate,pendingConfirm,pendingUpdate;
  String? pendingCreateKey,pendingConfirmKey,pendingUpdateKey;
  bool pendingCreateAutoConfirm=false,localRecoveryBusy=false,localRecoveryBlocked=false;
  String? pendingCreateCartId,pendingCreateCartOwner;
  LocalScope? get _localScope=>branchId==null?null:widget.client.localScope(widget.session,branchId!);
  bool get _localConfigured=>widget.client.localStore!=null&&widget.session.installationId.isNotEmpty;
  bool _lastNavigationLock=false;
  bool pendingNeedsReceipt=false;
  Timer? _syncTimer;
  AppLifecycleListener? _syncLifecycle;
  int _syncDelay=15;
  bool _foreground=true;
  void _scheduleRecovery(){
    _syncTimer?.cancel();
    if(!mounted||!_localConfigured||!_foreground)return;
    _syncTimer=Timer(Duration(seconds:_syncDelay),()async{
      if(!mounted||!_foreground)return;
      if(!saving&&!localRecoveryBusy&&!localRecoveryBlocked&&widget.session.expiresAt.isAfter(DateTime.now())){
        // Only retry previously submitted save-only commands; confirmations remain explicit.
        if(pendingCreate!=null&&!pendingCreateAutoConfirm){await _resolveCreate();}
        else if(pendingUpdate!=null&&pendingUpdate!['auto']!=true){await _resolvePendingUpdate();}
      }
      _syncDelay=(pendingCreate!=null||pendingUpdate!=null)?(_syncDelay*2).clamp(15,120).toInt():15;
      _scheduleRecovery();
    });
  }
  bool get _navigationLocked=>saving||localRecoveryBusy||
    (!localRecoveryBlocked&&(pendingCreate!=null||pendingUpdate!=null||pendingConfirm!=null));
  @override void setState(VoidCallback fn){
    super.setState(fn);
    final locked=_navigationLocked;
    if(locked!=_lastNavigationLock){
      _lastNavigationLock=locked;
      WidgetsBinding.instance.addPostFrameCallback((_){
        if(mounted)widget.onNavigationLockChanged?.call(locked);
      });
    }
  }
  bool _sameScope(String token,String branch)=>mounted&&widget.session.token==token&&branchId==branch&&widget.session.expiresAt.isAfter(DateTime.now())&&widget.session.grants.any((g)=>g.branchId==branch&&g.permission.startsWith('orders.'));
  Future<void> _restorePending()async{
    final scope=_localScope,store=widget.client.localStore;
    if(scope==null||store==null)return;
    final token=widget.session.token,branch=scope.branch;
    setState((){
      localRecoveryBusy=true;localRecoveryBlocked=false;pendingNeedsReceipt=false;
      // Do not carry in-memory pending commands across branches or grants.
      // The durable slot remains intact until an authenticated server ACK.
      pendingCreate=null;pendingCreateKey=null;pendingCreateAutoConfirm=false;pendingCreateCartId=null;pendingCreateCartOwner=null;
      pendingUpdate=null;pendingUpdateKey=null;
      pendingConfirm=null;pendingConfirmKey=null;
    });
    try{
      final data=await store.salesRecovery(scope);
      if(!_sameScope(token,branch)||data==null)return;
      final kind=data['kind'],key=data['key'],body=data['body'];
      if(key is! String||key.isEmpty||body is! Map<String,dynamic>)throw const FormatException();
      final nested=body['body'];
      final actualBranch=kind=='update' ? (nested is Map ? nested['branchId'] : null) : body['branchId'];
      if(actualBranch!=branch)throw const FormatException();
      final command=kind=='update'?nested:body;
      if(command is Map&&command['shipping'] is Map){
        final warehouse=(command['shipping'] as Map)['warehouseId'];
        if(warehouse is String&&!widget.session.grants.any((g)=>g.branchId==branch&&g.warehouseId==warehouse&&g.permission=='inventory.read'))throw const FormatException();
      }
      final requiredPermission=switch(kind){
        'create'=>'orders.create','update'=>'orders.update','confirm'=>'orders.confirm',
        _=>null,
      };
      if(requiredPermission==null||!can(requiredPermission))throw const FormatException();
      setState((){
        pendingNeedsReceipt=true;
        if(kind=='create'){pendingCreate=body;pendingCreateKey=key;pendingCreateAutoConfirm=data['auto']==true;pendingCreateCartId=data['cartId'] is String ? data['cartId'] as String : null;pendingCreateCartOwner=data['cartOwner'] is String ? data['cartOwner'] as String:null;}
        if(kind=='update'){pendingUpdate=body;pendingUpdateKey=key;}
        if(kind=='confirm'){pendingConfirm=body;pendingConfirmKey=key;}
      });
      inform('Có yêu cầu bán hàng chưa được đối chiếu. Hãy kiểm tra lại khi có kết nối.');
    }catch(_){
      if(_sameScope(token,branch)){
        setState(()=>localRecoveryBlocked=true);
        inform('Không đọc được dữ liệu chờ trên máy. Không tự gửi lại.',error:true);
      }
    }finally{if(_sameScope(token,branch))setState(()=>localRecoveryBusy=false);}
  }
  Future<void> _persistPending(LocalScope? scope,String? kind,String? key,Map<String,dynamic>? body,{bool auto=false,String? previousKey,String? cartId,String? cartOwner})async{
    if(!_localConfigured)return;
    if(scope==null)throw StateError('Thiếu phạm vi lưu yêu cầu');
    await widget.client.localStore!.saveSalesRecovery(scope,kind==null?null:{'kind':kind,'key':key,'body':body,'auto':auto,if(kind=='create'&&cartId!=null)'cartId':cartId,if(kind=='create'&&cartOwner!=null)'cartOwner':cartOwner},expectedKey:previousKey);
  }
  String newKey()=>'sales-'+DateTime.now().microsecondsSinceEpoch.toString()+'-'+(++sequence).toString();
  bool can(String permission)=>widget.session.grants.any(
    (g)=>g.permission==permission&&g.branchId==branchId);
  String money(dynamic value)=>erpGroupedVndText(value);
  String stateOf(Map<String,dynamic> row){
    if(row['status']=='CANCELLED')return 'Đã hủy';
    if(row['versionStatus']=='DRAFT'&&row['status']=='CONFIRMED')return 'Đang điều chỉnh';
    return row['status']=='CONFIRMED'?'Đã xác nhận':'Đang lập';
  }
  void inform(String text,{bool error=false}){
    if(mounted)ErpToast.show(context,text,isError:error);
  }
  @override void initState(){
    super.initState();loadBranches();
    if(widget.client.localStore!=null){
      _syncLifecycle=AppLifecycleListener(onStateChange:(state){
        _foreground=state==AppLifecycleState.resumed;
        _syncDelay=15;_scheduleRecovery();
      });
      _scheduleRecovery();
    }
  }
  @override void didUpdateWidget(covariant SalesWorkspace old){
    super.didUpdateWidget(old);
    if(old.session.token!=widget.session.token||old.client!=widget.client){
      generation++;branches=[];orders=[];branchId=null;retryKeys.clear();
      pendingCreate=null;pendingCreateKey=null;pendingConfirm=null;
      pendingConfirmKey=null;pendingUpdate=null;pendingUpdateKey=null;
      pendingCreateAutoConfirm=false;localRecoveryBusy=false;localRecoveryBlocked=false;pendingNeedsReceipt=false;loadBranches();_syncDelay=15;_scheduleRecovery();
    }
  }
  @override void dispose(){generation++;_syncTimer?.cancel();_syncLifecycle?.dispose();search.dispose();super.dispose();}
  Future<void> loadBranches()async{
    final id=++generation;
    setState((){loading=true;error=null;});
    try{
      final result=await widget.client.salesCatalog(widget.session,'branches');
      final values=result.items;
      if(result.cached)inform('Đang dùng danh mục chi nhánh lưu trên máy; dữ liệu có thể cũ.');
      if(!mounted||generation!=id)return;
      final permitted=values.where((x)=>widget.session.grants.any((g)=>
        g.branchId==x['id']&&g.permission.startsWith('orders.'))).toList();
      setState((){
        branches=permitted;
        branchId=permitted.isEmpty?null:permitted.first['id'] as String;
      });
      if(branchId==null){
        setState((){error='Tài khoản chưa có quyền xem đơn hàng.';loading=false;});
      }else{await _restorePending();await reload();}
    }on ErpApiError catch(e){
      if(mounted&&generation==id)setState((){loading=false;error=e.message;});
    }catch(_){
      if(mounted&&generation==id)setState((){
        loading=false;error='Không tải được chi nhánh.';
      });
    }
  }
  Future<void> reload()async{
    final branch=branchId;if(branch==null)return;
    final id=++generation;
    setState((){loading=true;error=null;});
    try{
      final values=await widget.client.salesOrders(widget.session.token,branch,query:search.text);
      if(mounted&&generation==id)setState((){orders=values;loading=false;});
    }on ErpApiError catch(e){
      if(mounted&&generation==id)setState((){loading=false;error=e.message;});
    }catch(_){
      if(mounted&&generation==id)setState((){
        loading=false;error='Không tải được đơn hàng.';
      });
    }
  }
  Future<Map<String,dynamic>?> editForm({Map<String,dynamic>? order,bool copying=false,bool localDraft=false})async{
    final branch=branchId;if(branch==null)return null;
    final formScope=_localScope,formToken=widget.session.token,formSession=widget.session;
    bool cachedCatalog=false;
    Future<List<Map<String,dynamic>>> catalog(String resource,{String? query,String? itemId})async{
      if(!_sameScope(formToken,branch))throw const ErpApiError(401,'Phiên đã thay đổi.');
      final value=await widget.client.salesCatalog(formSession,resource,branchId:branch,query:query??'',itemId:itemId);
      if(value.cached)cachedCatalog=true;
      return value.items;
    }
    List<Map<String,dynamic>> customers,skus,lists,channels;
    try{
      final items=await Future.wait([
        catalog('customers'),
        catalog('r1/skus'),
        catalog('price-lists'),
        catalog('r1/channels'),
      ]);
      customers=items[0].where((x)=>x['active']==true).toList();
      skus=items[1].where((x)=>x['active']==true).toList();
      lists=items[2].where((x)=>x['active']==true).toList();
      channels=items[3].where((x)=>x['active']==true).toList();
    }on ErpApiError catch(e){inform(e.message,error:true);return null;}
    catch(_){inform('Không tải được danh mục bán hàng.',error:true);return null;}
    Map<String,dynamic>? entrySettings;
    try{
      final result=await widget.client.localSalesEntrySettings(formSession,branch);
      entrySettings=result.settings;if(result.cached)cachedCatalog=true;
    }on ErpApiError catch(e){
      if(e.status!=404&&e.status!=405){inform(e.message,error:true);return null;}
    }catch(_){inform('Không tải được thiết lập lập đơn.',error:true);return null;}
    final modern=entrySettings!=null;
    if(!modern){inform('Máy chủ chưa hỗ trợ giao nhận mới. Cần cập nhật máy chủ trước khi lập đơn.',error:true);return null;}
    bool canPrice()=>can(modern?'orders.price.override':'orders.update');
    bool canDiscount()=>can(modern?'orders.discount.override':'orders.update');
    bool canTax()=>can(modern?'orders.tax.override':'orders.update');
    final savedShipping=order?['shipping'] is Map
      ?Map<String,dynamic>.from(order!['shipping'] as Map):<String,dynamic>{};
    if(!modern&&savedShipping.isNotEmpty){
      inform('Không tải được thông tin giao nhận đã lưu.',error:true);return null;
    }
    if((customers.isEmpty&&!can('catalog.write')&&!modern)||skus.isEmpty||lists.isEmpty){
      if(mounted)setState(()=>missingCatalog=customers.isEmpty?'customers':
        skus.isEmpty?'products':'prices');
      inform('Hãy bổ sung dữ liệu bắt buộc trước khi lập đơn hàng.',error:true);
      return null;
    }
    if(mounted&&missingCatalog!=null)setState(()=>missingCatalog=null);
    // Optional to opening the order: master dropdowns become available only on
    // migrated 0017 and for actors granted catalog.read. Never fall back to
    // a free-text group name or block existing order entry.
    List<Map<String,dynamic>> customerGroups=[],customerRegions=[];
    if(can('catalog.write')&&can('catalog.read')){
      try{
        final masters=await Future.wait([
          widget.client.catalogDirectoryAll(widget.session.token,
            'customer-groups',branchId:branch),
          widget.client.catalogDirectoryAll(widget.session.token,
            'customer-regions',branchId:branch),
        ]);
        customerGroups=masters[0].where((x)=>x['active']!=false).toList();
        customerRegions=masters[1].where((x)=>x['active']!=false).toList();
      }on ErpApiError catch(_){
        // Creation can proceed with no group/region, but references must
        // never be guessed. Catalog customer creation remains migration gated.
      }
    }
    // Only warehouses granted to this actor may be offered for stock lookup.
    List<Map<String,dynamic>> stockWarehouses=[];
    if(can('inventory.read')){
      try{
        stockWarehouses=await catalog('warehouses');
      }catch(_){
        // An unavailable inventory service does not block order drafting.
      }
    }
    if(!_sameScope(formToken,branch))return null;
    if(cachedCatalog)inform('Danh mục trên máy có thể cũ. Chỉ máy chủ mới xác nhận giá và đơn hàng.');
    if(modern&&stockWarehouses.isEmpty){
      inform('Tài khoản chưa có quyền kho xuất hàng.',error:true);return null;
    }
    final deliveryLabels={'TRIP':'Giao thường','MANUAL':'Giao thủ công','PICKUP':'Khách lấy tại kho'};
    final collectionLabels={'COLLECT_ON_DELIVERY':'Thu khi giao','PREPAID':'Trả trước',
      'COLLECT_AFTER_DELIVERY':'Thu sau giao','CREDIT_TERMS':'Công nợ theo hạn'};
    var deliveryChoice=(savedShipping['deliveryChoice']??entrySettings['deliveryChoice']??'TRIP').toString();
    var collectionPolicy=(savedShipping['collectionPolicy']??'COLLECT_ON_DELIVERY').toString();
    var customerMode=(savedShipping['customerMode']??'EXISTING').toString();
    String? locationId=savedShipping['customerLocationId'] as String?;
    var deliveryAddress=(savedShipping['deliveryAddress']??'').toString();
    var deliveryDate=(savedShipping['requestedDeliveryDate']??'').toString();
    var walkInName=(savedShipping['walkInName']??'').toString();
    var walkInPhone=(savedShipping['walkInPhone']??'').toString();
    var rememberDelivery=savedShipping['rememberDeliveryChoice']==true,walkInBusy=false,locationBusy=false;
    int locationGeneration=0,addressGeneration=0,addressEditGeneration=0,customerChoiceGeneration=0;
    List<Map<String,dynamic>> locations=[];
    Map<String,dynamic>? walkInCustomer=entrySettings['walkInCustomer'] is Map
      ?Map<String,dynamic>.from(entrySettings['walkInCustomer'] as Map):null;
    String? customer=(order?['customerId'] as String?) ??
      (localDraft?null:(customers.length==1?customers.single['id'] as String:null));
    if(savedShipping.isEmpty&&customer!=null){
      deliveryAddress=(customers.where((x)=>x['id']==customer).firstOrNull?['deliveryAddress']??'').toString();
    }
    String? list=(order?['priceListId'] as String?) ??
      (localDraft?null:(lists.length==1?lists.single['id'] as String:null));
    String? channel=order?['channelId'] as String?;
    bool listManuallySelected=localDraft ? (order?['localListManuallySelected']==true) : order!=null;
    int listResolveGeneration=0;
    final note=TextEditingController(text:order?['note'] as String? ?? '');
    final lines=<_OrderLine>[];
    final localDiscount=localDraft&&order?['localDocumentDiscount'] is Map?order!['localDocumentDiscount'] as Map:const {};
    var documentDiscountMode=(localDiscount['mode']??'NONE').toString(),documentDiscountValue=(localDiscount['value']??'0').toString(),documentDiscountReason=(localDiscount['reason']??'').toString(),overrideReason=localDraft?(order?['localOverrideReason']??'').toString():'';
    if(localDraft&&savedShipping['warehouseId']!=null&&!stockWarehouses.any((w)=>w['id']==savedShipping['warehouseId'])){
      note.dispose();inform('Kho của giỏ đã lưu không còn trong phạm vi được cấp. Không tự đổi kho.',error:true);return null;
    }
    if(localDraft){
      // Resolve persisted IDs against authorized server data, not a truncated first page.
      Future<bool> resolveSaved(String resource,String? id,List<Map<String,dynamic>> target)async{
        if(id==null||target.any((x)=>x['id']==id))return true;
        final matches=(await catalog(resource,itemId:id)).where((x)=>x['id']==id&&x['active']==true).toList();
        if(matches.length!=1)return false;
        target.add(matches.single);return true;
      }
      try{
        final validCustomer=customerMode=='WALK_IN'
          ? (customer!=null && walkInCustomer?['id']==customer && walkInCustomer?['active']!=false)
          : await resolveSaved('customers',customer,customers);
        final validList=await resolveSaved('price-lists',list,lists);
        if(!_sameScope(formToken,branch)){note.dispose();return null;}
        if(!validCustomer||!validList){
          note.dispose();inform('Khách hàng hoặc bảng giá đã lưu không còn khả dụng. Giỏ vẫn được giữ trên máy.',error:true);return null;
        }
      }catch(_){note.dispose();inform('Chưa đối chiếu được khách hàng hoặc bảng giá đã lưu. Giỏ vẫn được giữ trên máy.',error:true);return null;}
    }
    if(order?['lines'] is List){
      for(final v in order!['lines'] as List<dynamic>){
        final row=Map<String,dynamic>.from(v as Map);
        // B1 lines were sold in the product's base unit. Never substitute
        // a carton or an unrelated product when a catalog page is incomplete.
        final legacyProduct=row['productId'] as String?;
        final priorSku=row['sellSkuId'] as String?;
        var matching=skus.where((x)=>priorSku!=null
          ? x['id']==priorSku
          : x['productId']==legacyProduct && x['isBase']==true &&
            x['unitCode']==row['unitCode']).toList();
        if(matching.length!=1){
          // The initial page contains only 100 SKUs. Resolve a historical
          // line by its exact persisted SKU instead of silently replacing it.
          List<Map<String,dynamic>> found;
          try{
            found=priorSku==null
              ?await catalog('r1/skus',query:(row['sku']??row['code']??'').toString())
              :await catalog('r1/skus',itemId:priorSku);
          }catch(_){found=[];}
          matching=found.where((x)=>priorSku!=null
            ? x['id']==priorSku
            : x['productId']==legacyProduct&&x['isBase']==true&&
              x['unitCode']==row['unitCode']).toList();
          for(final sku in matching){
            if(!skus.any((x)=>x['id']==sku['id']))skus.add(sku);
          }
        }
        if(matching.length!=1){
          for(final line in lines){line.dispose();}
          note.dispose();
          inform('Không tìm thấy đúng SKU và đơn vị của dòng hàng cũ. Hãy tìm đủ sản phẩm trong danh mục trước khi sửa.',error:true);
          return null;
        }
        final line=_OrderLine(matching.single['id'] as String,row['quantity'].toString());
        final snapshot=row['priceSnapshot'];
        if(!copying&&snapshot is Map&&snapshot['documentDiscount'] is Map){
          final d=snapshot['documentDiscount'] as Map;
          documentDiscountMode=(d['mode']??'NONE').toString();
          documentDiscountValue=erpGroupedDecimalText(d['value']);
          documentDiscountReason=(d['reason']??'').toString();
        }
        if(!copying&&snapshot is Map&&snapshot['manualOverride']==true){
          if(snapshot['manualPriceOverride']!=false)line.unitPrice.text=erpGroupedDecimalText(row['unitPrice']);
          line.discountMode=(snapshot['discountMode']??'PERCENT').toString();
          line.taxMode=(snapshot['taxMode']??'EXCLUSIVE').toString();
          line.discountRate.text=erpGroupedDecimalText(line.discountMode=='PERCENT'?row['discountRate']:snapshot['discountValue']);
          line.taxRate.text=erpGroupedDecimalText(row['taxRate']);
          line.discountEdited=snapshot['discountOverride']==true&&(localDraft||snapshot['restoreOverride']==true||
            (line.discountMode!='PERCENT'||RegExp('[1-9]').hasMatch(line.discountRate.text)));
          line.taxEdited=snapshot['taxOverride']==true&&(localDraft||snapshot['restoreOverride']==true||
            (line.taxMode!='EXCLUSIVE'||RegExp('[1-9]').hasMatch(line.taxRate.text)));
          if(snapshot['discountOverride']==null)line.discountEdited=RegExp('[1-9]').hasMatch(line.discountRate.text);
          if(snapshot['taxOverride']==null)line.taxEdited=RegExp('[1-9]').hasMatch(line.taxRate.text);
          line.overrideReason=(snapshot['overrideReason']??'').toString();
        }
        lines.add(line);
      }
    }
    // Never silently preselect the first product in a sales document.
    // New orders must add an explicit SKU from search/barcode.

    String? formError,quotedStamp,previewGrandTotal,previewSubtotal,
      previewDiscountTotal,previewTaxTotal;
    List<Map<String,dynamic>>? quotes;
    bool quoteBusy=false;
    Timer? quoteDebounce;
    int quoteGeneration=0;
    final quantityPattern=RegExp(r'^(?:0|[1-9]\d{0,8})(?:\.\d{1,3})?$');
    bool validLines()=>lines.isNotEmpty&&
      lines.every((x)=>quantityPattern.hasMatch(erpNumberCanonical(x.quantity.text))&&
      RegExp('[1-9]').hasMatch(x.quantity.text)&&
      (x.unitPrice.text.trim().isEmpty||
        RegExp(r'^\d{1,13}(?:\.\d{1,4})?$').hasMatch(erpNumberCanonical(x.unitPrice.text)))&&
      (x.discountMode=='PERCENT'?RegExp(r'^\d{1,3}(?:\.\d{1,2})?$'):RegExp(r'^\d{1,13}(?:\.\d{1,4})?$')).hasMatch(erpNumberCanonical(x.discountRate.text))&&
      RegExp(r'^\d{1,3}(?:\.\d{1,2})?$').hasMatch(erpNumberCanonical(x.taxRate.text)));
    bool documentDiscountActive()=>documentDiscountMode!='NONE'&&RegExp('[1-9]').hasMatch(documentDiscountValue);
    Map<String,dynamic> documentDiscount()=>{'mode':documentDiscountMode,'value':erpNumberCanonical(documentDiscountValue),'reason':documentDiscountReason.trim()};
    bool adjusted(_OrderLine line)=>line.unitPrice.text.trim().isNotEmpty||line.discountEdited||line.taxEdited;
    bool hasManualPrice()=>lines.any(adjusted);
    Map<String,dynamic> adjustments(_OrderLine line){
      final price=line.unitPrice.text.trim().isNotEmpty;
      return {
        if(price)'unitPrice':erpNumberCanonical(line.unitPrice.text),
        if((!modern&&price)||(modern&&line.discountEdited))...{
          if(line.discountMode=='PERCENT')'discountRate':erpNumberCanonical(line.discountRate.text)
          else ...{'discountMode':line.discountMode,'discountValue':erpNumberCanonical(line.discountRate.text)},
        },
        if((!modern&&price)||(modern&&line.taxEdited))...{
          'taxRate':erpNumberCanonical(line.taxRate.text),
          if(line.taxMode!='EXCLUSIVE')'taxMode':line.taxMode,
        },
      };
    }
    String stamp()=>[
      customer??'',list??'',channel??'',documentDiscountMode,erpNumberCanonical(documentDiscountValue),
      ...lines.map((x)=>[x.sellSkuId,erpNumberCanonical(x.quantity.text),
        erpNumberCanonical(x.unitPrice.text),erpNumberCanonical(x.discountRate.text),
        erpNumberCanonical(x.taxRate.text),x.discountMode,x.taxMode,x.discountEdited,x.taxEdited].join(':')),
    ].join('|');
    final originalStamp=stamp(),originalNote=note.text.trim();
    void invalidate(StateSetter refresh){
      quoteDebounce?.cancel();
      quoteGeneration++;
      refresh((){
      for(final line in lines){
        final manual=line.unitPrice.text;
        if(line.displayedPrice.text!=manual){line.displayedPrice.text=manual;}
      }
      quotes=null;quotedStamp=null;previewGrandTotal=null;previewSubtotal=null;
      previewDiscountTotal=null;previewTaxTotal=null;formError=null;quoteBusy=false;
      });
    }
    Future<void> preview(BuildContext context,StateSetter refresh)async{
      if(customer==null||list==null||!validLines()){
        refresh(()=>formError='Hãy chọn khách hàng, SKU và nhập số lượng hợp lệ.');
        return;
      }
      final before=stamp();
      final request=++quoteGeneration;
      refresh((){quoteBusy=true;formError=null;quotes=null;quotedStamp=null;
        previewGrandTotal=null;});
      try{
        final basket=await widget.client.salesPricePreview(widget.session.token,{
          'branchId':branch,'customerId':customer,'priceListId':list,
          if(channel!=null)'channelId':channel,
          if(modern&&documentDiscountActive())'documentDiscount':documentDiscount(),
          'lines':lines.map((line)=>{'sellSkuId':line.sellSkuId,
            'quantity':erpNumberCanonical(line.quantity.text),
            ...adjustments(line)}).toList(),
        });
        if(!context.mounted||request!=quoteGeneration)return;
        final quoted=(basket['lines'] as List<dynamic>)
          .map((x)=>Map<String,dynamic>.from(x as Map)).toList();
        if(quoted.length!=lines.length)throw const FormatException('QUOTE_LINES');
        refresh((){
          if(before==stamp()){
            quotes=quoted;
            for(var i=0;i<lines.length;i++){
              final line=lines[i];
              final value=line.unitPrice.text.isEmpty?erpGroupedDecimalText(quoted[i]['unitPrice']):line.unitPrice.text;
              if(line.displayedPrice.text!=value){
                line.displayedPrice.value=TextEditingValue(text:value,selection:TextSelection(baseOffset:0,extentOffset:value.length));
              }
            }
            previewGrandTotal=basket['grandTotal'] as String?;
            previewSubtotal=basket['subtotal'] as String?;
            previewDiscountTotal=basket['discountTotal'] as String?;
            previewTaxTotal=basket['taxTotal'] as String?;
            quotedStamp=before;
          }
          quoteBusy=false;
        });
      }on ErpApiError catch(e){
        if(context.mounted&&request==quoteGeneration)refresh((){
          quoteBusy=false;formError=e.message;
        });
      }catch(_){
        if(context.mounted&&request==quoteGeneration)refresh((){
          quoteBusy=false;formError='Không tra được giá. Vui lòng thử lại.';
        });
      }
    }

    void scheduleQuote(BuildContext ctx,StateSetter refresh){
      quoteDebounce?.cancel();
      if(customer==null||list==null||!validLines())return;
      final expected=quoteGeneration;
      quoteDebounce=Timer(const Duration(milliseconds:260),(){
        if(ctx.mounted&&expected==quoteGeneration)preview(ctx,refresh);
      });
    }

    final skuSearch=TextEditingController();
    final customerSearch=TextEditingController();
    final newCustomerCode=TextEditingController();
    final newCustomerName=TextEditingController();
    final newCustomerPhone=TextEditingController();
    final newCustomerAddress=TextEditingController();
    final newCustomerPaymentTerms=TextEditingController(text:'0');
    String? newCustomerGroupId,newCustomerRegionId;
    const quickCustomerKind='sales.customer.quick';
    final savedQuickCustomer=widget.client.pendingR1(
      widget.session.actorId,branch,quickCustomerKind);
    bool quickCustomerVisible=savedQuickCustomer!=null,quickCustomerBusy=false;
    Map<String,dynamic>? pendingQuickCustomer=savedQuickCustomer?.payload;
    String? pendingQuickCustomerKey=savedQuickCustomer?.key;
    if(pendingQuickCustomer!=null){
      newCustomerCode.text=pendingQuickCustomer['code']?.toString()??'';
      newCustomerName.text=pendingQuickCustomer['name']?.toString()??'';
      newCustomerPhone.text=pendingQuickCustomer['phone']?.toString()??'';
      newCustomerAddress.text=pendingQuickCustomer['deliveryAddress']?.toString()??'';
      newCustomerGroupId=pendingQuickCustomer['customerGroupId'] as String?;
      newCustomerRegionId=pendingQuickCustomer['customerRegionId'] as String?;
      newCustomerPaymentTerms.text=pendingQuickCustomer['paymentTermsDays']?.toString()??'0';
    }
    final skuFocus=FocusNode();
    final customerFocus=FocusNode();
    Timer? skuDebounce,customerDebounce;
    List<Map<String,dynamic>> skuMatches=[],skuAllMatches=[];
    List<Map<String,dynamic>> customerMatches=[];
    int selectedSkuIndex=0,skuSearchGeneration=0;
    bool skuExplicitSelection=false;
    int selectedCustomerIndex=0,customerSearchGeneration=0;
    String? skuResultsFor,skuSearchError;
    bool skuBusy=false,customerBusy=false,starterUntouched=order==null;
    bool skuPriceBusy=false,stockBusy=false,stockLoaded=false,stockComplete=false,stockCached=false;
    String? stockError,warehouseId=stockWarehouses.any((w)=>w['id']==savedShipping['warehouseId'])
      ?savedShipping['warehouseId'] as String:stockWarehouses.length==1
      ?stockWarehouses.single['id'] as String:null;
    String shippingStamp()=>[warehouseId,deliveryChoice,collectionPolicy,customerMode,
      locationId,deliveryAddress,deliveryDate,walkInName,walkInPhone,rememberDelivery].join('|');
    final originalShippingStamp=shippingStamp();
    Future<void> loadLocations(BuildContext ctx,StateSetter refresh,{bool selectDefault=false})async{
      final run=++locationGeneration,id=customer,addressRun=addressGeneration,editRun=addressEditGeneration;
      if(!modern||id==null||customerMode=='WALK_IN')return;
      refresh(()=>locationBusy=true);
      try{
        final found=await widget.client.customerLocations(widget.session.token,branch,id);
        if(!ctx.mounted||run!=locationGeneration||customer!=id)return;
        refresh((){
          locations=found.where((x)=>x['active']!=false).toList();
          if(locationId!=null&&!locations.any((x)=>x['id']==locationId)){
            locations.add({'id':locationId,'name':'Địa chỉ đã lưu','address':deliveryAddress});
          }
          if(selectDefault&&addressRun==addressGeneration&&editRun==addressEditGeneration&&locationId==null){
            final preferred=locations.where((x)=>x['isDefault']==true).firstOrNull;
            if(preferred!=null){
              locationId=preferred['id'] as String;
              deliveryAddress=(preferred['address']??'').toString();
              addressGeneration++;
            }
          }
          locationBusy=false;
        });
      }catch(_){
        if(ctx.mounted&&run==locationGeneration)refresh((){
          locationBusy=false;
          if(locationId!=null)locations=[{'id':locationId,'name':'Địa chỉ đã lưu','address':deliveryAddress}];
        });
      }
    }
    int priceGeneration=0,stockGeneration=0;
    Map<String,Map<String,dynamic>> skuQuotes={},stockByProduct={};
    final variantsByProduct=<String,List<Map<String,dynamic>>>{};
    final variantLoading=<String>{},variantFailed=<String>{};
    Future<void> loadVariants(BuildContext ctx,StateSetter refresh,
        String productId)async{
      if(variantsByProduct.containsKey(productId)||
          variantLoading.contains(productId)||variantFailed.contains(productId))return;
      variantLoading.add(productId);
      try{
        final variantResult=await widget.client.localProductVariants(formSession,branch,productId);
        final all=variantResult.items;
        if(variantResult.cached)cachedCatalog=true;
        if(!ctx.mounted)return;
        refresh((){
          variantsByProduct[productId]=all.where((x)=>x['active']==true).toList();
          for(final variant in all){
            if(!skus.any((x)=>x['id']==variant['id']))skus.add(variant);
          }
          variantLoading.remove(productId);
        });
      }on ErpApiError catch(e){
        if(ctx.mounted)refresh((){
          variantLoading.remove(productId);variantFailed.add(productId);
          formError='Không tải đủ đơn vị bán cho sản phẩm: ${e.message}';
        });
      }catch(_){
        if(ctx.mounted)refresh((){
          variantLoading.remove(productId);variantFailed.add(productId);
          formError='Chưa tải được các đơn vị bán của sản phẩm.';
        });
      }
    }
    final skuResultScroll=ScrollController();
    String priceContext()=>[customer??'',list??'',channel??'',
      ...lines.map((line)=>line.sellSkuId+':'+erpNumberCanonical(line.quantity.text))].join('|');
    String skuQuantity(String id){
      for(final line in lines){
        if(line.sellSkuId==id&&quantityPattern.hasMatch(erpNumberCanonical(line.quantity.text))&&
            RegExp('[1-9]').hasMatch(line.quantity.text)){
          return erpNumberCanonical(line.quantity.text);
        }
      }
      return '1';
    }
    Future<void> loadPrices(BuildContext ctx,StateSetter refresh,
        List<Map<String,dynamic>> candidates)async{
      final run=++priceGeneration;
      final contextKey=priceContext();
      refresh((){
        skuQuotes={};
        skuPriceBusy=customer!=null&&list!=null&&candidates.isNotEmpty;
      });
      if(!skuPriceBusy)return;
      // Limit to 12 results and three concurrent lookups per batch.
      for(var i=0;i<candidates.length;i+=3){
        final found=await Future.wait(candidates.skip(i).take(3).map((sku)async{
          final id=sku['id'].toString();
          try{
            final q=await widget.client.salesSkuPrice(widget.session.token,
              branchId:branch,sellSkuId:id,customerId:customer!,
              priceListId:list!,channelId:channel,quantity:skuQuantity(id));
            return <String,dynamic>{'id':id,'quote':q};
          }catch(_){return <String,dynamic>{'id':id};}
        }));
        if(!ctx.mounted||run!=priceGeneration||contextKey!=priceContext())return;
        refresh((){
          for(final row in found){
            if(row['quote'] is Map<String,dynamic>){
              skuQuotes[row['id'] as String]=row['quote'] as Map<String,dynamic>;
            }
          }
        });
      }
      if(ctx.mounted&&run==priceGeneration)refresh(()=>skuPriceBusy=false);
    }
    Future<void> loadStock(BuildContext ctx,StateSetter refresh)async{
      final warehouse=warehouseId;
      final run=++stockGeneration;
      if(warehouse==null)return;
      refresh((){
        stockBusy=true;stockLoaded=false;stockComplete=false;stockError=null;stockCached=false;
        stockByProduct={};
      });
      final found=<String,Map<String,dynamic>>{};
      try{
        var complete=false,cached=false;
        for(var offset=0;offset<2000;offset+=100){
          final page=await widget.client.localStockPage(formSession,branch,warehouse,offset);
          cached=cached||page.cached;
          for(final row in page.items){found[row['productId'].toString()]=row;}
          if(!page.hasMore){complete=true;break;}
        }
        if(!ctx.mounted||run!=stockGeneration||warehouseId!=warehouse)return;
        refresh((){
          stockByProduct=found;stockComplete=complete&&!cached;
          stockCached=cached;stockLoaded=true;stockBusy=false;
          if(!complete)stockError='Tồn kho chưa được tải đầy đủ.';
        });
      }on ErpApiError catch(e){
        if(ctx.mounted&&run==stockGeneration)refresh((){
          stockBusy=false;stockLoaded=false;stockError=e.message;
        });
      }catch(_){
        if(ctx.mounted&&run==stockGeneration)refresh((){
          stockBusy=false;stockLoaded=false;stockError='Không tải được tồn kho.';
        });
      }
    }
    void pricingChanged(BuildContext ctx,StateSetter refresh){
      invalidate(refresh);priceGeneration++;
      scheduleQuote(ctx,refresh);
      if(skuMatches.isNotEmpty){
        loadPrices(ctx,refresh,skuMatches);
      }else{refresh((){skuQuotes={};skuPriceBusy=false;});}
    }
    // R1-C owns customer/group/channel -> price-list selection. Resolve the
    // selected list from the server once per commercial context, instead of
    // making the operator choose it on every new order.
    Future<void> resolveList(BuildContext ctx,StateSetter refresh,
        {String? sellSkuId})async{
      if(customer==null||listManuallySelected)return;
      final skuId=sellSkuId??(lines.isNotEmpty?lines.first.sellSkuId:
        skuMatches.isNotEmpty?skuMatches.first['id'].toString():null);
      if(skuId==null)return;
      final currentCustomer=customer!,currentChannel=channel;
      final run=++listResolveGeneration;
      if(lists.length==1){
        final only=lists.single['id'] as String;
        if(list!=only){list=only;pricingChanged(ctx,refresh);}
        return;
      }
      try{
        final result=await widget.client.r1PriceQuote(widget.session.token,{
          'branchId':branch,'sellSkuId':skuId,'customerId':currentCustomer,
          'quantity':'1',
          if(currentChannel!=null)'channelId':currentChannel,
        });
        if(!ctx.mounted||run!=listResolveGeneration||
            currentCustomer!=customer||currentChannel!=channel||
            listManuallySelected)return;
        final quote=Map<String,dynamic>.from(result['quote'] as Map);
        final chosen=quote['priceListId'] as String?;
        if(chosen==null)return;
        if(!lists.any((x)=>x['id']==chosen)){
          lists.add({'id':chosen,'code':quote['priceListCode'],
            'name':quote['priceListCode']??'Bảng giá tự chọn','active':true});
        }
        if(list!=chosen){
          list=chosen;
          pricingChanged(ctx,refresh);
        }else{
          if(skuMatches.isNotEmpty)loadPrices(ctx,refresh,skuMatches);
          scheduleQuote(ctx,refresh);
        }
      }on ErpApiError catch(e){
        if(ctx.mounted&&run==listResolveGeneration&&list==null){
          refresh(()=>formError='Chưa có bảng giá áp dụng cho khách này: ${e.message}');
        }
      }catch(_){
        if(ctx.mounted&&run==listResolveGeneration&&list==null){
          refresh(()=>formError='Chưa xác định bảng giá theo khách. '
            'Hãy kiểm tra phân bổ bảng giá hoặc chọn thủ công.');
        }
      }
    }
    void customerPricingChanged(BuildContext ctx,StateSetter refresh){
      listResolveGeneration++;
      listManuallySelected=false;
      if(lists.length>1)list=null;
      pricingChanged(ctx,refresh);
      resolveList(ctx,refresh);
    }
    void keepSkuVisible(){
      WidgetsBinding.instance.addPostFrameCallback((_){
        if(!skuResultScroll.hasClients)return;
        final y=(selectedSkuIndex*48.0).clamp(
          0.0,skuResultScroll.position.maxScrollExtent);
        skuResultScroll.animateTo(y.toDouble(),
          duration:const Duration(milliseconds:130),curve:Curves.easeOut);
      });
    }
    String customerLabel(Map<String,dynamic> x)=>
      (x['code']??'').toString()+' · '+(x['name']??'').toString();
    String selectedCustomer()=>customerMode=='WALK_IN'?'Khách lẻ':customers.where((x)=>x['id']==customer).isEmpty
      ? 'Chọn khách hàng'
      :customerLabel(customers.firstWhere((x)=>x['id']==customer));
    void chooseSku(BuildContext ctx,Map<String,dynamic> item,StateSetter refresh){
      final id=item['id'] as String;
      if(lines.length>=30){refresh(()=>formError='Tối đa 30 dòng hàng.');return;}
      if(!skus.any((x)=>x['id']==id))skus.add(item);
      loadVariants(ctx,refresh,item['productId'].toString());
      if(lines.any((x)=>x.sellSkuId==id)&&!starterUntouched){
        refresh(()=>formError='SKU đã có trong đơn. Hãy sửa số lượng tại dòng tương ứng.');
        return;
      }
      if(starterUntouched&&lines.length==1){
        lines.first.sellSkuId=id;
      }else{
        lines.add(_OrderLine(id,'1'));
      }
      starterUntouched=false;
      skuSearch.clear();
      skuSearchGeneration++;priceGeneration++;
      skuResultsFor=null;skuSearchError=null;
      skuMatches=[];skuAllMatches=[];skuExplicitSelection=false;skuQuotes={};
      invalidate(refresh);
      if(!listManuallySelected&&lists.length>1){
        resolveList(ctx,refresh,sellSkuId:id);
      }else{scheduleQuote(ctx,refresh);}
      // Fast entry: select the new row's quantity, not the search field.
      final selectedLine=lines.last;
      WidgetsBinding.instance.addPostFrameCallback((_){
        if(selectedLine.quantityFocus.context==null)return;
        selectedLine.quantityFocus.requestFocus();
        selectedLine.quantity.selection=TextSelection(
          baseOffset:0,extentOffset:selectedLine.quantity.text.length);
      });
    }
    // An exact scanned SKU/barcode wins over a substring match unless the
    // operator deliberately moved the highlighted row by keyboard or mouse.
    // Inspect the complete returned page, not only the 12 visible suggestions.
    void chooseEnteredSku(BuildContext ctx,StateSetter refresh){
      if(skuMatches.isEmpty||skuResultsFor!=skuSearch.text.trim())return;
      final term=skuSearch.text.trim().toLowerCase();
      if(!skuExplicitSelection){
        final exact=skuAllMatches.where((item)=>
          (item['code']??item['sku']??'').toString().toLowerCase()==term||
          (item['barcode']??'').toString().toLowerCase()==term).toList();
        if(exact.length==1){chooseSku(ctx,exact.single,refresh);return;}
        if(exact.length>1){
          refresh(()=>formError='Mã hàng không duy nhất. Hãy chọn đúng SKU.');
          return;
        }
      }
      chooseSku(ctx,skuMatches[selectedSkuIndex],refresh);
    }
    Future<void> findSkus(BuildContext ctx,StateSetter refresh,{bool addOnEnter=false})async{
      final term=skuSearch.text.trim();
      if(term.isEmpty)return;
      final request=++skuSearchGeneration;
      priceGeneration++;
      refresh((){
        skuBusy=true;skuSearchError=null;skuMatches=[];skuAllMatches=[];
        skuExplicitSelection=false;skuQuotes={};
        skuPriceBusy=false;skuResultsFor=null;selectedSkuIndex=0;
      });
      try{
        final found=await catalog('r1/skus',query:term);
        if(!ctx.mounted||skuSearch.text.trim()!=term||
            request!=skuSearchGeneration)return;
        final available=found.where((sku)=>sku['active']==true).toList();
        final visible=available.take(12).toList();
        refresh((){
          skuBusy=false;skuMatches=visible;skuAllMatches=available;
          skuResultsFor=term;
          if(visible.isEmpty)skuSearchError='Không tìm thấy SKU đang bán.';
        });
        if(addOnEnter&&available.isNotEmpty){
          final exact=available.where((sku)=>
            (sku['code']??sku['sku']??'').toString().toLowerCase()==term.toLowerCase()||
            (sku['barcode']??'').toString().toLowerCase()==term.toLowerCase()).toList();
          if(exact.length==1){chooseSku(ctx,exact.single,refresh);return;}
          if(available.length==1){chooseSku(ctx,available.single,refresh);return;}
        }
        if(visible.isNotEmpty){
          if(customer!=null&&!listManuallySelected&&list==null&&lists.length>1){
            resolveList(ctx,refresh,sellSkuId:visible.first['id'].toString());
          }else{loadPrices(ctx,refresh,visible);}
          if(warehouseId!=null&&!stockLoaded&&!stockBusy)loadStock(ctx,refresh);
        }
      }on ErpApiError catch(e){
        if(ctx.mounted&&request==skuSearchGeneration)refresh((){
          skuBusy=false;skuSearchError=e.message;
        });
      }catch(_){
        if(ctx.mounted&&request==skuSearchGeneration)refresh((){
          skuBusy=false;skuSearchError='Không tìm được sản phẩm. Thử lại.';
        });
      }
    }
    void chooseCustomer(BuildContext ctx,Map<String,dynamic> item,StateSetter refresh){
      if(!customers.any((x)=>x['id']==item['id']))customers.add(item);
      customerChoiceGeneration++;locationBusy=false;
      customer=item['id'] as String;
      customerMode='EXISTING';walkInName='';walkInPhone='';
      locationId=null;locations=[];locationGeneration++;addressGeneration++;
      deliveryAddress=(item['deliveryAddress']??'').toString();
      customerSearch.clear();customerMatches=[];
      customerSearchGeneration++;
      customerPricingChanged(ctx,refresh);
      if(modern)loadLocations(ctx,refresh,selectDefault:true);
      skuFocus.requestFocus();
    }
    Future<void> chooseWalkIn(BuildContext ctx,StateSetter refresh)async{
      if(walkInBusy)return;
      final choice=++customerChoiceGeneration;
      refresh(()=>walkInBusy=true);
      const kind='sales.walk-in.prepare';
      final actor=widget.session.actorId;
      final pending=widget.client.pendingR1(actor,branch,kind);
      final key=pending?.key??newKey();
      try{
        if(walkInCustomer==null){
          widget.client.retainR1(actor,branch,kind,{'branchId':branch},key);
          walkInCustomer=await widget.client.prepareSalesWalkIn(widget.session.token,branch,key:key);
          widget.client.clearR1(actor,branch,kind);
        }
        if(!ctx.mounted||choice!=customerChoiceGeneration||widget.session.actorId!=actor||branchId!=branch)return;
        locationBusy=false;
        customer=walkInCustomer!['id'] as String;
        customerMode='WALK_IN';deliveryChoice='PICKUP';
        if(!['PREPAID','COLLECT_ON_DELIVERY'].contains(collectionPolicy))collectionPolicy='COLLECT_ON_DELIVERY';
        locationId=null;locations=[];deliveryAddress='';locationGeneration++;addressGeneration++;
        customerSearch.clear();customerMatches=[];customerSearchGeneration++;
        customerPricingChanged(ctx,refresh);skuFocus.requestFocus();
      }on ErpApiError catch(e){
        if(ctx.mounted)refresh(()=>formError=e.message);
      }catch(_){
        if(ctx.mounted)refresh(()=>formError='Chưa xác minh được khách lẻ. Bấm lại để kiểm tra.');
      }finally{
        if(ctx.mounted)refresh(()=>walkInBusy=false);
      }
    }
    Future<void> createQuickCustomer(BuildContext ctx,StateSetter refresh)async{
      if(!can('catalog.write')||quickCustomerBusy)return;
      if(pendingQuickCustomer==null){
        final code=newCustomerCode.text.trim().toUpperCase();
        final name=newCustomerName.text.trim();
        if(code.isEmpty||name.isEmpty){
          refresh(()=>formError='Cần nhập mã và tên khách hàng mới.');
          return;
        }
        final days=int.tryParse(newCustomerPaymentTerms.text.trim());
        if(days==null||days<0||days>365){
          refresh(()=>formError='Số ngày thanh toán phải từ 0 đến 365.');
          return;
        }
        final payload=<String,dynamic>{
          'branchId':branch,'code':code,'name':name,'paymentTermsDays':days,
        };
        if(newCustomerGroupId!=null)
          payload['customerGroupId']=newCustomerGroupId;
        if(newCustomerRegionId!=null)
          payload['customerRegionId']=newCustomerRegionId;
        if(newCustomerPhone.text.trim().isNotEmpty){
          payload['phone']=newCustomerPhone.text.trim();
        }
        if(newCustomerAddress.text.trim().isNotEmpty){
          payload['deliveryAddress']=newCustomerAddress.text.trim();
        }
        pendingQuickCustomer=payload;
        pendingQuickCustomerKey=newKey();
        widget.client.retainR1(widget.session.actorId,branch,
          quickCustomerKind,payload,pendingQuickCustomerKey!);
      }
      refresh(()=>quickCustomerBusy=true);
      try{
        // Repeat the same payload/key only; a lost ACK must not create a second customer.
        final result=await widget.client.createCatalogWithKey(
          widget.session.token,'customers',pendingQuickCustomer!,
          key:pendingQuickCustomerKey!);
        if(!ctx.mounted)return;
        final saved=<String,dynamic>{
          ...pendingQuickCustomer!,
          'id':result['id'],'code':result['code'],'name':result['name'],
          'active':true,'paymentTermsDays':
            pendingQuickCustomer!['paymentTermsDays']??0,
        };
        chooseCustomer(ctx,saved,refresh);
        widget.client.clearR1(widget.session.actorId,branch,quickCustomerKind);
        refresh((){
          quickCustomerVisible=false;
          quickCustomerBusy=false;
          pendingQuickCustomer=null;
          pendingQuickCustomerKey=null;
        });
      }on ErpApiError catch(e){
        if(!ctx.mounted)return;
        refresh((){
          quickCustomerBusy=false;
          formError=e.message;
          // Unknown commit outcome: keep the exact body/key for a safe retry.
          // Auth failures do not prove the earlier commit rolled back.
          // Retain the same request/key across reauthentication and form reopen.
          final definite=e.status>=400&&e.status<500&&
            e.status!=401&&e.status!=403&&e.status!=408&&
            e.code!='UNKNOWN_OUTCOME';
          if(definite){
            widget.client.clearR1(widget.session.actorId,branch,quickCustomerKind);
            pendingQuickCustomer=null;
            pendingQuickCustomerKey=null;
          }else{
            formError=e.status==401||e.status==403
              ?'Chưa xác minh tạo khách vì phiên hoặc quyền đã thay đổi. Yêu cầu được giữ để kiểm tra lại khi có quyền.'
              :'Chưa xác minh được kết quả tạo khách. Bấm kiểm tra lại để gửi cùng mã yêu cầu.';
          }
        });
      }catch(_){
        if(ctx.mounted)refresh((){
          quickCustomerBusy=false;
          formError='Chưa xác minh được kết quả tạo khách. Bấm kiểm tra lại để gửi cùng mã yêu cầu.';
        });
      }
    }
    Future<void> findCustomers(BuildContext ctx,StateSetter refresh)async{
      final term=customerSearch.text.trim();
      if(term.isEmpty){refresh((){customerMatches=customers.take(12).toList();selectedCustomerIndex=0;});return;}
      final run=++customerSearchGeneration;
      refresh(()=>customerBusy=true);
      try{
        final values=await catalog('customers',query:term);
        if(!ctx.mounted||run!=customerSearchGeneration||
          term!=customerSearch.text.trim())return;
        refresh((){
          customerBusy=false;selectedCustomerIndex=0;
          customerMatches=values.where((x)=>x['active']==true).toList();
        });
      }on ErpApiError catch(e){
        if(ctx.mounted&&run==customerSearchGeneration)refresh((){
          customerBusy=false;formError=e.message;
        });
      }catch(_){
        if(ctx.mounted&&run==customerSearchGeneration)refresh((){
          customerBusy=false;formError='Không tìm được khách hàng.';
        });
      }
    }
    String totalQuoted()=>previewGrandTotal??'0';
    bool draftSaving=false,finishDraft=false,draftWriteFailed=false;
    final autoDraft=formScope!=null&&(order==null||copying||localDraft);
    final cartId=autoDraft?(localDraft&&(order?['localCartId'] is String)?order!['localCartId'] as String:newKey()):null;
    final cartOwner=autoDraft?(localDraft&&(order?['localCartOwner'] is String)?order!['localCartOwner'] as String:newKey()):null;

    Map<String,dynamic> draftSnapshot(){
      return <String,dynamic>{
          if(cartId!=null)'localCartId':cartId,
          if(cartOwner!=null)'localCartOwner':cartOwner,
          'customerId':customer,'priceListId':list,'channelId':channel,'note':note.text,
          'localDocumentDiscount':{'mode':documentDiscountMode,'value':documentDiscountValue,'reason':documentDiscountReason},
          'localOverrideReason':overrideReason,'localListManuallySelected':listManuallySelected,
          'shipping':{'warehouseId':warehouseId,'deliveryChoice':deliveryChoice,
            'collectionPolicy':collectionPolicy,'customerMode':customerMode,'customerLocationId':locationId,
            'deliveryAddress':deliveryAddress,'requestedDeliveryDate':deliveryDate,
            'walkInName':walkInName,'walkInPhone':walkInPhone,'rememberDeliveryChoice':rememberDelivery},
          'lines':lines.map((line){
            final sku=skus.where((x)=>x['id']==line.sellSkuId).firstOrNull;
            return <String,dynamic>{'sellSkuId':line.sellSkuId,'sku':sku?['code']??sku?['sku'],
              'quantity':erpNumberCanonical(line.quantity.text),
              'unitPrice':erpNumberCanonical(line.unitPrice.text),
              'discountRate':erpNumberCanonical(line.discountRate.text),'taxRate':erpNumberCanonical(line.taxRate.text),
              'priceSnapshot':{'manualOverride':adjusted(line),'manualPriceOverride':line.unitPrice.text.isNotEmpty,
                'discountMode':line.discountMode,'taxMode':line.taxMode,'discountOverride':line.discountEdited,
                'taxOverride':line.taxEdited,'discountValue':erpNumberCanonical(line.discountRate.text),
                'overrideReason':overrideReason.trim().isNotEmpty?overrideReason:line.overrideReason,
                if(documentDiscountActive())'documentDiscount':documentDiscount()}};
          }).toList(),
        };
    }
    final writer=formScope!=null&&cartId!=null?LocalCartWriter(widget.client.localStore!,formScope,cartId,cartOwner):null;
    String? lastSnapshot=autoDraft?jsonEncode(draftSnapshot()):null;
    Future<void> persistDraft({bool force=false})async{
      if(writer==null||finishDraft||!_sameScope(formToken,branch))return;
      final snapshot=draftSnapshot(),encoded=jsonEncode(snapshot);
      if(!force&&encoded==lastSnapshot&&!draftWriteFailed)return;
      lastSnapshot=encoded;
      try{
        await writer.save(snapshot);
        draftWriteFailed=false;
      }catch(_){draftWriteFailed=true;}
    }
    var cartPulse=0;
    final autoTimer=writer==null?null:Timer.periodic(const Duration(milliseconds:600),(_){
      if(!draftSaving)unawaited(persistDraft(force:(++cartPulse%7)==0));
    });
    final lifecycle=writer==null?null:AppLifecycleListener(onStateChange:(_){
      if(!draftSaving)unawaited(persistDraft());
    });
    Future<void> saveLocalDraft(BuildContext ctx,StateSetter refresh)async{
      if(writer==null||draftSaving||!_sameScope(formToken,branch))return;
      if(quickCustomerBusy||walkInBusy||pendingQuickCustomer!=null){
        refresh(()=>formError='Hãy đối chiếu yêu cầu tạo khách trước khi lưu trên máy.');return;
      }
      refresh(()=>draftSaving=true);
      try{
        await persistDraft(force:true);
        if(draftWriteFailed)throw StateError('Không lưu được giỏ');
        await writer.release();
        if(ctx.mounted&&_sameScope(formToken,branch)){
          finishDraft=true;
          inform('Đã lưu giỏ trên máy; chưa tạo đơn, chưa xuất kho.');
          Navigator.pop(ctx);
        }
      }catch(_){if(ctx.mounted)refresh(()=>formError='Không lưu được giỏ trên máy. Hãy giữ màn hình và thử lại.');}
      finally{if(ctx.mounted)refresh(()=>draftSaving=false);}
    }
    Future<void> submitForm(BuildContext ctx,StateSetter refresh,{required bool confirm})async{
      if(!_sameScope(formToken,branch)||draftSaving||quickCustomerBusy||pendingQuickCustomer!=null)return;
      if(customer==null||list==null||!validLines()){
        refresh(()=>formError='Kiểm tra khách hàng, SKU và số lượng từng dòng.');
        return;
      }
      if(quotes==null||quotedStamp!=stamp()){
        refresh(()=>formError='Giá chưa cập nhật xong. Kiểm tra kết nối hoặc bấm Làm mới giá.');
        return;
      }
      if(modern&&documentDiscountActive()&&documentDiscountReason.trim().isEmpty){
        refresh(()=>formError='Nhập lý do chiết khấu toàn đơn.');return;
      }
      if(modern&&(warehouseId==null||walkInBusy||
        (customerMode=='WALK_IN'&&walkInPhone.trim().isNotEmpty&&
          !RegExp(r'^\+?[0-9]{9,15}$').hasMatch(walkInPhone.trim())))){
        refresh(()=>formError='Chọn kho xuất và kiểm tra số điện thoại khách lẻ.');return;
      }
      if(writer!=null){
        final before=jsonEncode(draftSnapshot());
        refresh(()=>draftSaving=true);
        await persistDraft(force:true);
        if(!ctx.mounted||!_sameScope(formToken,branch))return;
        refresh(()=>draftSaving=false);
        if(draftWriteFailed){refresh(()=>formError='Không lưu được giỏ trước khi gửi. Vui lòng thử lại.');return;}
        if(before!=jsonEncode(draftSnapshot())||quotes==null||quotedStamp!=stamp()){
          refresh(()=>formError='Đơn vừa thay đổi. Hãy kiểm tra và lưu lại.');return;
        }
        finishDraft=true;
      }
      Navigator.pop(ctx,{
        'branchId':branch,'customerId':customer,'priceListId':list,
        if(modern)'shipping':{
          'warehouseId':warehouseId,'deliveryChoice':deliveryChoice,
          'collectionPolicy':collectionPolicy,'customerMode':customerMode,
          if(deliveryChoice!='PICKUP'&&locationId!=null)'customerLocationId':locationId,
          if(deliveryChoice!='PICKUP'&&deliveryAddress.trim().isNotEmpty)'deliveryAddress':deliveryAddress.trim(),
          if(deliveryDate.isNotEmpty)'requestedDeliveryDate':deliveryDate,
          if(customerMode=='WALK_IN'&&walkInName.trim().isNotEmpty)'walkInName':walkInName.trim(),
          if(customerMode=='WALK_IN'&&walkInPhone.trim().isNotEmpty)'walkInPhone':walkInPhone.trim(),
          if((order==null||copying||localDraft)&&rememberDelivery)'rememberDeliveryChoice':true,
        },
        if(channel!=null)'channelId':channel,
        if(modern&&documentDiscountActive())'documentDiscount':documentDiscount(),
        'note':note.text.trim(),
        'lines':lines.asMap().entries.map((entry)=>{
          'sellSkuId':entry.value.sellSkuId,
          'quantity':erpNumberCanonical(entry.value.quantity.text),
          'expectedPriceSignature':quotes![entry.key]['priceSignature'],
          ...adjustments(entry.value),
          if(modern&&adjusted(entry.value)&&(overrideReason.trim().isNotEmpty||entry.value.overrideReason.trim().isNotEmpty))
            'overrideReason':overrideReason.trim().isNotEmpty?overrideReason.trim():entry.value.overrideReason,
        }).toList(),
        '_confirmAfterSave':confirm,
        if(cartId!=null)'_localCartId':cartId,
        if(cartOwner!=null)'_localCartOwner':cartOwner,
      });
    }
    Future<void> requestClose(BuildContext ctx)async{
      if(draftSaving)return;
      if(quickCustomerBusy||walkInBusy){
        inform('Đang gửi yêu cầu tạo khách. Hãy kiểm tra kết quả trước khi đóng.',error:true);
        return;
      }
      if(pendingQuickCustomer!=null){
        // Persisted in the scoped client queue: leaving the form does not
        // discard the original payload/key if session rights are lost.
        inform('Yêu cầu tạo khách chưa xác minh đã được giữ lại. Mở lại đơn để kiểm tra khi có quyền.',error:true);
        Navigator.pop(ctx);
        return;
      }
      if(stamp()==originalStamp&&note.text.trim()==originalNote&&shippingStamp()==originalShippingStamp&&overrideReason.isEmpty){
        if(writer!=null){await persistDraft(force:true);if(draftWriteFailed){inform('Chưa lưu được giỏ.',error:true);return;}await writer.release();finishDraft=true;}
        if(ctx.mounted)Navigator.pop(ctx);return;
      }
      final discard=await showDialog<String>(context:ctx,builder:(confirmCtx)=>
        AlertDialog(
          title:const Text('Bỏ thay đổi đơn hàng?'),
          content:Text(writer!=null?'Giỏ được lưu trên máy. Anh/chị muốn giữ hay bỏ giỏ?':'Thông tin vừa nhập chưa được lưu.'),
          actions:[
            TextButton(onPressed:()=>Navigator.pop(confirmCtx,'continue'),
              child:const Text('Tiếp tục nhập')),
            if(writer!=null)TextButton(onPressed:()=>Navigator.pop(confirmCtx,'keep'),child:const Text('Giữ giỏ trên máy')),
            FilledButton(onPressed:()=>Navigator.pop(confirmCtx,'discard'),
              child:const Text('Bỏ thay đổi')),
          ],
        ));
      if(!ctx.mounted)return;
      if(writer!=null&&discard=='keep'){await persistDraft(force:true);if(!ctx.mounted)return;if(draftWriteFailed){inform('Không lưu được giỏ.',error:true);return;}try{await writer.release();}catch(_){inform('Giỏ đang mở ở cửa sổ khác.',error:true);return;}finishDraft=true;Navigator.pop(ctx);return;}
      if(discard=='discard'){
        if(writer!=null){finishDraft=true;try{await writer.clear();}catch(_){finishDraft=false;inform('Không xóa được giỏ.',error:true);return;}}
        if(ctx.mounted)Navigator.pop(ctx);
      }
    }
    var firstQuoteScheduled=false;
    try{
      final navigator=Navigator.of(context,rootNavigator:true);
      final route=DialogRoute<Map<String,dynamic>>(
        context:context,barrierDismissible:false,
        themes:InheritedTheme.capture(from:context,to:navigator.context),
        builder:(dialog)=>StatefulBuilder(builder:(ctx,refresh){
          final media=MediaQuery.sizeOf(ctx);
          // Editable SKU unit adds 32px to the desktop row: stack before overflow.
           final narrow=media.width<960;
          final width=media.width*0.96>1440?1440.0:media.width*0.96;
          final ready=quotes!=null&&quotedStamp==stamp();
          if(!firstQuoteScheduled){
            firstQuoteScheduled=true;
            WidgetsBinding.instance.addPostFrameCallback((_){
              if(ctx.mounted){
                scheduleQuote(ctx,refresh);
                if(modern&&customer!=null&&customerMode!='WALK_IN'){
                  loadLocations(ctx,refresh,selectDefault:savedShipping.isEmpty);
                }
              }
            });
          }
          return Focus(autofocus:true,onKeyEvent:(node,event){
            if(event is! KeyDownEvent&&event is! KeyRepeatEvent)return KeyEventResult.ignored;
            if(event.logicalKey==LogicalKeyboardKey.f3){
              skuFocus.requestFocus();
              skuSearch.selection=TextSelection(
                baseOffset:0,extentOffset:skuSearch.text.length);
              return KeyEventResult.handled;
            }
            if(event.logicalKey==LogicalKeyboardKey.f4){
              customerFocus.requestFocus();
              customerSearch.selection=TextSelection(
                baseOffset:0,extentOffset:customerSearch.text.length);
              return KeyEventResult.handled;
            }
            if(event.logicalKey==LogicalKeyboardKey.escape){
              if(skuMatches.isNotEmpty||skuBusy||skuSearchError!=null||
                   customerMatches.isNotEmpty){
                skuSearchGeneration++;priceGeneration++;
                refresh((){
                  skuMatches=[];skuAllMatches=[];skuExplicitSelection=false;
                  customerMatches=[];skuBusy=false;skuSearchError=null;
                });
              }else{requestClose(ctx);}
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },child:Dialog(
            insetPadding:const EdgeInsets.symmetric(horizontal:8,vertical:10),
            clipBehavior:Clip.antiAlias,
            child:SizedBox(width:width,height:media.height*0.94,
              child:Column(children:[
                Container(
                  padding:EdgeInsets.symmetric(horizontal:narrow?12:18,vertical:5),
                  color:ErpPalette.of(context).action,
                  child:Row(children:[
                    const Icon(Icons.receipt_long_outlined,color:Colors.white),
                    const SizedBox(width:10),
                    Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
                      Text(order==null||copying||localDraft?'Lập đơn bán hàng':'Điều chỉnh đơn bán hàng',
                        style:TextStyle(color:ErpPalette.of(context).onAction,fontSize:narrow?16:21,
                          fontWeight:FontWeight.w800)),
                    ])),
                    IconButton(tooltip:'Đóng',onPressed:()=>requestClose(ctx),
                      icon:const Icon(Icons.close,color:Colors.white)),
                  ]),
                ),
                Expanded(child:SingleChildScrollView(
                  padding:EdgeInsets.all(narrow?10:14),
                  child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
                    if(cachedCatalog)Text('Danh mục lưu trên máy có thể cũ. Phải tra giá máy chủ trước khi lưu đơn.',style:TextStyle(color:ErpPalette.of(context).warning)),
                    Wrap(
                      key:const ValueKey('sales-order-context'),
                      spacing:12,runSpacing:12,children:[
                        if(stockWarehouses.isNotEmpty)SizedBox(width:narrow?((width-40)/2).clamp(108.0,240.0).toDouble():200,child:DropdownButtonFormField<String>(
                        key:ValueKey('sales-stock-warehouse-'+warehouseId.toString()),
                        initialValue:warehouseId,isExpanded:true,menuMaxHeight:240,
                        decoration:const InputDecoration(labelText:'Kho xuất',isDense:true,contentPadding:EdgeInsets.symmetric(horizontal:10,vertical:8),
                          border:UnderlineInputBorder()),
                        items:[
                          const DropdownMenuItem<String>(value:null,
                            child:Text('Chọn kho xuất')),
                          ...stockWarehouses.map((w)=>DropdownMenuItem<String>(
                            value:w['id'] as String,
                            child:Text((w['name']??w['code']??'Kho').toString(),
                              overflow:TextOverflow.ellipsis))),
                        ],
                        onChanged:(id){
                          warehouseId=id;stockGeneration++;
                          refresh((){
                            stockByProduct={};stockBusy=false;
                            stockLoaded=false;stockComplete=false;stockError=null;
                          });
                          if(id!=null&&skuMatches.isNotEmpty)loadStock(ctx,refresh);
                        })),
                        SizedBox(width:narrow?((width-40)/2).clamp(108.0,240.0).toDouble():240,child:DropdownButtonFormField<String>(
                        key:ValueKey('sales-price-list-'+list.toString()),
                        initialValue:lists.any((x)=>x['id']==list)?list:null,
                        isExpanded:true,menuMaxHeight:240,decoration:InputDecoration(labelText:listManuallySelected?'Bảng giá · Chọn tay':'Bảng giá · Tự động',isDense:true,contentPadding:const EdgeInsets.symmetric(horizontal:10,vertical:8),border:const UnderlineInputBorder()),
                        hint:const Text('Theo khách hàng',overflow:TextOverflow.ellipsis),
                        items:[
                          const DropdownMenuItem<String>(value:null,child:Text('Tự động theo khách')),
                          ...lists.map((x)=>DropdownMenuItem<String>(
                            value:x['id'] as String,
                            child:Text((x['name']??'').toString(),overflow:TextOverflow.ellipsis))),
                        ],
                        onChanged:(v){
                          if(v==null){customerPricingChanged(ctx,refresh);return;}
                          listResolveGeneration++;listManuallySelected=true;
                          list=v;pricingChanged(ctx,refresh);})),
                        SizedBox(width:narrow?((width-40)/2).clamp(108.0,240.0).toDouble():200,child:DropdownButtonFormField<String>(
                        key:ValueKey('sales-channel-'+channel.toString()),
                        initialValue:channels.any((x)=>x['id']==channel)?channel:null,
                        isExpanded:true,menuMaxHeight:240,decoration:const InputDecoration(labelText:'Kênh bán',isDense:true,contentPadding:EdgeInsets.symmetric(horizontal:10,vertical:8),border:UnderlineInputBorder()),
                        items:[
                          const DropdownMenuItem<String>(value:null,child:Text('Bán trực tiếp')),
                          ...channels.map((x)=>DropdownMenuItem<String>(
                            value:x['id'] as String,
                            child:Text((x['name']??'').toString(),overflow:TextOverflow.ellipsis))),
                        ],onChanged:(v){channel=v;customerPricingChanged(ctx,refresh);})),
                        SizedBox(width:narrow?((width-40)/2).clamp(108.0,240.0).toDouble():190,child:DropdownButtonFormField<String>(
                          key:ValueKey('sales-delivery-$deliveryChoice'),initialValue:deliveryChoice,
                          isExpanded:true,decoration:const InputDecoration(labelText:'Giao nhận',isDense:true),
                          items:deliveryLabels.entries.map((e)=>DropdownMenuItem(value:e.key,child:Text(e.value,overflow:TextOverflow.ellipsis))).toList(),
                          onChanged:customerMode=='WALK_IN'?null:(v){if(v!=null)refresh(()=>deliveryChoice=v);})),
                        SizedBox(width:narrow?((width-40)/2).clamp(108.0,240.0).toDouble():190,child:DropdownButtonFormField<String>(
                          key:ValueKey('sales-collection-$collectionPolicy'),initialValue:collectionPolicy,
                          isExpanded:true,decoration:const InputDecoration(labelText:'Thanh toán',isDense:true),
                          items:collectionLabels.entries.where((e)=>customerMode!='WALK_IN'||
                            ['PREPAID','COLLECT_ON_DELIVERY'].contains(e.key))
                            .map((e)=>DropdownMenuItem(value:e.key,child:Text(e.value,overflow:TextOverflow.ellipsis))).toList(),
                          onChanged:(v){if(v!=null)refresh(()=>collectionPolicy=v);})),
                      ]),
                    const SizedBox(height:18),
                    Align(alignment:Alignment.centerLeft,child:ConstrainedBox(
                      constraints:const BoxConstraints(maxWidth:760),
                      child:Row(children:[
                        Expanded(child:Focus(onKeyEvent:(node,event){
                      if(event is! KeyDownEvent&&event is! KeyRepeatEvent||customerMatches.isEmpty)
                        return KeyEventResult.ignored;
                      if(event.logicalKey==LogicalKeyboardKey.arrowDown){
                        refresh(()=>selectedCustomerIndex=
                          (selectedCustomerIndex+1)%customerMatches.length);
                        return KeyEventResult.handled;
                      }
                      if(event.logicalKey==LogicalKeyboardKey.arrowUp){
                        refresh(()=>selectedCustomerIndex=
                          (selectedCustomerIndex-1+customerMatches.length)%customerMatches.length);
                        return KeyEventResult.handled;
                      }
                      if(event.logicalKey==LogicalKeyboardKey.enter){
                        chooseCustomer(ctx,customerMatches[selectedCustomerIndex],refresh);
                        return KeyEventResult.handled;
                      }
                      return KeyEventResult.ignored;
                    },child:TextField(
                      key:const ValueKey('sales-customer-search'),
                      controller:customerSearch,focusNode:customerFocus,
                      selectAllOnFocus:true,
                      onChanged:(_){
                        customerDebounce?.cancel();
                        customerSearchGeneration++;
                        refresh((){
                          customerMatches=[];selectedCustomerIndex=0;
                          customerBusy=false;
                        });
                        if(customerSearch.text.trim().isNotEmpty){
                          customerDebounce=Timer(const Duration(milliseconds:220),
                            (){if(ctx.mounted)findCustomers(ctx,refresh);});
                        }
                      },
                      onSubmitted:(_){
                        customerDebounce?.cancel();
                        if(customerMatches.isNotEmpty){
                          chooseCustomer(ctx,customerMatches[selectedCustomerIndex],refresh);
                        }else{findCustomers(ctx,refresh);}
                      },
                      decoration:InputDecoration(labelText:customer==null?'Khách hàng · F4':selectedCustomer()+' · F4',isDense:false,contentPadding:const EdgeInsets.symmetric(horizontal:10,vertical:14),
                        floatingLabelBehavior:FloatingLabelBehavior.always,
                        hintText:'Tìm mã hoặc tên',
                        prefixIcon:const Icon(Icons.person_search_outlined),
                        suffixIcon:IconButton(tooltip:'Tìm khách',onPressed:()=>findCustomers(ctx,refresh),
                          icon:const Icon(Icons.search)))))),
                        if(can('catalog.write'))TextButton.icon(
                        key:const ValueKey('sales-quick-customer-toggle'),
                        onPressed:quickCustomerBusy?null:()=>refresh((){
                          quickCustomerVisible=!quickCustomerVisible;
                        }),
                        icon:const Icon(Icons.person_add_alt_1_outlined),
                        label:const Text('Tạo khách nhanh')),
                      ]))),
                    if(quickCustomerVisible)Container(
                      key:const ValueKey('sales-quick-customer-panel'),
                      margin:const EdgeInsets.symmetric(vertical:8),
                      padding:const EdgeInsets.all(12),
                      decoration:BoxDecoration(
                        color:ErpPalette.of(context).mint,
                        border:Border.all(color:ErpPalette.of(context).border),
                        borderRadius:BorderRadius.circular(6)),
                      child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
                        const Text('Thêm khách hàng vào danh mục',
                          style:TextStyle(fontWeight:FontWeight.w700)),
                        const SizedBox(height:8),
                        Wrap(spacing:8,runSpacing:8,children:[
                          SizedBox(width:narrow?280:140,child:TextField(
                            key:const ValueKey('sales-quick-customer-code'),
                            controller:newCustomerCode,
                            enabled:!quickCustomerBusy&&pendingQuickCustomer==null,
                            decoration:const InputDecoration(labelText:'Mã khách *'))),
                          SizedBox(width:narrow?280:210,child:TextField(
                            key:const ValueKey('sales-quick-customer-name'),
                            controller:newCustomerName,
                            enabled:!quickCustomerBusy&&pendingQuickCustomer==null,
                            decoration:const InputDecoration(labelText:'Tên khách *'))),
                          SizedBox(width:narrow?280:170,child:TextField(
                            key:const ValueKey('sales-quick-customer-phone'),
                            controller:newCustomerPhone,
                            enabled:!quickCustomerBusy&&pendingQuickCustomer==null,
                            keyboardType:TextInputType.phone,
                            decoration:const InputDecoration(labelText:'Điện thoại'))),
                          SizedBox(width:narrow?280:240,child:TextField(
                            key:const ValueKey('sales-quick-customer-address'),
                            controller:newCustomerAddress,
                            enabled:!quickCustomerBusy&&pendingQuickCustomer==null,
                            decoration:const InputDecoration(labelText:'Địa chỉ giao'))),
                          SizedBox(width:narrow?280:210,child:
                            DropdownButtonFormField<String?>(
                              key:ValueKey('sales-quick-customer-group-$newCustomerGroupId'),
                              initialValue:customerGroups.any((x)=>x['id']==newCustomerGroupId)
                                ?newCustomerGroupId:null,
                              isExpanded:true,
                              decoration:const InputDecoration(labelText:'Nhóm khách hàng'),
                              items:[
                                const DropdownMenuItem<String?>(
                                  value:null,child:Text('Chưa phân nhóm')),
                                ...customerGroups.map((x)=>DropdownMenuItem<String?>(
                                  value:x['id'] as String,
                                  child:Text("${x['code']} · ${x['name']}",
                                    overflow:TextOverflow.ellipsis))),
                              ],
                              onChanged:quickCustomerBusy||pendingQuickCustomer!=null
                                ?null:(v)=>refresh(()=>newCustomerGroupId=v))),
                          SizedBox(width:narrow?280:210,child:
                            DropdownButtonFormField<String?>(
                              key:ValueKey('sales-quick-customer-region-$newCustomerRegionId'),
                              initialValue:customerRegions.any((x)=>x['id']==newCustomerRegionId)
                                ?newCustomerRegionId:null,
                              isExpanded:true,
                              decoration:const InputDecoration(labelText:'Khu vực bán hàng'),
                              items:[
                                const DropdownMenuItem<String?>(
                                  value:null,child:Text('Chưa phân khu vực')),
                                ...customerRegions.map((x)=>DropdownMenuItem<String?>(
                                  value:x['id'] as String,
                                  child:Text("${x['code']} · ${x['name']}",
                                    overflow:TextOverflow.ellipsis))),
                              ],
                              onChanged:quickCustomerBusy||pendingQuickCustomer!=null
                                ?null:(v)=>refresh(()=>newCustomerRegionId=v))),
                          SizedBox(width:narrow?280:160,child:TextField(
                            key:const ValueKey('sales-quick-customer-payment-terms'),
                            controller:newCustomerPaymentTerms,
                            enabled:!quickCustomerBusy&&pendingQuickCustomer==null,
                            keyboardType:TextInputType.number,
                            decoration:const InputDecoration(labelText:'Hạn thanh toán (ngày)'))),
                        ]),
                        const SizedBox(height:8),
                        Row(children:[
                          TextButton(
                            onPressed:quickCustomerBusy||pendingQuickCustomer!=null?null:
                              ()=>refresh(()=>quickCustomerVisible=false),
                            child:const Text('Đóng')),
                          const SizedBox(width:8),
                          FilledButton(
                            key:const ValueKey('sales-quick-customer-save'),
                            onPressed:quickCustomerBusy?null:
                              ()=>createQuickCustomer(ctx,refresh),
                            child:Text(quickCustomerBusy?'Đang lưu…':
                              pendingQuickCustomer==null?'Lưu khách hàng':'Kiểm tra lại')),
                        ]),
                      ])),
                    if(customerBusy)const LinearProgressIndicator(),
                    if(customerMatches.isNotEmpty)ConstrainedBox(
                      constraints:const BoxConstraints(maxHeight:148),
                      child:ListView(shrinkWrap:true,children:[
                        for(var i=0;i<customerMatches.length;i++)ListTile(
                          key:ValueKey('sales-customer-result-'+customerMatches[i]['id'].toString()),
                          selected:i==selectedCustomerIndex,dense:true,
                          title:Text(customerLabel(customerMatches[i]),
                            maxLines:1,overflow:TextOverflow.ellipsis),
                          subtitle:Text((customerMatches[i]['deliveryAddress']??
                            customerMatches[i]['phone']??'').toString(),
                            maxLines:1,overflow:TextOverflow.ellipsis),
                          onTap:()=>chooseCustomer(ctx,customerMatches[i],refresh),
                        ),
                      ]),
                    ),
                    const SizedBox(height:4),
                    if(modern)...[
                      Wrap(spacing:8,runSpacing:6,crossAxisAlignment:WrapCrossAlignment.center,children:[
                        OutlinedButton.icon(key:const ValueKey('sales-walk-in'),
                          onPressed:walkInBusy||quickCustomerBusy?null:()=>chooseWalkIn(ctx,refresh),
                          icon:const Icon(Icons.person_outline),label:Text(walkInBusy?'Đang kiểm tra':'Khách lẻ')),
                        OutlinedButton.icon(key:const ValueKey('sales-delivery-date'),
                          onPressed:()async{
                            final now=DateTime.now(),selected=DateTime.tryParse(deliveryDate)??now;
                            final date=await showDatePicker(context:ctx,
                              initialDate:selected,firstDate:DateTime(1900),lastDate:DateTime(2199,12,31));
                            if(date!=null&&ctx.mounted)refresh(()=>deliveryDate=date.toIso8601String().substring(0,10));
                          },icon:const Icon(Icons.calendar_today_outlined,size:16),
                          label:Text(deliveryDate.isEmpty?'Ngày giao dự kiến':deliveryDate)),
                        if(deliveryDate.isNotEmpty)IconButton(tooltip:'Bỏ ngày giao',
                          onPressed:()=>refresh(()=>deliveryDate=''),icon:const Icon(Icons.close,size:16)),
                        if(order==null||copying)
                          FilterChip(label:const Text('Nhớ hình thức giao'),selected:rememberDelivery,
                            onSelected:(v)=>refresh(()=>rememberDelivery=v)),
                      ]),
                      if(customerMode=='WALK_IN')Wrap(spacing:8,runSpacing:6,children:[
                        SizedBox(width:205,child:TextFormField(key:const ValueKey('sales-walk-in-name'),
                          initialValue:walkInName,decoration:const InputDecoration(labelText:'Tên khách (không bắt buộc)',isDense:true),
                          onChanged:(v)=>walkInName=v)),
                        SizedBox(width:185,child:TextFormField(key:const ValueKey('sales-walk-in-phone'),
                          initialValue:walkInPhone,keyboardType:TextInputType.phone,
                          decoration:const InputDecoration(labelText:'Điện thoại',isDense:true),
                          onChanged:(v)=>walkInPhone=v)),
                      ]),
                      if(customerMode!='WALK_IN'&&deliveryChoice!='PICKUP')...[
                        if(locationBusy)const LinearProgressIndicator(minHeight:2),
                        if(locations.isNotEmpty)DropdownButtonFormField<String>(
                          key:ValueKey('sales-location-$customer-$locationId'),
                          initialValue:locations.any((x)=>x['id']==locationId)?locationId:null,
                          isExpanded:true,decoration:const InputDecoration(labelText:'Địa điểm giao hàng',isDense:true),
                          items:[const DropdownMenuItem<String>(value:null,child:Text('Nhập địa chỉ')),
                            ...locations.map((x)=>DropdownMenuItem<String>(value:x['id'] as String,
                              child:Text((x['name']??x['address']??'').toString(),overflow:TextOverflow.ellipsis)))],
                          onChanged:(v)=>refresh((){
                            locationId=v;addressGeneration++;
                            if(v!=null)deliveryAddress=(locations.firstWhere((x)=>x['id']==v)['address']??'').toString();
                          })),
                        TextFormField(key:ValueKey('sales-delivery-address-$customer-$addressGeneration'),
                          initialValue:deliveryAddress,readOnly:locationId!=null,
                          decoration:const InputDecoration(labelText:'Địa chỉ giao',isDense:true),
                          onChanged:(v){deliveryAddress=v;addressEditGeneration++;}),
                      ],
                      Text('Hạn thanh toán: ${customerMode=='WALK_IN'?0:customers.where((x)=>x['id']==customer).firstOrNull?['paymentTermsDays']??savedShipping['paymentTermsDays']??0} ngày · Chưa ghi nhận thu tiền',
                        style:TextStyle(fontSize:12,color:ErpPalette.of(context).muted)),
                    ],
                    if(!modern&&customers.any((x)=>x['id']==customer))
                      Text('Địa chỉ giao: '+
                        (customers.firstWhere((x)=>x['id']==customer)['deliveryAddress']??'Chưa cập nhật').toString()+
                        ' · Thanh toán: '+
                        (customers.firstWhere((x)=>x['id']==customer)['paymentTermsDays']??0).toString()+' ngày',
                        style:TextStyle(fontSize:12,color:ErpPalette.of(context).muted)),
                    const Divider(height:14),
                    Align(alignment:Alignment.centerLeft,child:ConstrainedBox(
                      constraints:const BoxConstraints(maxWidth:760),
                      child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
                    Focus(
                      onKeyEvent:(node,event){
                        if(event is! KeyDownEvent&&event is! KeyRepeatEvent||skuMatches.isEmpty||
          skuResultsFor!=skuSearch.text.trim())return KeyEventResult.ignored;
                        if(event.logicalKey==LogicalKeyboardKey.arrowDown){
                          refresh((){
                            selectedSkuIndex=(selectedSkuIndex+1)%skuMatches.length;
                            skuExplicitSelection=true;
                          });
                          keepSkuVisible();
                          return KeyEventResult.handled;
                        }
                        if(event.logicalKey==LogicalKeyboardKey.arrowUp){
                          refresh((){
                            selectedSkuIndex=(selectedSkuIndex-1+skuMatches.length)%skuMatches.length;
                            skuExplicitSelection=true;
                          });
                          keepSkuVisible();
                          return KeyEventResult.handled;
                        }
                        if(event.logicalKey==LogicalKeyboardKey.enter){
                          chooseEnteredSku(ctx,refresh);
                          return KeyEventResult.handled;
                        }
                        return KeyEventResult.ignored;
                      },
                      child:TextField(
                        key:const ValueKey('sales-sku-search'),
                        controller:skuSearch,focusNode:skuFocus,selectAllOnFocus:true,
                        onChanged:(_){
                          skuDebounce?.cancel();
                          skuSearchGeneration++;priceGeneration++;
                          refresh((){
                            skuMatches=[];skuAllMatches=[];skuExplicitSelection=false;
                            skuQuotes={};skuResultsFor=null;
                            skuSearchError=null;selectedSkuIndex=0;
                            skuBusy=false;skuPriceBusy=false;
                          });
                          if(skuSearch.text.trim().isNotEmpty){
                            skuDebounce=Timer(const Duration(milliseconds:220),
                              (){if(ctx.mounted)findSkus(ctx,refresh);});
                          }
                        },
                        textInputAction:TextInputAction.search,
                        onSubmitted:(_){
                          skuDebounce?.cancel();
                          if(skuMatches.isNotEmpty&&skuResultsFor==skuSearch.text.trim()){
                            chooseEnteredSku(ctx,refresh);
                          }else{findSkus(ctx,refresh,addOnEnter:true);}
                        },
                        decoration:InputDecoration(labelText:'Tìm hàng · F3',isDense:true,contentPadding:const EdgeInsets.symmetric(horizontal:10,vertical:9),
                          hintText:'Nhập mã hàng hoặc quét barcode rồi Enter',
                          prefixIcon:const Icon(Icons.qr_code_scanner_outlined),
                          suffixIcon:IconButton(
                            tooltip:'Tìm hàng',onPressed:()=>findSkus(ctx,refresh),
                            icon:const Icon(Icons.search)))),
                    ),
                    if(skuBusy)const LinearProgressIndicator(minHeight:3),
                    if(skuSearchError!=null)
                      Padding(padding:const EdgeInsets.symmetric(vertical:8),
                        child:Text(skuSearchError!,
                          key:const ValueKey('sales-sku-error'),
                          style:TextStyle(color:ErpPalette.of(context).danger,fontSize:12))),
                    if(skuMatches.isNotEmpty)
                      Material(
                        key:const ValueKey('sales-sku-dropdown'),
                        elevation:9,shadowColor:const Color(0x33102E24),
                        color:ErpPalette.of(context).surface,clipBehavior:Clip.antiAlias,
                        shape:RoundedRectangleBorder(
                          borderRadius:BorderRadius.circular(9),
                          side:BorderSide(color:ErpPalette.of(context).border)),
                        child:Column(mainAxisSize:MainAxisSize.min,children:[
                          Container(color:ErpPalette.of(context).mint,
                            padding:const EdgeInsets.symmetric(horizontal:12,vertical:8),
                            child:Row(children:[
                              Expanded(child:Text('TÊN SẢN PHẨM · MÃ / ĐVT',
                                style:TextStyle(fontSize:10,fontWeight:FontWeight.w800,
                                  color:ErpPalette.of(context).primary))),
                              Text('GIÁ / KHẢ DỤNG',
                                style:TextStyle(fontSize:10,fontWeight:FontWeight.w800,
                                  color:ErpPalette.of(context).primary)),
                            ])),
                          ConstrainedBox(
                            constraints:const BoxConstraints(maxHeight:144),
                            child:ListView.builder(
                              controller:skuResultScroll,shrinkWrap:true,
                              itemExtent:48,itemCount:skuMatches.length,
                              itemBuilder:(context,i){
                                final sku=skuMatches[i];
                                final id=sku['id'].toString();
                                final unitPrice=skuQuotes[id]?['unitPrice'];
                                final priceText=customer==null||list==null
                                  ?'Chọn khách / bảng giá'
                                  :unitPrice!=null?money(unitPrice)
                                    :skuPriceBusy?'Đang tra giá…':'Chưa xác định giá';
                                final stock=stockByProduct[sku['productId'].toString()];
                                final available=warehouseId==null?'Chưa chọn kho'
                                  :stockBusy?'Đang tra tồn…'
                                  :stockError!=null?'Chưa xác định tồn'
                                  :stock!=null
                                    ?(stockCached?'Tồn cũ: ':'')+erpGroupedDecimalText(stock['available'])+' '+(stock['baseUnit']??'đv gốc').toString()
                                    :stockComplete?'0 đv gốc':'Chưa xác định tồn';
                                return Material(
                                  color:i==selectedSkuIndex
                                    ?ErpPalette.of(context).mint:Colors.transparent,
                                  child:InkWell(
                                    key:ValueKey('sales-sku-result-'+i.toString()),
                                    onTap:()=>chooseSku(ctx,sku,refresh),
                                    onHover:(hover){
                                      if(hover&&!skuExplicitSelection&&selectedSkuIndex!=i){
                                        // Hover updates the visual row; only arrow keys signal an
                                        // intentional keyboard override of a scanned exact ID.
                                        refresh(()=>selectedSkuIndex=i);
                                      }
                                    },
                                    child:Container(
                                      decoration:BoxDecoration(border:Border(
                                        bottom:BorderSide(color:ErpPalette.of(context).border,width:.7))),
                                      padding:const EdgeInsets.symmetric(horizontal:10,vertical:3),
                                      child:Row(children:[
                                        Expanded(child:Column(
                                          crossAxisAlignment:CrossAxisAlignment.start,
                                          mainAxisAlignment:MainAxisAlignment.center,children:[
                                            Text((sku['productName']??'Sản phẩm').toString(),
                                              maxLines:1,overflow:TextOverflow.ellipsis,
                                              style:TextStyle(fontSize:13,
                                                fontWeight:FontWeight.w700,color:ErpPalette.of(context).ink)),
                                            const SizedBox(height:3),
                                            Text('SKU '+(sku['code']??sku['sku']??'').toString()+
                                              ' · '+(sku['unitCode']??'').toString()+
                                              ((sku['barcode']??'').toString().isEmpty
                                                ?'':' · '+sku['barcode'].toString()),
                                              maxLines:1,overflow:TextOverflow.ellipsis,
                                              style:TextStyle(fontSize:11,color:ErpPalette.of(context).muted)),
                                          ])),
                                        const SizedBox(width:8),
                                        SizedBox(width:narrow?116:175,
                                          child:Column(crossAxisAlignment:CrossAxisAlignment.end,
                                            mainAxisAlignment:MainAxisAlignment.center,children:[
                                              Text(priceText,maxLines:1,
                                                overflow:TextOverflow.ellipsis,
                                                style:TextStyle(fontSize:narrow?11:13,
                                                  fontWeight:FontWeight.w800,
                                                  color:unitPrice!=null?ErpPalette.of(context).fresh:ErpPalette.of(context).muted)),
                                              const SizedBox(height:3),
                                              Text(available,maxLines:1,overflow:TextOverflow.ellipsis,
                                                style:TextStyle(fontSize:11,color:ErpPalette.of(context).muted)),
                                            ])),
                                      ]),
                                    ),
                                  ),
                                );
                              }),
                          ),
                        ]),
                      ),
                      ]))),
                    const SizedBox(height:12),
                    if(lines.isNotEmpty&&!narrow)Padding(
                      padding:const EdgeInsets.symmetric(horizontal:8,vertical:7),
                      child:Row(children:[
                        Expanded(flex:5,child:Text('HÀNG HÓA / SKU',
                          style:TextStyle(fontWeight:FontWeight.w700,fontSize:11,color:ErpPalette.of(context).muted))),
                        SizedBox(width:92,child:Text('ĐVT',style:TextStyle(fontSize:11,color:ErpPalette.of(context).muted))),
                        SizedBox(width:112,child:Text('SỐ LƯỢNG',textAlign:TextAlign.center,style:TextStyle(fontSize:11,color:ErpPalette.of(context).muted))),
                        SizedBox(width:124,child:Text('ĐƠN GIÁ',textAlign:TextAlign.right,
                          style:TextStyle(fontSize:11,color:ErpPalette.of(context).muted))),
                        SizedBox(width:76,child:Text('CK',textAlign:TextAlign.right,
                          style:TextStyle(fontSize:11,color:ErpPalette.of(context).muted))),
                        SizedBox(width:76,child:Text('THUẾ %',textAlign:TextAlign.right,
                          style:TextStyle(fontSize:11,color:ErpPalette.of(context).muted))),
                        SizedBox(width:120,child:Text('THÀNH TIỀN',textAlign:TextAlign.right,
                          style:TextStyle(fontSize:11,color:ErpPalette.of(context).muted))),
                        const SizedBox(width:36),
                      ])),
                    for(var i=0;i<lines.length;i++)Builder(builder:(rowContext){
                      final entry=lines[i];
                      final sku=skus.firstWhere((x)=>x['id']==entry.sellSkuId);
                      final name=(sku['productName']??sku['name']??'Sản phẩm').toString();
                      final code=(sku['code']??sku['sku']??'').toString();
                      final productId=sku['productId'].toString();
                      if(!variantsByProduct.containsKey(productId)&&
                          !variantLoading.contains(productId)&&
                          !variantFailed.contains(productId)){
                        WidgetsBinding.instance.addPostFrameCallback((_){
                          if(ctx.mounted)loadVariants(ctx,refresh,productId);
                        });
                      }
                      final variants=variantsByProduct[productId];
                      final unitChoices=<Map<String,dynamic>>[
                        if(variants!=null)...variants,
                        if(variants==null||
                            !variants.any((x)=>x['id']==entry.sellSkuId))sku,
                      ];
                      // Every editor uses the same text metrics and underline box.
                      // Keep mobile labels floating so the selected unit and quantity align.
                      final lineStyle=Theme.of(ctx).textTheme.bodyLarge;
                      InputDecoration lineDecoration(String label,{String? hint,
                          TextStyle? hintStyle})=>InputDecoration(
                        isDense:true,filled:false,labelText:narrow?label:null,
                        floatingLabelBehavior:narrow?FloatingLabelBehavior.always:FloatingLabelBehavior.never,
                        hintText:hint,hintStyle:hintStyle,
                        constraints:BoxConstraints.tightFor(height:narrow?56:48),
                        border:const UnderlineInputBorder(),enabledBorder:const UnderlineInputBorder(),
                        disabledBorder:const UnderlineInputBorder(),focusedBorder:const UnderlineInputBorder(),
                        contentPadding:const EdgeInsets.symmetric(horizontal:3,vertical:8));
                      final unitField=SizedBox(width:narrow?128:92,
                        child:DropdownButtonFormField<String>(
                          key:ValueKey('sales-unit-$i-${entry.sellSkuId}'),
                          initialValue:entry.sellSkuId,
                          focusNode:entry.unitFocus,isDense:true,isExpanded:true,
                          menuMaxHeight:240,style:lineStyle,
                          decoration:lineDecoration('ĐVT'),
                          items:unitChoices.map((variant)=>DropdownMenuItem<String>(
                            value:variant['id'] as String,
                            child:Text((variant['unitCode']??'').toString(),
                              maxLines:1,overflow:TextOverflow.ellipsis))).toList(),
                          onChanged:variants==null||variants.length<2?null:(next){
                            if(next==null||next==entry.sellSkuId)return;
                            final options=variants.where((x)=>x['id']==next&&
                              x['productId']==productId&&x['active']==true).toList();
                            if(options.length!=1){
                              refresh(()=>formError='Đơn vị bán đã chọn không còn hợp lệ.');
                              return;
                            }
                            entry.sellSkuId=next;
                            // The old unit's manual price, discount and tax
                            // are not transferable to another exact SKU.
                            entry.unitPrice.clear();
                            entry.discountRate.text='0';
                            entry.taxRate.text='0';
                            entry.discountMode='PERCENT';entry.taxMode='EXCLUSIVE';
                            entry.discountEdited=false;entry.taxEdited=false;entry.overrideReason='';
                            if(!listManuallySelected&&lists.length>1){
                              listResolveGeneration++;list=null;
                              pricingChanged(ctx,refresh);
                              resolveList(ctx,refresh,sellSkuId:next);
                            }else{pricingChanged(ctx,refresh);}
                          }));

                      final quote=ready&&i<quotes!.length?quotes![i]:null;
                      final price=quote==null?'—':money(quote['unitPrice']);
                      final lineTotal=quote==null?'—':money(quote['lineTotal']);
                      final productName=Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
                        Text(name,style:TextStyle(color:ErpPalette.of(context).ink,fontWeight:FontWeight.w700),
                          maxLines:2,overflow:TextOverflow.ellipsis),
                        Text('SKU $code',style:TextStyle(color:ErpPalette.of(context).muted,fontSize:12),
                          maxLines:1,overflow:TextOverflow.ellipsis),
                      ]);
                      final quantityField=SizedBox(width:narrow?118:100,
                        child:TextField(
                          key:ValueKey('sales-qty-$i'),
                          controller:entry.quantity,focusNode:entry.quantityFocus,
                          selectAllOnFocus:true,
                          onTap:()=>entry.quantity.selection=TextSelection(
                            baseOffset:0,extentOffset:entry.quantity.text.length),
                          onChanged:(_)=>pricingChanged(ctx,refresh),
                          onSubmitted:(_)=>skuFocus.requestFocus(),
                          keyboardType:const TextInputType.numberWithOptions(decimal:true),
                          inputFormatters:const [ErpGroupedNumberFormatter(maxIntegerDigits:9,maxFractionDigits:3)],
                          textInputAction:TextInputAction.next,
                          textAlign:TextAlign.center,style:lineStyle,
                          textAlignVertical:TextAlignVertical.center,
                          decoration:lineDecoration('Số lượng'),
                        ));
                      final unitPriceField=SizedBox(width:124,child:TextField(
                        key:ValueKey('sales-price-$i'),
                        controller:entry.displayedPrice,focusNode:entry.priceFocus,
                        selectAllOnFocus:true,
                        onTap:()=>entry.displayedPrice.selection=TextSelection(baseOffset:0,extentOffset:entry.displayedPrice.text.length),
                        readOnly:!canPrice(),
                        keyboardType:const TextInputType.numberWithOptions(decimal:true),
                        inputFormatters:const [ErpGroupedNumberFormatter(maxIntegerDigits:13,maxFractionDigits:4)],
                        onChanged:(v){entry.unitPrice.text=v;pricingChanged(ctx,refresh);},
                        textAlign:TextAlign.right,style:lineStyle,
                        textAlignVertical:TextAlignVertical.center,
                        decoration:lineDecoration('Đơn giá',
                          hint:price=='—'?'—':erpGroupedDecimalText(quote!['unitPrice']),
                          hintStyle:TextStyle(color:ErpPalette.of(context).ink,fontWeight:FontWeight.w600))));
                      Widget percentField(String title,TextEditingController controller,
                          String fieldKey)=>SizedBox(width:76,child:TextField(
                        key:ValueKey('sales-'+fieldKey+'-$i'),
                        controller:controller,selectAllOnFocus:true,onTap:()=>controller.selection=TextSelection(baseOffset:0,extentOffset:controller.text.length),readOnly:fieldKey=='discount'?!canDiscount():!canTax(),
                        keyboardType:const TextInputType.numberWithOptions(decimal:true),
                        inputFormatters:[ErpGroupedNumberFormatter(
                          maxIntegerDigits:fieldKey=='discount'&&entry.discountMode!='PERCENT'?13:3,
                          maxFractionDigits:fieldKey=='discount'&&entry.discountMode!='PERCENT'?4:2)],
                        onChanged:(_){
                          if(!modern&&entry.unitPrice.text.isEmpty&&quote!=null){
                            entry.unitPrice.text=erpGroupedDecimalText(quote['unitPrice']);
                          }
                          if(fieldKey=='discount')entry.discountEdited=true;
                          else entry.taxEdited=true;
                          pricingChanged(ctx,refresh);
                        },
                        textAlign:TextAlign.right,style:lineStyle,
                        textAlignVertical:TextAlignVertical.center,
                        decoration:lineDecoration(title,hint:narrow?null:title)));
                      final discountField=percentField(entry.discountMode=='PERCENT'?'CK %':'CK ₫',entry.discountRate,'discount');
                      final taxField=percentField('Thuế %',entry.taxRate,'tax');
                      final modes=Wrap(spacing:4,runSpacing:2,alignment:WrapAlignment.end,children:[
                        if(canDiscount())PopupMenuButton<String>(tooltip:'Cách tính chiết khấu dòng',
                          key:ValueKey('sales-discount-mode-$i'),
                          onSelected:(v){entry.discountMode=v;entry.discountRate.text='0';entry.discountEdited=true;pricingChanged(ctx,refresh);},
                          itemBuilder:(_)=>const [
                            PopupMenuItem(value:'PERCENT',child:Text('Chiết khấu %')),
                            PopupMenuItem(value:'PER_UNIT',child:Text('Chiết khấu mỗi đơn vị')),
                            PopupMenuItem(value:'TOTAL_AMOUNT',child:Text('Chiết khấu cả dòng')),
                          ],
                          child:Text(switch(entry.discountMode){
                            'PER_UNIT'=>'CK/ĐVT ▾','TOTAL_AMOUNT'=>'CK dòng ▾',_=>'CK % ▾',
                          },style:TextStyle(fontSize:11,color:ErpPalette.of(context).muted))),
                        if(canTax())PopupMenuButton<String>(tooltip:'Giá đã gồm hay chưa gồm thuế',
                          key:ValueKey('sales-tax-mode-$i'),
                          onSelected:(v){entry.taxMode=v;entry.taxEdited=true;pricingChanged(ctx,refresh);},
                          itemBuilder:(_)=>const [
                            PopupMenuItem(value:'EXCLUSIVE',child:Text('Giá chưa gồm thuế')),
                            PopupMenuItem(value:'INCLUSIVE',child:Text('Giá đã gồm thuế')),
                          ],child:Text(entry.taxMode=='INCLUSIVE'?'Gồm thuế ▾':'Chưa thuế ▾',
                            style:TextStyle(fontSize:11,color:ErpPalette.of(context).muted))),
                        if(adjusted(entry))InkWell(
                          key:ValueKey('sales-reset-price-$i'),
                          onTap:(){entry.unitPrice.clear();entry.discountRate.text='0';entry.taxRate.text='0';
                            entry.discountEdited=false;entry.taxEdited=false;entry.discountMode='PERCENT';
                            entry.taxMode='EXCLUSIVE';entry.overrideReason='';pricingChanged(ctx,refresh);},
                          child:Text('Giá hệ thống',style:TextStyle(fontSize:11,color:ErpPalette.of(context).muted))),
                      ]);
                      final split=TextButton(
                        style:TextButton.styleFrom(minimumSize:const Size(0,24),padding:const EdgeInsets.symmetric(horizontal:4),tapTargetSize:MaterialTapTargetSize.shrinkWrap),
                        key:ValueKey('sales-split-$i'),
                        child:const Text('↳ Tách dòng',style:TextStyle(fontSize:11)),
                        onPressed:!(can('orders.create')||can('orders.update'))||lines.length>=30?null:(){
                          // Do not deduct source quantity or copy stale manual price/discount.
                          final next=_OrderLine(entry.sellSkuId,'1');
                          lines.insert(i+1,next);
                          pricingChanged(ctx,refresh);
                          WidgetsBinding.instance.addPostFrameCallback((_){
                            if(ctx.mounted)next.unitFocus.requestFocus();
                          });
                        });
                      final previousPrice=TextButton(
                        style:TextButton.styleFrom(minimumSize:const Size(0,24),padding:const EdgeInsets.symmetric(horizontal:4),tapTargetSize:MaterialTapTargetSize.shrinkWrap),
                        key:ValueKey('sales-last-price-$i'),
                        child:const Text('Giá lần mua trước',style:TextStyle(fontSize:11)),
                        onPressed:customer==null||customerMode=='WALK_IN'||!canPrice()?null:()async{
                          final selectedCustomer=customer!;
                          final requestedSku=entry.sellSkuId;
                          try{
                            final data=await widget.client.salesLastPurchasePrice(
                              widget.session.token,branchId:branch,
                              customerId:selectedCustomer,sellSkuId:requestedSku);
                            // Changing UOM makes a previous per-piece price
                            // inapplicable to the new carton SKU, even if the
                            // old request returns after the new quote.
                            if(!ctx.mounted||customer!=selectedCustomer||
                                entry.sellSkuId!=requestedSku||
                                !lines.contains(entry))return;
                            if(data==null){
                              refresh(()=>formError='Khách này chưa từng mua SKU này.');
                              return;
                            }
                            final historicalTaxMode=(data['taxMode']??'EXCLUSIVE').toString();
                            final historicalTax=erpGroupedDecimalText(data['taxRate']);
                            final historicalDiscountMode=(data['discountMode']??'PERCENT').toString();
                            final historicalDiscount=erpGroupedDecimalText(
                              historicalDiscountMode=='PERCENT'?data['discountRate']:data['discountValue']);
                            final needsTax=historicalTaxMode!='EXCLUSIVE'||RegExp('[1-9]').hasMatch(historicalTax);
                            final needsDiscount=historicalDiscountMode!='PERCENT'||RegExp('[1-9]').hasMatch(historicalDiscount);
                            if((needsTax&&!canTax())||(needsDiscount&&!canDiscount())||
                                (!modern&&(historicalTaxMode!='EXCLUSIVE'||historicalDiscountMode!='PERCENT'))){
                              refresh(()=>formError='Không đủ quyền hoặc phiên bản để áp dụng đúng thuế và chiết khấu của lần mua trước.');
                              return;
                            }
                            entry.unitPrice.text=erpGroupedDecimalText(data['unitPrice']);
                            if(canDiscount()){
                              entry.discountMode=historicalDiscountMode;
                              entry.discountRate.text=historicalDiscount;
                              entry.discountEdited=needsDiscount;
                            }
                            if(canTax()){
                              entry.taxMode=historicalTaxMode;
                              entry.taxRate.text=historicalTax;
                              entry.taxEdited=needsTax;
                            }
                            pricingChanged(ctx,refresh);
                          }on ErpApiError catch(e){
                            if(ctx.mounted)refresh(()=>formError=e.message);
                          }
                        });
                      final remove=IconButton(
                        constraints:const BoxConstraints(minWidth:32,minHeight:32),
                        padding:EdgeInsets.zero,
                        key:ValueKey('sales-remove-$i'),
                        tooltip:'Bỏ dòng hàng',
                        onPressed:(){
                          lines.removeAt(i).dispose();
                          pricingChanged(ctx,refresh);
                        },
                        icon:Icon(Icons.close,size:18,color:ErpPalette.of(context).muted));
                      return Container(
                        key:ValueKey('sales-line-$i'),
                        padding:const EdgeInsets.symmetric(horizontal:8,vertical:4),
                        decoration:BoxDecoration(
                          border:Border(bottom:BorderSide(color:ErpPalette.of(context).border))),
                        child:narrow?
                          Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
                            Row(children:[
                              Text((i+1).toString()+'. ',style:TextStyle(color:ErpPalette.of(context).muted)),
                              Expanded(child:productName),remove,
                            ]),
                            Wrap(spacing:4,children:[previousPrice,split]),
                            const SizedBox(height:5),
                            // Keep quantity input on its own line: long
                            // server-quoted amounts must not compete for
                            // horizontal space on 320px/360px phones.
                            Row(children:[
                              unitField,
                              const SizedBox(width:12),
                              quantityField,
                            ]),
                            const SizedBox(height:6),
                            Wrap(alignment:WrapAlignment.end,spacing:8,runSpacing:4,
                              children:[unitPriceField,discountField,taxField]),
                            if(modern)modes,
                            Column(crossAxisAlignment:CrossAxisAlignment.end,children:[
                              Text('Thành tiền: $lineTotal',
                                textAlign:TextAlign.right,softWrap:true,
                                style:TextStyle(color:ErpPalette.of(context).ink,
                                  fontWeight:FontWeight.w800)),
                            ]),
                          ]):
                          Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
                          Row(children:[
                            Expanded(flex:5,child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[productName,Wrap(spacing:4,children:[previousPrice,split])])),
                            unitField,
                            SizedBox(width:112,child:quantityField),
                            unitPriceField,discountField,taxField,
                            SizedBox(width:120,child:Text(lineTotal,textAlign:TextAlign.right,
                              style:const TextStyle(fontWeight:FontWeight.w800))),
                            SizedBox(width:36,child:remove),
                          ]),
                          if(modern)modes,
                          ]),
                      );
                    }),
                    if(lines.isEmpty)Padding(
                      padding:EdgeInsets.symmetric(vertical:12),
                      child:Text('Chưa có dòng hàng. Tìm theo mã, tên hoặc barcode rồi nhấn Enter để thêm.',
                        style:TextStyle(color:ErpPalette.of(context).muted))),
                    const Divider(height:12),
                    if(modern&&canDiscount())...[
                      Wrap(spacing:8,runSpacing:8,crossAxisAlignment:WrapCrossAlignment.center,children:[
                        SizedBox(width:210,child:DropdownButtonFormField<String>(
                          key:ValueKey('sales-document-discount-$documentDiscountMode'),
                          initialValue:documentDiscountMode,isExpanded:true,
                          decoration:const InputDecoration(labelText:'Chiết khấu toàn đơn',isDense:true),
                          items:const [DropdownMenuItem(value:'NONE',child:Text('Không áp dụng')),
                            DropdownMenuItem(value:'PERCENT',child:Text('Phần trăm')),
                            DropdownMenuItem(value:'TOTAL_AMOUNT',child:Text('Số tiền VND'))],
                          onChanged:(v){
                            if(v==null)return;
                            refresh((){documentDiscountMode=v;documentDiscountValue='0';});
                            invalidate(refresh);scheduleQuote(ctx,refresh);
                          })),
                        if(documentDiscountMode!='NONE')SizedBox(width:160,child:TextFormField(
                          key:ValueKey('sales-document-discount-value-$documentDiscountMode'),
                          initialValue:documentDiscountValue,
                          keyboardType:const TextInputType.numberWithOptions(decimal:true),
                          inputFormatters:[ErpGroupedNumberFormatter(maxIntegerDigits:documentDiscountMode=='PERCENT'?3:13,
                            maxFractionDigits:documentDiscountMode=='PERCENT'?2:0)],
                          decoration:InputDecoration(labelText:documentDiscountMode=='PERCENT'?'Tỷ lệ %':'Số tiền VND',isDense:true),
                          onChanged:(v){documentDiscountValue=v;invalidate(refresh);scheduleQuote(ctx,refresh);})),
                      ]),
                      if(documentDiscountMode!='NONE')TextFormField(
                        key:const ValueKey('sales-document-discount-reason'),
                        initialValue:documentDiscountReason,maxLength:500,
                        decoration:const InputDecoration(labelText:'Lý do chiết khấu toàn đơn',isDense:true),
                        onChanged:(v)=>documentDiscountReason=v),
                    ],
                    if(modern&&hasManualPrice())TextFormField(
                      key:const ValueKey('sales-override-reason'),initialValue:overrideReason,maxLength:500,
                      decoration:const InputDecoration(labelText:'Lý do điều chỉnh (không bắt buộc)',isDense:true),
                      onChanged:(v)=>overrideReason=v),
                    TextField(controller:note,minLines:1,maxLines:2,selectAllOnFocus:true,
                      decoration:const InputDecoration(labelText:'Ghi chú',isDense:true,filled:false,border:UnderlineInputBorder(),enabledBorder:UnderlineInputBorder(),focusedBorder:UnderlineInputBorder())),
                    if(formError!=null)Padding(
                      padding:const EdgeInsets.only(top:10),
                      child:Text(formError!,key:const ValueKey('sales-form-error'),
                        style:TextStyle(color:ErpPalette.of(context).danger))),
                  ]),
                )),
                Container(
                  width:double.infinity,
                  decoration:BoxDecoration(
                    color:ErpPalette.of(context).onAction,
                    border:Border(top:BorderSide(color:ErpPalette.of(context).border))),
                  padding:EdgeInsets.symmetric(horizontal:narrow?12:20,vertical:10),
                  child:Wrap(
                    alignment:WrapAlignment.spaceBetween,
                    crossAxisAlignment:WrapCrossAlignment.center,
                    spacing:8,runSpacing:8,children:[
                      if(ready)Column(
                        crossAxisAlignment:CrossAxisAlignment.start,
                        children:[
                          Text('Tiền hàng: '+money(previewSubtotal)),
                          if(previewDiscountTotal!=null&&erpDecimalText(previewDiscountTotal)!='0')
                            Text('Chiết khấu: '+money(previewDiscountTotal)),
                          if(previewTaxTotal!=null&&erpDecimalText(previewTaxTotal)!='0')
                            Text('Thuế: '+money(previewTaxTotal)),
                        ]),
                      Text('Tổng tiền: '+(ready?money(totalQuoted()):'—'),
                        key:const ValueKey('sales-total'),
                        style:TextStyle(color:ErpPalette.of(context).ink,fontSize:16,
                          fontWeight:FontWeight.w800)),
                      Wrap(spacing:8,runSpacing:7,children:[
                        TextButton(onPressed:()=>requestClose(ctx),child:const Text('Đóng')),
                        if(formScope!=null&&(order==null||copying||localDraft))OutlinedButton.icon(
                          key:const ValueKey('sales-save-local'),onPressed:draftSaving?null:()=>saveLocalDraft(ctx,refresh),
                          icon:const Icon(Icons.save_outlined),label:const Text('Lưu trên máy')),
                        OutlinedButton.icon(
                          key:const ValueKey('sales-quote'),
                          onPressed:quoteBusy?null:()=>preview(ctx,refresh),
                          icon:const Icon(Icons.calculate_outlined),
                          label:Text(quoteBusy?'Đang cập nhật…':'Làm mới giá')),
                        FilledButton(
                          key:const ValueKey('sales-save'),
                          onPressed:draftSaving||quoteBusy||!ready?null:()=>submitForm(ctx,refresh,confirm:false),
                          child:const Text('Lưu đơn hàng')),
                        if(can('orders.confirm'))FilledButton.icon(
                          key:const ValueKey('sales-save-confirm'),
                          onPressed:draftSaving||quoteBusy||!ready?null:()=>submitForm(ctx,refresh,confirm:true),
                          icon:const Icon(Icons.verified_outlined),
                          label:const Text('Lưu và xác nhận')),
                      ]),
                    ]),
                ),
              ])),
          ));
        }),
      );
      final result=await navigator.push(route);
      autoTimer?.cancel();
      quoteDebounce?.cancel();skuDebounce?.cancel();customerDebounce?.cancel();
      // The popped route remains mounted during its exit animation. Never dispose
      // focus nodes/controllers until the overlay has actually been removed.
      await route.completed;
      return result;
    }finally{
      autoTimer?.cancel();lifecycle?.dispose();
      await persistDraft();
      quoteDebounce?.cancel();
      quoteGeneration++;
      skuDebounce?.cancel();customerDebounce?.cancel();
      priceGeneration++;stockGeneration++;skuResultScroll.dispose();
      note.dispose();skuSearch.dispose();customerSearch.dispose();
      newCustomerCode.dispose();newCustomerName.dispose();
      newCustomerPhone.dispose();newCustomerAddress.dispose();
      newCustomerPaymentTerms.dispose();
      skuFocus.dispose();customerFocus.dispose();
      for(final line in lines){line.dispose();}
    }
  }
  Future<void> createOrder({Map<String,dynamic>? source})async{
    if(saving||localRecoveryBusy||localRecoveryBlocked||pendingConfirm!=null||pendingUpdate!=null||
      !can('orders.create'))return;
    if(pendingCreate==null){
      Map<String,dynamic>? draft;
      final scope=_localScope,token=widget.session.token;
      if(scope!=null){
        List<({String id,Map<String,dynamic> draft})> carts;
        try{carts=await widget.client.localStore!.savedCarts(scope);}
        catch(_){inform('Không đọc được giỏ đang lưu trên máy.',error:true);return;}
        if(!_sameScope(token,scope.branch))return;
        if(carts.isNotEmpty&&source==null){
          final decision=await showDialog<String>(context:context,builder:(ctx)=>AlertDialog(
            title:const Text('Giỏ hàng trên máy'),
            content:SizedBox(width:440,height:((carts.length*74)+48).clamp(130,375).toDouble(),
              child:ListView(children:[
                const Text('Mỗi cửa sổ lưu giỏ riêng. Chọn giỏ để tiếp tục.'),
                for(var i=0;i<carts.length;i++)
                  ListTile(
                    title:Text('Giỏ '+(i+1).toString()),
                    subtitle:Text('Dòng hàng: '+((carts[i].draft['lines'] as List?)?.length??0).toString()+
                      ' · '+carts[i].id.substring(carts[i].id.length>13?carts[i].id.length-13:0)),
                    onTap:()=>Navigator.pop(ctx,'resume:'+carts[i].id),
                    trailing:IconButton(tooltip:'Bỏ giỏ này',
                      onPressed:()=>Navigator.pop(ctx,'discard:'+carts[i].id),
                      icon:const Icon(Icons.delete_outline)),
                  ),
              ])),
            actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('Đóng'))],
          ));
          if(!_sameScope(token,scope.branch)||decision==null)return;
          final picked=decision.substring(decision.indexOf(':')+1);
          final target=carts.where((e)=>e.id==picked).firstOrNull;
          if(target==null)return;
          if(decision.startsWith('discard:')){
            final yes=await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(
              title:const Text('Xóa giỏ trên máy?'),
              content:const Text('Chỉ xóa giỏ được chọn, không xóa giỏ cửa sổ khác hoặc chứng từ.'),
              actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('Giữ lại')),
                FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('Xóa giỏ'))]));
            if(yes==true&&_sameScope(token,scope.branch)){
              try{
                final claimId=newKey(),claimOwner=newKey();
                await widget.client.localStore!.claimScopedCart(scope,picked,claimId,owner:claimOwner);
                await widget.client.localStore!.clearScopedCart(scope,claimId,owner:claimOwner);
              }
              catch(_){inform('Không thể xóa giỏ trên máy.',error:true);}
            }
            return;
          }
          try{
            final claimedId=newKey();
            final claimedOwner=newKey();
            draft=await widget.client.localStore!.claimScopedCart(scope,picked,claimedId,owner:claimedOwner);
            draft['localCartId']=claimedId;
            draft['localCartOwner']=claimedOwner;
          }catch(_){inform('Giỏ đã được mở trong cửa sổ khác. Không tạo trùng đơn.',error:true);return;}
        }
      }
      final form=await editForm(order:source??draft,copying:source!=null,localDraft:draft!=null);if(form==null||!mounted||widget.session.token!=token)return;
      final auto=form.remove('_confirmAfterSave')==true;
      final selectedCartId=form.remove('_localCartId') as String?;
      final selectedCartOwner=form.remove('_localCartOwner') as String?;
      setState((){
        pendingCreateCartId=selectedCartId;
        pendingCreateCartOwner=selectedCartOwner;
        pendingCreate=Map<String,dynamic>.from(form);
        pendingCreateKey=newKey();pendingCreateAutoConfirm=auto;pendingNeedsReceipt=false;
      });
    }
    await _resolveCreate();
  }
  Future<void> _resolveCreate()async{
    final body=pendingCreate,key=pendingCreateKey,scope=_localScope,token=widget.session.token;
    if(saving||body==null||key==null||!can('orders.create'))return;
    final recoveredAttempt=pendingNeedsReceipt;
    var serverMayHaveSeenCommand=recoveredAttempt;
    Future<String> cartDisposition()async{
      if(scope==null||pendingCreateCartId==null||pendingCreateCartOwner==null)return 'unknown';
      return widget.client.localStore!.cartCreateDisposition(scope,pendingCreateCartId!,
        owner:pendingCreateCartOwner!,commandKey:key);
    }
    setState(()=>saving=true);
    try{
      // Always reconcile a lost acknowledgment before consulting mutable local
      // cart state. Another tab may have already retired the cart after ACK.
      final recovered=_localConfigured&&recoveredAttempt
        ?await widget.client.salesRecovery(token,'create',body,key:key,revision:0):null;
      if(!_sameScope(token,body['branchId'] as String))return;
      Map<String,dynamic> created;
      if(recovered!=null){
        created=recovered;
      }else{
        if(recoveredAttempt&&scope!=null&&pendingCreateCartId!=null){
          final status=await cartDisposition();
          if(status=='rejected'||status=='never-submitted'){
            // Stale tab whose original command was either definitively
            // rejected or never submitted before the cart changed ownership.
            // Only clear the exact matching key; never change the new cart.
            try{await _persistPending(scope,null,null,null,previousKey:key);}catch(_){}
            if(_sameScope(token,body['branchId'] as String)){
              setState((){
                pendingCreate=null;pendingCreateKey=null;pendingCreateAutoConfirm=false;
                pendingCreateCartId=null;pendingCreateCartOwner=null;
                localRecoveryBlocked=false;
              });
              inform(status=='rejected'
                ?'Đơn đã bị máy chủ từ chối. Mở giỏ để sửa và tra giá lại.'
                :'Giỏ đã được mở ở cửa sổ khác trước khi gửi đơn. Không tạo trùng.',error:true);
            }
            return;
          }
          // Crash between the durable intent write and cart submission:
          // the same owner may still atomically mark the cart submitted,
          // then retry the exact original command key and body.
          if(status!='submitted'&&status!='editing')throw const LocalRecoveryConflict();
        }
        if(scope!=null&&pendingCreateCartId!=null&&pendingCreateCartOwner==null){
          throw const LocalRecoveryConflict();
        }
        await _persistPending(scope,'create',key,body,auto:pendingCreateAutoConfirm,
          cartId:pendingCreateCartId,cartOwner:pendingCreateCartOwner);
        if(scope!=null&&pendingCreateCartId!=null&&pendingCreateCartOwner!=null){
          await widget.client.localStore!.markCartSubmitting(scope,pendingCreateCartId!,
            owner:pendingCreateCartOwner!,commandKey:key);
        }
        if(!_sameScope(token,body['branchId'] as String))return;
        serverMayHaveSeenCommand=true;
        pendingNeedsReceipt=true;
        created=await widget.client.createSalesOrder(token,body,key:key);
      }
      if(!_sameScope(token,body['branchId'] as String))return;
      final auto=pendingCreateAutoConfirm;
      final next=auto?<String,dynamic>{
        'id':created['id'],'branchId':body['branchId'],'revision':created['revision'],
      }:null;
      if(auto&&created['revision'] is! int)throw const LocalRecoveryConflict();
      var nextKey=auto?newKey():null;
      // A received ACK is final even when another PWA tab already cleared its
      // local source slot. Reuse its pending confirm key, never generate two.
      try{
        await _persistPending(scope,auto?'confirm':null,nextKey,next,previousKey:key);
      }on LocalRecoveryConflict{
        final active=scope!=null?await widget.client.localStore!.salesRecovery(scope):null;
        if(active==null){
          if(auto)await _persistPending(scope,'confirm',nextKey,next);
        }else if(auto&&active['kind']=='confirm'&&active['body'] is Map&&
          (active['body'] as Map)['id']==created['id']&&
          (active['body'] as Map)['revision']==created['revision']&&
          active['key'] is String){
          nextKey=active['key'] as String;
        }else{
          throw const LocalRecoveryConflict();
        }
      }
      if(scope!=null){
        if(pendingCreateCartId!=null&&pendingCreateCartOwner!=null){
          try{
            await widget.client.localStore!.clearScopedCart(scope,pendingCreateCartId!,
              owner:pendingCreateCartOwner!,commandKey:key);
          }catch(_){ /* Receipt proves COMMIT; the other tab may have retired the cart. */ }
        }else if(recoveredAttempt) {
          // Never delete a different tab's new cart as part of a legacy ACK.
        }else{
          await widget.client.localStore!.clearCart(scope);
        }
      }
      if(!_sameScope(token,body['branchId'] as String))return;
      setState((){
        pendingCreate=null;pendingCreateKey=null;pendingCreateAutoConfirm=false;
        pendingCreateCartId=null;pendingCreateCartOwner=null;
        if(auto){pendingConfirm=next;pendingConfirmKey=nextKey;pendingNeedsReceipt=false;}
      });
      if(!auto)inform('Đã lưu đơn hàng.');
      await reload();
    }on LocalRecoveryConflict catch(_){
      // Terminal rejection is durable even if another tab already released
      // and reopened the cart. Remove only this command's stranded slot.
      String status='unknown';
      try{status=await cartDisposition();}catch(_){}
      if(!serverMayHaveSeenCommand||status=='rejected'||status=='never-submitted'){
        try{await _persistPending(scope,null,null,null,previousKey:key);}catch(_){}
      }
      if(_sameScope(token,body['branchId'] as String))setState((){
        pendingCreate=null;pendingCreateKey=null;pendingCreateAutoConfirm=false;
        pendingCreateCartId=null;pendingCreateCartOwner=null;
        localRecoveryBlocked=status!='rejected'&&status!='never-submitted';
      });
      inform(status=='rejected'
        ?'Đơn đã bị từ chối. Mở lại giỏ để kiểm tra giá và nhập lại.'
        :status=='never-submitted'?'Giỏ đã đổi cửa sổ trước khi gửi. Không tạo trùng.'
        :'Yêu cầu đang chờ ở cửa sổ khác. Không gửi trùng.',error:true);
    }on ErpApiError catch(e){
      // Only explicit validation failures prove that the request was rolled back.
      // Unknown 409, timeout, 502/503/504 and transport errors stay replayable.
      final rejected=e.code=='PRICE_UNAVAILABLE_OR_PRODUCT_INACTIVE'||
        e.code=='CUSTOMER_OR_PRICE_LIST_UNAVAILABLE'||
        e.code=='INVALID_REFERENCE'||e.code=='INVALID_QUANTITY'||
        e.code=='DUPLICATE_PRODUCT'||e.code=='INVALID_LINES'||
        e.code=='UNKNOWN_FIELD'||e.code=='PRICE_STALE'||
        e.code=='PRICE_QUOTE_REQUIRED'||e.code=='SKU_UNAVAILABLE'||
        e.code=='SKU_HAS_NO_EFFECTIVE_BASE_PRICE'||
        e.code=='PRICE_LIST_UNAVAILABLE'||e.code=='CHANNEL_UNAVAILABLE'||
        e.code=='CUSTOMER_UNAVAILABLE'||e.code=='INVALID_LINE_IDENTITY';
      if(rejected&&_sameScope(token,body['branchId'] as String)){
        try{
          if(scope!=null&&pendingCreateCartId!=null&&pendingCreateCartOwner!=null){
            // Persist terminal rejection FIRST; a second tab may be restoring
            // the same command while the recovery slot is still occupied.
            await widget.client.localStore!.releaseRejectedCart(scope,pendingCreateCartId!,
              owner:pendingCreateCartOwner!,commandKey:key);
          }
          await _persistPending(scope,null,null,null,previousKey:key);
        }catch(_){inform('Chưa ghi xong kết quả đơn bị từ chối trên máy.',error:true);return;}
        if(!_sameScope(token,body['branchId'] as String))return;
        setState((){
          pendingCreate=null;pendingCreateKey=null;pendingCreateAutoConfirm=false;pendingCreateCartId=null;pendingCreateCartOwner=null;
        });
        inform('Không lưu được với thông tin đã chọn. Anh/chị hãy kiểm tra và lập lại đơn.',error:true);
      }else if(mounted){
        inform(e.status==0||e.status>=500||e.status==424
          ? 'Chưa nhận được kết quả lưu. Chọn “Kiểm tra đơn vừa lưu” để đối chiếu.'
          : e.message,error:true);
      }
    }catch(_){
      inform('Chưa nhận được kết quả. Chọn “Kiểm tra đơn vừa lưu”.',error:true);
    }finally{
      if(mounted)setState(()=>saving=false);
    }
    if(mounted&&pendingConfirm!=null)await _resolveSavedConfirm();
  }
  Future<void> _resolveSavedConfirm()async{
    final cmd=pendingConfirm,key=pendingConfirmKey,scope=_localScope,token=widget.session.token;
    if(cmd==null||key==null||saving||!can('orders.confirm'))return;
    final id=cmd['id'] as String,branch=cmd['branchId'] as String,
      revision=cmd['revision'] as int;
    setState(()=>saving=true);
    try{
      await _persistPending(scope,'confirm',key,cmd);
      if(!_sameScope(token,branch))return;
      // Lost confirmation ACK: check canonical server state before retrying.
      // Orders may be created and confirmed without the separate orders.read
      // grant. Use read-before-retry only when this actor is allowed to read;
      // otherwise replay the SAME idempotent confirm key and body.
      Map<String,dynamic>? existing;
      if(can('orders.read')){
        existing=await widget.client.salesOrder(token,id,branch);
      }
      if(existing?['versionStatus']=='CONFIRMED'&&
          existing?['revision'] is int&&(existing!['revision'] as int)>revision){
        if(!_sameScope(token,branch))return;
        await _persistPending(scope,null,null,null,previousKey:key);
        if(_sameScope(token,branch))setState((){pendingConfirm=null;pendingConfirmKey=null;});
        inform('Đơn hàng đã được máy chủ xác nhận.');
      }else{
        if(!_sameScope(token,branch))return;
        final receipt=_localConfigured&&pendingNeedsReceipt
          ?await widget.client.salesRecovery(token,'confirm',{'branchId':branch},key:key,revision:revision,orderId:id):null;
        if(!_sameScope(token,branch))return;
        pendingNeedsReceipt=true;
        if(receipt==null)await widget.client.salesOrderAction(token,id,'confirm',branch,revision,key:key);
        if(!_sameScope(token,branch))return;
        await _persistPending(scope,null,null,null,previousKey:key);
        if(_sameScope(token,branch))setState((){pendingConfirm=null;pendingConfirmKey=null;});
        inform('Đã lưu và xác nhận đơn hàng.');
      }
      await reload();
    }on LocalRecoveryConflict catch(_){
      if(_sameScope(token,branch))setState((){
        pendingConfirm=null;pendingConfirmKey=null;localRecoveryBlocked=true;
      });
      inform('Xác nhận đang xử lý ở cửa sổ khác. Kiểm tra trạng thái máy chủ.',error:true);
    }on ErpApiError catch(e){
      if({'PRICE_STALE','REVISION_CONFLICT','ORDER_CANCELLED',
          'VERSION_ALREADY_CONFIRMED','CUSTOMER_OR_PRICE_LIST_UNAVAILABLE',
          'CHANNEL_UNAVAILABLE','PRICE_LIST_UNAVAILABLE','CUSTOMER_UNAVAILABLE',
          'SKU_UNAVAILABLE','SKU_HAS_NO_EFFECTIVE_BASE_PRICE',
          'INVALID_REFERENCE'}.contains(e.code)&&_sameScope(token,branch)){
        try{await _persistPending(scope,null,null,null,previousKey:key);}catch(_){inform('Chưa xóa được yêu cầu đã từ chối trên máy.',error:true);return;}
        if(!_sameScope(token,branch))return;
        setState((){pendingConfirm=null;pendingConfirmKey=null;});
        inform('Không thể xác nhận do đơn hoặc giá đã thay đổi. Đơn vẫn được lưu; hãy kiểm tra và cập nhật lại.',
          error:true);
        await reload();
      }else{
        inform('Chưa rõ kết quả xác nhận. Chọn “Kiểm tra xác nhận” để đối chiếu.',
          error:true);
      }
    }catch(_){
      inform('Chưa rõ kết quả xác nhận. Chọn “Kiểm tra xác nhận” để đối chiếu.',
        error:true);
    }finally{
      if(mounted)setState(()=>saving=false);
    }
  }
  Future<void> updateOrder(Map<String,dynamic> order)async{
    if(saving||localRecoveryBusy||pendingConfirm!=null||pendingCreate!=null||!can('orders.update'))return;
    if(pendingUpdate!=null){await _resolvePendingUpdate();return;}
    final scope=_localScope,id=order['id'] as String,token=widget.session.token;
    var editSource=order;
    String? supersededKey,supersededOwner;
    if(scope!=null){
      List<Map<String,dynamic>> saved;
      try{saved=await widget.client.localStore!.unsentSalesUpdates(scope,id);}
      catch(_){inform('Không đọc được bản sửa đã lưu; chưa mở đơn mới.',error:true);return;}
      if(!_sameScope(token,scope.branch))return;
      if(saved.isNotEmpty){
        final selected=await showDialog<String>(context:context,builder:(ctx)=>AlertDialog(
          title:const Text('Bản sửa đơn chưa gửi'),
          content:SizedBox(width:510,height:((saved.length*76)+68).clamp(140,390).toDouble(),
            child:ListView(children:[
              const Text('Chọn bản sửa để xem nội dung trước khi gửi hoặc bỏ.'),
              const SizedBox(height:8),
              for(var index=0;index<saved.length;index++)
                ListTile(
                  title:Text('Bản sửa '+(index+1).toString()+' · '+
                    (saved[index]['key'] as String).split('-').skip(1).join('-')),
                  subtitle:Text('Số dòng '+(((saved[index]['command'] as Map)['body'] as Map)['lines'] as List).length.toString()+
                    ' · '+(saved[index]['status']=='rejected'?'Cần đối chiếu':
                      saved[index]['status']=='unsent'?'Chưa gửi':'Cần xác minh máy chủ')),
                  onTap:()=>Navigator.pop(ctx,saved[index]['key'] as String),
                ),
            ])),
          actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('Đóng'))],
        ));
        if(!_sameScope(token,scope.branch)||selected==null)return;
        final item=saved.where((x)=>x['key']==selected).firstOrNull;
        if(item==null)return;
        Map<String,dynamic> cmd,body;
        try{
          cmd=Map<String,dynamic>.from(item['command'] as Map);
          body=Map<String,dynamic>.from(cmd['body'] as Map);
          if(cmd['id']!=id||body['branchId']!=scope.branch||body['lines'] is! List)throw const FormatException();
        }catch(_){inform('Bản sửa trên máy không hợp lệ, không gửi lại.',error:true);return;}
        final lines=body['lines'] as List;
        final status=item['status'];
        final canReconcile=status=='rejected'||status=='reconciling';
        final decision=await showDialog<String>(context:context,builder:(ctx)=>AlertDialog(
          title:Text('Kiểm tra bản sửa · '+selected.split('-').skip(1).join('-')),
          content:SizedBox(width:520,height:350,
            child:SingleChildScrollView(child:Column(
              crossAxisAlignment:CrossAxisAlignment.start,children:[
                Text('Khách hàng: '+(body['customerId']??'—').toString()),
                Text('Bảng giá: '+(body['priceListId']??'—').toString()),
                Text('Ghi chú: '+(body['note']??'—').toString()),
                Text('Trạng thái: '+(status=='rejected'?'Đã bị máy chủ từ chối':
                  status=='unsent'?'Chưa gửi':status=='reconciling'?'Đang sửa ở cửa sổ khác':'Chưa rõ kết quả, phải đối soát bản gốc')),
                const SizedBox(height:10),
                for(var index=0;index<lines.length;index++)...[
                  Text('Dòng '+(index+1).toString()+' · SKU '+((lines[index] as Map)['sellSkuId']??'').toString(),
                    style:const TextStyle(fontWeight:FontWeight.w700)),
                  Text('SL: '+((lines[index] as Map)['quantity']??'').toString()+
                    ' · Giá sửa: '+((lines[index] as Map)['unitPrice']??'Theo bảng giá').toString()),
                  if((lines[index] as Map)['discountRate']!=null)
                    Text('CK: '+((lines[index] as Map)['discountRate']).toString()),
                  if((lines[index] as Map)['taxRate']!=null)
                    Text('Thuế: '+((lines[index] as Map)['taxRate']).toString()),
                ],
              ],
            ))),
          actions:[
            TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('Đóng')),
            if(status=='rejected')TextButton(onPressed:()=>Navigator.pop(ctx,'discard'),
              child:const Text('Bỏ bản sửa')),
            if(canReconcile)OutlinedButton(onPressed:()=>Navigator.pop(ctx,'reconcile'),
              child:const Text('Đối chiếu và sửa')),
            if(status!='rejected')FilledButton(onPressed:()=>Navigator.pop(ctx,'retry'),
              child:const Text('Kiểm tra/gửi bản gốc')),
          ],
        ));
        if(!_sameScope(token,scope.branch)||decision==null)return;
        if(decision=='discard'){
          final approved=await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(
            title:const Text('Xóa bản sửa chưa gửi?'),
            content:const Text('Thao tác chỉ xóa thay đổi lưu trên máy; không sửa hoặc hủy đơn máy chủ.'),
            actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('Giữ lại')),
              FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('Xóa bản sửa'))]));
          if(approved==true&&_sameScope(token,scope.branch)){
            try{await widget.client.localStore!.clearUnsentSalesUpdate(scope,id,selected,requiredStatus:'rejected');}
            catch(_){inform('Không xóa được bản sửa lưu trên máy.',error:true);}
          }
          return;
        }
        if(decision=='retry'){
          if(status=='rejected')return;
          setState((){
            pendingUpdate=cmd;pendingUpdateKey=selected;pendingNeedsReceipt=true;
            localRecoveryBlocked=false;
          });
          await _resolvePendingUpdate();return;
        }
        if(decision!='reconcile'||!canReconcile)return;
        final claimId=newKey();
        try{
          await widget.client.localStore!.claimRejectedSalesUpdate(scope,id,selected,claimId);
        }catch(_){
          inform('Bản sửa đang được xử lý ở cửa sổ khác. Không được tự gửi lại.',error:true);
          return;
        }
        try{
          final latest=await widget.client.salesOrder(token,id,scope.branch);
          if(!_sameScope(token,scope.branch)){
            try{await widget.client.localStore!.releaseRejectedSalesClaim(scope,id,selected,claimId);}catch(_){}
            return;
          }
          editSource=erpSalesReconciliationOrder(latest,cmd);
          supersededKey=selected;
          supersededOwner=claimId;
          inform('Đang đối chiếu bản sửa với đơn mới nhất. Giá phải tra lại trên máy chủ.');
        }catch(_){
          try{await widget.client.localStore!.releaseRejectedSalesClaim(scope,id,selected,claimId);}catch(_){}
          inform('Chưa tải được đơn mới nhất để đối chiếu. Bản sửa được giữ nguyên.',error:true);return;
        }
      }
    }
    final form=await editForm(order:editSource);
    if(form==null||!mounted||widget.session.token!=token){
      if(scope!=null&&supersededKey!=null&&supersededOwner!=null){
        try{await widget.client.localStore!.releaseRejectedSalesClaim(scope,id,supersededKey,supersededOwner);}catch(_){}
      }
      return;
    }
    final auto=form.remove('_confirmAfterSave')==true;
    final command=<String,dynamic>{'id':id,'revision':editSource['revision'],
      'body':Map<String,dynamic>.from(form),'auto':auto};
    final key=newKey();
    if(scope!=null){
      try{
        if(supersededKey!=null&&supersededOwner!=null){
          await widget.client.localStore!.replaceReconciledSalesUpdate(
            scope,id,supersededKey,supersededOwner,key,command);
        }else{
          await widget.client.localStore!.saveUnsentSalesUpdate(scope,id,key,command);
        }
      }catch(_){
        // An expired claim may have been taken by another tab. Preserve the
        // operator's entered new quote separately; never send it automatically.
        try{await widget.client.localStore!.saveUnsentSalesUpdate(scope,id,key,command);}catch(_){}
        inform('Bản sửa mới chưa được đối chiếu an toàn. Đã giữ bản gốc; không gửi yêu cầu.',error:true);
        return;
      }
    }
    if(!_sameScope(token,scope?.branch??branchId??''))return;
    setState((){
      pendingUpdate=command;pendingUpdateKey=key;pendingNeedsReceipt=false;
      localRecoveryBlocked=false;
    });
    await _resolvePendingUpdate();
  }
  Future<void> _resolvePendingUpdate()async{
    final cmd=pendingUpdate,key=pendingUpdateKey,scope=_localScope,token=widget.session.token;
    if(cmd==null||key==null||saving||!can('orders.update'))return;
    final id=cmd['id'] as String,rev=cmd['revision'] as int;
    final body=Map<String,dynamic>.from(cmd['body'] as Map);
    final auto=cmd['auto']==true;
    setState(()=>saving=true);
    try{
      // Original key receipt is authoritative after COMMIT, even if another
      // tab already cleared its local unsent record.
      if(_localConfigured&&pendingNeedsReceipt){
        final prior=await widget.client.salesRecovery(token,'update',body,
          key:key,revision:rev,orderId:id);
        if(!_sameScope(token,body['branchId'] as String))return;
        if(prior!=null){
          // The update has committed. Never replay it. Save-and-confirm must
          // transition atomically to a durable confirm intent, not be forgotten.
          final next=auto?<String,dynamic>{
            'id':id,'branchId':body['branchId'],'revision':prior['revision'],
          }:null;
          if(auto&&prior['revision'] is! int)throw const LocalRecoveryConflict();
          final nextKey=auto?newKey():null;
          try{
            await _persistPending(scope,auto?'confirm':null,nextKey,next,previousKey:key);
          }on LocalRecoveryConflict{
            if(!auto){
              // This slot now belongs to another tab; never delete their command.
            }else if(scope!=null&&await widget.client.localStore!.salesRecovery(scope)==null){
              await _persistPending(scope,'confirm',nextKey,next);
            }else{
              throw const LocalRecoveryConflict();
            }
          }
          if(scope!=null){
            try{await widget.client.localStore!.clearUnsentSalesUpdate(scope,id,key);}
            catch(_){ /* Original ACK is authoritative, old cache remains visible. */ }
          }
          if(_sameScope(token,body['branchId'] as String)){
            setState((){
              pendingUpdate=null;pendingUpdateKey=null;localRecoveryBlocked=false;
              if(auto){pendingConfirm=next;pendingConfirmKey=nextKey;pendingNeedsReceipt=false;}
            });
            inform(auto?'Đã lưu đơn, đang xác nhận trên máy chủ.':
              'Máy chủ đã lưu bản sửa. Không gửi trùng.');
            await reload();
            if(auto&&mounted)unawaited(Future<void>.delayed(Duration.zero,()async{
              if(mounted)await _resolveSavedConfirm();
            }));
          }
          return;
        }
      }
      if(_localConfigured&&pendingNeedsReceipt&&scope!=null){
        final saved=await widget.client.localStore!.unsentSalesUpdates(scope,id);
        final same=saved.where((x)=>x['key']==key).toList();
        if(same.length!=1){
          setState(()=>localRecoveryBlocked=true);
          inform('Không còn bản sửa trên máy và chưa có xác nhận. Không tự gửi lại.',error:true);
          return;
        }
        if(same.single['status']=='rejected'){
          // Another tab received a definitive server rejection. Do not
          // recreate a stranded recovery slot for this terminal command.
          try{await _persistPending(scope,null,null,null,previousKey:key);}
          on LocalRecoveryConflict{ /* Never touch a different tab's key. */ }
          if(_sameScope(token,body['branchId'] as String)){
            setState((){pendingUpdate=null;pendingUpdateKey=null;localRecoveryBlocked=true;});
            inform('Máy chủ đã từ chối bản sửa. Mở Sửa để đối chiếu và tra giá lại.',error:true);
          }
          return;
        }
        if(!{'unsent','inflight',null}.contains(same.single['status'])){
          setState(()=>localRecoveryBlocked=true);
          inform('Bản sửa đang được xử lý ở cửa sổ khác. Không tự gửi lại.',error:true);
          return;
        }
      }
      await _persistPending(scope,'update',key,cmd);
      if(scope!=null)await widget.client.localStore!.markUnsentSalesUpdate(scope,id,key,'inflight');
      if(!_sameScope(token,body['branchId'] as String))return;
      // Only server can accept the original idempotent mutation.
      pendingNeedsReceipt=true;
      final updated=await widget.client.updateSalesOrder(token,id,rev,body,key:key);
      if(!_sameScope(token,body['branchId'] as String))return;
      final next=auto?<String,dynamic>{'id':id,'branchId':body['branchId'],'revision':updated['revision']}:null;
      final nextKey=auto?newKey():null;
      await _persistPending(scope,auto?'confirm':null,nextKey,next,previousKey:key);
      if(scope!=null)await widget.client.localStore!.clearUnsentSalesUpdate(scope,id,key);
      if(!_sameScope(token,body['branchId'] as String))return;
      setState((){
        pendingUpdate=null;pendingUpdateKey=null;
        if(auto){
          pendingConfirm=next;
          pendingConfirmKey=nextKey;
        }
      });
      if(!auto)inform('Đã cập nhật đơn hàng.');
      await reload();
    }on LocalRecoveryConflict catch(_){
      // A peer tab may have rejected/rebased this exact request between our
      // receipt preflight and the CAS. Release only our original key, never
      // another command, so a stranded slot cannot lock the whole branch.
      var terminal=false;
      if(scope!=null){
        try{
          final items=await widget.client.localStore!.unsentSalesUpdates(scope,id);
          final matching=items.where((x)=>x['key']==key).toList();
          terminal=matching.isEmpty||matching.any((x)=>
            {'rejected','reconciling'}.contains(x['status']));
          if(terminal){
            try{await _persistPending(scope,null,null,null,previousKey:key);}catch(_){}
          }
        }catch(_){}
      }
      if(_sameScope(token,body['branchId'] as String))setState((){
        pendingUpdate=null;pendingUpdateKey=null;localRecoveryBlocked=!terminal;
      });
      inform(terminal
        ?'Bản sửa cũ đã bị từ chối hoặc thay thế. Mở lại đơn để đối chiếu.'
        :'Bản sửa chưa gửi đã được giữ riêng trên máy. Mở Sửa để kiểm tra.',error:true);
    }on ErpApiError catch(e){
      final rejected={'PRICE_STALE','SKU_UNAVAILABLE','INVALID_QUANTITY',
        'DUPLICATE_PRODUCT','INVALID_LINES','VERSION_ALREADY_CONFIRMED',
        'REVISION_CONFLICT','CONFIRMED_CUSTOMER_OR_PRICE_LIST_IMMUTABLE',
        'CUSTOMER_OR_PRICE_LIST_UNAVAILABLE','INVALID_REFERENCE',
        'CHANNEL_UNAVAILABLE','PRICE_LIST_UNAVAILABLE','CUSTOMER_UNAVAILABLE',
        'SKU_HAS_NO_EFFECTIVE_BASE_PRICE'}.contains(e.code);
      if(rejected&&_sameScope(token,body['branchId'] as String)){
        try{
          await _persistPending(scope,null,null,null,previousKey:key);
          if(scope!=null)await widget.client.localStore!.markUnsentSalesUpdate(scope,id,key,'rejected');
        }catch(_){inform('Chưa lưu được kết quả từ chối trên máy.',error:true);return;}
        if(!_sameScope(token,body['branchId'] as String))return;
        // Keep the rejected edit available for an explicitly reviewed new quote.
        setState((){pendingUpdate=null;pendingUpdateKey=null;localRecoveryBlocked=true;});
        inform('Không thể cập nhật vì dữ liệu hoặc giá đã thay đổi. Hãy mở lại đơn và tra giá.',
          error:true);
        await reload();
      }else{
        inform('Chưa rõ kết quả cập nhật. Chọn “Kiểm tra cập nhật” để đối chiếu.',
          error:true);
      }
    }catch(_){
      inform('Chưa rõ kết quả cập nhật. Chọn “Kiểm tra cập nhật” để đối chiếu.',
        error:true);
    }finally{
      if(mounted)setState(()=>saving=false);
    }
    if(mounted&&pendingConfirm!=null)await _resolveSavedConfirm();
  }
  Future<String?> reasonDialog(String title)async{
    final controller=TextEditingController();
    try{
      return await showDialog<String>(context:context,builder:(ctx)=>AlertDialog(
        title:Text(title),
        content:TextField(controller:controller,maxLines:2,autofocus:true,
          decoration:const InputDecoration(labelText:'Lý do')),
        actions:[
          TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('Đóng')),
          FilledButton(onPressed:()=>Navigator.pop(ctx,controller.text.trim()),
            child:const Text('Tiếp tục')),
        ],
      ));
    }finally{controller.dispose();}
  }
  Future<void> action(Map<String,dynamic> order,String action)async{
    final branch=branchId;
    if(branch==null||saving||localRecoveryBusy||localRecoveryBlocked||pendingCreate!=null||
       pendingUpdate!=null||pendingConfirm!=null)return;
    String? reason;
    if(action=='confirm'){
      final allow=await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(
        title:const Text('Xác nhận đơn bán hàng'),
        content:Text('Xác nhận chứng từ với số tiền '+money(order['total'])+
          '. Sau khi xác nhận, thay đổi phải qua phiên bản điều chỉnh. '+
          'Thao tác này chưa xuất kho, giao hàng hoặc ghi nhận thu tiền.'),
        actions:[
          TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('Quay lại')),
          FilledButton(key:const ValueKey('sales-approve-confirm'),
            onPressed:()=>Navigator.pop(ctx,true),child:const Text('Xác nhận đơn')),
        ],
      ));
      if(allow!=true||!mounted)return;
    }
    if(action!='confirm'){
      reason=await reasonDialog(action=='amend'?'Điều chỉnh đơn hàng':'Hủy đơn hàng');
      if(reason==null)return;
      if(reason.length<3){inform('Vui lòng nhập lý do.',error:true);return;}
    }
    if(!mounted)return;
    setState(()=>saving=true);
    final id=order['id'] as String,rev=order['revision'] as int;
    final label=action+'-'+id+'-'+rev.toString();
    final key=retryKeys.putIfAbsent(label,newKey);
    try{
      await widget.client.salesOrderAction(widget.session.token,id,action,branch,rev,
        key:key,reason:reason);
      retryKeys.remove(label);
      inform(action=='confirm'?'Đã xác nhận đơn hàng.':
        action=='amend'?'Đã mở điều chỉnh đơn hàng.':'Đã hủy đơn hàng.');
      await reload();
    }on ErpApiError catch(e){inform(e.message,error:true);}
    catch(_){inform('Chưa nhận được kết quả. Vui lòng tải lại đơn.',error:true);}
    finally{if(mounted)setState(()=>saving=false);}
  }
  Future<void> openOrder(Map<String,dynamic> row)async{
    final branch=branchId;if(branch==null)return;
    Map<String,dynamic> item;
    try{item=await widget.client.salesOrder(widget.session.token,row['id'] as String,branch);}
    on ErpApiError catch(e){inform(e.message,error:true);return;}
    catch(_){inform('Không mở được đơn hàng.',error:true);return;}
    if(!mounted)return;
    String statusText(String code,String type){
      if(type=='fulfillment')return switch(code){
        'NOT_ALLOCATED'=>'Chưa giữ hàng','PARTIAL'=>'Giữ một phần',
        'ALLOCATED'=>'Đã phân bổ',_=>'Chưa xử lý',
      };
      if(type=='delivery')return switch(code){
        'NOT_DISPATCHED'=>'Chưa giao','PARTIAL'=>'Giao một phần',
        'DELIVERED'=>'Đã giao',_=>'Chưa xử lý',
      };
      return switch(code){
        'NOT_DUE'=>'Chưa phát sinh phải thu','PARTIAL'=>'Thu một phần',
        'PAID'=>'Đã thanh toán',_=>'Chưa xử lý',
      };
    }
    Widget statusInfo(String title,String value,IconData icon)=>Container(
      width:195,padding:const EdgeInsets.all(12),
      decoration:BoxDecoration(
        border:Border(bottom:BorderSide(color:ErpPalette.of(context).border))),
      child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        Row(children:[Icon(icon,color:ErpPalette.of(context).primary,size:18),
          const SizedBox(width:6),Expanded(child:Text(title,
            style:TextStyle(fontSize:12,color:ErpPalette.of(context).muted)))]),
        const SizedBox(height:5),
        Text(value,style:TextStyle(fontWeight:FontWeight.w700,
          color:ErpPalette.of(context).ink)),
      ]),
    );
    await showDialog<void>(context:context,builder:(ctx){
      final size=MediaQuery.sizeOf(ctx);
      final narrow=size.width<720;
      final width=size.width*.96>1440?1440.0:size.width*.96;
      return Dialog(
        insetPadding:const EdgeInsets.symmetric(horizontal:8,vertical:10),
        clipBehavior:Clip.antiAlias,
        child:SizedBox(width:width,height:size.height*.94,
          child:Column(children:[
            Container(
              padding:EdgeInsets.symmetric(horizontal:narrow?12:20,vertical:12),
              color:ErpPalette.of(context).action,
              child:Row(children:[
                const Icon(Icons.receipt_long_outlined,color:Colors.white),
                const SizedBox(width:8),
                Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
                  Text(item['documentNo'] as String? ?? 'Đơn hàng đang lập',
                    style:TextStyle(color:ErpPalette.of(context).onAction,
                      fontWeight:FontWeight.w800,fontSize:narrow?16:20)),
                  Text((item['customerName']??'').toString()+' · '+stateOf(item),
                    style:TextStyle(color:ErpPalette.of(context).onAction.withValues(alpha:.82),fontSize:12),
                    overflow:TextOverflow.ellipsis),
                ])),
                IconButton(tooltip:'Đóng',onPressed:()=>Navigator.pop(ctx),
                  icon:const Icon(Icons.close,color:Colors.white)),
              ]),
            ),
            Expanded(child:SingleChildScrollView(
              padding:EdgeInsets.all(narrow?12:20),
              child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
                Text('Tiến trình đơn hàng',style:TextStyle(
                  color:ErpPalette.of(context).ink,fontWeight:FontWeight.w800,fontSize:17)),
                const SizedBox(height:10),
                Wrap(spacing:8,runSpacing:8,children:[
                  statusInfo('Thương mại',stateOf(item),Icons.assignment_turned_in_outlined),
                  statusInfo('Kho',
                    statusText((item['fulfillmentStatus']??'').toString(),'fulfillment'),
                    Icons.inventory_2_outlined),
                  statusInfo('Giao hàng',
                    statusText((item['deliveryStatus']??'').toString(),'delivery'),
                    Icons.local_shipping_outlined),
                  statusInfo('Thanh toán',
                    statusText((item['paymentStatus']??'').toString(),'payment'),
                    Icons.account_balance_wallet_outlined),
                ]),
                const SizedBox(height:18),
                if(item['shipping'] is Map)...[
                  Text('Kho xuất: ${item['shipping']['warehouseName']??'—'}'),
                  Text('Giao nhận: ${const {'TRIP':'Giao thường','MANUAL':'Giao thủ công','PICKUP':'Khách lấy tại kho'}[item['shipping']['deliveryChoice']]??'—'}'),
                  if(item['shipping']['deliveryAddress']!=null)Text('Địa chỉ: ${item['shipping']['deliveryAddress']}'),
                  if(item['shipping']['requestedDeliveryDate']!=null)Text('Ngày giao: ${item['shipping']['requestedDeliveryDate']}'),
                  Text('Thanh toán: ${const {'COLLECT_ON_DELIVERY':'Thu khi giao','PREPAID':'Trả trước','COLLECT_AFTER_DELIVERY':'Thu sau giao','CREDIT_TERMS':'Công nợ theo hạn'}[item['shipping']['collectionPolicy']]??'—'} · ${item['shipping']['paymentTermsDays']??0} ngày'),
                  if(item['shipping']['customerMode']=='WALK_IN')Text('Khách lẻ: ${item['shipping']['walkInName']??''} ${item['shipping']['walkInPhone']??''}'),
                  const SizedBox(height:12),
                ],
                Text('Hàng hóa và giá đã lưu',style:TextStyle(
                  fontWeight:FontWeight.w800,color:ErpPalette.of(context).ink,fontSize:16)),
                const SizedBox(height:8),
                for(final line in (item['lines'] as List<dynamic>))
                  Container(
                    padding:const EdgeInsets.symmetric(horizontal:6,vertical:12),
                    decoration:BoxDecoration(
                      border:Border(bottom:BorderSide(color:ErpPalette.of(context).border))),
                    child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
                      Text((line['productName']??'').toString(),
                        style:TextStyle(color:ErpPalette.of(context).ink,fontWeight:FontWeight.w700)),
                      Text('SKU '+(line['sku']??'').toString(),
                        style:TextStyle(color:ErpPalette.of(context).muted,fontSize:12)),
                      const SizedBox(height:6),
                      Wrap(spacing:16,runSpacing:6,children:[
                        Text('Số lượng: '+erpGroupedDecimalText(line['quantity'])+' '+line['unitCode'].toString()),
                        Text('Đơn giá: '+money(line['unitPrice'])),
                        Text('Thành tiền: '+money(line['lineTotal']),
                          style:const TextStyle(fontWeight:FontWeight.w700)),
                      ]),
                      if(line['priceSnapshot'] is Map&&line['priceSnapshot']['overrideReason']!=null)
                        Text('Lý do điều chỉnh: ${line['priceSnapshot']['overrideReason']}',
                          style:TextStyle(fontSize:12,color:ErpPalette.of(context).muted)),
                      if(line['priceSnapshot'] is Map&&line['priceSnapshot']['documentDiscount'] is Map)
                        Text('CK toàn đơn: '+money(line['priceSnapshot']['documentDiscount']['allocatedAmount'])+
                          ' · '+(line['priceSnapshot']['documentDiscount']['reason']??'').toString(),
                          style:TextStyle(fontSize:12,color:ErpPalette.of(context).muted)),
                      if(line['priceSnapshot'] is Map)
                        Padding(padding:const EdgeInsets.only(top:6),
                          child:Text('Đơn vị cơ sở quy đổi: '+
                            (line['priceSnapshot']['normalizedBaseQuantity']??'').toString()+
                            ' · Chính sách giá đã lưu: '+
                            ((line['priceSnapshot']['trace'] as List?)?.length??0).toString()+' quy tắc',
                            style:TextStyle(fontSize:12,color:ErpPalette.of(context).muted))),
                    ]),
                  ),
                const Divider(height:24),
                Wrap(spacing:18,runSpacing:7,alignment:WrapAlignment.spaceBetween,children:[
                  Text('Tiền hàng: '+money(item['subtotal'])),
                  Text('Giảm giá: '+money(item['discountTotal'])),
                  Text('Thuế: '+money(item['taxTotal'])),
                  Text('Tổng tiền: '+money(item['total']),
                    style:TextStyle(color:ErpPalette.of(context).ink,fontSize:18,
                      fontWeight:FontWeight.w800)),
                ]),
                const SizedBox(height:12),
                if((item['note']??'').toString().isNotEmpty)Text(
                  'Ghi chú: '+item['note'].toString()),
                const SizedBox(height:18),
                Text('Lịch sử chứng từ',style:TextStyle(
                  fontWeight:FontWeight.w800,color:ErpPalette.of(context).ink,fontSize:16)),
                const SizedBox(height:8),
                for(final v in (item['history'] as List<dynamic>))
                  ListTile(contentPadding:EdgeInsets.zero,dense:true,
                    leading:Icon(Icons.history,color:ErpPalette.of(context).primary),
                    title:Text('Phiên bản '+v['version'].toString()+' · '+
                      (v['state']=='DRAFT'?'Đang lập':
                       v['state']=='CANCELLED'?'Đã hủy':'Đã xác nhận')),
                    subtitle:Text('Tổng tiền: '+money(v['total'])+
                      ((v['amendmentReason']??'').toString().isEmpty?'':' · '+
                      v['amendmentReason'].toString())),
                  ),
                const SizedBox(height:12),
                Text('Xác nhận đơn không có nghĩa đã xuất kho, giao hàng hoặc thu tiền.',
                  style:TextStyle(color:ErpPalette.of(context).muted,fontSize:12)),
              ]),
            )),
            Container(padding:EdgeInsets.symmetric(horizontal:narrow?12:20,vertical:10),
              decoration:BoxDecoration(color:ErpPalette.of(context).surface,
                border:Border(top:BorderSide(color:ErpPalette.of(context).border))),
              child:Wrap(alignment:WrapAlignment.end,
                crossAxisAlignment:WrapCrossAlignment.center,
                spacing:8,runSpacing:8,children:[
                  TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('Đóng')),
                  if(item['status']=='CONFIRMED'&&item['versionStatus']=='CONFIRMED'&&item['documentNo'] is String)
                    OutlinedButton.icon(key:const ValueKey('sales-print-order'),
                      onPressed:()async{
                        try{
                          final html=confirmedSalesPrintDocument(item);
                          await FilePicker.platform.saveFile(dialogTitle:'Lưu bản in đơn hàng',
                            fileName:'${item['documentNo']}.html',type:FileType.custom,
                            allowedExtensions:const ['html'],bytes:Uint8List.fromList(utf8.encode(html)));
                          if(mounted)inform('Mở bản in HTML đã lưu để in đơn hàng.');
                        }catch(_){if(mounted)inform('Không lưu được bản in.',error:true);}
                      },icon:const Icon(Icons.print_outlined,size:16),label:const Text('Bản in')),
                  if(can('orders.create'))
                    OutlinedButton.icon(key:const ValueKey('sales-copy-order'),
                      onPressed:(){Navigator.pop(ctx);createOrder(source:item);},
                      icon:const Icon(Icons.copy_outlined,size:16),label:const Text('Sao chép đơn')),
                  if(item['versionStatus']=='DRAFT'&&can('orders.update'))
                    OutlinedButton(onPressed:(){Navigator.pop(ctx);updateOrder(item);},
                      child:const Text('Sửa đơn')),
                  if(item['versionStatus']=='DRAFT'&&can('orders.confirm'))
                    FilledButton(key:const ValueKey('sales-confirm'),
                      onPressed:(){Navigator.pop(ctx);action(item,'confirm');},
                      child:const Text('Xác nhận')),
                  if(item['status']=='CONFIRMED'&&item['versionStatus']=='CONFIRMED'&&can('orders.amend'))
                    OutlinedButton(onPressed:(){Navigator.pop(ctx);action(item,'amend');},
                      child:const Text('Điều chỉnh')),
                  if(item['status']!='CANCELLED'&&can('orders.cancel'))
                    TextButton(onPressed:(){Navigator.pop(ctx);action(item,'cancel');},
                      child:const Text('Hủy đơn')),
                ]),
            ),
          ]),
        ),
      );
    });

  }
  @override Widget build(BuildContext context){
    return Padding(
      padding:const EdgeInsets.all(18),
      child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
        Wrap(alignment:WrapAlignment.spaceBetween,
          crossAxisAlignment:WrapCrossAlignment.center,spacing:12,runSpacing:12,children:[
            Text('Danh sách đơn bán hàng',
              style:TextStyle(color:ErpPalette.of(context).ink,fontSize:18,fontWeight:FontWeight.w800)),
            FilledButton.icon(
              key:const ValueKey('sales-create'),
              onPressed:saving||localRecoveryBusy||localRecoveryBlocked?null:pendingConfirm!=null?_resolveSavedConfirm:
                pendingUpdate!=null?_resolvePendingUpdate:
                !can('orders.create')?null:createOrder,
              icon:Icon(pendingConfirm!=null||pendingCreate!=null||
                pendingUpdate!=null?Icons.sync:Icons.add),
              label:Text(pendingConfirm!=null?'Kiểm tra xác nhận':
                pendingUpdate!=null?'Kiểm tra cập nhật':
                pendingCreate==null?'Lập đơn hàng':'Kiểm tra đơn vừa lưu')),
          ]),
        const SizedBox(height:14),
        if(missingCatalog!=null)Container(
          key:const ValueKey('sales-missing-prerequisite'),
          padding:const EdgeInsets.all(12),
          margin:const EdgeInsets.only(bottom:12),
          decoration:BoxDecoration(color:ErpPalette.of(context).mint,
            border:Border.all(color:ErpPalette.of(context).border),borderRadius:BorderRadius.circular(6)),
          child:Wrap(spacing:8,runSpacing:8,
            crossAxisAlignment:WrapCrossAlignment.center,children:[
              Text('Chưa đủ '+(missingCatalog=='customers'?'khách hàng':
                missingCatalog=='products'?'SKU bán hàng':'bảng giá')+
                ' để lập đơn.',style:TextStyle(color:ErpPalette.of(context).ink,
                  fontWeight:FontWeight.w700)),
              OutlinedButton.icon(
                key:const ValueKey('sales-open-prerequisite'),
                onPressed:widget.onOpenCatalog==null?null:()=>
                  widget.onOpenCatalog!(missingCatalog!),
                icon:const Icon(Icons.open_in_new),
                label:Text('Đến '+(missingCatalog=='customers'?'Khách hàng':
                  missingCatalog=='products'?'Sản phẩm':'Bảng giá'))),
            ]),
        ),
        if(localRecoveryBlocked)OutlinedButton(onPressed:_restorePending,child:const Text('Thử đọc lại dữ liệu chờ trên máy')),
        if(branchId!=null)DropdownButtonFormField<String>(
          key:ValueKey('sales-branch-'+branchId!),initialValue:branchId,isExpanded:true,
          decoration:const InputDecoration(labelText:'Chi nhánh'),
          items:branches.map((x)=>DropdownMenuItem<String>(
            value:x['id'] as String,child:Text(x['name'] as String))).toList(),
          onChanged:_navigationLocked?null:(value)async{setState(()=>branchId=value);await _restorePending();await reload();}),
        const SizedBox(height:12),
        TextField(key:const ValueKey('sales-search'),controller:search,
          onSubmitted:(_)=>reload(),
          decoration:InputDecoration(labelText:'Tìm mã đơn hoặc khách hàng',
            prefixIcon:const Icon(Icons.search),
            suffixIcon:IconButton(tooltip:'Tìm kiếm',onPressed:reload,
              icon:const Icon(Icons.arrow_forward)))),
        const SizedBox(height:14),
        if(error!=null)Padding(padding:const EdgeInsets.only(bottom:12),
          child:Text(error!,style:TextStyle(color:ErpPalette.of(context).danger))),
        if(loading)const Center(child:Padding(padding:EdgeInsets.all(22),
          child:CircularProgressIndicator()))
        else if(orders.isEmpty)Center(child:Padding(
          padding:EdgeInsets.all(26),child:Text('Chưa có đơn hàng.',
            style:TextStyle(color:ErpPalette.of(context).muted))))
        else if(MediaQuery.sizeOf(context).width<720)
          Column(children:[
            for(final o in orders)InkWell(
              onTap:saving?null:()=>openOrder(o),
              child:Container(
                padding:const EdgeInsets.symmetric(horizontal:8,vertical:11),
                decoration:BoxDecoration(
                  border:Border(bottom:BorderSide(color:ErpPalette.of(context).border))),
                child:Row(children:[
                  Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
                    Text(o['documentNo'] as String? ?? 'Chưa cấp số',
                      style:TextStyle(fontWeight:FontWeight.w700,color:ErpPalette.of(context).ink)),
                    Text((o['customerName']??'').toString(),maxLines:1,
                      overflow:TextOverflow.ellipsis),
                    Text(stateOf(o),style:TextStyle(
                      color:ErpPalette.of(context).muted,fontSize:12)),
                  ])),
                  const SizedBox(width:10),
                  Text(money(o['total']),style:TextStyle(
                    color:ErpPalette.of(context).ink,fontWeight:FontWeight.w700)),
                  Icon(Icons.chevron_right,color:ErpPalette.of(context).muted),
                ]),
              )),
          ])
        else SingleChildScrollView(scrollDirection:Axis.horizontal,child:DataTable(
          headingRowColor:WidgetStatePropertyAll(ErpPalette.of(context).mint),
          headingTextStyle:TextStyle(fontWeight:FontWeight.w700,color:ErpPalette.of(context).ink),
          columns:const [
            DataColumn(label:Text('Số đơn')),
            DataColumn(label:Text('Khách hàng')),
            DataColumn(label:Text('Thành tiền')),
            DataColumn(label:Text('Trạng thái')),
            DataColumn(label:Text('Thao tác')),
          ],
          rows:orders.map((o)=>DataRow(cells:[
            DataCell(Text(o['documentNo'] as String? ?? 'Chưa cấp số')),
            DataCell(Text(o['customerName'] as String? ?? '')),
            DataCell(Text(money(o['total']))),
            DataCell(Text(stateOf(o))),
            DataCell(TextButton(onPressed:saving?null:()=>openOrder(o),
              child:const Text('Chi tiết'))),
          ])).toList(),
        )),
        Align(alignment:Alignment.centerRight,child:TextButton.icon(
          onPressed:loading?null:reload,icon:const Icon(Icons.refresh),
          label:const Text('Làm mới'))),
      ]),
    );
  }
}
