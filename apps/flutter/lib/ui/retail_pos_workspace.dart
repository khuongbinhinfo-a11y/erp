import 'dart:async';
import 'dart:math';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../local/local_store.dart';
import 'erp_display.dart';
import 'app_update.dart';
import 'retail_receipt.dart';
import 'erp_number_input.dart';
import 'erp_tokens.dart';
import 'identity_client.dart';
import 'sales_workspace.dart' show erpRetailStepQuantity;

/// POS is a separate task surface, not a cosmetic mode of the distribution
/// order editor. Only an acknowledged, atomic server POS checkout can
/// report issued inventory and settled payment; no client-side ledger writes.
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
  int _generation=0,_quoteVersion=0,_searchVersion=0,_catalogVersion=0,_customerChoiceVersion=0;
  bool _loading=true,_searching=false,_quoting=false,_configOpen=false,_cached=false,_catalogLoading=false;
  String? _branch,_warehouse,_priceList,_walkIn,_error,_quoteError,_total;
  List<Map<String,dynamic>> _branches=[],_warehouses=[],_priceLists=[],_customers=[],_matches=[],_catalog=[];
  List<_RetailLine> _lines=[];
  List<Map<String,dynamic>> _priced=[];
  Map<String,dynamic>? _shift,_pendingCheckout,_lastReceipt;
  bool _busyAction=false,_preparingWalkIn=false;
   String? _canonicalWalkIn;
  String? _posError;
  String _nonce()=>DateTime.now().microsecondsSinceEpoch.toString()+'-'+
    Random.secure().nextInt(0x7fffffff).toRadixString(16);
  bool get _canSettle=>_lines.isNotEmpty&&_total!=null&&_priceList!=null&&
    _walkIn!=null&&!_quoting&&_priced.length==_lines.length&&
    _shift!=null&&!_busyAction&&_pendingCheckout==null;


  @override void initState(){super.initState();unawaited(_loadBranches());}
  @override void didUpdateWidget(covariant RetailPosWorkspace old){
    super.didUpdateWidget(old);
    if(old.session.token!=widget.session.token||
        old.session.actorId!=widget.session.actorId||
        old.session.installationId!=widget.session.installationId){
      ++_generation;++_quoteVersion;++_searchVersion;++_catalogVersion;
      _debounce?.cancel();_search.clear();
      _branch=null;_warehouse=null;_priceList=null;_walkIn=null;_canonicalWalkIn=null;_preparingWalkIn=false;++_customerChoiceVersion;
      _lines=[];_matches=[];_catalog=[];_priced=[];_total=null;_error=null;
      _shift=null;_pendingCheckout=null;_lastReceipt=null;
      unawaited(_loadBranches());
    }
  }
  @override void dispose(){
    ++_generation;++_quoteVersion;++_searchVersion;++_catalogVersion;
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
    ++_quoteVersion;++_searchVersion;++_catalogVersion;_debounce?.cancel();
    setState((){
      _branch=branch;_warehouse=null;_priceList=null;_walkIn=null;_canonicalWalkIn=null;_preparingWalkIn=false;++_customerChoiceVersion;
      _lines=[];_priced=[];_matches=[];_catalog=[];_total=null;_quoteError=null;
      _loading=true;_error=null;_search.clear();
      _shift=null;_pendingCheckout=null;_lastReceipt=null;
    });
    try{
      final result=await Future.wait<Object>([
        widget.client.salesCatalog(widget.session,'warehouses',branchId:branch),
        widget.client.salesCatalog(widget.session,'price-lists',branchId:branch),
        widget.client.salesEntrySettings(widget.session.token,branch),
        widget.client.salesCatalog(widget.session,'customers',branchId:branch),
      ]);
      if(!mounted||g!=_generation)return;
      final warehouses=(result[0] as ({List<Map<String,dynamic>> items,bool cached})).items;
      final lists=(result[1] as ({List<Map<String,dynamic>> items,bool cached})).items
        .where((p)=>p['active']!=false).toList();
      final settings=result[2] as Map<String,dynamic>;
      final walkIn=settings['walkInCustomer'];
      final customers=(result[3] as ({List<Map<String,dynamic>> items,bool cached})).items
        .where((x)=>x['active']!=false).toList();
      if(walkIn is Map&&walkIn['id'] is String&&
         !customers.any((x)=>x['id']==walkIn['id'])){
        customers.insert(0,Map<String,dynamic>.from(walkIn));
      }
      final preferred=lists.where((p)=>p['code']?.toString().toUpperCase()=='RETAIL').firstOrNull;
      setState((){
        _warehouses=warehouses;_priceLists=lists;_customers=customers;
        _warehouse=warehouses.isEmpty?null:warehouses.first['id'] as String;
        _priceList=(preferred??lists.firstOrNull)?['id'] as String?;
        _canonicalWalkIn=walkIn is Map&&walkIn['active']==true?walkIn['id'] as String?:null;
         _walkIn=_canonicalWalkIn;
        _loading=false;
      });
      await _restoreCart(g);
      await _loadPosState(g);
      unawaited(_loadCatalog(g));
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
       // The pending server command remains retryable with the same key.
       // A warehouse switch must not leave the guest action disabled.
       _preparingWalkIn=false;
      _matches=[];_quoteError=null;
    });
    await _pendingWrite;
    await _restoreCart(g);
    await _loadPosState(g);
    unawaited(_loadCatalog(g));
  }
  Future<void> _loadCatalog(int generation)async{
    final branch=_branch,request=++_catalogVersion;
    if(branch==null)return;
    if(mounted)setState(()=>_catalogLoading=true);
    try{
      // Bounded browsing is display data, not a verified price or stock fact.
      final result=await widget.client.salesCatalog(widget.session,'r1/skus',branchId:branch);
      if(!mounted||generation!=_generation||request!=_catalogVersion||branch!=_branch)return;
      setState((){
        _catalog=result.items.where((item)=>item['active']!=false).take(100).toList();
        _catalogLoading=false;
        _cached=_cached||result.cached;
      });
    }catch(_){
      if(mounted&&generation==_generation&&request==_catalogVersion)
        setState(()=>_catalogLoading=false);
    }
  }
  Future<void> _loadPosState(int g)async{
    final scope=_scope,store=widget.client.localStore;
    if(scope==null)return;
    try{
      final saved=await store?.retailPending(scope);
      if(!mounted||g!=_generation)return;
      setState(()=>_pendingCheckout=saved);
      final shift=await widget.client.posCurrentShift(widget.session.token,_branch!,_warehouse!);
      if(!mounted||g!=_generation)return;
      setState((){_shift=shift;_posError=null;});
    }on ErpApiError catch(e){
      if(mounted&&g==_generation)setState((){_shift=null;_posError=e.message;});
    }catch(_){
      if(mounted&&g==_generation)setState((){_shift=null;_posError='Chưa kết nối được ca bán.';});
    }
  }
  Future<void> _openShift()async{
    final branch=_branch,warehouse=_warehouse;
    if(branch==null||warehouse==null||_busyAction)return;
    final counter=TextEditingController(text:'Quầy chính');
    final opening=TextEditingController(text:'0');
    final form=await showDialog<Map<String,String>>(context:context,builder:(ctx)=>AlertDialog(
      title:const Text('Mở ca bán hàng'),
      content:Column(mainAxisSize:MainAxisSize.min,children:[
        TextField(controller:counter,decoration:const InputDecoration(labelText:'Tên quầy')),
        TextField(controller:opening,keyboardType:TextInputType.number,
          inputFormatters:const [ErpGroupedNumberFormatter(maxIntegerDigits:16,maxFractionDigits:0)],
          decoration:const InputDecoration(labelText:'Tiền mặt đầu ca')),
      ]),
      actions:[
        TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('Hủy')),
        FilledButton(onPressed:()=>Navigator.pop(ctx,{
          'counterName':counter.text.trim(),'openingCash':erpNumberCanonical(opening.text),
        }),child:const Text('Mở ca')),
      ]));
    counter.dispose();opening.dispose();
    if(form==null)return;
    setState((){_busyAction=true;_posError=null;});
    try{
      await widget.client.posOpenShift(widget.session.token,{
        'branchId':branch,'warehouseId':warehouse,...form},key:'pos-shift-'+_nonce());
      if(mounted)await _loadPosState(_generation);
    }on ErpApiError catch(e){if(mounted){
      setState(()=>_posError=e.message);
      await _loadPosState(_generation);
    }}catch(_){if(mounted)setState(()=>_posError='Không mở được ca. Hãy kiểm tra lại trạng thái ca.');}
    finally{if(mounted)setState(()=>_busyAction=false);}
  }
  Future<void> _closeShift()async{
    final shiftId=_shift?['id']?.toString(),branch=_branch,warehouse=_warehouse;
    if(shiftId==null||branch==null||warehouse==null||_busyAction||_pendingCheckout!=null)return;
    final closing=TextEditingController(text:_shift?['expectedCash']?.toString()??'0');
    final count=await showDialog<String>(context:context,builder:(ctx)=>AlertDialog(
      title:const Text('Đóng ca và đối soát tiền mặt'),
      content:Column(mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.start,children:[
        Text('Tiền mặt dự kiến: '+erpVndText(_shift?['expectedCash'])),
        TextField(controller:closing,keyboardType:TextInputType.number,
          inputFormatters:const [ErpGroupedNumberFormatter(maxIntegerDigits:16,maxFractionDigits:0)],
          decoration:const InputDecoration(labelText:'Tiền mặt kiểm đếm')),
      ]),
      actions:[
        TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('Hủy')),
        FilledButton(onPressed:()=>Navigator.pop(ctx,erpNumberCanonical(closing.text)),
          child:const Text('Xác nhận đóng ca')),
      ]));
    closing.dispose();
    if(count==null)return;
    setState(()=>_busyAction=true);
    try{
      final result=await widget.client.posCloseShift(widget.session.token,shiftId,{
        'branchId':branch,'warehouseId':warehouse,'closingCash':count,
      },key:'pos-close-'+_nonce());
      if(mounted){
        setState(()=>_shift=null);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(
          'Đã đóng ca. Chênh lệch: '+erpVndText(result['variance']))));
      }
    }on ErpApiError catch(e){if(mounted)setState(()=>_posError=e.message);}
    catch(_){if(mounted)setState(()=>_posError='Không đóng được ca. Kiểm tra kết nối.');}
    finally{if(mounted)setState(()=>_busyAction=false);}
  }
  Future<void> _checkoutDialog()async{
    final total=_total;
    if(!_canSettle||total==null||_branch==null||_warehouse==null||_shift==null)return;
    final cash=TextEditingController(text:erpNumberText(total));
    final bank=TextEditingController(text:'0');
    final payment=await showDialog<Map<String,String>>(context:context,builder:(ctx)=>AlertDialog(
      title:const Text('Thanh toán tại quầy'),
      content:Column(mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.start,children:[
        Text('Khách cần thanh toán: '+erpVndText(total),
          style:const TextStyle(fontWeight:FontWeight.bold)),
        const SizedBox(height:12),
        TextField(key:const ValueKey('pos-cash-received'),controller:cash,
          keyboardType:TextInputType.number,
          inputFormatters:const [ErpGroupedNumberFormatter(maxIntegerDigits:16,maxFractionDigits:0)],
          decoration:const InputDecoration(labelText:'Tiền mặt khách đưa')),
        const SizedBox(height:8),
        TextField(key:const ValueKey('pos-bank-amount'),controller:bank,
          keyboardType:TextInputType.number,
          inputFormatters:const [ErpGroupedNumberFormatter(maxIntegerDigits:16,maxFractionDigits:0)],
          decoration:const InputDecoration(labelText:'Tiền chuyển khoản')),
        const SizedBox(height:8),
        const Text('Chỉ xuất kho, ghi nhận thu tiền sau khi máy chủ xác nhận.'),
      ]),
      actions:[
        TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('Quay lại')),
        FilledButton(key:const ValueKey('pos-confirm-payment'),
          onPressed:()=>Navigator.pop(ctx,{
            'cashReceived':erpNumberCanonical(cash.text),
            'bankAmount':erpNumberCanonical(bank.text),
          }),child:const Text('Xác nhận thanh toán')),
      ]));
    cash.dispose();bank.dispose();
    if(payment==null||!mounted||!_canSettle)return;
    try{
      final totalMoney=BigInt.parse(total),cashMoney=BigInt.parse(payment['cashReceived']!),
        bankMoney=BigInt.parse(payment['bankAmount']!);
      if(cashMoney<BigInt.zero||bankMoney<BigInt.zero||bankMoney>totalMoney||
          cashMoney+bankMoney<totalMoney||payment.values.any((x)=>x.length>16)){
        setState(()=>_posError='Tiền mặt và chuyển khoản không đủ hoặc không hợp lệ.');
        return;
      }
    }catch(_){setState(()=>_posError='Nhập tiền nguyên VND hợp lệ.');return;}
    final fields=<String,dynamic>{
      'branchId':_branch,'warehouseId':_warehouse,'shiftId':_shift!['id'],
      'customerId':_walkIn,'priceListId':_priceList,...payment,
      'lines':_lines.asMap().entries.map((entry)=>({
        'sellSkuId':entry.value.id,'quantity':entry.value.quantity,
        'expectedPriceSignature':_priced[entry.key]['priceSignature'],
      })).toList(),
    };
    final scope=_scope,store=widget.client.localStore;
    if(scope==null||store==null){
      setState(()=>_posError='Không có kho lưu giao dịch an toàn trên thiết bị.');
      return;
    }
    final command={'key':'pos-checkout-'+_nonce(),'body':fields};
    try{
      await _pendingWrite;
      await store.saveRetailPending(scope,command);
    }catch(_){if(mounted)setState(()=>_posError='Có giao dịch chưa đối soát. Hãy kiểm tra trước.');return;}
    if(!mounted)return;
    setState(()=>_pendingCheckout=command);
    await _resolvePendingCheckout();
  }
  Future<void> _resolvePendingCheckout()async{
    final pending=_pendingCheckout,scope=_scope,store=widget.client.localStore;
    if(pending==null||_busyAction||scope==null||store==null)return;
    final key=pending['key']?.toString(),raw=pending['body'];
    if(key==null||raw is! Map)return;
    final fields=Map<String,dynamic>.from(raw);
    final branch=_branch,warehouse=_warehouse,token=widget.session.token;
    if(branch==null||warehouse==null||fields['branchId']!=branch||
        fields['warehouseId']!=warehouse)return;
    setState((){_busyAction=true;_posError=null;});
    try{
      final prior=await widget.client.posCheckoutRecovery(token,fields,key:key);
      final receipt=prior??await widget.client.posCheckout(token,fields,key:key);
      await _applyPendingPosOutcome(receipt,key,branch,warehouse,token);
    }on ErpApiError catch(e){
      if(mounted)setState(()=>_posError=e.message+'; giữ giao dịch để đối soát, không thanh toán lần hai.');
    }catch(_){
      if(mounted)setState(()=>_posError='Chưa xác minh máy chủ đã nhận tiền. Hãy kiểm tra giao dịch, không tạo đơn khác.');
    }finally{if(mounted)setState(()=>_busyAction=false);}
  }

  /// Only a server-committed CANCELED receipt can unlock a rejected command.
  /// If checkout won the race, the same endpoint returns the PAID receipt.
  Future<void> _applyPendingPosOutcome(Map<String,dynamic> outcome,String key,
    String branch,String warehouse,String token)async{
    final scope=_scope,store=widget.client.localStore;
    if(scope==null||store==null||!mounted||_branch!=branch||
       _warehouse!=warehouse||widget.session.token!=token)return;
    if(outcome['status']=='CANCELED'){
      await store.clearRetailPending(scope,key);
      if(!mounted||_branch!=branch||_warehouse!=warehouse)return;
      setState((){
        _pendingCheckout=null;_priced=[];_total=null;_quoteError=null;
        _posError='Giao dịch cũ đã hủy an toàn. Anh/chị có thể sửa giỏ và tính giá lại.';
      });
      await _quote();
      return;
    }
    if(outcome['paymentStatus']!='PAID'||outcome['deliveryStatus']!='DELIVERED'||
       outcome['total'] is! String||outcome['id'] is! String){
      throw const FormatException('Unverified POS outcome');
    }
    await store.clearRetailPending(scope,key);
    if(!mounted||_branch!=branch||_warehouse!=warehouse)return;
    setState((){
      _pendingCheckout=null;_lastReceipt=outcome;
      _lines=[];_priced=[];_total=null;_posError=null;
    });
    _queueSave();
    await _loadPosState(_generation);
    if(mounted)await _showReceipt(outcome);
  }
  Future<void> _cancelPendingCheckout()async{
    final pending=_pendingCheckout;
    if(pending==null||_busyAction)return;
    final key=pending['key']?.toString(),raw=pending['body'];
    final branch=_branch,warehouse=_warehouse,token=widget.session.token;
    if(key==null||raw is! Map||branch==null||warehouse==null)return;
    final fields=Map<String,dynamic>.from(raw);
    if(fields['branchId']!=branch||fields['warehouseId']!=warehouse)return;
    setState((){_busyAction=true;_posError=null;});
    try{
      final outcome=await widget.client.posCancelCheckout(token,fields,key:key);
      await _applyPendingPosOutcome(outcome,key,branch,warehouse,token);
    }on ErpApiError catch(e){
      if(mounted)setState(()=>_posError=e.message+
        '; giao dịch vẫn được giữ cho đến khi máy chủ xác minh.');
    }catch(_){
      if(mounted)setState(()=>_posError='Chưa đối soát được lệnh hủy. '+
        'Không được tạo giao dịch khác trước khi kiểm tra lại.');
    }finally{if(mounted)setState(()=>_busyAction=false);}
  }
  Future<void> _printReceipt(Map<String,dynamic> receipt)async{
    final branch=_branch,warehouse=_warehouse,token=widget.session.token;
    final checkoutId=receipt['id'];
    if(!erpAndroidUpdateSupported||checkoutId is! String||
       branch==null||warehouse==null)return;
    try{
      final verified=await widget.client.posReceipt(token,branch,warehouse,checkoutId);
      if(!mounted||_branch!=branch||_warehouse!=warehouse||
          widget.session.token!=token)return;
      final html=erpRetailReceiptHtml(verified);
      final opened=await const MethodChannel('erp/pos_receipt').invokeMethod<bool>(
        'printReceipt',{'html':html});
      if(mounted&&opened!=true)throw const FormatException('Không mở được trình in');
    }catch(_){
      if(mounted)setState(()=>_posError='Không mở được trình in Android. Phiếu vẫn lưu trong lịch sử quầy.');
    }
  }
  Future<void> _showReceipt(Map<String,dynamic> receipt)async{
    if(!mounted)return;
    final label='Phiếu bán '+(receipt['documentNo']?.toString()??'');
    await showDialog<void>(context:context,builder:(ctx)=>AlertDialog(
      title:Text(label),content:Column(mainAxisSize:MainAxisSize.min,
      crossAxisAlignment:CrossAxisAlignment.start,children:[
        const Text('Đã thanh toán và giao hàng tại quầy.'),
        Text('Tổng tiền: '+erpVndText(receipt['total'])),
        Text('Tiền mặt nhận: '+erpVndText(receipt['cashReceived'])),
        Text('Chuyển khoản: '+erpVndText(receipt['bankAmount'])),
        Text('Tiền trả lại: '+erpVndText(receipt['changeDue'])),
      ]),
      actions:[
        if(erpAndroidUpdateSupported)TextButton.icon(
          onPressed:(){Navigator.pop(ctx);unawaited(_printReceipt(receipt));},
          icon:const Icon(Icons.print_outlined),label:const Text('In phiếu')),
        TextButton(onPressed:(){
          Clipboard.setData(ClipboardData(text:label+'\nTổng: '+
            erpVndText(receipt['total'])+'\nTiền thừa: '+erpVndText(receipt['changeDue'])));
          Navigator.pop(ctx);
        },child:const Text('Sao chép phiếu')),
        FilledButton(onPressed:()=>Navigator.pop(ctx),child:const Text('Đóng')),
      ]));
  }
  Future<void> _showHistory()async{
    final branch=_branch,warehouse=_warehouse;
    if(branch==null||warehouse==null||_busyAction)return;
    setState(()=>_busyAction=true);
    try{
      final items=await widget.client.posCheckouts(widget.session.token,branch,warehouse);
      if(!mounted)return;
      await showModalBottomSheet<void>(context:context,isScrollControlled:true,
        builder:(ctx)=>SafeArea(child:FractionallySizedBox(heightFactor:.72,
          child:Column(children:[
            const Padding(padding:EdgeInsets.all(16),child:Text('Lịch sử bán tại quầy',
              style:TextStyle(fontSize:18,fontWeight:FontWeight.bold))),
            Expanded(child:items.isEmpty?const Center(child:Text('Chưa có giao dịch')):
              ListView.builder(itemCount:items.length,itemBuilder:(ctx,i){
                final item=items[i],returned=item['returned']==true;
                return ListTile(
                  leading:Icon(returned?Icons.assignment_return_outlined:Icons.receipt_long_outlined),
                  title:Text(item['documentNo']?.toString()??'Phiếu bán'),
                  subtitle:Text(returned?'Đã hoàn hàng':'Đã thanh toán'),
                  trailing:Text(erpVndText(item['total'])),
                  onTap:()async{
                    Navigator.pop(ctx);
                    try{
                      final receipt=await widget.client.posReceipt(widget.session.token,
                        branch,warehouse,item['id'] as String);
                      if(!mounted||branch!=_branch||warehouse!=_warehouse)return;
                      setState(()=>_lastReceipt=receipt);
                      await _showReceipt(receipt);
                    }on ErpApiError catch(e){
                      if(mounted)setState(()=>_posError=e.message);
                    }
                  },
                );
              })),
          ]))));
    }on ErpApiError catch(e){if(mounted)setState(()=>_posError=e.message);}
    catch(_){if(mounted)setState(()=>_posError='Không tải được lịch sử quầy.');}
    finally{if(mounted)setState(()=>_busyAction=false);}
  }
  Future<void> _returnLastSale()async{
    final receipt=_lastReceipt,branch=_branch,warehouse=_warehouse,shift=_shift;
    if(receipt==null||receipt['returnId']!=null||branch==null||warehouse==null||shift==null||_busyAction)return;
    final method=await showDialog<String>(context:context,builder:(ctx)=>AlertDialog(
      title:const Text('Hoàn trả toàn bộ giao dịch'),
      content:Text('Hoàn hàng về kho và hoàn '+erpVndText(receipt['total'])+
        '. Chọn cách thực trả tiền; mọi bút toán được ghi riêng.'),
      actions:[
        TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('Hủy')),
        TextButton(onPressed:()=>Navigator.pop(ctx,'CASH'),child:const Text('Hoàn tiền mặt')),
        TextButton(onPressed:()=>Navigator.pop(ctx,'BANK_TRANSFER'),child:const Text('Hoàn chuyển khoản')),
      ]));
    if(method==null)return;
    setState(()=>_busyAction=true);
    try{
      final result=await widget.client.posReturn(widget.session.token,{
        'branchId':branch,'warehouseId':warehouse,'shiftId':shift['id'],
        'checkoutId':receipt['id'],'refundMethod':method,
      },key:'pos-return-'+_nonce());
      if(mounted){setState(()=>_lastReceipt=null);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(
          'Đã hoàn hàng và ghi nhận hoàn '+erpVndText(result['amount']))));
        await _loadPosState(_generation);
      }
    }on ErpApiError catch(e){if(mounted)setState(()=>_posError=e.message);}
    catch(_){if(mounted)setState(()=>_posError='Chưa xác minh hoàn hàng. Cần đối chiếu giao dịch trước khi thử lại.');}
    finally{if(mounted)setState(()=>_busyAction=false);}
  }

  Future<void> _chooseWalkIn()async{
     final branch=_branch,actor=widget.session.actorId;
     if(branch==null||_loading||!_hasSalesGrant||_preparingWalkIn)return;
     if(_canonicalWalkIn!=null){
       setState((){++_customerChoiceVersion;_walkIn=_canonicalWalkIn;});
       unawaited(_quote());
       return;
     }
     final generation=_generation,choiceVersion=_customerChoiceVersion;
     const kind='sales.walk-in.prepare';
     final pending=widget.client.pendingR1(actor,branch,kind);
     final key=pending?.key??'pos-walk-in-'+_nonce();
     if(pending==null){
       widget.client.retainR1(actor,branch,kind,{'branchId':branch},key);
     }
     setState((){_preparingWalkIn=true;_posError=null;});
     try{
       final customer=await widget.client.prepareSalesWalkIn(widget.session.token,branch,key:key);
       if(!mounted||generation!=_generation||_branch!=branch||
          widget.session.actorId!=actor)return;
       final customerId=customer['id'];
       if(customerId is! String||customerId.isEmpty)throw const FormatException('WALK_IN_ID');
       widget.client.clearR1(actor,branch,kind);
       setState((){
         _canonicalWalkIn=customerId;
         if(!_customers.any((x)=>x['id']==customerId))_customers.insert(0,customer);
         // A later explicit customer choice always wins over the HTTP response.
         if(choiceVersion==_customerChoiceVersion)_walkIn=customerId;
       });
       if(choiceVersion==_customerChoiceVersion)unawaited(_quote());
     }on ErpApiError catch(e){
       if(e.status==400||e.status==404||e.status==409)
         widget.client.clearR1(actor,branch,kind);
       if(mounted&&generation==_generation)setState(()=>_posError=e.message);
     }catch(_){
       if(mounted&&generation==_generation)setState(()=>
         _posError='Chưa xác minh được khách lẻ. Bấm lại để kiểm tra cùng yêu cầu.');
     }finally{
       if(mounted&&generation==_generation)setState(()=>_preparingWalkIn=false);
     }
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
  void _editCart(Map<String,dynamic> sku,{int delta=1,bool refocus=true}){
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
    if(refocus){_search.clear();_onSearch('');_searchFocus.requestFocus();}
  }
  void _remove(int i){
    setState(()=>_lines.removeAt(i));
    _queueSave();unawaited(_quote());
  }
  void _onSearch(String query){
    _debounce?.cancel();
    final term=query.trim();
    ++_searchVersion;
    setState((){_matches=[];_searching=term.isNotEmpty;});
    if(term.isEmpty)return;
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
    final keyboardOpen=MediaQuery.viewInsetsOf(context).bottom>0;
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

        if(!keyboardOpen)Padding(padding:const EdgeInsets.only(top:5),child:Wrap(
          crossAxisAlignment:WrapCrossAlignment.center,spacing:8,runSpacing:4,children:[
            Text(_shift==null?'Chưa mở ca':('Đang bán · '+(_shift?['counterName']?.toString()??'Quầy')),
              style:TextStyle(fontSize:12,color:palette.muted)),
            if(_shift==null)TextButton.icon(
              key:const ValueKey('pos-open-shift'),onPressed:_busyAction?null:_openShift,
              icon:const Icon(Icons.play_circle_outline),label:const Text('Mở ca bán')),
            if(_shift!=null)TextButton.icon(
              key:const ValueKey('pos-close-shift'),
              onPressed:_busyAction||_pendingCheckout!=null?null:_closeShift,
              icon:const Icon(Icons.stop_circle_outlined),label:const Text('Đóng ca')),
            TextButton.icon(key:const ValueKey('pos-history'),
              onPressed:_busyAction?null:_showHistory,
              icon:const Icon(Icons.history),label:const Text('Lịch sử quầy')),
            if(_lastReceipt!=null)TextButton.icon(
              key:const ValueKey('pos-last-receipt'),
              onPressed:()=>_showReceipt(_lastReceipt!),icon:const Icon(Icons.receipt_long_outlined),
              label:const Text('Phiếu vừa bán')),
            if(_lastReceipt!=null&&_lastReceipt!['returnId']==null&&_shift!=null)TextButton(
              key:const ValueKey('pos-return-last'),
              onPressed:_busyAction?null:_returnLastSale,
              child:const Text('Hoàn hàng')),
          ])),
        if(_posError!=null)Text(_posError!,style:TextStyle(color:palette.danger,fontSize:12)),
        if(_configOpen)Padding(padding:const EdgeInsets.only(top:8),child:Column(children:[
          _selector('Chi nhánh',_branch,_branches,(value)=>unawaited(_loadBranch(value))),
          const SizedBox(height:6),
          _selector('Kho bán',_warehouse,_warehouses,(value)=>unawaited(_setWarehouse(value))),
          const SizedBox(height:6),
          _selector('Bảng giá',_priceList,_priceLists,_changePriceList),
          const SizedBox(height:6),
          _selector('Khách hàng',_walkIn,_customers,(id){
            setState((){++_customerChoiceVersion;_walkIn=id;});unawaited(_quote());
          }),
        ])),
        const SizedBox(height:8),
        Padding(padding:const EdgeInsets.only(top:4),child:Wrap(spacing:8,runSpacing:4,crossAxisAlignment:WrapCrossAlignment.center,children:[
           TextButton.icon(key:const ValueKey('pos-walk-in-quick'),
             onPressed:_branch==null||_loading||_preparingWalkIn||!_hasSalesGrant
               ?null:()=>unawaited(_chooseWalkIn()),
             icon:const Icon(Icons.person_outline,size:18),
             label:Text(_preparingWalkIn?'Đang chuẩn bị…':'Khách lẻ')),
           if(_canonicalWalkIn!=null&&_walkIn==_canonicalWalkIn)
             Text('Đang chọn khách lẻ',style:TextStyle(color:palette.muted,fontSize:12)),
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
        if(_matches.isNotEmpty)ConstrainedBox(constraints:BoxConstraints(maxHeight:keyboardOpen?140:190),
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
                      onPressed:line.quantity=='1'?null:()=>_editCart(line.sku,delta:-1,refocus:false),
                      tooltip:'Giảm số lượng',icon:const Icon(Icons.remove_circle_outline)),
                    Text(erpNumberText(line.quantity),style:const TextStyle(fontWeight:FontWeight.w700)),
                    IconButton(key:ValueKey('pos-plus-'+i.toString()),
                      onPressed:()=>_editCart(line.sku,refocus:false),tooltip:'Tăng số lượng',
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
        if(!keyboardOpen)Divider(color:palette.border),
        if(!keyboardOpen)Row(children:[
          Text('Tạm tính',style:TextStyle(fontWeight:FontWeight.w700,color:palette.ink)),
          const SizedBox(width:8),
          Expanded(child:Text(erpVndText(_total),key:const ValueKey('pos-grand-total'),
            textAlign:TextAlign.end,maxLines:1,overflow:TextOverflow.ellipsis,
            style:TextStyle(fontSize:20,fontWeight:FontWeight.w800,color:palette.primary))),
        ]),
        if(keyboardOpen)Align(alignment:Alignment.centerRight,
          child:Text('Tạm tính: '+erpVndText(_total),
            style:TextStyle(fontWeight:FontWeight.w700,color:palette.primary))),
        if(!keyboardOpen)const SizedBox(height:6),
        if(_busyAction)const LinearProgressIndicator(),
        if(!keyboardOpen&&_pendingCheckout!=null)FilledButton.icon(
          key:const ValueKey('pos-reconcile'),
          onPressed:_busyAction?null:_resolvePendingCheckout,
          icon:const Icon(Icons.sync),
          label:const Text('Kiểm tra giao dịch chưa có xác nhận')),
        if(!keyboardOpen&&_pendingCheckout!=null)OutlinedButton.icon(
          key:const ValueKey('pos-cancel-intent'),
          onPressed:_busyAction?null:_cancelPendingCheckout,
          icon:const Icon(Icons.cancel_outlined),
          label:const Text('Hủy lệnh sau đối soát để sửa giỏ')),
        if(!keyboardOpen&&_pendingCheckout==null)FilledButton.icon(key:const ValueKey('pos-checkout-disabled'),
          onPressed:_canSettle?_checkoutDialog:null,icon:const Icon(Icons.point_of_sale),
          label:Text(_shift==null?'Mở ca trước khi thanh toán':
            _canSettle?'Thanh toán và hoàn tất bán':'Chọn hàng và xác minh giá để thanh toán')),
        if(!keyboardOpen)const SizedBox(height:3),
        if(!keyboardOpen)Text(_pendingCheckout!=null
          ?'Không tạo giao dịch mới khi chưa đối soát kết quả máy chủ.'
          :'Chỉ xác nhận đã bán khi máy chủ ghi nhận đủ xuất kho và thanh toán.',
          key:const ValueKey('pos-no-fake-settlement'),
          textAlign:TextAlign.center,style:TextStyle(fontSize:11,color:palette.muted)),
      ]),
    ));
  }

  Widget _selector(String label,String? value,List<Map<String,dynamic>> rows,
      void Function(String) onChanged)=>DropdownButtonFormField<String>(
    key:ValueKey('pos-select-'+label+'-'+(value??'')),initialValue:rows.any((x)=>x['id']==value)?value:null,
    isExpanded:true,decoration:InputDecoration(labelText:label,isDense:true,
      border:const OutlineInputBorder()),
    items:rows.map((x)=>DropdownMenuItem<String>(value:x['id'] as String,
      child:Text(x['name']?.toString()??x['code']?.toString()??'—',
        maxLines:1,overflow:TextOverflow.ellipsis))).toList(),
    onChanged:(value){if(value!=null)onChanged(value);},
  );
}
