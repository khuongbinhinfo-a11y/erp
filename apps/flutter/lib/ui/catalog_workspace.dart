import 'package:material_ui/material_ui.dart';
import 'erp_navigation_ui.dart';
import 'erp_tokens.dart';
import 'erp_display.dart';
import 'erp_toast.dart';
import 'identity_client.dart';
import 'r1_catalog_workspace.dart';

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
  bool loading=true,saving=false;
  String? error;
  int requestSerial=0;
  final search=TextEditingController();

  static const tabs=<String,List<ErpSectionTab<String>>>{
    'customers':[
      ErpSectionTab('customers','Khách hàng'),
      ErpSectionTab('suppliers','Nhà cung cấp'),
    ],
    'products':[
      ErpSectionTab('products','Sản phẩm'),
      ErpSectionTab('groups','Nhóm hàng'),
      ErpSectionTab('units','Đơn vị và quy đổi'),
      ErpSectionTab('skus','SKU bán hàng'),
      ErpSectionTab('barcodes','Mã vạch'),
    ],
    'price-lists':[
      ErpSectionTab('price-lists','Bảng giá'),
      ErpSectionTab('prices','Lịch sử đơn giá'),
      ErpSectionTab('channels','Kênh bán'),
      ErpSectionTab('rules','Chính sách giá'),
      ErpSectionTab('quote','Tra giá theo khách'),
    ],
    'warehouses':[
      ErpSectionTab('warehouses','Kho được cấp quyền'),
    ],
  };
  static const titles=<String,String>{
    'customers':'Khách hàng','suppliers':'Nhà cung cấp',
    'products':'Sản phẩm','groups':'Nhóm hàng',
    'price-lists':'Bảng giá','prices':'Lịch sử đơn giá',
    'warehouses':'Kho hàng',
  };

  static const r1Kinds={'units','skus','barcodes','channels','rules','quote'};
  bool get isR1=>r1Kinds.contains(resource);
  bool get canWrite => resource!='warehouses' && widget.session.grants.any(
    (g)=>g.permission=='catalog.write'&&g.branchId==branchId);
  @override void initState(){
    super.initState();resource=widget.area;_loadBranches();
  }
  @override void didUpdateWidget(covariant CatalogWorkspace oldWidget){
    super.didUpdateWidget(oldWidget);
    if(oldWidget.session.token!=widget.session.token ||
      oldWidget.client!=widget.client || oldWidget.area!=widget.area){
      requestSerial++;items=[];branches=[];branchId=null;resource=widget.area;search.clear();
      _loadBranches();
    }
  }
  @override void dispose(){
    requestSerial++;search.dispose();super.dispose();
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
  String _errorMessage(ErpApiError e) => e.status==503
    ? 'Danh mục đang tạm gián đoạn. Vui lòng thử lại.'
    : e.message;

  Future<void> _loadRecords()async{
    if(isR1){if(mounted)setState(()=>loading=false);return;}
    final currentBranch=branchId;
    if(currentBranch==null)return;
    final stamp=++requestSerial;
    setState((){loading=true;error=null;items=[];});
    try{
      final result=await widget.client.catalogItems(
        widget.session.token,resource,branchId:currentBranch,query:search.text);
      if(!mounted||requestSerial!=stamp)return;
      setState((){items=result;loading=false;});
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
    setState((){resource=next;search.clear();items=[];});
    _loadRecords();
  }

  Future<void> _add()async{
    if(!canWrite||saving||branchId==null)return;
    final code=TextEditingController(),name=TextEditingController();
    final unit=TextEditingController(text:'cai');
    final customerGroup=TextEditingController();
    final phone=TextEditingController(),deliveryAddress=TextEditingController();
    final paymentTerms=TextEditingController(text:'0');
    final altUnit=TextEditingController(),conversion=TextEditingController();
    final amount=TextEditingController(),discount=TextEditingController(text:'0');
    String? productId,priceListId,groupId;
    List<Map<String,dynamic>> availableProducts=[],availableLists=[],availableGroups=[];
    try{
      if(resource=='prices'){
        availableProducts=await widget.client.catalogItems(widget.session.token,'products',branchId:branchId);
        availableLists=await widget.client.catalogItems(widget.session.token,'price-lists',branchId:branchId);
        if(availableProducts.isEmpty||availableLists.isEmpty){
          if(mounted)ErpToast.show(context,'Cần tạo sản phẩm và bảng giá trước khi thêm đơn giá.',isError:true);
          return;
        }
        productId=availableProducts.first['id'] as String;
        priceListId=availableLists.first['id'] as String;
      }
      if(resource=='products'){
        availableGroups=await widget.client.catalogItems(widget.session.token,'groups',branchId:branchId);
      }
      if(!mounted)return;
      final payload=await showDialog<Map<String,dynamic>>(context:context,builder:(dialog)=>
        StatefulBuilder(builder:(ctx,refresh)=>AlertDialog(
          title:Text(resource=='prices'?'Thêm phiên bản đơn giá':'Thêm ${titles[resource]!.toLowerCase()}'),
          content:SizedBox(width:430,child:SingleChildScrollView(child:Column(
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
                    labelText:resource=='products'?'SKU':'Mã',
                    hintText:resource=='products'?'SKU-001':'MA-001')),
                const SizedBox(height:12),
                TextField(key:const ValueKey('catalog-create-name'),
                  controller:name,decoration:const InputDecoration(labelText:'Tên')),
                if(resource=='customers')...[
                  const SizedBox(height:12),
                  TextField(controller:customerGroup,
                    decoration:const InputDecoration(labelText:'Nhóm khách hàng')),
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
                if(resource=='products')...[
                  const SizedBox(height:12),
                  TextField(controller:unit,
                    decoration:const InputDecoration(labelText:'Đơn vị gốc',hintText:'cai')),
                  if(availableGroups.isNotEmpty)...[
                    const SizedBox(height:12),
                    DropdownButtonFormField<String?>(
                      initialValue:groupId,isExpanded:true,
                      decoration:const InputDecoration(labelText:'Nhóm hàng (tùy chọn)'),
                      items:[
                        const DropdownMenuItem<String?>(value:null,child:Text('Chưa phân nhóm')),
                        ...availableGroups.map((g)=>DropdownMenuItem<String?>(
                          value:g['id'] as String,child:Text(g['name'] as String))),
                      ],
                      onChanged:(v)=>refresh(()=>groupId=v)),
                  ],
                  const SizedBox(height:12),
                  TextField(controller:altUnit,
                    decoration:const InputDecoration(labelText:'Đơn vị quy đổi (tùy chọn)',hintText:'thung')),
                  const SizedBox(height:12),
                  TextField(controller:conversion,keyboardType:TextInputType.number,
                    decoration:const InputDecoration(labelText:'Hệ số sang đơn vị gốc',hintText:'12.000000')),
                ],
              ],
            ]))),
          actions:[
            TextButton(onPressed:()=>Navigator.pop(dialog),child:const Text('Hủy')),
            FilledButton(
              key:const ValueKey('catalog-create-confirm'),
              onPressed:(){
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
                  if(resource=='customers'){
                    body.addAll({
                      if(customerGroup.text.trim().isNotEmpty)
                        'customerGroup':customerGroup.text.trim(),
                      'phone':phone.text.trim().isEmpty?null:phone.text.trim(),
                      'deliveryAddress':deliveryAddress.text.trim().isEmpty
                        ?null:deliveryAddress.text.trim(),
                      'paymentTermsDays':int.tryParse(paymentTerms.text.trim())??-1,
                    });
                  }
                  if(resource=='products'){
                    body.addAll({'baseUnit':unit.text.trim(),'groupId':groupId,
                      'units':altUnit.text.trim().isEmpty&&conversion.text.trim().isEmpty
                        ? [] :[{'unitCode':altUnit.text.trim(),'toBase':conversion.text.trim()}]});
                  }
                }
                Navigator.pop(dialog,body);
              },
              child:const Text('Lưu trên server')),
          ],
        )));
      if(payload==null||!mounted)return;
      setState(()=>saving=true);
      try{
        await widget.client.createCatalog(widget.session.token,resource,payload);
        if(!mounted)return;
        ErpToast.show(context,'Đã lưu ${titles[resource]!.toLowerCase()} sau xác nhận server.');
        await _loadRecords();
      }on ErpApiError catch(e){
        if(mounted){
          ErpToast.show(context,_errorMessage(e),isError:true);
          // A lost ACK may follow COMMIT: always re-read before considering a retry.
          await _loadRecords();
        }
      }catch(_){
        if(mounted){
          ErpToast.show(context,'Không rõ kết quả ghi. Đã tải lại dữ liệu để đối chiếu.',isError:true);
          await _loadRecords();
        }
      }finally{if(mounted)setState(()=>saving=false);}
    }on ErpApiError catch(e){
      if(mounted)ErpToast.show(context,_errorMessage(e),isError:true);
    }finally{
      code.dispose();name.dispose();unit.dispose();customerGroup.dispose();
      phone.dispose();deliveryAddress.dispose();paymentTerms.dispose();
      altUnit.dispose();conversion.dispose();amount.dispose();discount.dispose();
    }
  }

  bool get canEdit => canWrite && resource!='prices' && resource!='warehouses';
  Future<void> _edit(Map<String,dynamic> row)async{
    if(!canEdit||saving||branchId==null)return;
    final id=row['id'],revision=row['revision'];
    if(id is! String||revision is! int)return;
    var name=(row['name']??'').toString();
    var phone=(row['phone']??'').toString(),
      deliveryAddress=(row['deliveryAddress']??'').toString();
    var paymentTermsDays=(row['paymentTermsDays']??0).toString();
    var customerGroup=(row['customerGroup']??'').toString();
    bool active=row['active'] as bool? ?? true;
    final body=await showDialog<Map<String,dynamic>>(context:context,
        builder:(dialog)=>StatefulBuilder(builder:(context,refresh)=>AlertDialog(
          title:const Text('Sửa danh mục'),
          content:SizedBox(width:400,child:Column(mainAxisSize:MainAxisSize.min,
            children:[
              TextFormField(key:const ValueKey('catalog-edit-name'),
                initialValue:name,onChanged:(value)=>name=value,
                maxLength:160,decoration:const InputDecoration(labelText:'Tên')),
              if(resource=='customers')...[
                TextFormField(initialValue:customerGroup,
                  onChanged:(v)=>customerGroup=v,
                  decoration:const InputDecoration(labelText:'Nhóm khách hàng')),
                TextFormField(initialValue:phone,onChanged:(v)=>phone=v,
                  keyboardType:TextInputType.phone,
                  decoration:const InputDecoration(labelText:'Điện thoại')),
                TextFormField(initialValue:deliveryAddress,
                  onChanged:(v)=>deliveryAddress=v,
                  decoration:const InputDecoration(labelText:'Địa chỉ giao hàng')),
                TextFormField(initialValue:paymentTermsDays,
                  onChanged:(v)=>paymentTermsDays=v,
                  keyboardType:TextInputType.number,
                  decoration:const InputDecoration(labelText:'Số ngày thanh toán')),
              ],
              SwitchListTile(key:const ValueKey('catalog-edit-active'),
                title:const Text('Đang sử dụng'),value:active,
                onChanged:(v)=>refresh(()=>active=v)),
            ])),
          actions:[
            TextButton(onPressed:()=>Navigator.pop(dialog),child:const Text('Hủy')),
            FilledButton(key:const ValueKey('catalog-edit-save'),
              onPressed:()=>Navigator.pop(dialog,{
                'branchId':branchId,'name':name.trim(),'active':active,
                if(resource=='customers')...{
                  'customerGroup':customerGroup.trim().isEmpty?null:customerGroup.trim(),
                  'phone':phone.trim().isEmpty?null:phone.trim(),
                  'deliveryAddress':deliveryAddress.trim().isEmpty?null:deliveryAddress.trim(),
                  'paymentTermsDays':int.tryParse(paymentTermsDays.trim())??-1,
                },
              }),child:const Text('Cập nhật')),
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
              erpDecimalText(q['amount'])+' '+q['currency'].toString(),
              key:const ValueKey('catalog-quote-result'),
              style:const TextStyle(fontSize:22,fontWeight:FontWeight.w800)),
            if(q!=null)...[
              const SizedBox(height:8),
              Text('Chiết khấu: '+erpDecimalText(q['discountRate'])+'%'),
              Text('Hiệu lực: '+q['effectiveAt'].toString()),
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
    return value.toString();
  }
  List<(String,String)> get columns=>switch(resource){
    'customers'=>const [('code','Mã'),('name','Khách hàng'),('customerGroup','Nhóm'),
      ('phone','Điện thoại'),('paymentTermsDays','Ngày hạn'),('active','Trạng thái')],
    'suppliers'=>const [('code','Mã'),('name','Nhà cung cấp'),('active','Trạng thái')],
    'groups'=>const [('code','Mã nhóm'),('name','Tên nhóm'),('active','Trạng thái')],
    'products'=>const [('code','SKU'),('name','Sản phẩm'),('baseUnit','Đơn vị gốc'),('active','Trạng thái')],
    'price-lists'=>const [('code','Mã bảng giá'),('name','Bảng giá'),('currency','Tiền tệ'),('active','Trạng thái')],
    'prices'=>const [('productId','Mã sản phẩm (ID)'),('amount','Đơn giá'),('discountRate','CK %'),('effectiveAt','Hiệu lực')],
    _=>const [('code','Mã kho'),('name','Kho hàng'),('branchId','Chi nhánh (ID)')],
  };
  @override Widget build(BuildContext context){
    return Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
      if((tabs[widget.area]??[]).length>1)
        ErpSectionTabs<String>(
          keyPrefix:'catalog-inner',selected:resource,
          items:tabs[widget.area]!,onSelected:_changeResource),
      const SizedBox(height:16),
      if(isR1)R1CatalogWorkspace(
        key:ValueKey('r1-workspace-'+resource+'-'+branchId.toString()),
        kind:resource,branchId:branchId,branches:branches,
        client:widget.client,session:widget.session,
        changeBranch:(next){setState(()=>branchId=next);},
      ),
      if(!isR1)Card(clipBehavior:Clip.antiAlias,
        child:Padding(padding:const EdgeInsets.all(18),child:Column(
          crossAxisAlignment:CrossAxisAlignment.start,children:[
            Wrap(spacing:12,runSpacing:10,crossAxisAlignment:WrapCrossAlignment.center,children:[
              Text(titles[resource]??'Danh mục',style:const TextStyle(
                color:ErpTokens.ink,fontSize:18,fontWeight:FontWeight.w800)),
              if(branches.isNotEmpty)
                DropdownButton<String>(
                  key:const ValueKey('catalog-branch-picker'),
                  value:branchId,
                  items:branches.map((b)=>DropdownMenuItem<String>(
                    value:b['id'] as String,
                    child:Text('${b['code']} · ${b['name']}'))).toList(),
                  onChanged:(next){
                    if(next==null||next==branchId)return;
                    setState(()=>branchId=next);_loadRecords();
                  }),
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
              if(canWrite)FilledButton.icon(
                key:const ValueKey('catalog-create'),
                onPressed:saving||loading?null:_add,
                icon:const Icon(Icons.add,size:18),
                label:const Text('Tạo mới')),
            ]),
            const SizedBox(height:12),
            TextField(key:const ValueKey('catalog-search'),
              controller:search,
              onSubmitted:(_)=>_loadRecords(),
              decoration:InputDecoration(
                labelText:'Tìm trong ${titles[resource]!.toLowerCase()}',
                hintText:'Nhập mã hoặc tên rồi nhấn Enter',
                prefixIcon:const Icon(Icons.search),
                suffixIcon:IconButton(tooltip:'Tìm kiếm',
                  onPressed:_loadRecords,icon:const Icon(Icons.arrow_forward))),
            ),
            const SizedBox(height:14),
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
                columns:[
                  ...columns.map((entry)=>DataColumn(label:Text(entry.$2))),
                  if(canEdit)const DataColumn(label:Text('Thao tác')),
                ],
                rows:items.map((entry)=>DataRow(cells:[
                  ...columns.map((c)=>DataCell(Text(_cell(entry,c.$1)))),
                  if(canEdit)DataCell(IconButton(
                    key:ValueKey('catalog-edit-'+entry['id'].toString()),
                    icon:const Icon(Icons.edit_outlined,size:18),
                    tooltip:'Sửa/ngừng sử dụng',
                    onPressed:saving?null:()=>_edit(entry))),
                ])).toList())),
            if(resource=='warehouses')const Padding(
              padding:EdgeInsets.only(top:12),
              child:Text('Tồn khả dụng chỉ được xác nhận sau khi Inventory Ledger (#9) hoàn thiện.',
                style:TextStyle(fontSize:12,color:ErpTokens.muted))),
            if(resource=='prices')const Padding(
              padding:EdgeInsets.only(top:12),
              child:Text('Giá dùng NUMERIC và có lịch sử hiệu lực. Chưa xác nhận tồn kho hay đơn hàng.',
                style:TextStyle(fontSize:12,color:ErpTokens.muted))),
          ]))),
    ]);
  }
}
