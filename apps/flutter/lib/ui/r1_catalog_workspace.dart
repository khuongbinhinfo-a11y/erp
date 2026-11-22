import 'package:material_ui/material_ui.dart';
import 'erp_tokens.dart';
import 'erp_display.dart';
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
  const R1CatalogWorkspace({super.key,required this.kind,required this.branchId,
    required this.branches,required this.session,required this.client,
    required this.changeBranch});
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
  bool primary=true,stopProcessing=false,loading=true,busy=false,form=false;
  int generation=0,seq=0,quoteSerial=0;
  Map<String,dynamic>? pending,quote;
  String? pendingKey;
  bool get isQuote=>widget.kind=='quote';
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
      old.session.token!=widget.session.token||old.client!=widget.client){
      generation++;quoteSerial++;form=false;pending=null;pendingKey=null;quote=null;
      query.clear();items=[];reload();
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
  String getField(String key)=>fields[key]!.text.trim();
  String money(dynamic raw)=>erpVndText(raw);
  String errorMessage(ErpApiError e)=>switch(e.code){
    'SKU_HAS_NO_EFFECTIVE_BASE_PRICE'=>'Chưa có giá cơ sở hiệu lực cho SKU này.',
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
      final fetched=await Future.wait([
        widget.client.catalogItems(widget.session.token,'products',branchId:branch),
        widget.client.catalogItems(widget.session.token,'r1/skus',branchId:branch),
        widget.client.catalogItems(widget.session.token,'price-lists',branchId:branch),
        widget.client.catalogItems(widget.session.token,'customers',branchId:branch),
        widget.client.catalogItems(widget.session.token,'r1/channels',branchId:branch),
        widget.client.catalogDirectoryAll(widget.session.token,'customer-groups',
          branchId:branch),
        widget.client.catalogUnitDefinitionsAll(widget.session.token,
          branchId:branch),
      ]);
      if(!mounted||widget.branchId!=branch)return;
      setState((){
        products=fetched[0].where((x)=>x['active']!=false).toList();
        skus=fetched[1].where((x)=>x['active']!=false).toList();
        lists=fetched[2].where((x)=>x['active']!=false).toList();
        customers=fetched[3].where((x)=>x['active']!=false).toList();
        channels=fetched[4].where((x)=>x['active']!=false).toList();
        customerGroups=fetched[5].where((x)=>x['active']!=false).toList();
        unitDefinitions=fetched[6].where((x)=>x['active']!=false).toList();
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
      key:ValueKey('r1-input-'+key),controller:fields[key],
      onChanged:key=='quantity'?(_)=>changeQuoteContext((){}):null,
      keyboardType:numeric?const TextInputType.numberWithOptions(decimal:true):TextInputType.text,
      decoration:InputDecoration(labelText:title,hintText:hint));
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
          final start=DateTime.now().toUtc();
          payload.addAll({
            'priceListId':listId,'sellSkuId':skuId,'scopeKind':scope,
            'adjustment':adjustment,'amount':getField('amount'),
            'priority':rank,'stacking':stacking,'stopProcessing':stopProcessing,
            'minQuantity':getField('minQuantity'),
            'effectiveFrom':start.toIso8601String(),
            if(scope=='PROMOTION')
              'effectiveTo':start.add(Duration(days:promotionDays)).toIso8601String(),
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
        e.code=='PRICE_TARGET_UNAVAILABLE';
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
    if(busy||widget.branchId==null||skuId==null||listId==null)return;
    final stamp=++quoteSerial;
    setState((){busy=true;error=null;quote=null;});
    try{
      final result=await widget.client.r1PriceQuote(widget.session.token,{
        'branchId':widget.branchId,'sellSkuId':skuId,
        'priceListId':listId,'quantity':getField('quantity'),
        if(customerId!=null)'customerId':customerId,
        if(channelId!=null)'channelId':channelId,
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
  Widget editor(double width){
    final wide=width>660;
    final slotWidth=wide?280.0:width-34;
    Widget slot(Widget value)=>SizedBox(width:slotWidth,child:value);
    return Card(key:const ValueKey('r1-editor'),
      child:Padding(padding:const EdgeInsets.all(16),
        child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          Text(isQuote?'Tra giá theo ngữ cảnh':'Thêm '+heading.toLowerCase(),
            style:const TextStyle(fontSize:18,fontWeight:FontWeight.w700,
              color:ErpTokens.ink)),
          const SizedBox(height:14),
          if(busy)const LinearProgressIndicator(),
          Wrap(spacing:12,runSpacing:14,children:[
            if(widget.kind=='units'||widget.kind=='skus')...[
              slot(dropdown('Sản phẩm',productId,products,
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
              slot(textField('toBase','Hệ số quy đổi',numeric:true,hint:'12.000000')),
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
              slot(dropdown('Bảng giá',listId,lists,(v)=>changeQuoteContext(()=>listId=v))),
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
            if(isQuote)slot(textField('quantity','Số lượng',numeric:true)),
          ]),
          if(widget.kind=='rules')const Padding(
            padding:EdgeInsets.only(top:14),
            child:Text('Giá SKU lẻ và SKU thùng độc lập. Quy tắc đã lưu không bị ghi đè.',
              style:TextStyle(color:ErpTokens.muted,fontSize:12))),
          if(error!=null)Padding(padding:const EdgeInsets.only(top:12),
            child:Text(error!,style:const TextStyle(color:ErpTokens.danger))),
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
              style:const TextStyle(fontSize:22,fontWeight:FontWeight.w800,
                color:ErpTokens.primary)),
            Text('Thành tiền: '+money(quote!['lineTotal'])),
            Text('Quy đổi về đơn vị gốc: '+erpDecimalText(quote!['normalizedBaseQuantity'])),
            const SizedBox(height:12),
            const Text('Quy tắc áp dụng:',style:TextStyle(fontWeight:FontWeight.w700)),
            for(final t in quote!['trace'] as List<dynamic>)
              Text('• '+erpPriceRuleLabel((t as Map)['scope'])+' – '+
                erpPriceRuleLabel(t['adjustment'])+' → '+money(t['result'])),
            const SizedBox(height:8),
            const Text('Giá do máy chủ tính; chưa xác minh tồn khả dụng.',
              style:TextStyle(color:ErpTokens.muted,fontSize:12)),
          ],
        ])),
    );
  }
  List<(String,String)> get columns=>switch(widget.kind){
    'units'=>const [('productCode','Sản phẩm'),('unitCode','Đơn vị'),('toBase','Quy đổi')],
    'skus'=>const [('code','SKU'),('productName','Sản phẩm'),
      ('unitCode','Đơn vị'),('toBase','Quy đổi'),('barcode','Mã vạch')],
    'barcodes'=>const [('barcode','Mã vạch'),('isPrimary','Mã chính')],
    'channels'=>const [('code','Mã'),('name','Kênh bán')],
    'rules'=>const [('sku','SKU'),('scopeKind','Áp dụng'),
      ('adjustment','Cách tính'),('amount','Giá / tỷ lệ'),('priority','Ưu tiên')],
    _=>const [],
  };
  String cell(Map<String,dynamic> item,String key){
    final value=item[key];if(value==null)return '—';
    if(value is bool)return value?'Có':'Không';
    if(key=='toBase'||key=='amount')return erpDecimalText(value);
    if(key=='scopeKind'||key=='adjustment')return erpPriceRuleLabel(value);
    return value.toString();
  }
  Widget records(){
    if(loading)return const Padding(padding:EdgeInsets.all(24),
      child:Center(child:CircularProgressIndicator()));
    if(items.isEmpty)return const Padding(padding:EdgeInsets.all(26),
      child:Center(child:Text('Chưa có dữ liệu. Hãy thêm thông tin để bắt đầu.',
        style:TextStyle(color:ErpTokens.muted))));
    return LayoutBuilder(builder:(ctx,box){
      if(box.maxWidth<680)return Column(children:items.map((x)=>Card(
        child:Padding(padding:const EdgeInsets.all(12),
          child:Column(crossAxisAlignment:CrossAxisAlignment.start,
            children:[
              ...columns.map((c)=>Padding(padding:const EdgeInsets.only(bottom:5),
                child:Text(c.$2+': '+cell(x,c.$1)))),
              if(widget.kind=='rules'&&canWrite&&x['scopeKind']!='BASE'&&x['retiredAt']==null)
                TextButton.icon(onPressed:busy?null:()=>retirePolicy(x),
                  icon:const Icon(Icons.event_busy),
                  label:const Text('Kết thúc chính sách')),
              if(x['retiredAt']!=null)const Text('Đã kết thúc'),
            ])),
      )).toList());
      return SingleChildScrollView(scrollDirection:Axis.horizontal,
        child:DataTable(headingRowColor:const WidgetStatePropertyAll(ErpTokens.mint),
          headingTextStyle:const TextStyle(color:ErpTokens.ink,fontWeight:FontWeight.w700),
          columns:columns.map((c)=>DataColumn(label:Text(c.$2))).toList()+
            [if(widget.kind=='rules')const DataColumn(label:Text('Thao tác'))],
          rows:items.map((x)=>DataRow(cells:columns.map((c)=>
            DataCell(c.$1=='scopeKind'&&widget.kind=='rules'
              ? Column(mainAxisAlignment:MainAxisAlignment.center,
                crossAxisAlignment:CrossAxisAlignment.start,children:[
                  Text(cell(x,c.$1)),
                  if(x['retiredAt']!=null)const Text('Đã kết thúc',
                    style:TextStyle(color:ErpTokens.muted,fontSize:11)),
                ])
              :Text(cell(x,c.$1)))).toList()+
            [if(widget.kind=='rules')DataCell(
              x['scopeKind']!='BASE'&&x['retiredAt']==null&&canWrite
                ? TextButton(onPressed:busy?null:()=>retirePolicy(x),
                    child:Text(widget.client.pendingR1(widget.session.actorId,
                      widget.branchId!, 'rules.retire.'+x['id'].toString())==null
                        ?'Kết thúc':'Kiểm tra yêu cầu'))
                :const Text('—'),
            )])).toList()));
    });
  }
  @override Widget build(BuildContext context){
    return LayoutBuilder(builder:(ctx,constraints)=>Column(
      crossAxisAlignment:CrossAxisAlignment.stretch,children:[
        Card(child:Padding(padding:const EdgeInsets.all(16),
          child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
            Wrap(spacing:12,runSpacing:12,
              crossAxisAlignment:WrapCrossAlignment.center,children:[
                Text(heading,style:const TextStyle(color:ErpTokens.ink,
                  fontSize:18,fontWeight:FontWeight.w800)),
                if(widget.branches.isNotEmpty)SizedBox(width:235,child:
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
                if(!isQuote)SizedBox(width:260,child:TextField(controller:query,
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
              child:Text(error!,style:const TextStyle(color:ErpTokens.danger))),
            const SizedBox(height:16),
            if(!isQuote)records()
            else if(!form)const Text(
              'Chọn SKU, khách hàng, kênh bán và bảng giá để xem giá áp dụng.',
              style:TextStyle(color:ErpTokens.muted)),
          ]))),
        if(form)editor(constraints.maxWidth),
      ],
    ));
  }
}
