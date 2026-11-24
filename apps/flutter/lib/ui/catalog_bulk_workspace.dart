import 'dart:convert';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'erp_tokens.dart';
import 'identity_client.dart';

/// R1-B master import. Files never go to local durable storage; the backend
/// interprets all spreadsheet cells and owns preview validation + COMMIT.
class CatalogBulkWorkspace extends StatefulWidget{
  final ErpIdentityClient client;
  final IdentitySession session;
  final String? branchId;
  final bool canWrite;
  final String initialArea;
  /// Optional save hook for UI regression tests; production uses file_picker.
  final Future<void> Function(String fileName,Uint8List bytes)? saveCsvForTest;
  const CatalogBulkWorkspace({super.key,required this.client,required this.session,
    required this.branchId,required this.canWrite,required this.initialArea,
    this.saveCsvForTest});
  @override State<CatalogBulkWorkspace> createState()=>_CatalogBulkWorkspaceState();
}
class _CatalogBulkWorkspaceState extends State<CatalogBulkWorkspace>{
  static const names={
    'customers':'Khách hàng','products':'Sản phẩm',
    'skus':'SKU bán','prices':'Giá theo sản phẩm',
  };
  static const columns={
    'customers':{
      'code':'Mã khách hàng','name':'Tên khách hàng',
      'customerGroupCode':'Mã nhóm khách','customerRegionCode':'Mã khu vực',
      'phone':'Điện thoại','deliveryAddress':'Địa chỉ giao',
      'paymentTermsDays':'Số ngày công nợ','active':'Trạng thái',
    },
    'products':{
      'code':'Mã sản phẩm','name':'Tên sản phẩm',
      'baseUnit':'Mã đơn vị gốc','groupCode':'Mã nhóm hàng',
      'barcode':'Mã vạch gốc','active':'Trạng thái',
    },
    'skus':{
      'code':'Mã SKU','productCode':'Mã sản phẩm',
      'unitCode':'Mã đơn vị','toBase':'Hệ số quy đổi',
      'active':'Trạng thái','reason':'Lý do ngừng',
    },
    'prices':{
      'priceListCode':'Mã bảng giá','skuCode':'Mã SKU','productCode':'Mã sản phẩm',
      'name':'Tên hàng','unitCode':'Đơn vị',
      'amount':'Đơn giá','discountRate':'Chiết khấu %',
      'effectiveAt':'Ngày giờ hiệu lực',
    },
  };
  late String kind;
  String mode='UPSERT';
  bool hasHeader=true,busy=false;
  String? fileName,contentBase64,error,priceListId,defaultEffectiveAt;
  List<Map<String,dynamic>> priceLists=[];
  Map<String,dynamic>? inspection,preview,applied;
  final mapping=<String,String>{};
  Map<String,dynamic>? pendingPayload;
  String? pendingKey;
  List<String> get headers=>(inspection?['headers'] as List<dynamic>?)
    ?.map((x)=>x.toString()).toList()??[];
  List<String> get fieldKeys=>columns[kind]!.keys.toList();
  String get jobKey=>'catalog.bulk.'+kind;
  @override void initState(){
    super.initState();
    kind=widget.initialArea=='customers'?'customers':
      widget.initialArea=='price-lists'?'prices':'products';
    _restorePending();
    if(kind=='prices')_loadPriceLists();
  }
  @override void didUpdateWidget(covariant CatalogBulkWorkspace old){
    super.didUpdateWidget(old);
    if(old.branchId!=widget.branchId||old.session.actorId!=widget.session.actorId||
       old.session.token!=widget.session.token){
      setState((){
        fileName=null;contentBase64=null;inspection=null;preview=null;
        applied=null;mapping.clear();pendingPayload=null;pendingKey=null;error=null;
        priceListId=null;defaultEffectiveAt=null;priceLists=[];
      });
      _restorePending();
      if(kind=='prices')_loadPriceLists();
    }
  }
  Future<void> _loadPriceLists()async{
    final branch=widget.branchId,token=widget.session.token;
    if(branch==null)return;
    try{
      final rows=await widget.client.catalogItems(token,'price-lists',branchId:branch);
      if(!mounted||widget.branchId!=branch||widget.session.token!=token||kind!='prices')return;
      setState(()=>priceLists=rows.where((x)=>x['active']!=false).toList());
    }on ErpApiError catch(e){
      if(mounted&&widget.branchId==branch&&widget.session.token==token&&kind=='prices')
        setState(()=>error=e.message);
    }
  }
  void _restorePending(){
    final branch=widget.branchId;
    if(branch==null)return;
    final saved=widget.client.pendingR1(widget.session.actorId,branch,jobKey);
    if(saved==null)return;
    pendingPayload=Map<String,dynamic>.from(saved.payload);
    pendingKey=saved.key;
    final p=pendingPayload!;
    priceListId=p['priceListId'] as String?;
    defaultEffectiveAt=p['defaultEffectiveAt'] as String?;
    fileName=p['fileName'] as String?;
    contentBase64=p['contentBase64'] as String?;
    mode=p['mode'] as String? ?? 'UPSERT';
    hasHeader=p['hasHeader'] as bool? ?? true;
    mapping.clear();
    mapping.addAll(Map<String,String>.from(p['mapping'] as Map? ?? {}));
    preview={'hash':p['previewHash'],'summary':{'total':0}};
  }
  Map<String,dynamic> get params=>{
    'branchId':widget.branchId,'resource':kind,'mode':mode,
    'fileName':fileName,'contentBase64':contentBase64,
    'hasHeader':hasHeader,'mapping':Map<String,String>.from(mapping),
    if(kind=='prices'&&priceListId!=null)'priceListId':priceListId,
    if(kind=='prices'&&priceListId!=null&&defaultEffectiveAt!=null)'defaultEffectiveAt':defaultEffectiveAt,
  };
  bool get canOperate=>!busy&&pendingPayload==null&&widget.branchId!=null;
  bool get canImport=>canOperate&&(kind!='prices'||priceListId!=null);
  void _changeKind(String? next){
    if(next==null||next==kind||!canOperate)return;
    setState((){
      kind=next;fileName=null;contentBase64=null;inspection=null;
      priceListId=null;defaultEffectiveAt=null;priceLists=[];
      mapping.clear();preview=null;applied=null;error=null;
    });
    _restorePending();
    if(kind=='prices')_loadPriceLists();
  }
  Future<void> _pick()async{
    if(!canImport)return;
    try{
      final result=await FilePicker.platform.pickFiles(
        dialogTitle:'Chọn Excel hoặc CSV',
        type:FileType.custom,allowedExtensions:const ['csv','xlsx'],withData:true);
      if(result==null||result.files.isEmpty)return;
      final f=result.files.single,bytes=f.bytes;
      if(bytes==null||bytes.isEmpty||bytes.length>6*1024*1024){
        if(mounted)setState(()=>error='File phải có dữ liệu, tối đa 6 MB.');
        return;
      }
      if(!RegExp(r'\.(csv|xlsx)$',caseSensitive:false).hasMatch(f.name)){
        if(mounted)setState(()=>error='Chỉ nhận Excel .xlsx hoặc .csv.');
        return;
      }
      setState((){
        fileName=f.name;contentBase64=base64Encode(bytes);
        if(kind=='prices')defaultEffectiveAt=DateTime.now().toUtc().toIso8601String();
        inspection=null;preview=null;applied=null;mapping.clear();error=null;
      });
      await _inspect();
    }catch(_){
      if(mounted)setState(()=>error='Không đọc được file. Vui lòng thử lại.');
    }
  }
  Future<void> _inspect()async{
    if(contentBase64==null||fileName==null||widget.branchId==null||busy)return;
    setState((){busy=true;inspection=null;preview=null;error=null;});
    try{
      final result=await widget.client.bulkInspect(widget.session.token,{
        'branchId':widget.branchId,'resource':kind,'fileName':fileName,
        'contentBase64':contentBase64,'hasHeader':hasHeader,
      });
      if(!mounted)return;
      setState((){
        inspection=result;
        mapping.clear();
        mapping.addAll(Map<String,String>.from(
          result['suggestedMapping'] as Map? ?? {}));
      });
    }on ErpApiError catch(e){
      if(mounted)setState(()=>error='Không đọc được file: '+(e.code??e.message));
    }finally{if(mounted)setState(()=>busy=false);}
  }
  Future<void> _preview()async{
    if(!canImport||inspection==null||contentBase64==null)return;
    setState((){busy=true;preview=null;applied=null;error=null;});
    try{
      final result=await widget.client.bulkPreview(widget.session.token,params);
      if(mounted)setState(()=>preview=result);
    }on ErpApiError catch(e){
      if(mounted)setState(()=>error='Chưa xem trước được: '+(e.code??e.message));
    }finally{if(mounted)setState(()=>busy=false);}
  }
  Future<void> _apply()async{
    if(busy||widget.branchId==null||!widget.canWrite)return;
    final body=pendingPayload;
    final hash=(body?['previewHash']??preview?['hash']) as String?;
    final stats=preview?['summary'] as Map?;
    if(hash==null||(body==null&&(stats?['error']??1)!=0))return;
    if(body==null){
      final confirmed=await showDialog<bool>(
        context:context,builder:(dialog)=>AlertDialog(
          title:const Text('Xác nhận cập nhật hàng loạt'),
          content:Text('Tạo '+(stats?['create']??0).toString()+
            ', cập nhật '+(stats?['update']??0).toString()+
            ', giữ nguyên '+(stats?['unchanged']??0).toString()+
            '. Mọi dòng được xử lý trong một giao dịch. '
            'Bảng giá sẽ tạo phiên bản hiệu lực mới, không sửa lịch sử.'),
          actions:[
            TextButton(onPressed:()=>Navigator.pop(dialog,false),
              child:const Text('Quay lại')),
            FilledButton(key:const ValueKey('catalog-bulk-confirm'),
              onPressed:()=>Navigator.pop(dialog,true),
              child:const Text('Xác nhận nhập')),
          ]));
      if(confirmed!=true||!mounted)return;
    }
    final payload=body??{...params,'previewHash':hash};
    final key=pendingKey??'r1b-'+DateTime.now().microsecondsSinceEpoch.toString();
    widget.client.retainR1(widget.session.actorId,widget.branchId!,jobKey,payload,key);
    setState((){
      pendingPayload=payload;pendingKey=key;busy=true;error=null;
    });
    try{
      final result=await widget.client.bulkApply(widget.session.token,payload,key:key);
      widget.client.clearR1(widget.session.actorId,widget.branchId!,jobKey);
      if(!mounted)return;
      setState((){
        applied=result;pendingPayload=null;pendingKey=null;
        preview=null;
      });
    }on ErpApiError catch(e){
      if(!mounted)return;
      if(e.status==400||e.status==409||e.status==403||e.status==413){
        widget.client.clearR1(widget.session.actorId,widget.branchId!,jobKey);
        setState((){
          pendingPayload=null;pendingKey=null;preview=null;
          error='Dữ liệu thay đổi hoặc bị từ chối ('+(e.code??e.message)+
            '). Xem trước lại trước khi ghi.';
        });
      }else{
        setState(()=>error='Chưa xác nhận lưu dữ liệu ('+(e.code??e.message)+
          '). Bấm “Kiểm tra yêu cầu” để gửi lại đúng khóa, không tạo bản ghi trùng.');
      }
    }finally{if(mounted)setState(()=>busy=false);}
  }
  Future<void> _saveCsv({required bool template,bool excel=false})async{
    final branch=widget.branchId;
    if(branch==null||!canImport)return;
    setState((){busy=true;error=null;});
    try{
      final result=await widget.client.bulkCsvFile(widget.session.token,kind,branch,
        template:template,format:excel?'xlsx':'csv',priceListId:kind=='prices'?priceListId:null);
      if(!mounted)return;
      final fileName=result['fileName']?.toString()??(excel?'danh-muc.xlsx':'danh-muc.csv');
      final Uint8List bytes;
      if(excel){
        final encoded=result['contentBase64'];
        if(encoded is! String)throw const FormatException('MISSING_XLSX_CONTENT');
        bytes=base64Decode(encoded);
      }else{
        final csv=result['content'];
        if(csv is! String)throw const FormatException('MISSING_CSV_CONTENT');
        bytes=Uint8List.fromList(
          utf8.encode(csv.startsWith('\uFEFF')?csv:'\uFEFF$csv'));
      }
      if(widget.saveCsvForTest case final save?){
        await save(fileName,bytes);
      }else{
        // file_picker 8.x throws UnsupportedError on Web. 9.2.3 implements a
        // browser download while retaining the desktop save-file contract.
        await FilePicker.platform.saveFile(dialogTitle:'Lưu dữ liệu Excel/CSV',
          fileName:fileName,type:FileType.custom,
          allowedExtensions:excel?const ['xlsx']:const ['csv'],bytes:bytes);
      }
    }on ErpApiError catch(e){
      if(mounted)setState(()=>error='Không xuất được: '+(e.code??e.message));
    }on UnsupportedError{
      if(mounted)setState(()=>error='Trình duyệt không hỗ trợ tải tệp. '
        'Hãy cập nhật trình duyệt hoặc mở trên Chrome/Edge.');
    }catch(e){
      if(mounted)setState(()=>error='Không tải được tệp ('+
        e.runtimeType.toString()+'). '
        'Kiểm tra quyền tải tệp của trình duyệt rồi thử lại.');
    }finally{if(mounted)setState(()=>busy=false);}
  }
  Widget _mappingEditor(){
    return Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
      const Text('2. Ánh xạ cột Excel/CSV sang trường ERP',
        style:TextStyle(fontSize:16,fontWeight:FontWeight.w700)),
      const SizedBox(height:6),
      const Text('Cột không chọn = giữ nguyên khi cập nhật. Cột đã chọn nhưng ô trống '
        '= xóa giá trị tùy chọn. Mã khách, mã sản phẩm, SKU hoặc mã bảng giá '
        'là khóa nhận diện; không nhập tên danh mục thay cho mã.',
        style:TextStyle(color:ErpTokens.muted,fontSize:12)),
      const SizedBox(height:12),
      Wrap(spacing:12,runSpacing:12,children:[
        for(final field in fieldKeys.where((f)=>kind!='prices'||priceListId==null||
          f=='skuCode'||f=='amount'||f=='discountRate'||f=='effectiveAt'||
          (f=='priceListCode'&&mapping.containsKey(f))))
          SizedBox(width:290,child:DropdownButtonFormField<String?>(
            key:ValueKey('catalog-bulk-map-'+field+'-'+(mapping[field]??'')),
            isExpanded:true,initialValue:mapping[field],
            decoration:InputDecoration(labelText:columns[kind]![field]),
            items:[
              const DropdownMenuItem<String?>(value:null,child:Text('Không dùng cột này')),
              for(final header in headers)
                DropdownMenuItem<String?>(value:header,
                  child:Text(header,overflow:TextOverflow.ellipsis)),
            ],
            onChanged:canOperate?(v)=>setState((){
              if(v==null)mapping.remove(field);else mapping[field]=v;
              preview=null;applied=null;
            }):null)),
      ]),
      const SizedBox(height:8),
      Text('Tìm thấy '+(inspection?['rowCount']??0).toString()+
        ' dòng. Dòng có công thức Excel không được thực thi.',
        style:const TextStyle(color:ErpTokens.muted,fontSize:12)),
    ]);
  }
  Widget _previewTable(){
    final data=(preview?['rows'] as List<dynamic>? ?? [])
      .map((x)=>Map<String,dynamic>.from(x as Map)).toList();
    final summary=(preview?['summary'] as Map?)??{};
    final hasError=(summary['error']??1)!=0;
    String details(dynamic v){
      if(v==null)return '—';
      if(v is Map){
        final entries=v.entries.map((e)=>(columns[kind]?[e.key.toString()]??e.key.toString())+': '+
          (e.value??'∅').toString()).toList();
        return entries.join(' | ');
      }
      return v.toString();
    }
    return Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
      Text('3. Xem trước / đối soát '+data.length.toString()+' dòng',
        style:const TextStyle(fontSize:16,fontWeight:FontWeight.w700)),
      const SizedBox(height:8),
      Text('Tạo: '+(summary['create']??0).toString()+
        '  •  Sửa: '+(summary['update']??0).toString()+
        '  •  Giữ nguyên: '+(summary['unchanged']??0).toString()+
        '  •  Lỗi: '+(summary['error']??0).toString()),
      const SizedBox(height:8),
      Container(height:380,decoration:BoxDecoration(
        border:Border.all(color:ErpTokens.fresh)),
        child:ListView.separated(
          key:const ValueKey('catalog-bulk-preview-rows'),
          itemCount:data.length,
          separatorBuilder:(_,__)=>const Divider(height:1),
          itemBuilder:(context,index){
            final x=data[index],bad=x['action']=='ERROR';
            final actionLabel=switch(x['action']){
              'CREATE'=>'Thêm mới','UPDATE'=>'Cập nhật',
              'UNCHANGED'=>'Giữ nguyên','ERROR'=>'Có lỗi',
              _=>'Cần kiểm tra',
            };
            return Padding(padding:const EdgeInsets.all(10),
              child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
                Text('Dòng '+x['line'].toString()+' · '+x['key'].toString()+
                  ' · '+actionLabel,
                  style:TextStyle(fontWeight:FontWeight.w700,
                    color:bad?ErpTokens.danger:ErpTokens.ink)),
                if(bad)Text('Lỗi: '+x['error'].toString(),
                  style:const TextStyle(color:ErpTokens.danger))
                else ...[
                  Text('Trước: '+details(x['before']),
                    maxLines:2,overflow:TextOverflow.ellipsis,
                    style:const TextStyle(color:ErpTokens.muted,fontSize:12)),
                  Text('Sau: '+details(x['after']),
                    maxLines:2,overflow:TextOverflow.ellipsis),
                ],
              ]));
          }),
      ),
      const SizedBox(height:12),
      if(hasError)const Text('Có dòng lỗi: chưa thể áp dụng. Sửa file hoặc ánh xạ rồi xem trước lại.',
        style:TextStyle(color:ErpTokens.danger)),
      FilledButton.icon(
        key:const ValueKey('catalog-bulk-apply'),
        onPressed:busy||hasError||!widget.canWrite||pendingPayload!=null
          ?null:_apply,
        icon:const Icon(Icons.save_outlined),
        label:const Text('Xác nhận nhập toàn bộ')),
    ]);
  }
  @override Widget build(BuildContext context){
    return Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
      const Text('Nhập / cập nhật Excel – CSV',
        style:TextStyle(fontWeight:FontWeight.w800,fontSize:19,color:ErpTokens.ink)),
      const SizedBox(height:6),
      const Text('Quy trình: chọn file → ánh xạ cột → xem trước trước/sau → xác nhận. '
        'Chỉ lưu dữ liệu sau khi máy chủ xác nhận. Một file tối đa 5.000 dòng và 6 MB.',
        style:TextStyle(color:ErpTokens.muted,fontSize:12)),
      const SizedBox(height:15),
      Wrap(spacing:12,runSpacing:10,children:[
        SizedBox(width:230,child:DropdownButtonFormField<String>(
          key:const ValueKey('catalog-bulk-resource'),
          initialValue:kind,isExpanded:true,
          decoration:const InputDecoration(labelText:'Loại dữ liệu'),
          items:names.entries.map((e)=>DropdownMenuItem(
            value:e.key,child:Text(e.value))).toList(),
          onChanged:canOperate?_changeKind:null)),
        if(kind=='prices')SizedBox(width:300,child:DropdownButtonFormField<String>(
          key:ValueKey('catalog-bulk-price-list-'+(priceListId??'')),
          initialValue:priceLists.any((x)=>x['id']==priceListId)?priceListId:null,
          isExpanded:true,
          decoration:const InputDecoration(labelText:'Bảng giá đích'),
          items:priceLists.map((x)=>DropdownMenuItem<String>(
            value:x['id'].toString(),child:Text((x['name']??x['code']).toString(),
              overflow:TextOverflow.ellipsis))).toList(),
          onChanged:canOperate?(v)=>setState((){
            priceListId=v;preview=null;applied=null;error=null;
            defaultEffectiveAt=DateTime.now().toUtc().toIso8601String();
          }):null)),
        SizedBox(width:230,child:DropdownButtonFormField<String>(
          key:const ValueKey('catalog-bulk-mode'),
          initialValue:mode,isExpanded:true,
          decoration:const InputDecoration(labelText:'Chế độ'),
          items:const [
            DropdownMenuItem(value:'CREATE',child:Text('Chỉ thêm mới')),
            DropdownMenuItem(value:'UPDATE',child:Text('Chỉ cập nhật')),
            DropdownMenuItem(value:'UPSERT',child:Text('Thêm hoặc cập nhật')),
          ],onChanged:canOperate?(v)=>setState((){
            if(v!=null)mode=v;preview=null;applied=null;
          }):null)),
        OutlinedButton.icon(key:const ValueKey('catalog-bulk-template'),
          onPressed:canImport?()=>_saveCsv(template:true):null,
          icon:const Icon(Icons.download_outlined),label:const Text('Tải mẫu CSV')),
        OutlinedButton.icon(key:const ValueKey('catalog-bulk-export'),
          onPressed:canImport?()=>_saveCsv(template:false):null,
          icon:const Icon(Icons.file_download_outlined),label:const Text('Xuất dữ liệu CSV')),
        OutlinedButton.icon(key:const ValueKey('catalog-bulk-template-xlsx'),
          onPressed:canImport?()=>_saveCsv(template:true,excel:true):null,
          icon:const Icon(Icons.table_chart_outlined),label:const Text('Tải mẫu Excel')),
        OutlinedButton.icon(key:const ValueKey('catalog-bulk-export-xlsx'),
          onPressed:canImport?()=>_saveCsv(template:false,excel:true):null,
          icon:const Icon(Icons.table_view_outlined),label:const Text('Xuất Excel có định dạng')),
      ]),
      const SizedBox(height:14),
      Wrap(spacing:12,runSpacing:12,crossAxisAlignment:WrapCrossAlignment.center,
        children:[
          FilledButton.icon(key:const ValueKey('catalog-bulk-file'),
            onPressed:canImport?_pick:null,icon:const Icon(Icons.upload_file),
            label:const Text('1. Chọn Excel/CSV')),
          Text(fileName??'Chưa chọn file'),
          Row(mainAxisSize:MainAxisSize.min,children:[
            Checkbox(value:hasHeader,onChanged:canOperate&&contentBase64!=null
              ?(v){setState(()=>hasHeader=v??true);_inspect();}:null),
            const Text('Dòng đầu là tiêu đề'),
          ]),
        ]),
      if(busy)const Padding(padding:EdgeInsets.symmetric(vertical:12),
        child:LinearProgressIndicator()),
      if(error!=null)Padding(padding:const EdgeInsets.symmetric(vertical:10),
        child:Text(error!,key:const ValueKey('catalog-bulk-error'),
          style:const TextStyle(color:ErpTokens.danger))),
      if(inspection!=null&&pendingPayload==null)...[
        const SizedBox(height:20),
        _mappingEditor(),
        const SizedBox(height:12),
        FilledButton.icon(key:const ValueKey('catalog-bulk-preview'),
          onPressed:canImport?_preview:null,
          icon:const Icon(Icons.visibility_outlined),
          label:const Text('Xem trước toàn bộ thay đổi')),
      ],
      if(preview!=null&&pendingPayload==null)...[
        const SizedBox(height:20),_previewTable(),
      ],
      if(pendingPayload!=null)Padding(
        padding:const EdgeInsets.symmetric(vertical:12),
        child:FilledButton.icon(
          key:const ValueKey('catalog-bulk-retry'),
          onPressed:busy?null:_apply,
          icon:const Icon(Icons.sync),
          label:const Text('Kiểm tra yêu cầu đã gửi (retry cùng khóa)'))),
      if(applied!=null)Padding(padding:const EdgeInsets.only(top:12),
        child:Text('Đã lưu: '+
          (applied!['applied'] as List? ?? []).length.toString()+
          ' dòng được ghi; các dòng không đổi được giữ nguyên.',
          key:const ValueKey('catalog-bulk-applied'),
          style:const TextStyle(color:ErpTokens.primary,fontWeight:FontWeight.w700))),
    ]);
  }
}
