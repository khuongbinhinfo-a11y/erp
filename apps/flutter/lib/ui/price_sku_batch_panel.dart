import 'package:material_ui/material_ui.dart';
import 'erp_number_input.dart';
import 'erp_tokens.dart';
import 'erp_toast.dart';
import 'identity_client.dart';

/// A SKU price correction appends a new BASE policy. Historical rules and
/// prices on already accepted sales documents are never edited.
class PriceSkuBatchPanel extends StatefulWidget {
  final ErpIdentityClient client;
  final IdentitySession session;
  final String branchId;
  final Map<String,dynamic> priceList;
  final bool canWrite;
  final VoidCallback onClose;
  const PriceSkuBatchPanel({super.key,required this.client,
    required this.session,required this.branchId,required this.priceList,
    required this.canWrite,required this.onClose});
  @override State<PriceSkuBatchPanel> createState()=>_PriceSkuBatchPanelState();
}

class _PriceSkuBatchPanelState extends State<PriceSkuBatchPanel> {
  final query=TextEditingController();
  final sharedPrice=TextEditingController();
  final selected=<String,Map<String,dynamic>>{};
  final inputs=<String,TextEditingController>{};
  final current=<String,String>{};
  List<Map<String,dynamic>> rows=[],brands=[],groups=[],categories=[];
  String? brandId,groupId,categoryId;
  int page=0;
  static const pageSize=12;
  final reading=<String>{};
  List<Map<String,dynamic>> get pageRows=>rows.skip(page*pageSize).take(pageSize).toList();
  bool loading=false,saving=false;
  String? error;
  int generation=0;
  String get listId=>widget.priceList['id'].toString();
  String get token=>widget.session.token;
  @override void initState(){super.initState();loadTaxonomy();load();}
  Future<void> loadTaxonomy()async{
    try{
      final data=await Future.wait([
        widget.client.catalogDirectoryAll(token,'brands',branchId:widget.branchId),
        widget.client.catalogDirectoryAll(token,'groups',branchId:widget.branchId),
        widget.client.catalogDirectoryAll(token,'categories',branchId:widget.branchId),
      ]);
      if(mounted)setState((){brands=data[0];groups=data[1];categories=data[2];});
    }on ErpApiError catch(e){if(e.status!=503&&mounted)setState(()=>error=e.message);}
  }
  @override void didUpdateWidget(covariant PriceSkuBatchPanel old){
    super.didUpdateWidget(old);
    if(old.branchId!=widget.branchId||old.priceList['id']!=listId||
        old.session.token!=token){
      generation++;query.clear();selected.clear();current.clear();reading.clear();page=0;
      for(final field in inputs.values){field.dispose();}
      inputs.clear();rows=[];brandId=null;groupId=null;categoryId=null;
      brands=[];groups=[];categories=[];loadTaxonomy();load();
    }
  }
  @override void dispose(){
    generation++;query.dispose();sharedPrice.dispose();
    for(final field in inputs.values){field.dispose();}
    super.dispose();
  }
  Future<void> load()async{
    final run=++generation;
    setState((){loading=true;error=null;current.clear();reading.clear();page=0;});
    try{
      final found=await widget.client.r1CatalogItems(token,'skus',
        branchId:widget.branchId,query:query.text.trim(),
        brandId:brandId,groupId:groupId,categoryId:categoryId);
      if(mounted&&run==generation)setState((){
        rows=found.where((x)=>x['active']!=false).toList();
        loading=false;
      });
      if(mounted&&run==generation)await loadPagePrices();
    }on ErpApiError catch(e){
      if(mounted&&run==generation)setState((){
        loading=false;error=e.message;
      });
    }catch(_){
      if(mounted&&run==generation)setState((){
        loading=false;error='Không tải được SKU. Vui lòng tìm lại.';
      });
    }
  }
  String priceKind(String id)=>'catalog.sku-price.$listId.$id';
  bool unresolved(String id)=>widget.client.pendingR1(
    widget.session.actorId,widget.branchId,priceKind(id))!=null;
  void selectSku(Map<String,dynamic> sku,bool checked){
    final id=sku['id'].toString();
    setState((){
      if(checked){
        selected[id]=sku;
        final input=inputs.putIfAbsent(id,()=>TextEditingController());
        final pending=widget.client.pendingR1(
          widget.session.actorId,widget.branchId,priceKind(id));
        if(pending!=null)input.text=erpGroupedDecimalText(pending.payload['amount']);
      }else{
        selected.remove(id);
        inputs.remove(id)?.dispose();
      }
    });
    if(checked&&!current.containsKey(id))loadCurrent(id);
  }
  Future<void> loadPagePrices()async{
    final run=generation;
    final ids=pageRows.map((x)=>x['id'].toString()).toList();
    for(var i=0;i<ids.length;i+=4){
      if(!mounted||run!=generation)return;
      await Future.wait(ids.skip(i).take(4).map((id)=>loadCurrent(id)));
    }
  }
  Future<void> loadCurrent(String id)async{
    if(current.containsKey(id)||reading.contains(id))return;
    final run=generation;
    reading.add(id);
    try{
      final result=await widget.client.r1PriceQuote(token,{
        'branchId':widget.branchId,'priceListId':listId,
        'sellSkuId':id,'quantity':'1',
      });
      if(!mounted||run!=generation)return;
      final quote=Map<String,dynamic>.from(result['quote'] as Map);
      setState(()=>current[id]=erpGroupedVndText(quote['basePrice']));
    }on ErpApiError catch(e){
      if(mounted&&run==generation)setState((){
        current[id]=e.code=='SKU_HAS_NO_EFFECTIVE_BASE_PRICE'
          ?'Chưa có giá':'Không tải được giá';
      });
    }catch(_){
      if(mounted&&run==generation)
        setState(()=>current[id]='Không tải được giá');
    }finally{if(run==generation)reading.remove(id);}
  }
  // Read the effective BASE rule, not the final customer/promotion price.
  // Match its priority so this later version wins without masking future
  // versions at the same priority. Missing prices start at the standard 0.
  Future<int> effectiveBasePriority(String id)async{
    try{
      final response=await widget.client.r1PriceQuote(token,{
        'branchId':widget.branchId,'priceListId':listId,
        'sellSkuId':id,'quantity':'1',
      });
      final quote=response['quote'] as Map;
      final trace=quote['trace'] as List;
      final base=trace.first as Map;
      if(base['scope']=='EXISTING_BASE_PRICE'){
        final priority=base['priority'];
        return priority is int?priority:0;
      }
      final priority=base['priority'];
      if(base['scope']=='BASE_RULE'&&priority is int&&
          priority>= -100000&&priority<=100000)return priority;
      throw const ErpApiError(502,'Không xác định được ưu tiên giá cơ sở. Hãy thử lại.');
    }on ErpApiError catch(e){
      if(e.code=='SKU_HAS_NO_EFFECTIVE_BASE_PRICE')return 0;
      rethrow;
    }
  }
  void setSharedPrice(){
    final amount=erpNumberCanonical(sharedPrice.text);
    if(!RegExp(r'^\d{1,14}(?:\.\d{1,4})?$').hasMatch(amount)){
      setState(()=>error='Nhập đơn giá không âm, tối đa 4 số thập phân.');
      return;
    }
    setState((){
      error=null;
      for(final id in selected.keys){
        if(!unresolved(id))inputs[id]!.text=erpGroupedDecimalText(amount);
      }
    });
  }
  Future<void> save()async{
    if(saving||!widget.canWrite||selected.isEmpty)return;
    for(final id in selected.keys){
      final amount=erpNumberCanonical(inputs[id]?.text??'');
      if(!RegExp(r'^\d{1,14}(?:\.\d{1,4})?$').hasMatch(amount)){
        setState(()=>error='Cần nhập giá hợp lệ cho tất cả SKU đã chọn.');
        return;
      }
    }
    final retained=<String,String>{};
    for(final id in selected.keys){
      final previous=widget.client.pendingR1(
        widget.session.actorId,widget.branchId,priceKind(id));
      if(previous!=null)retained[id]=previous.payload['amount'].toString();
    }
    if(retained.isNotEmpty){
      final ack=await showDialog<bool>(context:context,
        builder:(dialog)=>AlertDialog(
          title:const Text('Kiểm tra cập nhật giá chưa xác nhận'),
          content:Text('Có ${retained.length} yêu cầu giá chưa rõ kết quả. '
            'Hệ thống phải gửi lại đúng giá và mã yêu cầu cũ trước: '
            '${retained.values.join(", ")} ₫. '
            'Sau khi kiểm tra kết quả cũ, anh/chị có thể cập nhật giá mới.'),
          actions:[
            TextButton(onPressed:()=>Navigator.pop(dialog,false),
              child:const Text('Quay lại')),
            FilledButton(onPressed:()=>Navigator.pop(dialog,true),
              child:const Text('Kiểm tra yêu cầu cũ')),
          ]));
      if(ack!=true||!mounted)return;
    }
    final confirmed=await showDialog<bool>(context:context,
      builder:(dialog)=>AlertDialog(
        title:const Text('Lưu giá bán'),
        content:Text('Cập nhật giá cho ${selected.length} mặt hàng? Đơn đã xác nhận không đổi.'),
        actions:[
          TextButton(onPressed:()=>Navigator.pop(dialog,false),
            child:const Text('Quay lại')),
          FilledButton(key:const ValueKey('price-sku-confirm'),
            onPressed:()=>Navigator.pop(dialog,true),
            child:const Text('Xác nhận lưu giá')),
        ]));
    if(confirmed!=true||!mounted)return;
    setState((){saving=true;error=null;});
    final ids=selected.keys.toList();
    var done=0;
    try{
      for(final id in ids){
        final kind=priceKind(id);
        final pending=widget.client.pendingR1(
          widget.session.actorId,widget.branchId,kind);
        final priority=pending==null?await effectiveBasePriority(id):null;
        if(!mounted)return;
        final body=pending?.payload??<String,dynamic>{
          'branchId':widget.branchId,'priceListId':listId,
          'sellSkuId':id,'scopeKind':'BASE','adjustment':'FIXED_PRICE',
          'amount':erpNumberCanonical(inputs[id]!.text),'priority':priority!,
          'stacking':'EXCLUSIVE','stopProcessing':false,
          'minQuantity':'1','effectiveFrom':DateTime.now().toUtc().toIso8601String(),
        };
        final key=pending?.key??
          'price-sku-$id-${DateTime.now().microsecondsSinceEpoch}';
        if(pending==null)widget.client.retainR1(
          widget.session.actorId,widget.branchId,kind,body,key);
        try{
          await widget.client.createR1Catalog(token,'rules',body,key:key);
        }on ErpApiError catch(e){
          if(e.status==400||e.status==404||e.code=='PRICE_RULE_OVERLAP'||
             e.code=='PRICE_TARGET_UNAVAILABLE'){
            widget.client.clearR1(widget.session.actorId,widget.branchId,kind);
          }
          rethrow;
        }
        widget.client.clearR1(widget.session.actorId,widget.branchId,kind);
        done++;
        if(mounted)setState((){
          selected.remove(id);current.remove(id);
          inputs.remove(id)?.dispose();
        });
      }
      if(mounted){
        ErpToast.show(context,'Đã cập nhật $done giá bán.');
        await load();
      }
    }on ErpApiError catch(e){
      if(mounted)setState(()=>error='Đã lưu $done/${ids.length} SKU. ${e.message}');
    }catch(_){
      if(mounted)setState(()=>error='Đã lưu $done/${ids.length} SKU. '
        'Các yêu cầu chưa xác nhận được giữ để thử lại cùng khóa.');
    }finally{if(mounted)setState(()=>saving=false);}
  }
  @override Widget build(BuildContext context){
    return Container(key:const ValueKey('price-sku-batch-panel'),
      margin:const EdgeInsets.only(top:12),
      padding:const EdgeInsets.all(14),
      decoration:BoxDecoration(
        color:ErpTokens.mint.withValues(alpha:0.18),
        border:Border.all(color:ErpTokens.border),
        borderRadius:BorderRadius.circular(8)),
      child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
        Row(children:[
          Expanded(child:Text('Giá bán · '+(widget.priceList['name']??widget.priceList['code']).toString(),
            style:const TextStyle(fontSize:16,fontWeight:FontWeight.w800))),
          IconButton(tooltip:'Đóng chỉnh giá SKU',onPressed:widget.onClose,
            icon:const Icon(Icons.close)),
        ]),
        const SizedBox(height:10),
        Wrap(spacing:8,runSpacing:8,crossAxisAlignment:WrapCrossAlignment.center,
          children:[
            SizedBox(width:300,child:TextField(
              key:const ValueKey('price-sku-search'),
              controller:query,onSubmitted:(_)=>load(),
              decoration:const InputDecoration(
                labelText:'Tìm tên sản phẩm, mã SKU',isDense:true,
                prefixIcon:Icon(Icons.search)))),
            OutlinedButton.icon(onPressed:loading||saving?null:load,
              icon:const Icon(Icons.search,size:17),
              label:const Text('Tìm')),
            OutlinedButton(onPressed:loading||saving?null:()=>setState((){
              for(final row in pageRows){
                final id=row['id'].toString();
                selected[id]=row;
                final input=inputs.putIfAbsent(id,()=>TextEditingController());
                final pending=widget.client.pendingR1(
                  widget.session.actorId,widget.branchId,priceKind(id));
                if(pending!=null)input.text=erpGroupedDecimalText(pending.payload['amount']);
              }
            }),child:const Text('Chọn trang')),
            TextButton(onPressed:saving?null:()=>setState((){
              selected.clear();
              for(final input in inputs.values){input.dispose();}
              inputs.clear();
            }),child:const Text('Bỏ chọn')),
            Text('Đã chọn ${selected.length} SKU',
              style:const TextStyle(fontWeight:FontWeight.w700)),
          ]),
        if(brands.isNotEmpty||groups.isNotEmpty||categories.isNotEmpty)
          Padding(padding:const EdgeInsets.only(top:8),child:Wrap(
            spacing:8,runSpacing:8,children:[
              SizedBox(width:178,child:DropdownButtonFormField<String?>(
                key:ValueKey('price-brand-filter-$brandId'),
                initialValue:brandId,isExpanded:true,
                decoration:const InputDecoration(labelText:'Nhãn hàng',isDense:true),
                items:[
                  const DropdownMenuItem<String?>(value:null,child:Text('Tất cả nhãn hàng')),
                  ...brands.where((b)=>b['active']!=false).map((b)=>
                    DropdownMenuItem<String?>(value:b['id'] as String,
                      child:Text(b['name'].toString(),overflow:TextOverflow.ellipsis))),
                ],
                onChanged:saving?null:(v){setState((){
                  brandId=v;groupId=null;categoryId=null;
                });load();})),
              SizedBox(width:178,child:DropdownButtonFormField<String?>(
                key:ValueKey('price-group-filter-$brandId-$groupId'),
                initialValue:groupId,isExpanded:true,
                decoration:const InputDecoration(labelText:'Nhóm sản phẩm',isDense:true),
                items:[
                  const DropdownMenuItem<String?>(value:null,child:Text('Tất cả nhóm')),
                  ...groups.where((g)=>g['active']!=false&&
                    (brandId==null||g['brandId']==brandId)).map((g)=>
                    DropdownMenuItem<String?>(value:g['id'] as String,
                      child:Text(g['name'].toString(),overflow:TextOverflow.ellipsis))),
                ],
                onChanged:saving?null:(v){setState((){
                  groupId=v;categoryId=null;
                });load();})),
              SizedBox(width:178,child:DropdownButtonFormField<String?>(
                key:ValueKey('price-category-filter-$groupId-$categoryId'),
                initialValue:categoryId,isExpanded:true,
                decoration:const InputDecoration(labelText:'Danh mục cha/con',isDense:true),
                items:[
                  const DropdownMenuItem<String?>(value:null,child:Text('Tất cả danh mục')),
                  ...categories.where((c)=>c['active']!=false&&
                    (groupId==null||c['groupId']==groupId)).map((c)=>
                    DropdownMenuItem<String?>(value:c['id'] as String,
                      child:Text('${c['code']} · ${c['name']}',
                        overflow:TextOverflow.ellipsis))),
                ],
                onChanged:saving?null:(v){setState(()=>categoryId=v);load();})),
            ])),
        if(loading)const Padding(padding:EdgeInsets.only(top:8),
          child:LinearProgressIndicator()),
        if(error!=null)Padding(padding:const EdgeInsets.symmetric(vertical:8),
          child:Text(error!,style:const TextStyle(color:ErpTokens.danger))),
        const SizedBox(height:8),
        ConstrainedBox(constraints:const BoxConstraints(maxHeight:340),
          child:ListView(shrinkWrap:true,children:[
            for(final sku in [
              ...selected.values,
              ...pageRows.where((r)=>!selected.containsKey(r['id'].toString())),
            ]) Builder(builder:(context){
              final id=sku['id'].toString();
              final checked=selected.containsKey(id);
              return Container(
                decoration:const BoxDecoration(border:Border(
                  bottom:BorderSide(color:ErpTokens.border))),
                padding:const EdgeInsets.symmetric(vertical:4),
                child:Row(children:[
                  Checkbox(key:ValueKey('price-sku-check-$id'),
                    value:checked,onChanged:saving||!widget.canWrite?null:
                      (value)=>selectSku(sku,value==true)),
                  Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,
                    children:[
                      Text((sku['productName']??sku['name']??'Sản phẩm').toString(),
                        maxLines:1,overflow:TextOverflow.ellipsis,
                        style:const TextStyle(fontWeight:FontWeight.w700,fontSize:13)),
                      Text('${sku['code']??sku['sku']} · ${sku['unitCode']??''} '
                        '· Giá cơ sở: ${current[id]??(reading.contains(id)?'Đang tải…':'Chưa tải')}',
                        maxLines:2,overflow:TextOverflow.ellipsis,
                        style:const TextStyle(fontSize:11,color:ErpTokens.muted)),
                    ])),
                  if(current[id]=='Không tải được giá'||(current[id]==null&&!pageRows.any((r)=>r['id'].toString()==id)&&!reading.contains(id)))IconButton(
                    tooltip:'Tải lại giá',
                    onPressed:(){setState(()=>current.remove(id));loadCurrent(id);},
                    icon:const Icon(Icons.refresh,size:18)),
                  if(!checked&&widget.canWrite)TextButton(
                    onPressed:saving?null:()=>selectSku(sku,true),child:const Text('Sửa giá')),
                  if(checked)SizedBox(width:130,
                    child:TextField(
                      key:ValueKey('price-sku-new-$id'),
                      controller:inputs[id],enabled:!saving&&!unresolved(id),
                      keyboardType:const TextInputType.numberWithOptions(decimal:true),
                      inputFormatters:const [ErpGroupedNumberFormatter()],
                      decoration:InputDecoration(
                        labelText:unresolved(id)?'Giá chờ xác nhận':'Giá mới (₫)',isDense:true))),
                ]),
              );
            }),
          ])),
        if(rows.length>pageSize)Row(mainAxisAlignment:MainAxisAlignment.end,children:[
          IconButton(tooltip:'Trang trước',onPressed:page==0||saving?null:(){
            setState(()=>page--);loadPagePrices();
          },icon:const Icon(Icons.chevron_left)),
          Text('Trang '+(page+1).toString()+'/'+((rows.length+pageSize-1)~/pageSize).toString()),
          IconButton(tooltip:'Trang sau',onPressed:(page+1)*pageSize>=rows.length||saving?null:(){
            setState(()=>page++);loadPagePrices();
          },icon:const Icon(Icons.chevron_right)),
        ]),
        const SizedBox(height:10),
        Wrap(spacing:8,runSpacing:8,crossAxisAlignment:WrapCrossAlignment.center,
          children:[
            SizedBox(width:175,child:TextField(
              key:const ValueKey('price-sku-shared'),
              controller:sharedPrice,
              keyboardType:const TextInputType.numberWithOptions(decimal:true),
              inputFormatters:const [ErpGroupedNumberFormatter()],
              decoration:const InputDecoration(labelText:'Giá áp dụng chung (₫)',isDense:true))),
            OutlinedButton(onPressed:saving||selected.isEmpty?null:setSharedPrice,
              child:const Text('Áp cho SKU đã chọn')),
            FilledButton.icon(key:const ValueKey('price-sku-save'),
              onPressed:saving||selected.isEmpty||!widget.canWrite?null:save,
              icon:const Icon(Icons.save_outlined,size:17),
              label:Text(saving?'Đang lưu…':'Lưu ${selected.length} giá')),
          ]),
      ]));
  }
}
