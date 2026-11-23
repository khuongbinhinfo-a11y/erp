import 'package:material_ui/material_ui.dart';
import 'erp_tokens.dart';
import 'erp_toast.dart';
import 'identity_client.dart';

/// Compact inline editor: no duplicate pricing engine and no free-text IDs.
class PriceListAssignmentsPanel extends StatefulWidget{
  final ErpIdentityClient client;
  final IdentitySession session;
  final String branchId;
  final Map<String,dynamic> priceList;
  final bool canWrite;
  final VoidCallback onClose;
  const PriceListAssignmentsPanel({super.key,required this.client,
    required this.session,required this.branchId,required this.priceList,
    required this.canWrite,required this.onClose});
  @override State<PriceListAssignmentsPanel> createState()=>_PriceListAssignmentsPanelState();
}
class _PriceListAssignmentsPanelState extends State<PriceListAssignmentsPanel>{
  final priority=TextEditingController(text:'0');
  final search=TextEditingController();
  String scope='DEFAULT';
  final selectedTargets=<String>{};
  DateTime? from,until;
  List<Map<String,dynamic>> rows=[],customers=[],groups=[],channels=[];
  bool busy=false,loading=true;
  String? error;
  String get listId=>widget.priceList['id'].toString();
  String get branch=>widget.branchId;
  String get token=>widget.session.token;
  @override void initState(){super.initState();load();}
  @override void didUpdateWidget(covariant PriceListAssignmentsPanel old){
    super.didUpdateWidget(old);
    if(old.branchId!=branch||old.priceList['id']!=listId||
        old.session.token!=token){
      rows=[];customers=[];groups=[];channels=[];
      scope='DEFAULT';selectedTargets.clear();from=null;until=null;load();
    }
  }
  @override void dispose(){priority.dispose();search.dispose();super.dispose();}

  Future<void> load()async{
    setState((){loading=true;error=null;});
    try{
      final all=await Future.wait<List<Map<String,dynamic>>>([
        widget.client.priceListAssignments(token,branch,priceListId:listId),
        widget.client.catalogItems(token,'customers',branchId:branch,
          query:search.text.trim()),
        widget.client.catalogDirectoryAll(token,'customer-groups',branchId:branch),
        widget.client.r1CatalogItems(token,'channels',branchId:branch,
          query:search.text.trim()),
      ]);
      if(!mounted)return;
      setState((){
        rows=all[0].where((x)=>x['priceListId']==listId).toList();
        customers=all[1].where((x)=>x['active']!=false).toList();
        groups=all[2].where((x)=>x['active']!=false).toList();
        channels=all[3].where((x)=>x['active']!=false).toList();
        loading=false;
      });
    }on ErpApiError catch(e){
      if(mounted)setState((){
        loading=false;
        error=e.status==503?'Cần áp dụng migration 0018 trước khi gán bảng giá.'
          :e.message;
      });
    }catch(_){
      if(mounted)setState((){
        loading=false;error='Chưa tải được phân bổ bảng giá từ máy chủ.';
      });
    }
  }
  List<Map<String,dynamic>> get choices=>switch(scope){
    'CUSTOMER'=>customers,
    'CUSTOMER_GROUP'=>groups,
    'CHANNEL'=>channels,
    _=>const [],
  };
  String scopeName(String kind)=>switch(kind){
    'DEFAULT'=>'Mặc định chi nhánh',
    'CUSTOMER'=>'Khách hàng',
    'CUSTOMER_GROUP'=>'Nhóm khách',
    'CHANNEL'=>'Kênh bán',
    _=>kind,
  };
  String dateLabel(DateTime? date,String empty){
    if(date==null)return empty;
    final local=date.toLocal();
    return '${local.day.toString().padLeft(2,'0')}/'
      '${local.month.toString().padLeft(2,'0')}/${local.year}';
  }
  DateTime? endExclusive(DateTime? day){
    if(day==null)return null;
    final local=day.toLocal();
    return DateTime(local.year,local.month,local.day+1).toUtc();
  }
  String effectiveLabel(dynamic value,{bool exclusiveEnd=false}){
    final parsed=DateTime.tryParse(value?.toString()??'');
    if(parsed==null)return 'Không giới hạn';
    final day=exclusiveEnd
      ?parsed.subtract(const Duration(microseconds:1)).toLocal()
      :parsed.toLocal();
    return dateLabel(day,'Không giới hạn');
  }
  Future<void> selectDay(bool end)async{
    final today=DateTime.now(),current=end?until:from;
    final picked=await showDatePicker(context:context,
      initialDate:current?.toLocal()??today,firstDate:DateTime(2020),
      lastDate:DateTime(2100),helpText:end?'Đến hết ngày':'Có hiệu lực từ ngày');
    if(picked!=null&&mounted)setState((){
      final normalized=DateTime(picked.year,picked.month,picked.day).toUtc();
      if(end)until=normalized;else from=normalized;
    });
  }
  Future<void> save()async{
    if(busy||loading||!widget.canWrite)return;
    final targets=scope=='DEFAULT'?<String>['']:selectedTargets.toList();
    if(targets.isEmpty){
      ErpToast.show(context,'Chọn ít nhất một đối tượng áp dụng.',isError:true);
      return;
    }
    if(from!=null&&until!=null&&until!.isBefore(from!)){
      ErpToast.show(context,'Ngày kết thúc phải từ ngày bắt đầu trở đi.',isError:true);
      return;
    }
    final p=int.tryParse(priority.text.trim());
    if(p==null||p< -100000||p>100000){
      ErpToast.show(context,'Ưu tiên phải là số nguyên từ -100000 đến 100000.',
        isError:true);
      return;
    }
    setState(()=>busy=true);
    var completed=0;
    try{
      // The server contract assigns one scoped target per command. Batch
      // deliberately sends separate stable idempotency keys, not a widened
      // unscoped assignment or a JSON array the API cannot validate.
      for(final id in targets){
        final kind='catalog.assign.price-list.$listId.$scope.${id.isEmpty?'default':id}';
        final pending=widget.client.pendingR1(widget.session.actorId,branch,kind);
        final body=pending?.payload??<String,dynamic>{
          'branchId':branch,'priceListId':listId,'scopeKind':scope,
          'priority':p,
          if(scope=='CUSTOMER')'customerId':id,
          if(scope=='CUSTOMER_GROUP')'customerGroupId':id,
          if(scope=='CHANNEL')'channelId':id,
          'effectiveFrom':from?.toIso8601String(),
          'effectiveTo':endExclusive(until)?.toIso8601String(),
        };
        final key=pending?.key??
          'r1c-list-assign-${DateTime.now().microsecondsSinceEpoch}-$id';
        if(pending==null)widget.client.retainR1(
          widget.session.actorId,branch,kind,body,key);
        try{
          await widget.client.assignPriceList(token,body,key:key);
        }on ErpApiError catch(e){
          if(e.status==400||e.status==404||
              ['PRICE_LIST_ASSIGNMENT_OVERLAP','ASSIGNMENT_TARGET_UNAVAILABLE',
               'PRICE_LIST_UNAVAILABLE'].contains(e.code)){
            widget.client.clearR1(widget.session.actorId,branch,kind);
          }
          rethrow;
        }
        widget.client.clearR1(widget.session.actorId,branch,kind);
        completed++;
        if(mounted)setState(()=>selectedTargets.remove(id));
      }
      if(!mounted)return;
      ErpToast.show(context,'Đã gán bảng giá cho $completed đối tượng.');
      await load();
    }on ErpApiError catch(e){
      if(mounted)ErpToast.show(context,
        'Đã lưu $completed/${targets.length}. ${e.message}',isError:true);
    }catch(_){
      if(mounted)ErpToast.show(context,
        'Đã lưu $completed/${targets.length}. Mục chưa xác nhận giữ nguyên yêu cầu để kiểm tra lại.',
        isError:true);
    }finally{if(mounted)setState(()=>busy=false);}
  }
  Future<void> toggle(Map<String,dynamic> row)async{
    if(busy||!widget.canWrite)return;
    final id=row['id'] as String,revision=row['revision'] as int;
    final kind='catalog.assign.toggle.$id';
    final pending=widget.client.pendingR1(widget.session.actorId,branch,kind);
    final body=pending?.payload??<String,dynamic>{
      'active':row['active']!=true,'revision':revision,
    };
    final key=pending?.key??'r1c-list-toggle-${DateTime.now().microsecondsSinceEpoch}';
    if(pending==null)widget.client.retainR1(widget.session.actorId,branch,kind,body,key);
    setState(()=>busy=true);
    try{
      await widget.client.togglePriceListAssignment(token,id,branch,
        body['revision'] as int,body['active'] as bool,key:key);
      widget.client.clearR1(widget.session.actorId,branch,kind);
      if(!mounted)return;
      ErpToast.show(context,'Đã cập nhật trạng thái phân bổ.');
      await load();
    }on ErpApiError catch(e){
      if(e.status==400||e.status==404||
          ['REVISION_CONFLICT','PRICE_LIST_ASSIGNMENT_OVERLAP',
           'ASSIGNMENT_TARGET_UNAVAILABLE','PRICE_LIST_UNAVAILABLE'].contains(e.code))
        widget.client.clearR1(widget.session.actorId,branch,kind);
      if(mounted)ErpToast.show(context,e.message,isError:true);
    }catch(_){
      if(mounted)ErpToast.show(context,'Chưa xác nhận. Thử lại đúng yêu cầu cũ.',
        isError:true);
    }finally{if(mounted)setState(()=>busy=false);}
  }
  @override Widget build(BuildContext context){
    final eligible=choices;
    final wide=MediaQuery.sizeOf(context).width>=780;
    return Container(key:const ValueKey('r1c-list-assignment-panel'),
      margin:const EdgeInsets.only(top:16),
      decoration:BoxDecoration(color:ErpTokens.mint.withValues(alpha:0.20),
        border:Border.all(color:ErpTokens.mint),
        borderRadius:BorderRadius.circular(8)),
      padding:const EdgeInsets.all(14),
      child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        Row(children:[
          Expanded(child:Text('Phân bổ · ${widget.priceList['code']}',
            style:const TextStyle(fontWeight:FontWeight.w800,
              fontSize:16,color:ErpTokens.ink))),
          IconButton(onPressed:widget.onClose,tooltip:'Đóng phân bổ',
            icon:const Icon(Icons.close,size:20)),
        ]),
        const Padding(padding:EdgeInsets.only(bottom:12),
          child:Text('Ưu tiên chọn: khách riêng → nhóm khách → kênh bán → mặc định. '
            'Trong cùng phạm vi: ưu tiên số lớn, sau đó ưu tiên bảng giá. '
            'Bảng giá hết hạn không được áp dụng.',
            style:TextStyle(fontSize:12,color:ErpTokens.muted))),
        if(loading)const LinearProgressIndicator(),
        if(error!=null)Padding(padding:const EdgeInsets.symmetric(vertical:8),
          child:Text(error!,style:const TextStyle(color:ErpTokens.danger))),
        if(!loading&&error==null)...[
          if(widget.canWrite)...[
            Wrap(spacing:8,runSpacing:8,
              crossAxisAlignment:WrapCrossAlignment.center,children:[
              SizedBox(width:wide?310:240,child:TextField(
                key:const ValueKey('r1c-assignment-target-search'),
                controller:search,
                decoration:const InputDecoration(
                  labelText:'Tìm khách hàng / kênh bán',
                  hintText:'Nhập mã hoặc tên chính xác',
                  isDense:true,prefixIcon:Icon(Icons.search)),
                onSubmitted:(_)=>load())),
              OutlinedButton.icon(
                key:const ValueKey('r1c-assignment-target-find'),
                onPressed:busy?null:load,
                icon:const Icon(Icons.search,size:17),
                label:const Text('Tìm trên máy chủ')),
              const Text('Kết quả khớp tìm kiếm từ máy chủ.',
                style:TextStyle(fontSize:12,color:ErpTokens.muted)),
            ]),
            const SizedBox(height:12),
          ],
          if(widget.canWrite)Wrap(spacing:10,runSpacing:10,
            crossAxisAlignment:WrapCrossAlignment.end,children:[
              SizedBox(width:wide?192:260,child:DropdownButtonFormField<String>(
                key:ValueKey('r1c-scope-$scope'),initialValue:scope,
                isExpanded:true,decoration:const InputDecoration(
                  labelText:'Áp dụng cho',isDense:true),
                items:const [
                  DropdownMenuItem(value:'DEFAULT',child:Text('Mặc định')),
                  DropdownMenuItem(value:'CUSTOMER',child:Text('Khách hàng')),
                  DropdownMenuItem(value:'CUSTOMER_GROUP',child:Text('Nhóm khách')),
                  DropdownMenuItem(value:'CHANNEL',child:Text('Kênh bán')),
                ],
                onChanged:busy?null:(v){if(v!=null)setState((){
                  scope=v;selectedTargets.clear();
                });})),
              if(scope!='DEFAULT')SizedBox(width:wide?380:260,
                child:Column(crossAxisAlignment:CrossAxisAlignment.start,
                  mainAxisSize:MainAxisSize.min,children:[
                  Row(children:[
                    Expanded(child:Text('${scopeName(scope)} · đã chọn ${selectedTargets.length}',
                      style:const TextStyle(fontWeight:FontWeight.w700,fontSize:12))),
                    TextButton(onPressed:busy?null:()=>setState((){
                      selectedTargets.addAll(eligible.map((e)=>e['id'].toString()));
                    }),child:const Text('Chọn kết quả')),
                    TextButton(onPressed:busy?null:()=>setState(()=>selectedTargets.clear()),
                      child:const Text('Bỏ chọn')),
                  ]),
                  DecoratedBox(decoration:BoxDecoration(
                      border:Border.all(color:ErpTokens.border),
                      borderRadius:BorderRadius.circular(6)),
                    child:ConstrainedBox(constraints:const BoxConstraints(maxHeight:156),
                      child:eligible.isEmpty
                        ?const Padding(padding:EdgeInsets.all(12),
                          child:Text('Không có kết quả. Tìm mã hoặc tên phía trên.'))
                        :ListView.builder(shrinkWrap:true,itemCount:eligible.length,
                          itemBuilder:(context,i){
                            final option=eligible[i];
                            final id=option['id'].toString();
                            return CheckboxListTile(
                              key:ValueKey('r1c-target-check-$id'),
                              dense:true,controlAffinity:ListTileControlAffinity.leading,
                              contentPadding:const EdgeInsets.symmetric(horizontal:8),
                              title:Text("${option['code']} · ${option['name']}",
                                maxLines:1,overflow:TextOverflow.ellipsis,
                                style:const TextStyle(fontSize:12)),
                              value:selectedTargets.contains(id),
                              onChanged:busy?null:(selected)=>setState((){
                                if(selected==true){selectedTargets.add(id);}
                                else{selectedTargets.remove(id);}
                              }));
                          }))),
                  ),
                  const Padding(padding:EdgeInsets.only(top:3),
                    child:Text('Có thể tìm tiếp và chọn thêm; chỉ chọn trong kết quả tải từ máy chủ.',
                      style:TextStyle(fontSize:11,color:ErpTokens.muted))),
                ])),
              SizedBox(width:120,child:TextField(
                key:const ValueKey('r1c-assignment-priority'),
                controller:priority,keyboardType:TextInputType.number,
                decoration:const InputDecoration(labelText:'Ưu tiên',
                  isDense:true))),
              OutlinedButton.icon(
                onPressed:busy?null:()=>selectDay(false),
                icon:const Icon(Icons.event,size:16),
                label:Text(dateLabel(from,'Từ ngày'))),
              if(from!=null)IconButton(
                tooltip:'Bỏ ngày bắt đầu',onPressed:()=>setState(()=>from=null),
                icon:const Icon(Icons.close,size:16)),
              OutlinedButton.icon(
                onPressed:busy?null:()=>selectDay(true),
                icon:const Icon(Icons.event_busy,size:16),
                label:Text(dateLabel(until,'Đến hết ngày'))),
              if(until!=null)IconButton(
                tooltip:'Bỏ ngày kết thúc',onPressed:()=>setState(()=>until=null),
                icon:const Icon(Icons.close,size:16)),
              FilledButton.icon(
                key:const ValueKey('r1c-assign-save'),
                onPressed:busy?null:save,icon:const Icon(Icons.check,size:18),
                label:Text(scope=='DEFAULT'?'Gán mặc định':
                  'Gán ${selectedTargets.length} đối tượng')),
            ]),
          const SizedBox(height:12),
          if(rows.isEmpty)const Text('Chưa có phân bổ cho bảng giá này.',
            style:TextStyle(color:ErpTokens.muted))
          else SingleChildScrollView(scrollDirection:Axis.horizontal,
            child:DataTable(dataRowMinHeight:42,dataRowMaxHeight:52,
              headingRowHeight:40,
              headingRowColor:const WidgetStatePropertyAll(ErpTokens.mint),
              columns:const [
                DataColumn(label:Text('Đối tượng')),
                DataColumn(label:Text('Hiệu lực')),
                DataColumn(label:Text('Ưu tiên')),
                DataColumn(label:Text('Trạng thái')),
                DataColumn(label:Text('Thao tác')),
              ],
              rows:rows.map((a){
                final kind=a['scopeKind']?.toString()??'DEFAULT';
                final who=a['customerCode']??a['customerGroupCode']??
                  a['channelCode']??'Chi nhánh';
                final active=a['active']==true;
                return DataRow(cells:[
                  DataCell(Text('${scopeName(kind)} · $who')),
                  DataCell(Text('${effectiveLabel(a['effectiveFrom'])} – '
                    '${effectiveLabel(a['effectiveTo'],exclusiveEnd:true)}')),
                  DataCell(Text(a['priority'].toString())),
                  DataCell(Text(active?'Đang áp dụng':'Đã ngừng')),
                  DataCell(!widget.canWrite?const Text('—'):TextButton(
                    onPressed:busy?null:()=>toggle(a),
                    child:Text(active?'Ngừng':'Sử dụng lại'))),
                ]);
              }).toList())),
        ],
      ]));
  }
}
