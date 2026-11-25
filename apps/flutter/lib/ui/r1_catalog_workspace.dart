import 'package:material_ui/material_ui.dart';
import 'erp_tokens.dart';
import 'erp_display.dart';
import 'erp_number_input.dart';
import 'erp_toast.dart';
import 'identity_client.dart';

/// Serialize every applicable restriction. Never widen a targeted promotion
/// into a global rule simply because a field was omitted from the request.
Map<String,dynamic> r1RuleRestrictions(String scope,{
  String? customerId,String? channelId,String? customerGroup,
}){
  if(scope=='BASE')return <String,dynamic>{};
  final group=customerGroup?.trim();
  return {
    if(channelId!=null)'channelId':channelId,
    if(customerId!=null&&(scope=='CUSTOMER'||scope=='PROMOTION'))
      'customerId':customerId,
    if(group!=null&&group.isNotEmpty&&
      (scope=='CUSTOMER_GROUP'||scope=='CUSTOMER'||scope=='PROMOTION'))
      'customerGroup':group,
  };
}

/// Reusable desktop/mobile R1 workplace: branch-scoped real APIs, no sample data.
class R1CatalogWorkspace extends StatefulWidget {
  final String kind;
  final String? branchId;
  final List<Map<String,dynamic>> branches;
  final IdentitySession session;
  final ErpIdentityClient client;
  final ValueChanged<String> changeBranch;
  /// When embedded in a product editor, all reads and choices are scoped.
  final Map<String,dynamic>? product;
  const R1CatalogWorkspace({super.key,required this.kind,required this.branchId,
    required this.branches,required this.session,required this.client,
    required this.changeBranch,this.product});
  @override State<R1CatalogWorkspace> createState()=>_R1CatalogWorkspaceState();
}
class _R1CatalogWorkspaceState extends State<R1CatalogWorkspace>{
  final query=TextEditingController();
  final fields=<String,TextEditingController>{
    for(final key in ['code','name','unitCode','toBase','barcode','amount','quantity',
      'priority','minQuantity','customerGroup'])
      key:TextEditingController(),
  };
  List<Map<String,dynamic>> items=[],products=[],skus=[],lists=[],customers=[],channels=[],
    customerGroups=[],unitDefinitions=[];
  String? error,productId,skuId,listId,customerId,channelId;
  String scope='BASE',adjustment='FIXED_PRICE',stacking='EXCLUSIVE';
  int promotionDays=7;
  DateTime? ruleStartDay,ruleEndDay,quoteDay;
  bool primary=true,stopProcessing=false,loading=true,busy=false,form=false;
  int generation=0,seq=0,quoteSerial=0;
  Map<String,dynamic>? pending,quote;
  String? pendingKey;
  String? inlineEditId;bool inlineActive=true,inlinePrimary=true;String inlineReason='';
  bool get isQuote=>widget.kind=='quote';
  String? get fixedProductId=>widget.product?['id'] as String?;
  bool get canWrite=>widget.session.grants.any((g)=>
    g.permission=='catalog.write'&&g.branchId==widget.branchId);
  String get heading=>switch(widget.kind){
    'units'=>'Đơn vị và quy đổi','skus'=>'SKU bán hàng',
    'barcodes'=>'Mã vạch','channels'=>'Kênh bán',
    'rules'=>'Quy tắc giá',_=>'Tra giá theo khách và kênh',
  };
  String get apiResource=>'r1/'+widget.kind;
  @override void initState(){super.initState();reload();}
  @override void didUpdateWidget(covariant R1CatalogWorkspace old){
    super.didUpdateWidget(old);
    if(old.branchId!=widget.branchId||old.kind!=widget.kind||
      old.session.token!=widget.session.token||old.client!=widget.client||
      old.product?['id']!=widget.product?['id']){
      generation++;quoteSerial++;form=false;pending=null;pendingKey=null;quote=null;
      query.clear();items=[];ruleStartDay=null;ruleEndDay=null;quoteDay=null;reload();
    }
  }
  @override void dispose(){
    generation++;quoteSerial++;query.dispose();for(final c in fields.values){c.dispose();}
    super.dispose();
  }
  void changeQuoteContext(VoidCallback apply){
    setState((){
      apply();
      quote=null;
      quoteSerial++;
    });
  }
  static const numericFields={'toBase','amount','quantity','priority','minQuantity'};
  String getField(String key)=>numericFields.contains(key)
    ?erpNumberCanonical(fields[key]!.text):fields[key]!.text.trim();
  String money(dynamic raw)=>erpVndText(raw);
  String errorMessage(ErpApiError e)=>switch(e.code){
    'SKU_HAS_NO_EFFECTIVE_BASE_PRICE'=>'Chưa có giá cơ sở hiệu lực cho SKU này.',
    'NO_APPLICABLE_PRICE_LIST'=>'Không có bảng giá áp dụng cho khách, nhóm, kênh và ngày tra.',
    'PRICE_LIST_ASSIGNMENT_MIGRATION_REQUIRED'=>'Chưa cập nhật cơ chế gán bảng giá trên máy chủ.',
    'PRICE_LIST_UNAVAILABLE_OR_EXPIRED'=>'Bảng giá đã hết hạn hoặc ngừng sử dụng.',
    'DUPLICATE'=>'Mã đã tồn tại. Vui lòng kiểm tra lại.',
    'IMMUTABLE_OR_UNIT_MISMATCH'=>'Hệ số phải đúng với đơn vị quy đổi đã tạo.',
    'PRODUCT_UNAVAILABLE'=>'Sản phẩm không còn sử dụng.',
    'PRICE_TARGET_UNAVAILABLE'=>'Bảng giá hoặc SKU không khả dụng.',
    'CUSTOMER_UNAVAILABLE'=>'Khách hàng không còn hoạt động.',
    'CHANNEL_UNAVAILABLE'=>'Kênh bán không còn hoạt động.',
    _=>e.message,
  };
  Future<void> reload()async{
    final branch=widget.branchId;if(branch==null)return;
    final stamp=++generation;
    setState((){loading=true;error=null;});
    try{
      final data=isQuote?<Map<String,dynamic>>[]:
        fixedProductId!=null?await widget.client.catalogProductDetailsAll(
          widget.session.token,widget.kind,branchId:branch,productId:fixedProductId!):
        await widget.client.catalogItems(widget.session.token,apiResource,
          branchId:branch,query:query.text);
      if(mounted&&stamp==generation)setState((){items=data;loading=false;});
    }on ErpApiError catch(e){
      if(mounted&&stamp==generation)setState((){loading=false;error=errorMessage(e);});
    }catch(_){
      if(mounted&&stamp==generation)setState((){
        loading=false;error='Không tải được thông tin. Vui lòng thử lại.';
      });
    }
  }
  Future<void> openForm()async{
    if(busy||widget.branchId==null)return;
    final carried=isQuote?null:widget.client.pendingR1(
      widget.session.actorId,widget.branchId!,widget.kind);
    if(carried!=null){
      final fixed=fixedProductId;
      if(fixed!=null){
        // The branch-wide pending intent is shared with the standalone tab.
        // Never retry another product's command inside this editor.
        bool matches=carried.payload['productId']==fixed;
        if(widget.kind=='barcodes'){
          try{
            final variants=await widget.client.catalogProductSkusAll(
              widget.session.token,branchId:widget.branchId!,productId:fixed);
            matches=variants.any((v)=>v['id']==carried.payload['sellSkuId']);
          }catch(_){matches=false;}
        }
        if(!mounted)return;
        if(!matches){
          setState(()=>error='Có yêu cầu chưa xác nhận ở sản phẩm khác. Kiểm tra yêu cầu tại danh mục chung trước.');
          return;
        }
      }
      // A previous COMMIT may have lost its ACK. Never reconstruct its price
      // rule using a new effective timestamp or a different idempotency key.
      setState((){
        pending=carried.payload;pendingKey=carried.key;
        error='Yêu cầu trước chưa có kết quả. Hãy kiểm tra lại trước khi tạo mới.';
        form=true;busy=false;
      });
      return;
    }
    // Channel master has no foreign-key selections. Open the form immediately,
    // without blocking the operator on unrelated product/price requests.
    if(widget.kind=='channels'){
      setState((){busy=false;error=null;quote=null;form=true;});
      return;
    }
    final branch=widget.branchId!;
    setState((){busy=true;error=null;quote=null;form=true;});
    try{
      final fixed=fixedProductId;
      final fetched=fixed==null?await Future.wait([
        widget.client.catalogItems(widget.session.token,'products',branchId:branch),
        widget.client.catalogItems(widget.session.token,'r1/skus',branchId:branch),
        widget.client.catalogItems(widget.session.token,'price-lists',branchId:branch),
        widget.client.catalogItems(widget.session.token,'customers',branchId:branch),
        widget.client.catalogItems(widget.session.token,'r1/channels',branchId:branch),
      ]):<List<Map<String,dynamic>>>[
        [widget.product!],
        await widget.client.catalogProductSkusAll(widget.session.token,
          branchId:branch,productId:fixed),
        [],[],[],
      ];
      // Auxiliary master directories are optional for legacy R1 scopes.
      // Do not break barcode entry or price quotation when 0017 is pending.
      List<Map<String,dynamic>> groups=[],uoms=[];
      if(widget.kind=='rules'){
        try{
          groups=await widget.client.catalogDirectoryAll(
            widget.session.token,'customer-groups',branchId:branch);
        }on ErpApiError catch(e){
          if(e.status!=503)rethrow;
        }
      }
      if(widget.kind=='units'||widget.kind=='skus'){
        try{
          uoms=await widget.client.catalogUnitDefinitionsAll(
            widget.session.token,branchId:branch);
        }on ErpApiError catch(e){
          if(e.status!=503)rethrow;
        }
      }
      if(!mounted||widget.branchId!=branch)return;
      setState((){
        products=fetched[0].where((x)=>x['active']!=false).toList();
        skus=fetched[1].where((x)=>x['active']!=false).toList();
        lists=fetched[2].where((x)=>x['active']!=false).toList();
        customers=fetched[3].where((x)=>x['active']!=false).toList();
        channels=fetched[4].where((x)=>x['active']!=false).toList();
        customerGroups=groups.where((x)=>x['active']!=false).toList();
        unitDefinitions=uoms.where((x)=>x['active']!=false).toList();
        productId=products.isEmpty?null:products.first['id'] as String;
        skuId=skus.isEmpty?null:skus.first['id'] as String;
        listId=lists.isEmpty?null:lists.first['id'] as String;
        customerId=null;channelId=null;
        for(final c in fields.values){c.clear();}
        // Never guess carton units or conversions from a sample value.
        fields['unitCode']!.clear();
        fields['toBase']!.clear();
        fields['quantity']!.text='1';
        fields['minQuantity']!.text='1';
        fields['priority']!.text='0';
        scope='BASE';adjustment='FIXED_PRICE';stacking='EXCLUSIVE';promotionDays=7;
        ruleStartDay=null;ruleEndDay=null;quoteDay=null;
        primary=true;stopProcessing=false;form=true;
      });
    }on ErpApiError catch(e){
      if(mounted)setState(()=>error=errorMessage(e));
    }catch(_){
      if(mounted)setState(()=>error='Không tải được các lựa chọn.');
    }finally{if(mounted)setState(()=>busy=false);}
  }
  Widget dropdown(String title,String? selected,List<Map<String,dynamic>> choices,
    ValueChanged<String?> changed,{bool empty=false}){
    final exists=choices.any((v)=>v['id']==selected);
    return DropdownButtonFormField<String>(
      key:ValueKey('r1-choice-'+title+'-'+widget.kind),isExpanded:true,
      initialValue:exists?selected:null,
      decoration:InputDecoration(labelText:title),
      items:[
        if(empty)const DropdownMenuItem<String>(value:null,child:Text('Không áp dụng')),
        ...choices.map((x)=>DropdownMenuItem<String>(
          value:x['id'] as String,
          child:Text((x['code']??x['sku']??'').toString()+' · '+
            (x['name']??x['productName']??'').toString(),
            overflow:TextOverflow.ellipsis))),
      ],
      onChanged:changed,
    );
  }
  Widget textField(String key,String title,{String hint='',bool numeric=false}){
    return TextField(
      key:ValueKey('r1-input-'+key),controller:fields[key],selectAllOnFocus:true,
      onChanged:key=='quantity'?(_)=>changeQuoteContext((){}):null,
      keyboardType:numeric?TextInputType.numberWithOptions(
        decimal:key!='priority',signed:key=='priority'):TextInputType.text,
      inputFormatters:numeric?[ErpGroupedNumberFormatter(
        maxIntegerDigits:key=='priority'?6:key=='amount'?13:12,
        maxFractionDigits:key=='priority'?0:key=='toBase'?6:key=='amount'?4:3,
        allowNegative:key=='priority')]:null,
      decoration:InputDecoration(labelText:title,hintText:hint));
  }
  String dayLabel(DateTime? day,String empty)=>day==null?empty:
    '${day.day.toString().padLeft(2,'0')}/${day.month.toString().padLeft(2,'0')}/${day.year}';
  Future<void> chooseDay(String mode)async{
    final current=mode=='start'?ruleStartDay:mode=='end'?ruleEndDay:quoteDay;
    final chosen=await showDatePicker(context:context,
      initialDate:current??DateTime.now(),
      firstDate:DateTime(2020),lastDate:DateTime(2100),
      helpText:mode=='start'?'Ngày bắt đầu':
        mode=='end'?'Ngày hết hiệu lực (tính hết ngày)':'Tra giá tại ngày');
    if(!mounted||chosen==null)return;
    setState((){
      if(mode=='start')ruleStartDay=chosen;
      else if(mode=='end')ruleEndDay=chosen;
      else{quoteDay=chosen;quote=null;quoteSerial++;}
    });
  }
  Future<void> save()async{
    if(busy||widget.branchId==null)return;
    Map<String,dynamic> payload;
    if(pending!=null){
      payload=pending!;
    }else{
      payload={'branchId':widget.branchId};
      switch(widget.kind){
        case 'units':
          payload.addAll({'productId':productId,'unitCode':getField('unitCode'),
            'toBase':getField('toBase')});break;
        case 'skus':
          payload.addAll({'productId':productId,'sku':getField('code'),
            'unitCode':getField('unitCode'),'toBase':getField('toBase')});break;
        case 'barcodes':
          payload.addAll({'sellSkuId':skuId,'barcode':getField('barcode'),
            'isPrimary':primary});break;
        case 'channels':
          payload.addAll({'code':getField('code'),'name':getField('name')});break;
        case 'rules':
          final rank=int.tryParse(getField('priority'));
          if(rank==null){setState(()=>error='Ưu tiên phải là số nguyên.');return;}
          if(scope=='CHANNEL'&&channelId==null||
            scope=='CUSTOMER'&&customerId==null||
            scope=='CUSTOMER_GROUP'&&getField('customerGroup').isEmpty){
            setState(()=>error='Vui lòng chọn thông tin áp dụng của quy tắc.');return;
          }
          final start=ruleStartDay==null?DateTime.now().toUtc():
            DateTime(ruleStartDay!.year,ruleStartDay!.month,ruleStartDay!.day).toUtc();
          final end=ruleEndDay!=null
            ?DateTime(ruleEndDay!.year,ruleEndDay!.month,ruleEndDay!.day+1).toUtc()
            :scope=='PROMOTION'?start.add(Duration(days:promotionDays)):null;
          if(end!=null&&!end.isAfter(start)){
            setState(()=>error='Ngày kết thúc phải sau thời điểm bắt đầu.');
            return;
          }
          payload.addAll({
            'priceListId':listId,'sellSkuId':skuId,'scopeKind':scope,
            'adjustment':adjustment,'amount':getField('amount'),
            'priority':rank,'stacking':stacking,'stopProcessing':stopProcessing,
            'minQuantity':getField('minQuantity'),
            'effectiveFrom':start.toIso8601String(),
            if(end!=null)'effectiveTo':end.toIso8601String(),
            ...r1RuleRestrictions(scope,customerId:customerId,
              channelId:channelId,customerGroup:getField('customerGroup')),
          });break;
        default:return;
      }
      pending=Map<String,dynamic>.from(payload);
      pendingKey='r1-'+DateTime.now().microsecondsSinceEpoch.toString()+'-'+(++seq).toString();
      widget.client.retainR1(widget.session.actorId,widget.branchId!,
        widget.kind,pending!,pendingKey!);
    }
    setState((){busy=true;error=null;});
    try{
      await widget.client.createR1Catalog(widget.session.token,widget.kind,
        payload,key:pendingKey!);
      if(!mounted)return;
      widget.client.clearR1(widget.session.actorId,widget.branchId!,widget.kind);
      setState((){form=false;pending=null;pendingKey=null;});
      ErpToast.show(context,'Đã lưu thông tin.');
      await reload();
    }on ErpApiError catch(e){
      if(!mounted)return;
      final definite=e.status==400||e.status==404||
        e.code=='DUPLICATE'||e.code=='INVALID_REFERENCE'||
        e.code=='IMMUTABLE_OR_UNIT_MISMATCH'||e.code=='PRODUCT_UNAVAILABLE'||
        e.code=='PRICE_TARGET_UNAVAILABLE'||
        e.code=='PRICE_RULE_OVERLAP';
      if(definite){
        widget.client.clearR1(widget.session.actorId,widget.branchId!,widget.kind);
        pending=null;pendingKey=null;
      }
      setState(()=>error=errorMessage(e));
      if(!definite)await reload();
    }catch(_){
      if(mounted)setState(()=>error='Chưa nhận được kết quả. Có thể kiểm tra lại cùng yêu cầu.');
    }finally{if(mounted)setState(()=>busy=false);}
  }
  Future<void> simulate()async{
    if(busy||widget.branchId==null||skuId==null)return;
    final stamp=++quoteSerial;
    setState((){busy=true;error=null;quote=null;});
    try{
      final result=await widget.client.r1PriceQuote(widget.session.token,{
        'branchId':widget.branchId,'sellSkuId':skuId,
        if(listId!=null)'priceListId':listId,'quantity':getField('quantity'),
        if(customerId!=null)'customerId':customerId,
        if(channelId!=null)'channelId':channelId,
        if(quoteDay!=null)'priceAt':DateTime(
          quoteDay!.year,quoteDay!.month,quoteDay!.day,12).toUtc().toIso8601String(),
      });
      if(mounted&&stamp==quoteSerial)
        setState(()=>quote=Map<String,dynamic>.from(result['quote'] as Map));
    }on ErpApiError catch(e){if(mounted&&stamp==quoteSerial)
      setState(()=>error=errorMessage(e));}
    catch(_){if(mounted&&stamp==quoteSerial)
      setState(()=>error='Không tra được giá. Vui lòng thử lại.');}
    finally{if(mounted)setState(()=>busy=false);}
  }
  Future<void> retirePolicy(Map<String,dynamic> rule)async{
    final branch=widget.branchId,ruleId=rule['id'] as String?;
    if(busy||!canWrite||branch==null||ruleId==null||
       rule['scopeKind']=='BASE'||rule['retiredAt']!=null)return;
    final actor=widget.session.actorId,kind='rules.retire.$ruleId';
    var prior=widget.client.pendingR1(actor,branch,kind);
    if(prior==null){
      // Never dispose a TextEditingController before dialog exit animations end.
      // A value callback avoids retaining editable state after the modal closes.
      String typedReason='';
      final confirmed=await showDialog<String>(context:context,
        builder:(dialog)=>AlertDialog(
          title:const Text('Kết thúc chính sách giá'),
          content:Column(mainAxisSize:MainAxisSize.min,children:[
            const Text('Chính sách ngừng áp dụng từ thời điểm xác nhận. Lịch sử giá đã dùng vẫn được giữ nguyên.'),
            TextField(maxLength:500,maxLines:2,
              onChanged:(v)=>typedReason=v,
              decoration:const InputDecoration(labelText:'Lý do kết thúc')),
          ]),
          actions:[
            TextButton(onPressed:()=>Navigator.pop(dialog),
              child:const Text('Đóng')),
            FilledButton(onPressed:()=>Navigator.pop(dialog,typedReason.trim()),
              child:const Text('Kết thúc chính sách')),
          ],
        ));
      if(!mounted||confirmed==null)return;
      if(confirmed.length<3){
        ErpToast.show(context,'Vui lòng nhập lý do ít nhất 3 ký tự.',isError:true);
        return;
      }
      final payload=<String,dynamic>{'branchId':branch,'reason':confirmed};
      final key='r1-retire-'+DateTime.now().microsecondsSinceEpoch.toString()+'-'+(++seq).toString();
      widget.client.retainR1(actor,branch,kind,payload,key);
      prior=(payload:payload,key:key);
    }
    setState(()=>busy=true);
    try{
      await widget.client.retireR1PriceRule(widget.session.token,ruleId,
        prior.payload,key:prior.key);
      widget.client.clearR1(actor,branch,kind);
      if(mounted){
        ErpToast.show(context,'Đã kết thúc chính sách giá.');
        await reload();
      }
    }on ErpApiError catch(e){
      if(e.status==400||e.status==404||e.code=='DUPLICATE')
        widget.client.clearR1(actor,branch,kind);
      if(mounted)ErpToast.show(context,errorMessage(e),isError:true);
    }catch(_){
      if(mounted)ErpToast.show(context,
        'Chưa nhận được kết quả. Chọn lại “Kết thúc” để kiểm tra đúng yêu cầu đã gửi.',
        isError:true);
    }finally{if(mounted)setState(()=>busy=false);}
  }
  bool get canEditLifecycle=>canWrite &&
    const {'skus','barcodes','channels'}.contains(widget.kind);
  Future<void> saveInlineLifecycle(Map<String,dynamic> row)async{
    final branch=widget.branchId,id=row['id'],revision=row['revision'];
    if(busy||branch==null||id is! String||revision is! int||inlineEditId!=id)return;
    final originalActive=row['active']==true,originalPrimary=row['isPrimary']==true;
    if(widget.kind=='skus'&&originalActive&&!inlineActive&&inlineReason.trim().length<3)return;
    final payload=<String,dynamic>{'branchId':branch,
      if(inlineActive!=originalActive)'active':inlineActive,
      if(widget.kind=='skus'&&originalActive&&!inlineActive)'reason':inlineReason.trim(),
      if(widget.kind=='barcodes'&&(inlinePrimary!=originalPrimary||!inlineActive&&originalPrimary))'isPrimary':inlineActive&&inlinePrimary};
    if(payload.length==1){setState(()=>inlineEditId=null);return;}
    setState(()=>busy=true);
    try{
      await widget.client.updateR1Catalog(widget.session.token,widget.kind,id,revision,payload);
      if(!mounted)return;
      setState(()=>inlineEditId=null);ErpToast.show(context,'Đã cập nhật.');await reload();
    }on ErpApiError catch(e){if(mounted){ErpToast.show(context,errorMessage(e),isError:true);await reload();}}
    finally{if(mounted)setState(()=>busy=false);}
  }
  Future<void> editRow(Map<String,dynamic> row)async{
    if(!canEditLifecycle||busy||widget.branchId==null)return;
    final targetId=row['id'],revision=row['revision'];
    if(targetId is! String||revision is! int)return;
    final branch=widget.branchId!;
    if(fixedProductId!=null){setState((){inlineEditId=targetId;inlineActive=row['active']==true;inlinePrimary=row['isPrimary']==true;inlineReason='';});return;}
    var active=row['active']==true;
    var primary=row['isPrimary']==true;
    var name=(row['name']??'').toString();
    final isBase=widget.kind=='skus'&&row['isBase']==true;
    var reason='';
    final originalName=name,originalActive=active,originalPrimary=primary;
    final fields=await showDialog<Map<String,dynamic>>(context:context,
      builder:(dialog)=>StatefulBuilder(builder:(ctx,refresh)=>AlertDialog(
        key:const ValueKey('r1-lifecycle-edit-dialog'),
        insetPadding:const EdgeInsets.symmetric(horizontal:12,vertical:12),
        title:Text('Sửa '+heading.toLowerCase()),
        content:SizedBox(width:(MediaQuery.sizeOf(ctx).width-70)
          .clamp(220.0,460.0).toDouble(),
          child:SingleChildScrollView(child:Column(
            mainAxisSize:MainAxisSize.min,
            crossAxisAlignment:CrossAxisAlignment.stretch,children:[
              Text('Mã: ${row['code']??row['barcode']??'—'}',
                style:TextStyle(fontSize:12,color:ErpPalette.of(ctx).muted)),
              if(widget.kind=='channels')...[
                const SizedBox(height:12),
                TextFormField(initialValue:name,maxLength:160,
                  decoration:const InputDecoration(labelText:'Tên kênh bán'),
                  onChanged:(v)=>name=v),
              ],
              const SizedBox(height:12),
              SwitchListTile(contentPadding:EdgeInsets.zero,
                key:const ValueKey('r1-lifecycle-active'),
                title:const Text('Đang sử dụng'),value:active,
                onChanged:(v)=>refresh(()=>active=v)),
              if(widget.kind=='skus'&&!active)...[
                const SizedBox(height:12),
                TextFormField(
                  key:const ValueKey('r1-sku-disable-reason'),
                  decoration:const InputDecoration(labelText:'Lý do ngừng SKU',
                    hintText:'Ví dụ: Nhập sai mã SKU'),
                  maxLines:2,onChanged:(v)=>refresh(()=>reason=v.trim())),
              ],
              if(isBase)Text(
                'SKU gốc gắn cố định với mã sản phẩm và đơn vị tồn kho. '
                'Nếu nhập sai SKU gốc, hãy ngừng SKU/sản phẩm cũ, '
                'tạo sản phẩm mới với mã đúng. Không tái sử dụng mã/đơn vị '
                'trên cùng sản phẩm; chứng từ và lịch sử cũ vẫn giữ nguyên.',
                style:TextStyle(color:ErpPalette.of(ctx).muted,fontSize:12)),
              if(widget.kind=='barcodes')SwitchListTile(
                contentPadding:EdgeInsets.zero,
                key:const ValueKey('r1-lifecycle-primary'),
                title:const Text('Mã vạch chính'),value:primary&&active,
                onChanged:active?(v)=>refresh(()=>primary=v):null),
              Text('Mã SKU, mã vạch và hệ số quy đổi đã tạo '
                'không được sửa trực tiếp. Ngừng mã sai và tạo mã mới.',
                style:TextStyle(color:ErpPalette.of(ctx).muted,fontSize:12)),
            ]))),
        actions:[
          TextButton(onPressed:()=>Navigator.pop(dialog),child:const Text('Hủy')),
          FilledButton(key:const ValueKey('r1-lifecycle-save'),
            onPressed:widget.kind=='skus'&&originalActive&&!active&&reason.length<3
              ?null:()=>Navigator.pop(dialog,{
              'branchId':branch,
              if(widget.kind=='channels'&&name!=originalName)'name':name.trim(),
              if(active!=originalActive)'active':active,
              if(widget.kind=='skus'&&originalActive&&!active)'reason':reason,
              if(widget.kind=='barcodes'&&(primary!=originalPrimary||
                !active&&originalPrimary))
                'isPrimary':active&&primary,
            }),child:const Text('Lưu thay đổi')),
        ],
      )));
    if(fields==null||!mounted||fields.length==1)return;
    setState(()=>busy=true);
    try{
      await widget.client.updateR1Catalog(widget.session.token,widget.kind,
        targetId,revision,fields);
      if(!mounted)return;
      ErpToast.show(context,'Đã cập nhật trên server.');
      await reload();
    }on ErpApiError catch(e){
      if(mounted){ErpToast.show(context,errorMessage(e),isError:true);await reload();}
    }finally{if(mounted)setState(()=>busy=false);}
  }

  Widget editor(double width){
    final wide=width>660;
    final slotWidth=wide?280.0:width-34;
    Widget slot(Widget value)=>SizedBox(width:slotWidth,child:value);
    return Card(key:const ValueKey('r1-editor'),
      child:Padding(padding:const EdgeInsets.all(16),
        child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          Text(isQuote?'Tra giá theo ngữ cảnh':'Thêm '+heading.toLowerCase(),
            style:TextStyle(fontSize:18,fontWeight:FontWeight.w700,
              color:ErpPalette.of(context).ink)),
          const SizedBox(height:14),
          if(busy)const LinearProgressIndicator(),
          Wrap(spacing:12,runSpacing:14,children:[
            if(widget.kind=='units'||widget.kind=='skus')...[
              if(fixedProductId==null)slot(dropdown('Sản phẩm',productId,products,
                (v)=>setState(()=>productId=v))),
              if(widget.kind=='skus')slot(textField('code','Mã SKU',hint:'SP001-T')),
              slot(DropdownButtonFormField<String>(
                key:const ValueKey('r1-unit-directory-select'),
                isExpanded:true,
                initialValue:unitDefinitions.any((u)=>u['code']==getField('unitCode'))
                  ?getField('unitCode'):null,
                decoration:const InputDecoration(labelText:'Đơn vị tính'),
                items:unitDefinitions.map((u)=>DropdownMenuItem<String>(
                  value:u['code'] as String,
                  child:Text("${u['code']} · ${u['name']}",
                    overflow:TextOverflow.ellipsis))).toList(),
                onChanged:(v)=>setState(()=>fields['unitCode']!.text=v??''))),
              slot(textField('toBase','Hệ số quy đổi',numeric:true,hint:'12')),
            ],
            if(widget.kind=='barcodes')...[
              slot(dropdown('SKU bán',skuId,skus,(v)=>changeQuoteContext(()=>skuId=v))),
              slot(textField('barcode','Mã vạch')),
              slot(SwitchListTile(
                title:const Text('Mã chính'),value:primary,
                onChanged:(v)=>setState(()=>primary=v))),
            ],
            if(widget.kind=='channels')...[
              slot(textField('code','Mã kênh',hint:'ONLINE')),
              slot(textField('name','Tên kênh',hint:'Đặt hàng trực tuyến')),
            ],
            if(widget.kind=='rules'||isQuote)...[
              if(isQuote)slot(DropdownButtonFormField<String>(
                key:const ValueKey('r1-quote-price-list-select'),
                isExpanded:true,initialValue:listId,
                decoration:const InputDecoration(labelText:'Bảng giá',
                  helperText:'Tự chọn theo khách, nhóm, kênh và mức ưu tiên'),
                items:[
                  const DropdownMenuItem<String>(value:null,
                    child:Text('Tự chọn bảng giá phù hợp')),
                  ...lists.map((x)=>DropdownMenuItem<String>(
                    value:x['id'] as String,
                    child:Text('${x['code']} · ${x['name']}',
                      overflow:TextOverflow.ellipsis))),
                ],
                onChanged:(v)=>changeQuoteContext(()=>listId=v),
              ))
              else slot(dropdown('Bảng giá',listId,lists,
                (v)=>changeQuoteContext(()=>listId=v))),
              slot(dropdown('SKU bán',skuId,skus,(v)=>changeQuoteContext(()=>skuId=v))),
              if(isQuote||scope=='CUSTOMER'||scope=='PROMOTION')
                slot(dropdown('Khách hàng',customerId,customers,
                  (v)=>changeQuoteContext(()=>customerId=v),empty:true)),
              if(isQuote||scope=='CHANNEL'||scope=='CUSTOMER_GROUP'||
                 scope=='CUSTOMER'||scope=='PROMOTION')
                slot(dropdown('Kênh bán',channelId,channels,
                  (v)=>changeQuoteContext(()=>channelId=v),empty:true)),
            ],
            if(widget.kind=='rules')...[
              slot(DropdownButtonFormField<String>(
                initialValue:scope,
                decoration:const InputDecoration(labelText:'Phạm vi giá'),
                items:const [
                  DropdownMenuItem(value:'BASE',child:Text('Giá cơ sở')),
                  DropdownMenuItem(value:'CHANNEL',child:Text('Theo kênh')),
                  DropdownMenuItem(value:'CUSTOMER_GROUP',child:Text('Nhóm khách')),
                  DropdownMenuItem(value:'CUSTOMER',child:Text('Khách riêng')),
                  DropdownMenuItem(value:'PROMOTION',child:Text('Khuyến mãi')),
                ],
                onChanged:(v){if(v!=null)setState(()=>scope=v);},
              )),
              if(scope=='PROMOTION')slot(DropdownButtonFormField<int>(
                key:const ValueKey('r1-promotion-days'),
                initialValue:promotionDays,
                decoration:const InputDecoration(labelText:'Thời hạn khuyến mãi'),
                items:const [
                  DropdownMenuItem(value:1,child:Text('1 ngày')),
                  DropdownMenuItem(value:7,child:Text('7 ngày')),
                  DropdownMenuItem(value:30,child:Text('30 ngày')),
                  DropdownMenuItem(value:90,child:Text('90 ngày')),
                ],
                onChanged:(v){if(v!=null)setState(()=>promotionDays=v);},
              )),
              if(scope=='CUSTOMER_GROUP'||scope=='CUSTOMER'||scope=='PROMOTION')
                slot(DropdownButtonFormField<String?>(
                  key:const ValueKey('r1-customer-group-directory-select'),
                  isExpanded:true,
                  initialValue:customerGroups.any((g)=>g['code']==getField('customerGroup'))
                    ?getField('customerGroup'):null,
                  decoration:const InputDecoration(labelText:'Nhóm khách hàng'),
                  items:[
                    const DropdownMenuItem<String?>(
                      value:null,child:Text('Không áp dụng')),
                    ...customerGroups.map((g)=>DropdownMenuItem<String?>(
                      value:g['code'] as String,
                      child:Text("${g['code']} · ${g['name']}",
                        overflow:TextOverflow.ellipsis))),
                  ],
                  onChanged:(v)=>setState(()=>fields['customerGroup']!.text=v??''))),
              slot(DropdownButtonFormField<String>(
                initialValue:adjustment,
                decoration:const InputDecoration(labelText:'Cách tính giá'),
                items:const [
                  DropdownMenuItem(value:'FIXED_PRICE',child:Text('Giá cố định')),
                  DropdownMenuItem(value:'PERCENT_DISCOUNT',child:Text('Giảm theo %')),
                  DropdownMenuItem(value:'AMOUNT_DISCOUNT',child:Text('Giảm số tiền')),
                  DropdownMenuItem(value:'PERCENT_MARKUP',child:Text('Tăng theo %')),
                  DropdownMenuItem(value:'AMOUNT_MARKUP',child:Text('Tăng số tiền')),
                ],onChanged:(v){if(v!=null)setState(()=>adjustment=v);},
              )),
              slot(textField('amount','Giá hoặc tỷ lệ',numeric:true)),
              slot(textField('minQuantity','Từ số lượng',numeric:true)),
              slot(textField('priority','Mức ưu tiên',numeric:true)),
              slot(Row(children:[
                Expanded(child:OutlinedButton.icon(
                  key:const ValueKey('r1-rule-start-day'),
                  onPressed:busy?null:()=>chooseDay('start'),
                  icon:const Icon(Icons.event,size:17),
                  label:Text(dayLabel(ruleStartDay,'Bắt đầu ngay'),
                    overflow:TextOverflow.ellipsis))),
                if(ruleStartDay!=null)IconButton(
                  tooltip:'Bắt đầu ngay',icon:const Icon(Icons.close,size:17),
                  onPressed:()=>setState(()=>ruleStartDay=null)),
              ])),
              slot(Row(children:[
                Expanded(child:OutlinedButton.icon(
                  key:const ValueKey('r1-rule-end-day'),
                  onPressed:busy?null:()=>chooseDay('end'),
                  icon:const Icon(Icons.event_busy,size:17),
                  label:Text(dayLabel(ruleEndDay,'Không đặt ngày kết thúc'),
                    overflow:TextOverflow.ellipsis))),
                if(ruleEndDay!=null)IconButton(
                  tooltip:'Không giới hạn',icon:const Icon(Icons.close,size:17),
                  onPressed:()=>setState(()=>ruleEndDay=null)),
              ])),
              slot(DropdownButtonFormField<String>(
                initialValue:stacking,
                decoration:const InputDecoration(labelText:'Kết hợp quy tắc'),
                items:const [
                  DropdownMenuItem(value:'EXCLUSIVE',child:Text('Chọn một')),
                  DropdownMenuItem(value:'STACKABLE',child:Text('Cộng dồn')),
                ],onChanged:(v){if(v!=null)setState(()=>stacking=v);},
              )),
              slot(SwitchListTile(title:const Text('Dừng xử lý tại đây'),
                value:stopProcessing,onChanged:(v)=>setState(()=>stopProcessing=v))),
            ],

            if(isQuote)...[
              slot(textField('quantity','Số lượng',numeric:true)),
              slot(Row(children:[
                Expanded(child:OutlinedButton.icon(
                  key:const ValueKey('r1-quote-date'),
                  onPressed:busy?null:()=>chooseDay('quote'),
                  icon:const Icon(Icons.event,size:17),
                  label:Text(dayLabel(quoteDay,'Giá hiện tại'),
                    overflow:TextOverflow.ellipsis))),
                if(quoteDay!=null)IconButton(
                  tooltip:'Tra giá hiện tại',icon:const Icon(Icons.close,size:17),
                  onPressed:()=>changeQuoteContext(()=>quoteDay=null)),
              ])),
            ],
          ]),
          if(widget.kind=='rules')Padding(
            padding:EdgeInsets.only(top:14),
            child:Text('Giá SKU lẻ và SKU thùng độc lập. Quy tắc đã lưu không bị ghi đè.',
              style:TextStyle(color:ErpPalette.of(context).muted,fontSize:12))),
          if(error!=null)Padding(padding:const EdgeInsets.only(top:12),
            child:Text(error!,style:TextStyle(color:ErpPalette.of(context).danger))),
          const SizedBox(height:15),
          Wrap(spacing:10,children:[
            OutlinedButton(onPressed:busy?null:(){
              // Closing the panel MUST NOT discard an unacknowledged write.
              setState((){form=false;error=null;});
            },child:const Text('Đóng')),
            FilledButton.icon(key:const ValueKey('r1-save'),
              onPressed:busy?null:isQuote?simulate:save,
              icon:const Icon(Icons.check),
              label:Text(isQuote?'Tra giá':
                pending==null?'Lưu thông tin':'Kiểm tra yêu cầu đã gửi')),
          ]),
          if(quote!=null)...[
            const Divider(height:32),
            Text('Đơn giá: '+money(quote!['unitPrice']),
              key:const ValueKey('r1-quote-price'),
              style:TextStyle(fontSize:22,fontWeight:FontWeight.w800,
                color:ErpPalette.of(context).primary)),
            const SizedBox(height:6),
            Text('SKU: ${quote!['sku']} · ${quote!['productName']} · '
              'ĐVT: ${quote!['unitCode']} · SL: ${erpNumberText(quote!['quantity'])}',
              key:const ValueKey('r1-quote-item-context')),
            Text('Bảng giá: ${quote!['priceListCode']??quote!['priceListId']}'),
            Text('${quote!['priceListSelectionReason']??'Bảng giá chỉ định'}',
              key:const ValueKey('r1-quote-list-reason'),
              style:TextStyle(color:ErpPalette.of(context).muted,fontSize:12)),
            Text('Thành tiền: '+money(quote!['lineTotal'])),
            Text('Quy đổi về đơn vị gốc: '+erpNumberText(quote!['normalizedBaseQuantity'])),
            const SizedBox(height:12),
            const Text('Quy tắc áp dụng:',style:TextStyle(fontWeight:FontWeight.w700)),
            for(final t in quote!['trace'] as List<dynamic>)
              Text('• '+((t as Map)['reason']?.toString()??
                  erpPriceRuleLabel(t['scope']))+' · '+
                erpPriceRuleLabel(t['adjustment'])+' → '+money(t['result'])),
            const SizedBox(height:8),
            Text('Giá do máy chủ tính; chưa xác minh tồn khả dụng.',
              style:TextStyle(color:ErpPalette.of(context).muted,fontSize:12)),
          ],
        ])),
    );
  }
  List<(String,String)> get columns=>switch(widget.kind){
    'units'=>const [('productCode','Sản phẩm'),('unitCode','Đơn vị'),('toBase','Quy đổi')],
    'skus'=>const [('code','SKU'),('productName','Sản phẩm'),
      ('unitCode','Đơn vị'),('toBase','Quy đổi'),('barcode','Mã vạch'),
      ('active','Đang dùng')],
    'barcodes'=>const [('sku','SKU'),('barcode','Mã vạch'),('isPrimary','Mã chính'),
      ('active','Đang dùng')],
    'channels'=>const [('code','Mã'),('name','Kênh bán'),
      ('active','Đang dùng')],
    'rules'=>const [
      ('priceListCode','Bảng giá'),('sku','SKU'),('scopeKind','Áp dụng'),
      ('channelCode','Kênh'),('customerCode','Khách'),('customerGroup','Nhóm khách'),
      ('minQuantity','Từ số lượng'),('adjustment','Cách tính'),
      ('amount','Giá / tỷ lệ'),('priority','Ưu tiên'),
      ('effectiveFrom','Bắt đầu'),('effectiveTo','Kết thúc')],
    _=>const [],
  };
  String cell(Map<String,dynamic> item,String key){
    final value=item[key];if(value==null)return '—';
    if(value is bool)return value?'Có':'Không';
    if(key=='toBase'||key=='amount'||key=='minQuantity')
      return erpNumberText(value);
    if((key=='effectiveFrom'||key=='effectiveTo')&&value is String){
      final date=DateTime.tryParse(value)?.toLocal();
      if(date!=null)return '${date.day.toString().padLeft(2,'0')}/'
        '${date.month.toString().padLeft(2,'0')}/${date.year}';
    }
    if(key=='scopeKind'||key=='adjustment')return erpPriceRuleLabel(value);
    return value.toString();
  }
  Widget records(){
    if(loading)return const Padding(padding:EdgeInsets.all(24),
      child:Center(child:CircularProgressIndicator()));
    if(items.isEmpty)return Padding(padding:EdgeInsets.all(26),
      child:Center(child:Text('Chưa có dữ liệu. Hãy thêm thông tin để bắt đầu.',
        style:TextStyle(color:ErpPalette.of(context).muted))));
    if(fixedProductId!=null)return Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
      for(final x in items)Padding(padding:const EdgeInsets.only(top:6,bottom:6),child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
        Wrap(spacing:8,runSpacing:6,crossAxisAlignment:WrapCrossAlignment.center,children:[
          for(final c in columns.where((c)=>!['productCode','productName','active','isPrimary'].contains(c.$1)))
            SizedBox(width:c.$1=='code'||c.$1=='barcode'?180:130,child:TextFormField(
              key:ValueKey('locked-${widget.kind}-${x['id']}-${c.$1}-${cell(x,c.$1)}'),initialValue:cell(x,c.$1),readOnly:true,
              decoration:InputDecoration(labelText:c.$2,isDense:true,suffixIcon:const Icon(Icons.lock_outline,size:14)))),
          if(widget.kind!='units')Text(x['active']==true?'Đang dùng':'Ngừng dùng',style:TextStyle(fontSize:12,color:ErpPalette.of(context).muted)),
          if(widget.kind=='barcodes'&&x['isPrimary']==true)const Text('Mã chính'),
          if(canEditLifecycle&&inlineEditId!=x['id'])TextButton(key:ValueKey('r1-edit-${x['id']}'),onPressed:busy?null:()=>editRow(x),child:const Text('Sửa')),
        ]),
        if(inlineEditId==x['id'])...[
          SwitchListTile(contentPadding:EdgeInsets.zero,title:const Text('Đang sử dụng'),value:inlineActive,onChanged:busy?null:(v)=>setState(()=>inlineActive=v)),
          if(widget.kind=='barcodes')SwitchListTile(contentPadding:EdgeInsets.zero,title:const Text('Mã vạch chính'),value:inlinePrimary&&inlineActive,onChanged:busy||!inlineActive?null:(v)=>setState(()=>inlinePrimary=v)),
          if(widget.kind=='skus'&&x['active']==true&&!inlineActive)TextFormField(key:ValueKey('product-sku-reason-${x['id']}'),initialValue:inlineReason,decoration:const InputDecoration(labelText:'Lý do ngừng SKU'),onChanged:(v)=>setState(()=>inlineReason=v)),
          Wrap(spacing:8,children:[TextButton(onPressed:busy?null:()=>setState(()=>inlineEditId=null),child:const Text('Hủy')),
            FilledButton(onPressed:busy||(widget.kind=='skus'&&x['active']==true&&!inlineActive&&inlineReason.trim().length<3)?null:()=>saveInlineLifecycle(x),child:const Text('Lưu thay đổi'))]),
        ],
      ])),
    ]);
    return LayoutBuilder(builder:(ctx,box){
      if(box.maxWidth<680)return Column(children:items.map((x)=>Column(children:[
        Padding(padding:const EdgeInsets.symmetric(horizontal:8,vertical:12),
          child:Column(crossAxisAlignment:CrossAxisAlignment.start,
            children:[
              ...columns.map((c)=>Padding(padding:const EdgeInsets.only(bottom:5),
                child:Text(c.$2+': '+cell(x,c.$1)))),
              if(canEditLifecycle)TextButton.icon(
                key:ValueKey('r1-edit-'+x['id'].toString()),
                onPressed:busy?null:()=>editRow(x),
                icon:const Icon(Icons.edit_outlined),label:const Text('Sửa')),
              if(widget.kind=='rules'&&canWrite&&x['scopeKind']!='BASE'&&x['retiredAt']==null)
                TextButton.icon(onPressed:busy?null:()=>retirePolicy(x),
                  icon:const Icon(Icons.event_busy),
                  label:const Text('Kết thúc chính sách')),
              if(x['retiredAt']!=null)const Text('Đã kết thúc'),
            ])),
        const Divider(height:1),
      ])).toList());
      return SingleChildScrollView(scrollDirection:Axis.horizontal,
        child:DataTable(headingRowColor:WidgetStatePropertyAll(ErpPalette.of(ctx).mint),
          headingTextStyle:TextStyle(color:ErpPalette.of(ctx).ink,fontWeight:FontWeight.w700),
          columns:columns.map((c)=>DataColumn(label:Text(c.$2))).toList()+
            [if(widget.kind=='rules'||canEditLifecycle)
              const DataColumn(label:Text('Thao tác'))],
          rows:items.map((x)=>DataRow(cells:columns.map((c)=>
            DataCell(c.$1=='scopeKind'&&widget.kind=='rules'
              ? Column(mainAxisAlignment:MainAxisAlignment.center,
                crossAxisAlignment:CrossAxisAlignment.start,children:[
                  Text(cell(x,c.$1)),
                  if(x['retiredAt']!=null)Text('Đã kết thúc',
                    style:TextStyle(color:ErpPalette.of(ctx).muted,fontSize:11)),
                ])
              :Text(cell(x,c.$1)))).toList()+
            [if(widget.kind=='rules'||canEditLifecycle)DataCell(
              Row(mainAxisSize:MainAxisSize.min,children:[
                if(canEditLifecycle)IconButton(
                  key:ValueKey('r1-edit-'+x['id'].toString()),
                  onPressed:busy?null:()=>editRow(x),
                  icon:const Icon(Icons.edit_outlined,size:18),
                  tooltip:'Sửa trạng thái/thông tin'),
                if(widget.kind=='rules')
                  x['scopeKind']!='BASE'&&x['retiredAt']==null&&canWrite
                    ? TextButton(onPressed:busy?null:()=>retirePolicy(x),
                        child:Text(widget.client.pendingR1(widget.session.actorId,
                          widget.branchId!, 'rules.retire.'+x['id'].toString())==null
                            ?'Kết thúc':'Kiểm tra yêu cầu'))
                    :const Text('—'),
              ])),
            ])).toList()));
    });
  }
  @override Widget build(BuildContext context){
    if(fixedProductId!=null)return LayoutBuilder(builder:(ctx,box)=>Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
      Padding(padding:const EdgeInsets.only(top:8,bottom:4),child:Row(children:[
        Expanded(child:Text(heading,style:const TextStyle(fontWeight:FontWeight.w700))),
        IconButton(tooltip:'Làm mới',onPressed:loading?null:reload,icon:const Icon(Icons.refresh,size:18)),
        if(canWrite)TextButton.icon(key:ValueKey('product-add-'+widget.kind),onPressed:busy?null:openForm,
          icon:const Icon(Icons.add,size:17),label:Text(widget.kind=='units'?'Thêm quy đổi':widget.kind=='skus'?'Thêm SKU':'Thêm mã vạch')),
      ])),
      if(error!=null&&!form)Text(error!,style:TextStyle(color:ErpPalette.of(ctx).danger)),
      records(),
      if(form)editor(box.maxWidth),
      const Divider(height:16),
    ]));
    return LayoutBuilder(builder:(ctx,constraints)=>Column(
      crossAxisAlignment:CrossAxisAlignment.stretch,children:[
        Card(child:Padding(padding:const EdgeInsets.all(16),
          child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
            Wrap(spacing:12,runSpacing:12,
              crossAxisAlignment:WrapCrossAlignment.center,children:[
                Text(heading,style:TextStyle(color:ErpPalette.of(ctx).ink,
                  fontSize:18,fontWeight:FontWeight.w800)),
                if(fixedProductId==null&&widget.branches.isNotEmpty)SizedBox(width:235,child:
                  DropdownButtonFormField<String>(
                    key:ValueKey('r1-branch-'+widget.branchId.toString()),
                    initialValue:widget.branchId,
                    decoration:const InputDecoration(labelText:'Chi nhánh'),
                    isExpanded:true,
                    items:widget.branches.map((x)=>DropdownMenuItem<String>(
                      value:x['id'] as String,
                      child:Text(x['name'].toString(),overflow:TextOverflow.ellipsis))).toList(),
                    onChanged:(v){if(v!=null)widget.changeBranch(v);},
                  )),
                if(!isQuote&&fixedProductId==null)SizedBox(width:260,child:TextField(controller:query,
                  onSubmitted:(_)=>reload(),
                  decoration:InputDecoration(labelText:'Tìm mã, tên, mã vạch',
                    prefixIcon:const Icon(Icons.search),
                    suffixIcon:IconButton(onPressed:reload,
                      icon:const Icon(Icons.arrow_forward),tooltip:'Tìm kiếm')))),
                OutlinedButton.icon(onPressed:loading?null:reload,
                  icon:const Icon(Icons.refresh),label:const Text('Làm mới')),
                if(isQuote||canWrite)FilledButton.icon(
                  key:const ValueKey('r1-new'),
                  onPressed:busy?null:openForm,
                  icon:const Icon(Icons.add),
                  label:Text(isQuote?'Tra giá':
                    widget.branchId!=null&&widget.client.pendingR1(
                      widget.session.actorId,widget.branchId!,widget.kind)!=null
                      ?'Kiểm tra yêu cầu trước':'Thêm mới')),
              ]),
            if(error!=null&&!form)Padding(
              padding:const EdgeInsets.only(top:12),
              child:Text(error!,style:TextStyle(color:ErpPalette.of(ctx).danger))),
            const SizedBox(height:16),
            if(!isQuote)records()
            else if(!form)Text(
              'Chọn SKU, khách hàng, kênh bán và bảng giá để xem giá áp dụng.',
              style:TextStyle(color:ErpPalette.of(ctx).muted)),
          ]))),
        if(form)editor(constraints.maxWidth),
      ],
    ));
  }
}
