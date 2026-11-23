import 'dart:async';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'erp_tokens.dart';
import 'erp_display.dart';
import 'erp_toast.dart';
import 'identity_client.dart';

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
  final TextEditingController quantity;
  final FocusNode quantityFocus=FocusNode();
  _OrderLine(this.sellSkuId,String value):quantity=TextEditingController(text:value);
  void dispose(){quantity.dispose();quantityFocus.dispose();}
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
  bool pendingCreateAutoConfirm=false;
  bool _lastNavigationLock=false;
  bool get _navigationLocked=>saving||pendingCreate!=null||
    pendingUpdate!=null||pendingConfirm!=null;
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
  String newKey()=>'sales-'+DateTime.now().microsecondsSinceEpoch.toString()+'-'+(++sequence).toString();
  bool can(String permission)=>widget.session.grants.any(
    (g)=>g.permission==permission&&g.branchId==branchId);
  String money(dynamic value)=>erpVndText(value);
  String stateOf(Map<String,dynamic> row){
    if(row['status']=='CANCELLED')return 'Đã hủy';
    if(row['versionStatus']=='DRAFT'&&row['status']=='CONFIRMED')return 'Đang điều chỉnh';
    return row['status']=='CONFIRMED'?'Đã xác nhận':'Đang lập';
  }
  void inform(String text,{bool error=false}){
    if(mounted)ErpToast.show(context,text,isError:error);
  }
  @override void initState(){super.initState();loadBranches();}
  @override void didUpdateWidget(covariant SalesWorkspace old){
    super.didUpdateWidget(old);
    if(old.session.token!=widget.session.token||old.client!=widget.client){
      generation++;branches=[];orders=[];branchId=null;retryKeys.clear();
      pendingCreate=null;pendingCreateKey=null;pendingConfirm=null;
      pendingConfirmKey=null;pendingUpdate=null;pendingUpdateKey=null;
      pendingCreateAutoConfirm=false;loadBranches();
    }
  }
  @override void dispose(){generation++;search.dispose();super.dispose();}
  Future<void> loadBranches()async{
    final id=++generation;
    setState((){loading=true;error=null;});
    try{
      final values=await widget.client.catalogItems(widget.session.token,'branches');
      if(!mounted||generation!=id)return;
      final permitted=values.where((x)=>widget.session.grants.any((g)=>
        g.branchId==x['id']&&g.permission.startsWith('orders.'))).toList();
      setState((){
        branches=permitted;
        branchId=permitted.isEmpty?null:permitted.first['id'] as String;
      });
      if(branchId==null){
        setState((){error='Tài khoản chưa có quyền xem đơn hàng.';loading=false;});
      }else{await reload();}
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
  Future<Map<String,dynamic>?> editForm({Map<String,dynamic>? order})async{
    final branch=branchId;if(branch==null)return null;
    List<Map<String,dynamic>> customers,skus,lists,channels;
    try{
      final items=await Future.wait([
        widget.client.catalogItems(widget.session.token,'customers',branchId:branch),
        widget.client.catalogItems(widget.session.token,'r1/skus',branchId:branch),
        widget.client.catalogItems(widget.session.token,'price-lists',branchId:branch),
        widget.client.catalogItems(widget.session.token,'r1/channels',branchId:branch),
      ]);
      customers=items[0].where((x)=>x['active']==true).toList();
      skus=items[1].where((x)=>x['active']==true).toList();
      lists=items[2].where((x)=>x['active']==true).toList();
      channels=items[3].where((x)=>x['active']==true).toList();
    }on ErpApiError catch(e){inform(e.message,error:true);return null;}
    catch(_){inform('Không tải được danh mục bán hàng.',error:true);return null;}
    if((customers.isEmpty&&!can('catalog.write'))||skus.isEmpty||lists.isEmpty){
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
        stockWarehouses=await widget.client.catalogItems(
          widget.session.token,'warehouses',branchId:branch);
      }catch(_){
        // An unavailable inventory service does not block order drafting.
      }
    }
    if(!mounted)return null;
    String? customer=order?['customerId'] as String? ??
      (customers.length==1?customers.single['id'] as String:null);
    String? list=order?['priceListId'] as String? ??
      (lists.length==1?lists.single['id'] as String:null);
    String? channel=order?['channelId'] as String?;
    final note=TextEditingController(text:order?['note'] as String? ?? '');
    final lines=<_OrderLine>[];
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
          final found=await widget.client.catalogItems(widget.session.token,
            'r1/skus',branchId:branch,query:(row['sku']??'').toString());
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
        lines.add(_OrderLine(matching.single['id'] as String,row['quantity'].toString()));
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
      lines.every((x)=>quantityPattern.hasMatch(x.quantity.text.trim())&&
      RegExp('[1-9]').hasMatch(x.quantity.text))&&
      lines.map((x)=>x.sellSkuId).toSet().length==lines.length;
    String stamp()=>[
      customer??'',list??'',channel??'',
      ...lines.map((x)=>x.sellSkuId+':'+x.quantity.text.trim()),
    ].join('|');
    final originalStamp=stamp(),originalNote=note.text.trim();
    void invalidate(StateSetter refresh){
      quoteDebounce?.cancel();
      quoteGeneration++;
      refresh((){
      quotes=null;quotedStamp=null;previewGrandTotal=null;previewSubtotal=null;
      previewDiscountTotal=null;previewTaxTotal=null;formError=null;
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
          'lines':lines.map((line)=>{'sellSkuId':line.sellSkuId,
            'quantity':line.quantity.text.trim()}).toList(),
        });
        if(!context.mounted||request!=quoteGeneration)return;
        final quoted=(basket['lines'] as List<dynamic>)
          .map((x)=>Map<String,dynamic>.from(x as Map)).toList();
        if(quoted.length!=lines.length)throw const FormatException('QUOTE_LINES');
        refresh((){
          if(before==stamp()){
            quotes=quoted;
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
    bool skuPriceBusy=false,stockBusy=false,stockLoaded=false,stockComplete=false;
    String? stockError,warehouseId=stockWarehouses.length==1
      ?stockWarehouses.single['id'] as String:null;
    int priceGeneration=0,stockGeneration=0;
    Map<String,Map<String,dynamic>> skuQuotes={},stockByProduct={};
    final skuResultScroll=ScrollController();
    String priceContext()=>[customer??'',list??'',channel??'',
      ...lines.map((line)=>line.sellSkuId+':'+line.quantity.text.trim())].join('|');
    String skuQuantity(String id){
      for(final line in lines){
        if(line.sellSkuId==id&&quantityPattern.hasMatch(line.quantity.text.trim())&&
            RegExp('[1-9]').hasMatch(line.quantity.text)){
          return line.quantity.text.trim();
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
        stockBusy=true;stockLoaded=false;stockComplete=false;stockError=null;
        stockByProduct={};
      });
      final found=<String,Map<String,dynamic>>{};
      try{
        var complete=false;
        for(var offset=0;offset<2000;offset+=100){
          final page=await widget.client.inventoryPage(widget.session.token,
            'balances',branchId:branch,warehouseId:warehouse,offset:offset);
          for(final row in page.items){found[row['productId'].toString()]=row;}
          if(!page.hasMore){complete=true;break;}
        }
        if(!ctx.mounted||run!=stockGeneration||warehouseId!=warehouse)return;
        refresh((){
          stockByProduct=found;stockComplete=complete;
          stockLoaded=true;stockBusy=false;
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
    void keepSkuVisible(){
      WidgetsBinding.instance.addPostFrameCallback((_){
        if(!skuResultScroll.hasClients)return;
        final y=(selectedSkuIndex*58.0).clamp(
          0.0,skuResultScroll.position.maxScrollExtent);
        skuResultScroll.animateTo(y.toDouble(),
          duration:const Duration(milliseconds:130),curve:Curves.easeOut);
      });
    }
    String customerLabel(Map<String,dynamic> x)=>
      (x['code']??'').toString()+' · '+(x['name']??'').toString();
    String selectedCustomer()=>customers.where((x)=>x['id']==customer).isEmpty
      ? 'Chọn khách hàng'
      :customerLabel(customers.firstWhere((x)=>x['id']==customer));
    void chooseSku(BuildContext ctx,Map<String,dynamic> item,StateSetter refresh){
      final id=item['id'] as String;
      if(lines.length>=30){refresh(()=>formError='Tối đa 30 dòng hàng.');return;}
      if(!skus.any((x)=>x['id']==id))skus.add(item);
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
      scheduleQuote(ctx,refresh);
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
        final found=await widget.client.catalogItems(widget.session.token,
          'r1/skus',branchId:branch,query:term);
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
          loadPrices(ctx,refresh,visible);
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
      customer=item['id'] as String;
      customerSearch.clear();customerMatches=[];
      customerSearchGeneration++;
      pricingChanged(ctx,refresh);
      skuFocus.requestFocus();
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
      if(term.isEmpty){refresh(()=>customerMatches=[]);return;}
      final run=++customerSearchGeneration;
      refresh(()=>customerBusy=true);
      try{
        final values=await widget.client.catalogItems(widget.session.token,'customers',
          branchId:branch,query:term);
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
    void submitForm(BuildContext ctx,StateSetter refresh,{required bool confirm}){
      if(customer==null||list==null||!validLines()){
        refresh(()=>formError='Kiểm tra khách hàng, SKU và số lượng từng dòng.');
        return;
      }
      if(quotes==null||quotedStamp!=stamp()){
        refresh(()=>formError='Giá chưa cập nhật xong. Kiểm tra kết nối hoặc bấm Làm mới giá.');
        return;
      }
      Navigator.pop(ctx,{
        'branchId':branch,'customerId':customer,'priceListId':list,
        if(channel!=null)'channelId':channel,
        'note':note.text.trim(),
        'lines':lines.asMap().entries.map((entry)=>{
          'sellSkuId':entry.value.sellSkuId,
          'quantity':entry.value.quantity.text.trim(),
          'expectedPriceSignature':quotes![entry.key]['priceSignature'],
        }).toList(),
        '_confirmAfterSave':confirm,
      });
    }
    Future<void> requestClose(BuildContext ctx)async{
      if(quickCustomerBusy){
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
      if(stamp()==originalStamp&&note.text.trim()==originalNote){
        Navigator.pop(ctx);return;
      }
      final discard=await showDialog<bool>(context:ctx,builder:(confirmCtx)=>
        AlertDialog(
          title:const Text('Bỏ thay đổi đơn hàng?'),
          content:const Text('Thông tin vừa nhập chưa được lưu.'),
          actions:[
            TextButton(onPressed:()=>Navigator.pop(confirmCtx,false),
              child:const Text('Tiếp tục nhập')),
            FilledButton(onPressed:()=>Navigator.pop(confirmCtx,true),
              child:const Text('Bỏ thay đổi')),
          ],
        ));
      if(discard==true&&ctx.mounted)Navigator.pop(ctx);
    }
    var firstQuoteScheduled=false;
    try{
      return await showDialog<Map<String,dynamic>>(
        context:context,barrierDismissible:false,
        builder:(dialog)=>StatefulBuilder(builder:(ctx,refresh){
          final media=MediaQuery.sizeOf(ctx);
          final narrow=media.width<720;
          final width=media.width*0.96>1440?1440.0:media.width*0.96;
          final ready=quotes!=null&&quotedStamp==stamp();
          if(!firstQuoteScheduled){
            firstQuoteScheduled=true;
            WidgetsBinding.instance.addPostFrameCallback((_){
              if(ctx.mounted)scheduleQuote(ctx,refresh);
            });
          }
          return Focus(autofocus:true,onKeyEvent:(node,event){
            if(event is! KeyDownEvent)return KeyEventResult.ignored;
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
                  padding:EdgeInsets.symmetric(horizontal:narrow?14:22,vertical:12),
                  color:ErpTokens.primary,
                  child:Row(children:[
                    const Icon(Icons.receipt_long_outlined,color:Colors.white),
                    const SizedBox(width:10),
                    Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
                      Text(order==null?'Lập đơn bán hàng':'Điều chỉnh đơn bán hàng',
                        style:TextStyle(color:Colors.white,fontSize:narrow?16:21,
                          fontWeight:FontWeight.w800)),
                      Text('Chi nhánh đang chọn · Giá xác nhận từ máy chủ',
                        style:const TextStyle(color:Colors.white70,fontSize:12)),
                    ])),
                    IconButton(tooltip:'Đóng',onPressed:()=>requestClose(ctx),
                      icon:const Icon(Icons.close,color:Colors.white)),
                  ]),
                ),
                Expanded(child:SingleChildScrollView(
                  padding:EdgeInsets.all(narrow?12:20),
                  child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
                    const Text('Người mua và chính sách giá',
                      style:TextStyle(color:ErpTokens.ink,fontSize:16,fontWeight:FontWeight.w700)),
                    const SizedBox(height:9),
                    if(stockWarehouses.isNotEmpty)...[
                      const SizedBox(height:8),
                      DropdownButtonFormField<String>(
                        key:ValueKey('sales-stock-warehouse-'+warehouseId.toString()),
                        initialValue:warehouseId,isExpanded:true,
                        decoration:const InputDecoration(labelText:'Kho tra tồn (chưa phải xuất kho)',
                          border:UnderlineInputBorder()),
                        items:[
                          const DropdownMenuItem<String>(value:null,
                            child:Text('Chọn kho để xem khả dụng')),
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
                        }),
                    ],
                    Focus(onKeyEvent:(node,event){
                      if(event is! KeyDownEvent||customerMatches.isEmpty)
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
                      decoration:InputDecoration(labelText:'Tìm khách theo mã, tên · F4',
                        hintText:selectedCustomer(),
                        prefixIcon:const Icon(Icons.person_search_outlined),
                        suffixIcon:IconButton(tooltip:'Tìm khách',onPressed:()=>findCustomers(ctx,refresh),
                          icon:const Icon(Icons.search))))),
                    if(can('catalog.write'))Align(
                      alignment:Alignment.centerLeft,
                      child:TextButton.icon(
                        key:const ValueKey('sales-quick-customer-toggle'),
                        onPressed:quickCustomerBusy?null:()=>refresh((){
                          quickCustomerVisible=!quickCustomerVisible;
                        }),
                        icon:const Icon(Icons.person_add_alt_1_outlined),
                        label:const Text('Tạo khách nhanh'))),
                    if(quickCustomerVisible)Container(
                      key:const ValueKey('sales-quick-customer-panel'),
                      margin:const EdgeInsets.symmetric(vertical:8),
                      padding:const EdgeInsets.all(12),
                      decoration:BoxDecoration(
                        color:ErpTokens.mint,
                        border:Border.all(color:ErpTokens.border),
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
                    const SizedBox(height:8),
                    if(!narrow)Row(children:[
                      Expanded(child:DropdownButtonFormField<String>(
                        key:ValueKey('sales-customer-'+customer.toString()),
                        initialValue:customers.any((x)=>x['id']==customer)?customer:null,
                        isExpanded:true,decoration:const InputDecoration(labelText:'Khách hàng',border:UnderlineInputBorder()),
                        items:customers.map((x)=>DropdownMenuItem<String>(
                          value:x['id'] as String,
                          child:Text(customerLabel(x),overflow:TextOverflow.ellipsis))).toList(),
                        onChanged:(v){customer=v;pricingChanged(ctx,refresh);})),
                      const SizedBox(width:10),
                      Expanded(child:DropdownButtonFormField<String>(
                        key:ValueKey('sales-price-list-'+list.toString()),
                        initialValue:lists.any((x)=>x['id']==list)?list:null,
                        isExpanded:true,decoration:const InputDecoration(labelText:'Bảng giá',border:UnderlineInputBorder()),
                        items:lists.map((x)=>DropdownMenuItem<String>(
                          value:x['id'] as String,child:Text((x['name']??'').toString(),
                            overflow:TextOverflow.ellipsis))).toList(),
                        onChanged:(v){list=v;pricingChanged(ctx,refresh);})),
                      const SizedBox(width:10),
                      Expanded(child:DropdownButtonFormField<String>(
                        key:ValueKey('sales-channel-'+channel.toString()),
                        initialValue:channels.any((x)=>x['id']==channel)?channel:null,
                        isExpanded:true,decoration:const InputDecoration(labelText:'Kênh bán',border:UnderlineInputBorder()),
                        items:[
                          const DropdownMenuItem<String>(value:null,child:Text('Bán trực tiếp')),
                          ...channels.map((x)=>DropdownMenuItem<String>(
                            value:x['id'] as String,
                            child:Text((x['name']??'').toString(),overflow:TextOverflow.ellipsis))),
                        ],
                        onChanged:(v){channel=v;pricingChanged(ctx,refresh);})),
                    ])else Column(children:[
                      DropdownButtonFormField<String>(
                        key:ValueKey('sales-customer-'+customer.toString()),
                        initialValue:customers.any((x)=>x['id']==customer)?customer:null,
                        isExpanded:true,decoration:const InputDecoration(labelText:'Khách hàng',border:UnderlineInputBorder()),
                        items:customers.map((x)=>DropdownMenuItem<String>(
                          value:x['id'] as String,
                          child:Text(customerLabel(x),overflow:TextOverflow.ellipsis))).toList(),
                        onChanged:(v){customer=v;pricingChanged(ctx,refresh);}),
                      const SizedBox(height:8),
                      DropdownButtonFormField<String>(
                        key:ValueKey('sales-price-list-'+list.toString()),
                        initialValue:lists.any((x)=>x['id']==list)?list:null,
                        isExpanded:true,decoration:const InputDecoration(labelText:'Bảng giá',border:UnderlineInputBorder()),
                        items:lists.map((x)=>DropdownMenuItem<String>(
                          value:x['id'] as String,
                          child:Text((x['name']??'').toString(),overflow:TextOverflow.ellipsis))).toList(),
                        onChanged:(v){list=v;pricingChanged(ctx,refresh);}),
                      const SizedBox(height:8),
                      DropdownButtonFormField<String>(
                        key:ValueKey('sales-channel-'+channel.toString()),
                        initialValue:channels.any((x)=>x['id']==channel)?channel:null,
                        isExpanded:true,decoration:const InputDecoration(labelText:'Kênh bán',border:UnderlineInputBorder()),
                        items:[
                          const DropdownMenuItem<String>(value:null,child:Text('Bán trực tiếp')),
                          ...channels.map((x)=>DropdownMenuItem<String>(
                            value:x['id'] as String,
                            child:Text((x['name']??'').toString(),overflow:TextOverflow.ellipsis))),
                        ],onChanged:(v){channel=v;pricingChanged(ctx,refresh);}),
                    ]),
                    const SizedBox(height:8),
                    if(customers.any((x)=>x['id']==customer))
                      Text('Địa chỉ giao: '+
                        (customers.firstWhere((x)=>x['id']==customer)['deliveryAddress']??'Chưa cập nhật').toString()+
                        ' · Thanh toán: '+
                        (customers.firstWhere((x)=>x['id']==customer)['paymentTermsDays']??0).toString()+' ngày',
                        style:const TextStyle(fontSize:12,color:ErpTokens.muted)),
                    const Divider(height:28),
                    const Text('Hàng hóa và đơn vị bán',
                      style:TextStyle(color:ErpTokens.ink,fontSize:16,fontWeight:FontWeight.w700)),
                    const SizedBox(height:8),
                    Focus(
                      onKeyEvent:(node,event){
                        if(event is! KeyDownEvent||skuMatches.isEmpty||
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
                        controller:skuSearch,focusNode:skuFocus,
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
                        decoration:InputDecoration(labelText:'Tìm sản phẩm theo tên, SKU, barcode · F3',
                          hintText:'Nhập mã hàng hoặc quét barcode rồi Enter',
                          prefixIcon:const Icon(Icons.qr_code_scanner_outlined),
                          suffixIcon:IconButton(
                            tooltip:'Tìm hàng',onPressed:()=>findSkus(ctx,refresh),
                            icon:const Icon(Icons.search)))),
                    ),
                    const Padding(padding:EdgeInsets.only(top:4,bottom:2),
                      child:Text('F3 tìm hàng · F4 tìm khách · ↑↓ chọn · Enter thêm',
                        style:TextStyle(color:ErpTokens.muted,fontSize:11))),
                    if(skuBusy)const LinearProgressIndicator(minHeight:3),
                    if(skuSearchError!=null)
                      Padding(padding:const EdgeInsets.symmetric(vertical:8),
                        child:Text(skuSearchError!,
                          key:const ValueKey('sales-sku-error'),
                          style:const TextStyle(color:ErpTokens.danger,fontSize:12))),
                    if(skuMatches.isNotEmpty)
                      Material(
                        key:const ValueKey('sales-sku-dropdown'),
                        elevation:9,shadowColor:const Color(0x33102E24),
                        color:ErpTokens.surface,clipBehavior:Clip.antiAlias,
                        shape:RoundedRectangleBorder(
                          borderRadius:BorderRadius.circular(9),
                          side:const BorderSide(color:ErpTokens.border)),
                        child:Column(mainAxisSize:MainAxisSize.min,children:[
                          Container(color:ErpTokens.mint,
                            padding:const EdgeInsets.symmetric(horizontal:12,vertical:8),
                            child:Row(children:[
                              const Expanded(child:Text('TÊN SẢN PHẨM · MÃ / ĐVT',
                                style:TextStyle(fontSize:10,fontWeight:FontWeight.w800,
                                  color:ErpTokens.primary))),
                              const Text('GIÁ / KHẢ DỤNG',
                                style:TextStyle(fontSize:10,fontWeight:FontWeight.w800,
                                  color:ErpTokens.primary)),
                            ])),
                          ConstrainedBox(
                            constraints:const BoxConstraints(maxHeight:220),
                            child:ListView.builder(
                              controller:skuResultScroll,shrinkWrap:true,
                              itemExtent:58,itemCount:skuMatches.length,
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
                                    ?stock['available'].toString()+' '+(stock['baseUnit']??'đv gốc').toString()
                                    :stockComplete?'0 đv gốc':'Chưa xác định tồn';
                                return Material(
                                  color:i==selectedSkuIndex
                                    ?const Color(0xE0E8F3EB):Colors.transparent,
                                  child:InkWell(
                                    key:ValueKey('sales-sku-result-'+i.toString()),
                                    onTap:()=>chooseSku(ctx,sku,refresh),
                                    onHover:(hover){
                                      if(hover&&selectedSkuIndex!=i){
                                        // Hover updates the visual row; only arrow keys signal an
                                        // intentional keyboard override of a scanned exact ID.
                                        refresh(()=>selectedSkuIndex=i);
                                      }
                                    },
                                    child:Container(
                                      decoration:const BoxDecoration(border:Border(
                                        bottom:BorderSide(color:ErpTokens.border,width:.7))),
                                      padding:const EdgeInsets.symmetric(horizontal:12,vertical:8),
                                      child:Row(children:[
                                        Expanded(child:Column(
                                          crossAxisAlignment:CrossAxisAlignment.start,
                                          mainAxisAlignment:MainAxisAlignment.center,children:[
                                            Text((sku['productName']??'Sản phẩm').toString(),
                                              maxLines:1,overflow:TextOverflow.ellipsis,
                                              style:const TextStyle(fontSize:13,
                                                fontWeight:FontWeight.w700,color:ErpTokens.ink)),
                                            const SizedBox(height:3),
                                            Text('SKU '+(sku['code']??sku['sku']??'').toString()+
                                              ' · '+(sku['unitCode']??'').toString()+
                                              ((sku['barcode']??'').toString().isEmpty
                                                ?'':' · '+sku['barcode'].toString()),
                                              maxLines:1,overflow:TextOverflow.ellipsis,
                                              style:const TextStyle(fontSize:11,color:ErpTokens.muted)),
                                          ])),
                                        const SizedBox(width:8),
                                        SizedBox(width:narrow?116:175,
                                          child:Column(crossAxisAlignment:CrossAxisAlignment.end,
                                            mainAxisAlignment:MainAxisAlignment.center,children:[
                                              Text(priceText,maxLines:1,
                                                overflow:TextOverflow.ellipsis,
                                                style:TextStyle(fontSize:narrow?11:13,
                                                  fontWeight:FontWeight.w800,
                                                  color:unitPrice!=null?const Color(0xFF087E52):ErpTokens.muted)),
                                              const SizedBox(height:3),
                                              Text(available,maxLines:1,overflow:TextOverflow.ellipsis,
                                                style:const TextStyle(fontSize:11,color:ErpTokens.muted)),
                                            ])),
                                      ]),
                                    ),
                                  ),
                                );
                              }),
                          ),
                          const Padding(
                            padding:EdgeInsets.symmetric(horizontal:12,vertical:6),
                            child:Text('Giá theo khách / chính sách · Tồn chỉ tham khảo; máy chủ xác nhận lại khi lưu đơn',
                              style:TextStyle(fontSize:10,color:ErpTokens.muted))),
                        ]),
                      ),
                    const SizedBox(height:12),
                    if(lines.isNotEmpty&&!narrow)Padding(
                      padding:const EdgeInsets.symmetric(horizontal:8,vertical:7),
                      child:Row(children:[
                        const Expanded(flex:5,child:Text('HÀNG HÓA / SKU',
                          style:TextStyle(fontWeight:FontWeight.w700,fontSize:11,color:ErpTokens.muted))),
                        const SizedBox(width:60,child:Text('ĐVT',style:TextStyle(fontSize:11,color:ErpTokens.muted))),
                        const SizedBox(width:112,child:Text('SỐ LƯỢNG',style:TextStyle(fontSize:11,color:ErpTokens.muted))),
                        const SizedBox(width:112,child:Text('ĐƠN GIÁ',textAlign:TextAlign.right,
                          style:TextStyle(fontSize:11,color:ErpTokens.muted))),
                        const SizedBox(width:130,child:Text('THÀNH TIỀN',textAlign:TextAlign.right,
                          style:TextStyle(fontSize:11,color:ErpTokens.muted))),
                        const SizedBox(width:42),
                      ])),
                    for(var i=0;i<lines.length;i++)Builder(builder:(rowContext){
                      final entry=lines[i];
                      final sku=skus.firstWhere((x)=>x['id']==entry.sellSkuId);
                      final name=(sku['productName']??sku['name']??'Sản phẩm').toString();
                      final code=(sku['code']??sku['sku']??'').toString();
                      final unit=(sku['unitCode']??'').toString();
                      final quote=ready&&i<quotes!.length?quotes![i]:null;
                      final price=quote==null?'—':money(quote['unitPrice']);
                      final lineTotal=quote==null?'—':money(quote['lineTotal']);
                      final productName=Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
                        Text(name,style:const TextStyle(color:ErpTokens.ink,fontWeight:FontWeight.w700),
                          maxLines:2,overflow:TextOverflow.ellipsis),
                        Text('SKU $code',style:const TextStyle(color:ErpTokens.muted,fontSize:12),
                          maxLines:1,overflow:TextOverflow.ellipsis),
                      ]);
                      final quantityField=SizedBox(width:narrow?118:100,
                        child:TextField(
                          key:ValueKey('sales-qty-$i'),
                          controller:entry.quantity,focusNode:entry.quantityFocus,
                          onTap:()=>entry.quantity.selection=TextSelection(
                            baseOffset:0,extentOffset:entry.quantity.text.length),
                          onChanged:(_)=>pricingChanged(ctx,refresh),
                          onSubmitted:(_)=>skuFocus.requestFocus(),
                          keyboardType:const TextInputType.numberWithOptions(decimal:true),
                          textInputAction:TextInputAction.next,
                          textAlign:TextAlign.center,
                          decoration:const InputDecoration(
                            isDense:true,labelText:'Số lượng',
                            border:UnderlineInputBorder(),
                            contentPadding:EdgeInsets.symmetric(horizontal:4,vertical:8)),
                        ));
                      final remove=IconButton(
                        key:ValueKey('sales-remove-$i'),
                        tooltip:'Bỏ dòng hàng',
                        onPressed:(){
                          lines.removeAt(i).dispose();
                          pricingChanged(ctx,refresh);
                        },
                        icon:const Icon(Icons.close,size:18,color:ErpTokens.muted));
                      return Container(
                        key:ValueKey('sales-line-$i'),
                        padding:const EdgeInsets.symmetric(horizontal:8,vertical:9),
                        decoration:const BoxDecoration(
                          border:Border(bottom:BorderSide(color:ErpTokens.border))),
                        child:narrow?
                          Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
                            Row(children:[
                              Text((i+1).toString()+'. ',style:const TextStyle(color:ErpTokens.muted)),
                              Expanded(child:productName),
                              remove,
                            ]),
                            const SizedBox(height:5),
                            // Keep quantity input on its own line: long
                            // server-quoted amounts must not compete for
                            // horizontal space on 320px/360px phones.
                            Row(children:[
                              Flexible(child:Text(unit,maxLines:2,
                                overflow:TextOverflow.ellipsis,
                                style:const TextStyle(color:ErpTokens.muted,fontSize:12))),
                              const SizedBox(width:12),
                              quantityField,
                            ]),
                            const SizedBox(height:6),
                            Column(crossAxisAlignment:CrossAxisAlignment.end,children:[
                              Text('Đơn giá: $price',textAlign:TextAlign.right,
                                softWrap:true,style:const TextStyle(
                                  color:ErpTokens.muted,fontSize:12)),
                              Text('Thành tiền: $lineTotal',
                                textAlign:TextAlign.right,softWrap:true,
                                style:const TextStyle(color:ErpTokens.ink,
                                  fontWeight:FontWeight.w800)),
                            ]),
                          ]):
                          Row(children:[
                            Expanded(flex:5,child:productName),
                            SizedBox(width:60,child:Text(unit,
                              style:const TextStyle(color:ErpTokens.muted))),
                            SizedBox(width:112,child:quantityField),
                            SizedBox(width:112,child:Text(price,textAlign:TextAlign.right)),
                            SizedBox(width:130,child:Text(lineTotal,textAlign:TextAlign.right,
                              style:const TextStyle(fontWeight:FontWeight.w800))),
                            SizedBox(width:42,child:remove),
                          ]),
                      );
                    }),
                    if(lines.isEmpty)const Padding(
                      padding:EdgeInsets.symmetric(vertical:12),
                      child:Text('Chưa có dòng hàng. Tìm theo mã, tên hoặc barcode rồi nhấn Enter để thêm.',
                        style:TextStyle(color:ErpTokens.muted))),
                    const Divider(height:24),
                    TextField(controller:note,maxLines:2,
                      decoration:const InputDecoration(labelText:'Ghi chú đơn hàng',border:UnderlineInputBorder())),
                    const SizedBox(height:8),
                    const Text('Giá và thành tiền do máy chủ tính, kiểm tra lại khi xác nhận. Xác nhận đơn không tự xuất kho hoặc thu tiền.',
                      style:TextStyle(fontSize:12,color:ErpTokens.muted)),
                    if(formError!=null)Padding(
                      padding:const EdgeInsets.only(top:10),
                      child:Text(formError!,key:const ValueKey('sales-form-error'),
                        style:const TextStyle(color:ErpTokens.danger))),
                  ]),
                )),
                Container(
                  decoration:const BoxDecoration(
                    color:Colors.white,
                    border:Border(top:BorderSide(color:ErpTokens.border))),
                  padding:EdgeInsets.symmetric(horizontal:narrow?12:20,vertical:10),
                  child:Wrap(
                    alignment:WrapAlignment.spaceBetween,
                    crossAxisAlignment:WrapCrossAlignment.center,
                    spacing:8,runSpacing:8,children:[
                      if(ready)Column(
                        crossAxisAlignment:CrossAxisAlignment.start,
                        children:[
                          Text('Tiền hàng: '+money(previewSubtotal)),
                          Text('Điều chỉnh giá đã nằm trong đơn giá.',
                            style:const TextStyle(color:ErpTokens.muted,fontSize:11)),
                          Text('Chiết khấu bổ sung: '+money(previewDiscountTotal)),
                          Text('Thuế: '+money(previewTaxTotal)+
                            ' · Chính sách thuế chưa cấu hình',
                            style:const TextStyle(color:ErpTokens.muted,fontSize:11)),
                        ]),
                      Text('Tạm tính: '+(ready?money(totalQuoted()):'Chưa tra giá'),
                        key:const ValueKey('sales-total'),
                        style:const TextStyle(color:ErpTokens.ink,fontSize:16,
                          fontWeight:FontWeight.w800)),
                      Wrap(spacing:8,runSpacing:7,children:[
                        TextButton(onPressed:()=>requestClose(ctx),child:const Text('Đóng')),
                        OutlinedButton.icon(
                          key:const ValueKey('sales-quote'),
                          onPressed:quoteBusy?null:()=>preview(ctx,refresh),
                          icon:const Icon(Icons.calculate_outlined),
                          label:Text(quoteBusy?'Đang cập nhật…':'Làm mới giá')),
                        FilledButton(
                          key:const ValueKey('sales-save'),
                          onPressed:quoteBusy||!ready?null:()=>submitForm(ctx,refresh,confirm:false),
                          child:const Text('Lưu đơn hàng')),
                        if(can('orders.confirm'))FilledButton.icon(
                          key:const ValueKey('sales-save-confirm'),
                          onPressed:quoteBusy||!ready?null:()=>submitForm(ctx,refresh,confirm:true),
                          icon:const Icon(Icons.verified_outlined),
                          label:const Text('Lưu và xác nhận')),
                      ]),
                    ]),
                ),
              ])),
          ));
        }),
      );
    }finally{
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
  Future<void> createOrder()async{
    if(saving||pendingConfirm!=null||pendingUpdate!=null||
      !can('orders.create'))return;
    if(pendingCreate==null){
      final form=await editForm();if(form==null||!mounted)return;
      final auto=form.remove('_confirmAfterSave')==true;
      setState((){
        pendingCreate=Map<String,dynamic>.from(form);
        pendingCreateKey=newKey();pendingCreateAutoConfirm=auto;
      });
    }
    await _resolveCreate();
  }
  Future<void> _resolveCreate()async{
    final body=pendingCreate,key=pendingCreateKey;
    if(saving||body==null||key==null)return;
    setState(()=>saving=true);
    try{
      // This exact body+key also recovers a lost acknowledgment after COMMIT.
      final created=await widget.client.createSalesOrder(widget.session.token,body,key:key);
      if(!mounted)return;
      final auto=pendingCreateAutoConfirm;
      setState((){
        pendingCreate=null;pendingCreateKey=null;pendingCreateAutoConfirm=false;
        if(auto){
          pendingConfirm={'id':created['id'],'branchId':body['branchId'],
            'revision':created['revision']};
          pendingConfirmKey=newKey();
        }
      });
      if(!auto)inform('Đã lưu đơn hàng.');
      await reload();
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
      if(rejected&&mounted){
        setState((){
          pendingCreate=null;pendingCreateKey=null;pendingCreateAutoConfirm=false;
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
    final cmd=pendingConfirm,key=pendingConfirmKey;
    if(cmd==null||key==null||saving)return;
    final id=cmd['id'] as String,branch=cmd['branchId'] as String,
      revision=cmd['revision'] as int;
    setState(()=>saving=true);
    try{
      // Lost confirmation ACK: check canonical server state before retrying.
      // Orders may be created and confirmed without the separate orders.read
      // grant. Use read-before-retry only when this actor is allowed to read;
      // otherwise replay the SAME idempotent confirm key and body.
      Map<String,dynamic>? existing;
      if(can('orders.read')){
        existing=await widget.client.salesOrder(widget.session.token,id,branch);
      }
      if(existing?['versionStatus']=='CONFIRMED'&&
          existing?['revision'] is int&&(existing!['revision'] as int)>revision){
        if(mounted)setState((){pendingConfirm=null;pendingConfirmKey=null;});
        inform('Đơn hàng đã được máy chủ xác nhận.');
      }else{
        await widget.client.salesOrderAction(widget.session.token,id,'confirm',
          branch,revision,key:key);
        if(mounted)setState((){pendingConfirm=null;pendingConfirmKey=null;});
        inform('Đã lưu và xác nhận đơn hàng.');
      }
      await reload();
    }on ErpApiError catch(e){
      if({'PRICE_STALE','REVISION_CONFLICT','ORDER_CANCELLED',
          'VERSION_ALREADY_CONFIRMED','CUSTOMER_OR_PRICE_LIST_UNAVAILABLE',
          'CHANNEL_UNAVAILABLE','PRICE_LIST_UNAVAILABLE','CUSTOMER_UNAVAILABLE',
          'SKU_UNAVAILABLE','SKU_HAS_NO_EFFECTIVE_BASE_PRICE',
          'INVALID_REFERENCE'}.contains(e.code)&&mounted){
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
    // The previous create/confirm must reach a recoverable server outcome
    // before another edit can replace any pending idempotency command.
    if(saving||pendingConfirm!=null||pendingCreate!=null)return;
    if(pendingUpdate!=null){await _resolvePendingUpdate();return;}
    final form=await editForm(order:order);if(form==null||!mounted)return;
    final auto=form.remove('_confirmAfterSave')==true;
    setState((){
      pendingUpdate={'id':order['id'],'revision':order['revision'],
        'body':Map<String,dynamic>.from(form),'auto':auto};
      pendingUpdateKey=newKey();
    });
    await _resolvePendingUpdate();
  }
  Future<void> _resolvePendingUpdate()async{
    final cmd=pendingUpdate,key=pendingUpdateKey;
    if(cmd==null||key==null||saving)return;
    final id=cmd['id'] as String,rev=cmd['revision'] as int;
    final body=Map<String,dynamic>.from(cmd['body'] as Map);
    final auto=cmd['auto']==true;
    setState(()=>saving=true);
    try{
      // Replays the exact original body+key after a lost COMMIT acknowledgment.
      final updated=await widget.client.updateSalesOrder(widget.session.token,id,rev,body,key:key);
      if(!mounted)return;
      setState((){
        pendingUpdate=null;pendingUpdateKey=null;
        if(auto){
          pendingConfirm={'id':id,'branchId':body['branchId'],
            'revision':updated['revision']};
          pendingConfirmKey=newKey();
        }
      });
      if(!auto)inform('Đã cập nhật đơn hàng.');
      await reload();
    }on ErpApiError catch(e){
      final rejected={'PRICE_STALE','SKU_UNAVAILABLE','INVALID_QUANTITY',
        'DUPLICATE_PRODUCT','INVALID_LINES','VERSION_ALREADY_CONFIRMED',
        'REVISION_CONFLICT','CONFIRMED_CUSTOMER_OR_PRICE_LIST_IMMUTABLE',
        'CUSTOMER_OR_PRICE_LIST_UNAVAILABLE','INVALID_REFERENCE',
        'CHANNEL_UNAVAILABLE','PRICE_LIST_UNAVAILABLE','CUSTOMER_UNAVAILABLE',
        'SKU_HAS_NO_EFFECTIVE_BASE_PRICE'}.contains(e.code);
      if(rejected&&mounted){
        setState((){pendingUpdate=null;pendingUpdateKey=null;});
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
    if(branch==null||saving||pendingCreate!=null||
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
      decoration:const BoxDecoration(
        border:Border(bottom:BorderSide(color:ErpTokens.border))),
      child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        Row(children:[Icon(icon,color:ErpTokens.primary,size:18),
          const SizedBox(width:6),Expanded(child:Text(title,
            style:const TextStyle(fontSize:12,color:ErpTokens.muted)))]),
        const SizedBox(height:5),
        Text(value,style:const TextStyle(fontWeight:FontWeight.w700,
          color:ErpTokens.ink)),
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
              color:ErpTokens.primary,
              child:Row(children:[
                const Icon(Icons.receipt_long_outlined,color:Colors.white),
                const SizedBox(width:8),
                Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
                  Text(item['documentNo'] as String? ?? 'Đơn hàng đang lập',
                    style:TextStyle(color:Colors.white,
                      fontWeight:FontWeight.w800,fontSize:narrow?16:20)),
                  Text((item['customerName']??'').toString()+' · '+stateOf(item),
                    style:const TextStyle(color:Colors.white70,fontSize:12),
                    overflow:TextOverflow.ellipsis),
                ])),
                IconButton(tooltip:'Đóng',onPressed:()=>Navigator.pop(ctx),
                  icon:const Icon(Icons.close,color:Colors.white)),
              ]),
            ),
            Expanded(child:SingleChildScrollView(
              padding:EdgeInsets.all(narrow?12:20),
              child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
                const Text('Tiến trình đơn hàng',style:TextStyle(
                  color:ErpTokens.ink,fontWeight:FontWeight.w800,fontSize:17)),
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
                const Text('Hàng hóa và giá đã lưu',style:TextStyle(
                  fontWeight:FontWeight.w800,color:ErpTokens.ink,fontSize:16)),
                const SizedBox(height:8),
                for(final line in (item['lines'] as List<dynamic>))
                  Container(
                    padding:const EdgeInsets.symmetric(horizontal:6,vertical:12),
                    decoration:const BoxDecoration(
                      border:Border(bottom:BorderSide(color:ErpTokens.border))),
                    child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
                      Text((line['productName']??'').toString(),
                        style:const TextStyle(color:ErpTokens.ink,fontWeight:FontWeight.w700)),
                      Text('SKU '+(line['sku']??'').toString(),
                        style:const TextStyle(color:ErpTokens.muted,fontSize:12)),
                      const SizedBox(height:6),
                      Wrap(spacing:16,runSpacing:6,children:[
                        Text('Số lượng: '+erpDecimalText(line['quantity'])+' '+line['unitCode'].toString()),
                        Text('Đơn giá: '+money(line['unitPrice'])),
                        Text('Thành tiền: '+money(line['lineTotal']),
                          style:const TextStyle(fontWeight:FontWeight.w700)),
                      ]),
                      if(line['priceSnapshot'] is Map)
                        Padding(padding:const EdgeInsets.only(top:6),
                          child:Text('Đơn vị cơ sở quy đổi: '+
                            (line['priceSnapshot']['normalizedBaseQuantity']??'').toString()+
                            ' · Chính sách giá đã lưu: '+
                            ((line['priceSnapshot']['trace'] as List?)?.length??0).toString()+' quy tắc',
                            style:const TextStyle(fontSize:12,color:ErpTokens.muted))),
                    ]),
                  ),
                const Divider(height:24),
                Wrap(spacing:18,runSpacing:7,alignment:WrapAlignment.spaceBetween,children:[
                  Text('Tiền hàng: '+money(item['subtotal'])),
                  Text('Giảm giá: '+money(item['discountTotal'])),
                  Text('Thuế: '+money(item['taxTotal'])),
                  Text('Tổng tiền: '+money(item['total']),
                    style:const TextStyle(color:ErpTokens.ink,fontSize:18,
                      fontWeight:FontWeight.w800)),
                ]),
                const SizedBox(height:12),
                if((item['note']??'').toString().isNotEmpty)Text(
                  'Ghi chú: '+item['note'].toString()),
                const SizedBox(height:18),
                const Text('Lịch sử chứng từ',style:TextStyle(
                  fontWeight:FontWeight.w800,color:ErpTokens.ink,fontSize:16)),
                const SizedBox(height:8),
                for(final v in (item['history'] as List<dynamic>))
                  ListTile(contentPadding:EdgeInsets.zero,dense:true,
                    leading:const Icon(Icons.history,color:ErpTokens.primary),
                    title:Text('Phiên bản '+v['version'].toString()+' · '+
                      (v['state']=='DRAFT'?'Đang lập':
                       v['state']=='CANCELLED'?'Đã hủy':'Đã xác nhận')),
                    subtitle:Text('Tổng tiền: '+money(v['total'])+
                      ((v['amendmentReason']??'').toString().isEmpty?'':' · '+
                      v['amendmentReason'].toString())),
                  ),
                const SizedBox(height:12),
                const Text('Xác nhận đơn không có nghĩa đã xuất kho, giao hàng hoặc thu tiền.',
                  style:TextStyle(color:ErpTokens.muted,fontSize:12)),
              ]),
            )),
            Container(padding:EdgeInsets.symmetric(horizontal:narrow?12:20,vertical:10),
              decoration:const BoxDecoration(color:Colors.white,
                border:Border(top:BorderSide(color:ErpTokens.border))),
              child:Wrap(alignment:WrapAlignment.end,
                crossAxisAlignment:WrapCrossAlignment.center,
                spacing:8,runSpacing:8,children:[
                  TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('Đóng')),
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
            const Text('Danh sách đơn bán hàng',
              style:TextStyle(color:ErpTokens.ink,fontSize:18,fontWeight:FontWeight.w800)),
            FilledButton.icon(
              key:const ValueKey('sales-create'),
              onPressed:saving?null:pendingConfirm!=null?_resolveSavedConfirm:
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
          decoration:BoxDecoration(color:ErpTokens.mint,
            border:Border.all(color:ErpTokens.border),borderRadius:BorderRadius.circular(6)),
          child:Wrap(spacing:8,runSpacing:8,
            crossAxisAlignment:WrapCrossAlignment.center,children:[
              Text('Chưa đủ '+(missingCatalog=='customers'?'khách hàng':
                missingCatalog=='products'?'SKU bán hàng':'bảng giá')+
                ' để lập đơn.',style:const TextStyle(color:ErpTokens.ink,
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
        if(branchId!=null)DropdownButtonFormField<String>(
          key:ValueKey('sales-branch-'+branchId!),initialValue:branchId,isExpanded:true,
          decoration:const InputDecoration(labelText:'Chi nhánh'),
          items:branches.map((x)=>DropdownMenuItem<String>(
            value:x['id'] as String,child:Text(x['name'] as String))).toList(),
          onChanged:(value){setState(()=>branchId=value);reload();}),
        const SizedBox(height:12),
        TextField(key:const ValueKey('sales-search'),controller:search,
          onSubmitted:(_)=>reload(),
          decoration:InputDecoration(labelText:'Tìm mã đơn hoặc khách hàng',
            prefixIcon:const Icon(Icons.search),
            suffixIcon:IconButton(tooltip:'Tìm kiếm',onPressed:reload,
              icon:const Icon(Icons.arrow_forward)))),
        const SizedBox(height:14),
        if(error!=null)Padding(padding:const EdgeInsets.only(bottom:12),
          child:Text(error!,style:const TextStyle(color:ErpTokens.danger))),
        if(loading)const Center(child:Padding(padding:EdgeInsets.all(22),
          child:CircularProgressIndicator()))
        else if(orders.isEmpty)const Center(child:Padding(
          padding:EdgeInsets.all(26),child:Text('Chưa có đơn hàng.',
            style:TextStyle(color:ErpTokens.muted))))
        else if(MediaQuery.sizeOf(context).width<720)
          Column(children:[
            for(final o in orders)InkWell(
              onTap:saving?null:()=>openOrder(o),
              child:Container(
                padding:const EdgeInsets.symmetric(horizontal:8,vertical:11),
                decoration:const BoxDecoration(
                  border:Border(bottom:BorderSide(color:ErpTokens.border))),
                child:Row(children:[
                  Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
                    Text(o['documentNo'] as String? ?? 'Chưa cấp số',
                      style:const TextStyle(fontWeight:FontWeight.w700,color:ErpTokens.ink)),
                    Text((o['customerName']??'').toString(),maxLines:1,
                      overflow:TextOverflow.ellipsis),
                    Text(stateOf(o),style:const TextStyle(
                      color:ErpTokens.muted,fontSize:12)),
                  ])),
                  const SizedBox(width:10),
                  Text(money(o['total']),style:const TextStyle(
                    color:ErpTokens.ink,fontWeight:FontWeight.w700)),
                  const Icon(Icons.chevron_right,color:ErpTokens.muted),
                ]),
              )),
          ])
        else SingleChildScrollView(scrollDirection:Axis.horizontal,child:DataTable(
          headingRowColor:const WidgetStatePropertyAll(ErpTokens.mint),
          headingTextStyle:const TextStyle(fontWeight:FontWeight.w700,color:ErpTokens.ink),
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
