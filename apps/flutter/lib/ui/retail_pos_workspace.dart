import 'dart:async';
import 'package:material_ui/material_ui.dart';

import '../local/local_store.dart';
import 'erp_display.dart';
import 'erp_tokens.dart';
import 'identity_client.dart';
import 'sales_workspace.dart' show erpRetailStepQuantity;

/// POS is a separate task surface, not a cosmetic mode of the distribution
/// order editor. There is no settlement endpoint today: never present order
/// confirmation as payment, inventory issue or a completed retail sale.
class RetailPosWorkspace extends StatefulWidget {
  final ErpIdentityClient client;
  final IdentitySession session;
  const RetailPosWorkspace({super.key,required this.client,required this.session});
  @override State<RetailPosWorkspace> createState()=>_RetailPosWorkspaceState();
}

class _RetailLine {
  final Map<String,dynamic> sku;
  String quantity;
  _RetailLine(this.sku,this.quantity);
  String get id=>sku['id']?.toString()??'';
}

class _RetailPosWorkspaceState extends State<RetailPosWorkspace> {
  final _search=TextEditingController();
  final _searchFocus=FocusNode();
  Timer? _debounce;
  Future<void> _pendingWrite=Future<void>.value();
  int _generation=0,_quoteVersion=0,_searchVersion=0;
  bool _loading=true,_searching=false,_quoting=false,_configOpen=false,_cached=false;
  String? _branch,_warehouse,_priceList,_walkIn,_error,_quoteError,_total;
  List<Map<String,dynamic>> _branches=[],_warehouses=[],_priceLists=[],_matches=[];
  List<_RetailLine> _lines=[];
  List<Map<String,dynamic>> _priced=[];

  @override void initState(){super.initState();unawaited(_loadBranches());}
  @override void didUpdateWidget(covariant RetailPosWorkspace old){
    super.didUpdateWidget(old);
    if(old.session.token!=widget.session.token||
        old.session.actorId!=widget.session.actorId||
        old.session.installationId!=widget.session.installationId){
      ++_generation;++_quoteVersion;++_searchVersion;
      _debounce?.cancel();_search.clear();
      _branch=null;_warehouse=null;_priceList=null;_walkIn=null;
      _lines=[];_matches=[];_priced=[];_total=null;_error=null;
      unawaited(_loadBranches());
    }
  }
  @override void dispose(){
    ++_generation;++_quoteVersion;++_searchVersion;
    _debounce?.cancel();_search.dispose();_searchFocus.dispose();
    super.dispose();
  }

  bool get _hasSalesGrant=>widget.session.grants.any((g)=>g.permission=='orders.create'&&
    (g.branchId==null||g.branchId==_branch));
  LocalScope? get _scope {
    if(_branch==null||_warehouse==null)return null;
    return widget.client.localScope(widget.session,_branch!,warehouse:_warehouse!);
  }
  Future<void> _loadBranches()async{
    final g=++_generation;
    if(mounted)setState((){_loading=true;_error=null;});
    try{
      final value=await widget.client.salesCatalog(widget.session,'branches');
      if(!mounted||g!=_generation)return;
      final allowed=value.items.where((b)=>widget.session.grants.any((p)=>
        p.permission=='orders.create'&&(p.branchId==null||p.branchId==b['id']))).toList();
      setState((){_branches=allowed;_cached=value.cached;_loading=false;});
      if(allowed.isNotEmpty)await _loadBranch(allowed.first['id'] as String);
    }on ErpApiError catch(e){
      if(mounted&&g==_generation)setState((){_loading=false;_error=e.message;});
    }catch(_){
      if(mounted&&g==_generation)setState((){_loading=false;_error='Không tải được chi nhánh bán lẻ.';});
    }
  }
  Future<void> _loadBranch(String branch)async{
    final g=++_generation;
    ++_quoteVersion;++_searchVersion;_debounce?.cancel();
    setState((){
      _branch=branch;_warehouse=null;_priceList=null;_walkIn=null;
      _lines=[];_priced=[];_matches=[];_total=null;_quoteError=null;
      _loading=true;_error=null;_search.clear();
    });
    try{
      final result=await Future.wait<Object>([
        widget.client.salesCatalog(widget.session,'warehouses',branchId:branch),
        widget.client.salesCatalog(widget.session,'price-lists',branchId:branch),
        widget.client.salesEntrySettings(widget.session.token,branch),
      ]);
      if(!mounted||g!=_generation)return;
      final warehouses=(result[0] as ({List<Map<String,dynamic>> items,bool cached})).items;
      final lists=(result[1] as ({List<Map<String,dynamic>> items,bool cached})).items
        .where((p)=>p['active']!=false).toList();
      final settings=result[2] as Map<String,dynamic>;
      final walkIn=settings['walkInCustomer'];
      final preferred=lists.where((p)=>p['code']?.toString().toUpperCase()=='RETAIL').firstOrNull;
      setState((){
        _warehouses=warehouses;_priceLists=lists;
        _warehouse=warehouses.isEmpty?null:warehouses.first['id'] as String;
        _priceList=(preferred??lists.firstOrNull)?['id'] as String?;
        _walkIn=walkIn is Map&&walkIn['active']==true?walkIn['id'] as String?:null;
        _loading=false;
      });
      await _restoreCart(g);
    }on ErpApiError catch(e){
      if(mounted&&g==_generation)setState((){_loading=false;_error=e.message;});
    }catch(_){
      if(mounted&&g==_generation)setState((){_loading=false;_error='Không tải được cấu hình quầy bán.';});
    }
  }
  Future<void> _restoreCart(int generation)async{
    final scope=_scope,store=widget.client.localStore;
    if(scope==null||store==null)return;
    try{
      final data=await store.loadRetailCart(scope);
      if(!mounted||generation!=_generation||data==null)return;
      final raw=data['lines'];
      if(raw is! List)return;
      final restored=<_RetailLine>[];
      for(final item in raw){
        if(item is! Map)continue;
        final rawSku=item['sku'],qty=item['quantity'];
        if(rawSku is! Map||qty is! String)continue;
        final sku=Map<String,dynamic>.from(rawSku);
        if(sku['id'] is! String||erpRetailStepQuantity(qty,1)==null)continue;
        if(restored.any((line)=>line.id==sku['id']))continue;
        restored.add(_RetailLine(sku,qty));
        if(restored.length==30)break;
      }
      setState((){_lines=restored;});
      unawaited(_quote());
    }catch(_){
      if(mounted&&generation==_generation)setState(()=>_error='Không khôi phục được giỏ trên thiết bị.');
    }
  }
  void _queueSave(){
    final scope=_scope,store=widget.client.localStore;
    if(scope==null||store==null)return;
    final snapshot=<String,dynamic>{'lines':_lines.map((line)=>{'sku':line.sku,'quantity':line.quantity}).toList()};
    _pendingWrite=_pendingWrite.catchError((Object _){}).then((_)=>
      snapshot['lines'] is List&&(snapshot['lines'] as List).isEmpty
        ?store.clearRetailCart(scope):store.saveRetailCart(scope,snapshot));
  }
  Future<void> _setWarehouse(String value)async{
    if(value==_warehouse)return;
    _queueSave();
    final g=++_generation;
    ++_quoteVersion;
    setState((){
      _warehouse=value;_lines=[];_priced=[];_total=null;
      _matches=[];_quoteError=null;
    });
    await _pendingWrite;
    await _restoreCart(g);
  }
  void _changePriceList(String value){
    if(value==_priceList)return;
    setState((){_priceList=value;});
    unawaited(_quote());
  }
  String _cartStamp()=>[
    _branch,_warehouse,_priceList,_walkIn,
    ..._lines.map((x)=>x.id+':'+x.quantity),
  ].join('|');

  Future<void> _quote()async{
    final version=++_quoteVersion,stamp=_cartStamp();
    setState((){_priced=[];_total=null;_quoteError=null;_quoting=_lines.isNotEmpty;});
    if(_lines.isEmpty)return;
    if(_branch==null||_warehouse==null||_walkIn==null||_priceList==null){
      setState((){_quoting=false;_quoteError='Chưa có khách lẻ, kho hoặc bảng giá được cấu hình.';});
      return;
    }
    try{
      final result=await widget.client.salesPricePreview(widget.session.token,{
        'branchId':_branch,'customerId':_walkIn,'priceListId':_priceList,
        'lines':_lines.map((line)=>{'sellSkuId':line.id,'quantity':line.quantity}).toList(),
      });
      if(!mounted||version!=_quoteVersion||stamp!=_cartStamp())return;
      final quoted=(result['lines'] as List).map((x)=>Map<String,dynamic>.from(x as Map)).toList();
      if(quoted.length!=_lines.length)throw const FormatException('Lệch số dòng giá');
      if(quoted.any((row)=>row['priceSignature'] is! String||
         row['unitPrice'] is! String||row['lineTotal'] is! String)){
        throw const FormatException('Giá chưa được xác nhận');
      }
      setState((){_priced=quoted;_total=result['grandTotal']?.toString();_quoting=false;});
    }on ErpApiError catch(e){
      if(mounted&&version==_quoteVersion)setState((){_quoting=false;_quoteError=e.message;});
    }catch(_){
      if(mounted&&version==_quoteVersion)setState((){
        _quoting=false;_quoteError='Chưa xác minh được giá từ máy chủ.';
      });
    }
  }
  void _editCart(Map<String,dynamic> sku,{int delta=1}){
    if(!_hasSalesGrant||sku['id'] is! String)return;
    final id=sku['id'] as String;
    final at=_lines.indexWhere((x)=>x.id==id);
    if(at<0&&(_lines.length>=30||delta<0))return;
    if(at<0){setState(()=>_lines.add(_RetailLine(sku,'1')));}
    else{
      final next=erpRetailStepQuantity(_lines[at].quantity,delta);
      if(next==null)return;
      setState(()=>_lines[at].quantity=next);
    }
    _queueSave();unawaited(_quote());
    _search.clear();_matches=[];_searchFocus.requestFocus();
  }
  void _remove(int i){
    setState(()=>_lines.removeAt(i));
    _queueSave();unawaited(_quote());
  }
  void _onSearch(String query){
    _debounce?.cancel();
    final term=query.trim();
    if(term.isEmpty){++_searchVersion;setState(()=>_matches=[]);return;}
    _debounce=Timer(const Duration(milliseconds:230),()=>unawaited(_findSku(term)));
  }
  Future<List<Map<String,dynamic>>> _findSku(String term)async{
    final branch=_branch,request=++_searchVersion;
    if(branch==null||term.trim().isEmpty)return [];
    setState(()=>_searching=true);
    try{
      final result=await widget.client.salesCatalog(widget.session,'r1/skus',
        branchId:branch,query:term);
      if(!mounted||request!=_searchVersion||_branch!=branch)return [];
      final rows=result.items.where((x)=>x['active']!=false).toList();
      setState((){_matches=rows;_searching=false;_cached=result.cached;});
      return rows;
    }catch(_){
      if(mounted&&request==_searchVersion)setState((){
        _searching=false;_matches=[];_error='Không tìm được SKU. Kiểm tra kết nối và thử lại.';
      });
      return [];
    }
  }
  Future<void> _onScan(String text)async{
    final term=text.trim();
    if(term.isEmpty)return;
    _debounce?.cancel();
    final rows=await _findSku(term);
    if(!mounted)return;
    final exact=rows.where((sku)=>sku['barcode']?.toString()==term||
      sku['code']?.toString().toLowerCase()==term.toLowerCase()).toList();
    if(exact.length==1)_editCart(exact.single);
  }

  @override Widget build(BuildContext context){
    final palette=ErpPalette.of(context),wide=MediaQuery.sizeOf(context).width>=760;
    final status=_branch==null?'Chọn chi nhánh':
      _warehouses.where((x)=>x['id']==_warehouse).firstOrNull?['name']?.toString()??'Chọn kho';
    return SafeArea(top:false,child:Padding(
      key:const ValueKey('erp-pos-workspace'),
      padding:EdgeInsets.symmetric(horizontal:wide?24:12,vertical:wide?18:8),
      child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
        Row(children:[
          Icon(Icons.point_of_sale,color:palette.primary,size:24),
          const SizedBox(width:8),
          Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
            Text('Bán tại quầy',style:TextStyle(fontSize:19,fontWeight:FontWeight.w800,color:palette.ink)),
            Text(status,maxLines:1,overflow:TextOverflow.ellipsis,
              style:TextStyle(color:palette.muted,fontSize:12)),
          ])),
          IconButton(key:const ValueKey('pos-settings'),tooltip:'Chọn chi nhánh, kho, bảng giá',
            onPressed:()=>setState(()=>_configOpen=!_configOpen),
            icon:Icon(_configOpen?Icons.expand_less:Icons.tune)),
        ]),
        if(_configOpen)Padding(padding:const EdgeInsets.only(top:8),child:Column(children:[
          _selector('Chi nhánh',_branch,_branches,(value)=>unawaited(_loadBranch(value))),
          const SizedBox(height:6),
          _selector('Kho bán',_warehouse,_warehouses,(value)=>unawaited(_setWarehouse(value))),
          const SizedBox(height:6),
          _selector('Bảng giá',_priceList,_priceLists,_changePriceList),
        ])),
        const SizedBox(height:8),
        TextField(key:const ValueKey('pos-sku-search'),controller:_search,focusNode:_searchFocus,
          enabled:!_loading&&_branch!=null&&_hasSalesGrant,
          textInputAction:TextInputAction.search,autocorrect:false,
          onChanged:_onSearch,onSubmitted:(value)=>unawaited(_onScan(value)),
          decoration:InputDecoration(
            prefixIcon:const Icon(Icons.qr_code_scanner),hintText:'Quét mã vạch hoặc tìm sản phẩm',
            isDense:true,border:const OutlineInputBorder(),
            suffixIcon:_searching?const Padding(padding:EdgeInsets.all(12),
              child:SizedBox(height:16,width:16,child:CircularProgressIndicator(strokeWidth:2))):
              _search.text.isNotEmpty?IconButton(tooltip:'Xóa tìm kiếm',
                onPressed:(){_search.clear();_onSearch('');setState((){});},
                icon:const Icon(Icons.close)):null)),
        if(_matches.isNotEmpty)ConstrainedBox(constraints:const BoxConstraints(maxHeight:190),
          child:ListView.builder(key:const ValueKey('pos-search-results'),shrinkWrap:true,
            itemCount:_matches.length,itemBuilder:(context,i){
              final item=_matches[i];
              return ListTile(key:ValueKey('pos-result-'+item['id'].toString()),
                dense:true,visualDensity:VisualDensity.compact,
                leading:const Icon(Icons.add_circle_outline),
                title:Text(item['productName']?.toString()??item['name']?.toString()??'Sản phẩm',
                  maxLines:1,overflow:TextOverflow.ellipsis),
                subtitle:Text([item['code'],item['unitCode'],item['barcode']]
                    .where((x)=>x!=null&&x.toString().isNotEmpty).join(' · '),
                    maxLines:1,overflow:TextOverflow.ellipsis),
                onTap:()=>_editCart(item));
            })),
        if(_loading)const LinearProgressIndicator(),
        if(_error!=null)Text(_error!,style:TextStyle(color:palette.danger)),
        if(_cached)Text('Dữ liệu danh mục lưu trên máy. Giá cần xác minh trực tuyến.',
          style:TextStyle(color:palette.warning,fontSize:12)),
        const SizedBox(height:8),
        Row(children:[
          Expanded(child:Text('Giỏ hàng · '+_lines.length.toString()+' mặt hàng',
            style:TextStyle(fontWeight:FontWeight.w700,color:palette.ink))),
          if(_lines.isNotEmpty)TextButton(
            key:const ValueKey('pos-clear-cart'),onPressed:(){
              setState(()=>_lines=[]);_queueSave();unawaited(_quote());
            },child:const Text('Xóa giỏ')),
        ]),
        Expanded(child:_lines.isEmpty
          ?Center(child:Text('Quét mã hoặc chọn sản phẩm để bắt đầu',
            style:TextStyle(color:palette.muted)))
          :ListView.separated(key:const ValueKey('pos-cart'),itemCount:_lines.length,
            separatorBuilder:(_,__)=>Divider(color:palette.border,height:1),
            itemBuilder:(context,i){
              final line=_lines[i],quoted=i<_priced.length?_priced[i]:null;
              return Padding(padding:const EdgeInsets.symmetric(vertical:9),
                child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
                  Text(line.sku['productName']?.toString()??line.sku['code']?.toString()??'Sản phẩm',
                    maxLines:2,overflow:TextOverflow.ellipsis,
                    style:TextStyle(color:palette.ink,fontWeight:FontWeight.w600)),
                  Text((line.sku['code']?.toString()??'')+' · '+
                    (line.sku['unitCode']?.toString()??''),
                    style:TextStyle(fontSize:12,color:palette.muted)),
                  const SizedBox(height:5),
                  Row(children:[
                    IconButton(key:ValueKey('pos-minus-'+i.toString()),
                      onPressed:line.quantity=='1'?null:()=>_editCart(line.sku,delta:-1),
                      tooltip:'Giảm số lượng',icon:const Icon(Icons.remove_circle_outline)),
                    Text(erpNumberText(line.quantity),style:const TextStyle(fontWeight:FontWeight.w700)),
                    IconButton(key:ValueKey('pos-plus-'+i.toString()),
                      onPressed:()=>_editCart(line.sku),tooltip:'Tăng số lượng',
                      icon:const Icon(Icons.add_circle_outline)),
                    IconButton(key:ValueKey('pos-remove-'+i.toString()),
                      onPressed:()=>_remove(i),tooltip:'Bỏ sản phẩm',icon:const Icon(Icons.delete_outline)),
                    const Spacer(),
                    Flexible(child:Column(crossAxisAlignment:CrossAxisAlignment.end,children:[
                      Text(erpVndText(quoted?['lineTotal']),textAlign:TextAlign.end,
                        style:TextStyle(fontWeight:FontWeight.w700,color:palette.ink)),
                      Text(quoted==null?'Chưa xác minh giá':
                        erpVndText(quoted['unitPrice'])+' / '+(line.sku['unitCode']?.toString()??''),
                        textAlign:TextAlign.end,style:TextStyle(fontSize:11,color:palette.muted)),
                    ])),
                  ]),
                ]));
            })),
        if(_quoting)const LinearProgressIndicator(),
        if(_quoteError!=null)Text(_quoteError!,style:TextStyle(color:palette.danger,fontSize:12)),
        Divider(color:palette.border),
        Row(children:[
          Text('Tạm tính',style:TextStyle(fontWeight:FontWeight.w700,color:palette.ink)),
          const Spacer(),
          Text(erpVndText(_total),key:const ValueKey('pos-grand-total'),
            style:TextStyle(fontSize:20,fontWeight:FontWeight.w800,color:palette.primary)),
        ]),
        const SizedBox(height:6),
        // POS must never fake cash receipt or stock movement using order.confirm.
        FilledButton.icon(key:const ValueKey('pos-checkout-disabled'),
          onPressed:null,icon:const Icon(Icons.lock_clock_outlined),
          label:const Text('Thanh toán tại quầy · Chưa khả dụng')),
        const SizedBox(height:3),
        Text('Giỏ và giá đã tách khỏi đơn phân phối. Chưa xuất kho, thu tiền hay hoàn tất bán.',
          key:const ValueKey('pos-no-fake-settlement'),
          textAlign:TextAlign.center,style:TextStyle(fontSize:11,color:palette.muted)),
      ]),
    ));
  }

  Widget _selector(String label,String? value,List<Map<String,dynamic>> rows,
      void Function(String) onChanged)=>DropdownButtonFormField<String>(
    key:ValueKey('pos-select-'+label),initialValue:rows.any((x)=>x['id']==value)?value:null,
    isExpanded:true,decoration:InputDecoration(labelText:label,isDense:true,
      border:const OutlineInputBorder()),
    items:rows.map((x)=>DropdownMenuItem<String>(value:x['id'] as String,
      child:Text(x['name']?.toString()??x['code']?.toString()??'—',
        maxLines:1,overflow:TextOverflow.ellipsis))).toList(),
    onChanged:(value){if(value!=null)onChanged(value);},
  );
}
