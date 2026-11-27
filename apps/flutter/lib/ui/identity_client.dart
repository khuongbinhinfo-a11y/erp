import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:crypto/crypto.dart';
import '../local/local_store.dart';

const erpApiOrigin = String.fromEnvironment('ERP_API_BASE_URL', defaultValue: '');

class ErpApiError implements Exception {
  final int status;
  final String message;
  final String? code;
  const ErpApiError(this.status,this.message,{this.code});
  @override String toString()=>message;
}
class IdentityGrant {
  final String roleId,permission;
  final String? branchId,warehouseId;
  const IdentityGrant({required this.roleId,required this.permission,this.branchId,this.warehouseId});
  factory IdentityGrant.fromJson(Map<String,dynamic> m)=>IdentityGrant(
    roleId:m['roleId'] as String? ?? '',permission:m['permission'] as String? ?? '',
    branchId:m['branchId'] as String?,warehouseId:m['warehouseId'] as String?);
}
class IdentitySession {
  final String actorId,token,loginName,installationId;
  final DateTime expiresAt;
  final List<IdentityGrant> grants;
  const IdentitySession({required this.actorId,required this.token,
    this.loginName='',this.installationId='',required this.expiresAt,required this.grants});
}
class IdentityUser {
  final String id,loginName;
  final int revision;
  final bool disabled;
  const IdentityUser({required this.id,required this.loginName,required this.revision,required this.disabled});
  factory IdentityUser.fromJson(Map<String,dynamic> m)=>IdentityUser(
    id:m['id'] as String,loginName:m['loginName'] as String,
    revision:m['revision'] as int,disabled:m['disabled'] as bool);
}
class IdentityScope {
  final String id,code,name;
  final String? branchId;
  const IdentityScope({required this.id,required this.code,required this.name,this.branchId});
  factory IdentityScope.fromJson(Map<String,dynamic> m)=>IdentityScope(
    id:m['id'] as String,code:m['code'] as String,name:m['name'] as String,
    branchId:m['branchId'] as String?);
}
class IdentityScopes {
  final List<IdentityScope> branches,warehouses;
  const IdentityScopes(this.branches,this.warehouses);
}
class ErpIdentityClient {
  final String apiOrigin;
  final http.Client _http;
  final ErpLocalStore? localStore;
  int _sequence=0;
  // One unresolved R1 command per actor/branch/resource is retained in the
  // authenticated client across workspace navigation; never store auth tokens.
  final Map<String,({Map<String,dynamic> payload,String key})> _r1Pending={};
  final Map<String,({Map<String,dynamic> body,String key,Uint8List bytes})>
    _mediaPending={};
  String _nonceUuid(){
    final rng=Random.secure();
    final b=List<int>.generate(16,(_)=>rng.nextInt(256));
    b[6]=(b[6]&15)|64;
    b[8]=(b[8]&63)|128;
    final hex=b.map((v)=>v.toRadixString(16).padLeft(2,'0')).join();
    return '${hex.substring(0,8)}-${hex.substring(8,12)}-${hex.substring(12,16)}-'
      '${hex.substring(16,20)}-${hex.substring(20)}';
  }
  String _r1PendingId(String actorId,String branchId,String kind)=>
    '$actorId|$branchId|$kind';
  ({Map<String,dynamic> payload,String key})? pendingR1(
    String actorId,String branchId,String kind){
    final p=_r1Pending[_r1PendingId(actorId,branchId,kind)];
    if(p==null)return null;
    return (payload:Map<String,dynamic>.from(p.payload),key:p.key);
  }
  void retainR1(String actorId,String branchId,String kind,
    Map<String,dynamic> payload,String key){
    _r1Pending[_r1PendingId(actorId,branchId,kind)]=
      (payload:Map<String,dynamic>.from(payload),key:key);
  }
  void clearR1(String actorId,String branchId,String kind){
    _r1Pending.remove(_r1PendingId(actorId,branchId,kind));
  }
  ErpIdentityClient({this.apiOrigin=erpApiOrigin,http.Client? httpClient,this.localStore}):_http=httpClient??http.Client();
  bool get configured=>Uri.tryParse(apiOrigin)?.scheme=='https'&&
    Uri.tryParse(apiOrigin)?.host.isNotEmpty==true;
  void dispose(){_r1Pending.clear();_mediaPending.clear();_inventoryPending.clear();_purchasePending.clear();_transferPending.clear();_stocktakePending.clear();_http.close();}
  String _key()=>'erp-'+DateTime.now().microsecondsSinceEpoch.toString()+'-${++_sequence}';
  Future<Map<String,dynamic>> _request(String method,String path,{
    String? token,Map<String,dynamic>? body,int? revision,String? idempotencyKey,
  })async{
    if(!configured)throw const ErpApiError(503,'Không kết nối được hệ thống.');
    final origin=Uri.parse(apiOrigin);
    final url=origin.resolve(path);
    if(url.scheme!='https'||url.origin!=origin.origin)throw const ErpApiError(400,'Không thể mở kết nối.');
    final headers=<String,String>{'accept':'application/json'};
    if(token!=null)headers['authorization']='Bearer $token';
    if(body!=null)headers['content-type']='application/json';
    if(revision!=null){headers['if-match']='$revision';headers['idempotency-key']=idempotencyKey??_key();}
    try{
      final req=http.Request(method,url)..headers.addAll(headers);
      if(body!=null)req.body=jsonEncode(body);
      final timeout=path.startsWith('/v1/catalog/bulk/')
        ?const Duration(seconds:150):
        path.endsWith('/media/complete')?const Duration(seconds:30):
        path=='/v1/auth/login'?const Duration(seconds:18):const Duration(seconds:10);
      final response=await http.Response.fromStream(await _http.send(req).timeout(timeout));
      dynamic decoded;
      try{
        decoded=jsonDecode(response.body);
      }on FormatException{
        throw const ErpApiError(502,
          'Dữ liệu nhận được không hợp lệ. Vui lòng thử lại.');
      }
      if(decoded is! Map<String,dynamic>)throw const ErpApiError(502,'Phản hồi API không hợp lệ.');
      if(response.statusCode>=400){
        final message=switch(response.statusCode){
          401=>'Sai tài khoản/mật khẩu hoặc phiên đã hết hạn.',
          403=>'Không có quyền sử dụng chức năng này.',
          409=>'Dữ liệu thay đổi hoặc thao tác bị trùng. Hãy tải lại.',
          429=>'Đăng nhập bị giới hạn. Vui lòng thử lại sau.',
          503=>path.startsWith('/v1/auth/')
            ? 'Đăng nhập đang tạm gián đoạn. Vui lòng thử lại.'
            : 'Hệ thống đang tạm gián đoạn. Vui lòng thử lại.',
          501=>'Chức năng này chưa thể sử dụng.',
          _=>'Yêu cầu không được chấp nhận.',
        };
        final fault=decoded['error'];
        final code=fault is Map<String,dynamic> && fault['code'] is String
          ? fault['code'] as String : null;
        throw ErpApiError(response.statusCode,message,code:code);
      }
      return decoded;
    }on ErpApiError{rethrow;}
    on TimeoutException{
      throw const ErpApiError(504,
        'Kết nối đang chậm. Vui lòng thử lại.');
    }
    catch(_){
      if(path=='/v1/auth/login'){
        try{
          final probe=await _http.get(origin.resolve('/v1/auth/config'))
            .timeout(const Duration(seconds:4));
          if(probe.statusCode==200){
            throw const ErpApiError(424,
              'Chưa thể đăng nhập. Vui lòng thử lại.');
          }
        }on ErpApiError{rethrow;}
        catch(_){/* probe unavailable; preserve the transport error */ }
      }
      // On Flutter Web, a legacy Compute endpoint without catalog OPTIONS/CORS
      // surfaces as a network error. Probe the already-public auth contract
      // before blaming the user's network. This never reads credentials or data.
      if(path.startsWith('/v1/catalog/')){
        try{
          final probe=await _http.get(origin.resolve('/v1/auth/config'))
            .timeout(const Duration(seconds:4));
          if(probe.statusCode==200||probe.statusCode==401||probe.statusCode==503){
            throw const ErpApiError(424,
              'Danh mục đang tạm gián đoạn. Vui lòng thử lại.');
          }
        }on ErpApiError{rethrow;}
        catch(_){/* public probe unavailable; report network failure */ }
      }
      throw const ErpApiError(0,'Mất kết nối. Vui lòng thử lại.');
    }
  }
  Future<IdentitySession> login(String username,String password)async{
    // Reauthentication must not discard a stock command whose COMMIT has no ACK.
    final raw=await _request('POST','/v1/auth/login',body:{'loginName':username,'password':password});
    final token=raw['token'] as String;
    try{
      final r=await _request('GET','/v1/auth/session',token:token);
      final actor=r['actorId'] as String;
      // An account switch cannot access another actor's pending operation.
      _inventoryPending.removeWhere((scope,_)=>!scope.startsWith('$actor:'));
    _purchasePending.removeWhere((scope,_)=>!scope.startsWith('$actor:'));
      _transferPending.removeWhere((scope,_)=>!scope.startsWith('$actor:'));
      _stocktakePending.removeWhere((scope,_)=>!scope.startsWith('$actor:'));
      // A lost customer or pricing ACK can survive session expiry. A fresh
      // login of the SAME actor may replay the exact idempotency key/body.
      // Never carry another account's pending catalog data across a switch.
      _r1Pending.removeWhere((scope,_)=>!scope.startsWith('$actor|'));
      return IdentitySession(actorId:actor,token:token,installationId:r['installationId'] as String? ?? '',
        loginName:r['loginName'] as String? ?? username,
        expiresAt:DateTime.parse(r['expiresAt'] as String? ?? raw['expiresAt'] as String),
        grants:(r['grants'] as List<dynamic>).map((v)=>IdentityGrant.fromJson(v as Map<String,dynamic>)).toList());
    }catch(_){
      // Failed session setup must not erase old actor's unacknowledged command.
      try{await _request('POST','/v1/auth/logout',token:token);}catch(_){}
      rethrow;
    }
  }
  Future<IdentitySession> restore(String token)async{
    final r=await _request('GET','/v1/auth/session',token:token);
    return IdentitySession(actorId:r['actorId'] as String,token:token,installationId:r['installationId'] as String? ?? '',
      loginName:r['loginName'] as String? ?? '',
      expiresAt:DateTime.parse(r['expiresAt'] as String),
      grants:(r['grants'] as List<dynamic>).map((v)=>
        IdentityGrant.fromJson(v as Map<String,dynamic>)).toList());
  }
  Future<IdentitySession> refresh(IdentitySession current)=>restore(current.token);
  Future<void> logout(String token)async{
    try{await _request('POST','/v1/auth/logout',token:token);}
    finally{_r1Pending.clear();_inventoryPending.clear();_purchasePending.clear();_transferPending.clear();_stocktakePending.clear();}
  }
  Future<List<IdentityUser>> users(String token)async{
    final r=await _request('GET','/v1/admin/users',token:token);
    return (r['users'] as List<dynamic>).map((v)=>IdentityUser.fromJson(v as Map<String,dynamic>)).toList();
  }
  Future<IdentityScopes> scopes(String token)async{
    final branches=<IdentityScope>[],warehouses=<IdentityScope>[];
    List<IdentityScope> parse(dynamic v)=>(v as List<dynamic>).map((x)=>
      IdentityScope.fromJson(x as Map<String,dynamic>)).toList();
    // A valid grant beyond the first page must never be labeled nonexistent.
    for(var offset=0;offset<=100000;offset+=100){
      final path=offset==0?'/v1/admin/scopes':
        '/v1/admin/scopes?offset=$offset';
      final r=await _request('GET',path,token:token);
      branches.addAll(parse(r['branches']));
      warehouses.addAll(parse(r['warehouses']));
      if(r['hasMoreBranches']!=true&&r['hasMoreWarehouses']!=true){
        return IdentityScopes(branches,warehouses);
      }
    }
    throw const ErpApiError(503,
      'Có quá nhiều chi nhánh hoặc kho; không thể kiểm tra đầy đủ tên phạm vi.');
  }
  Future<List<IdentityGrant>> grants(String token,String userId)async{
    final r=await _request('GET','/v1/admin/users/$userId/grants',token:token);
    return (r['grants'] as List<dynamic>).map((v)=>IdentityGrant.fromJson(v as Map<String,dynamic>)).toList();
  }
  LocalScope? localScope(IdentitySession session,String branch,{String warehouse=''}) {
    if(localStore==null||!configured||session.installationId.isEmpty||
      !session.expiresAt.isAfter(DateTime.now()))return null;
    if(branch!='*'&&!session.grants.any((g)=>g.branchId==branch))return null;
    if(warehouse.isNotEmpty&&!session.grants.any((g)=>g.branchId==branch&&g.warehouseId==warehouse))return null;
    return LocalScope(origin:Uri.parse(apiOrigin).origin,installation:session.installationId,
      actor:session.actorId,branch:branch,warehouse:warehouse);
  }
  String _grantStamp(IdentitySession session){
    final grants=session.grants.map((g)=>jsonEncode([g.roleId,g.permission,g.branchId,g.warehouseId])).toList()..sort();
    return sha256.convert(utf8.encode(jsonEncode(grants))).toString();
  }
  /// Only the order editor may use cached catalog snapshots. Never use them
  /// as a current price quote or authorization to submit a document.
  Future<({List<Map<String,dynamic>> items,bool cached})> salesCatalog(IdentitySession session,String resource,{
    String? branchId,String query='',String? itemId})async{
    final scope=localScope(session,branchId??'*');
    final key=jsonEncode([_grantStamp(session),resource,query.trim(),itemId]);
    try{
      final items=await catalogItems(session.token,resource,branchId:branchId,query:query,itemId:itemId);
      if(scope!=null){
        try{await localStore!.saveCache(scope,key,items,fetchedAt:DateTime.now(),ttl:const Duration(hours:12));}catch(_){}
      }
      return (items:items,cached:false);
    }on ErpApiError catch(e){
      if(scope==null||!{0,503,504}.contains(e.status))rethrow;
      try{
        final entry=await localStore!.cache(scope,key,now:DateTime.now());
        if(entry!=null&&!entry.stale&&entry.value is List){
          return (items:(entry.value as List).map((x)=>Map<String,dynamic>.from(x as Map)).toList(),cached:true);
        }
      }catch(_){}
      rethrow;
    }
  }
  Future<({List<Map<String,dynamic>> items,bool cached})> localProductVariants(IdentitySession session,String branch,String product)async{
    final scope=localScope(session,branch),key=jsonEncode(['variants',_grantStamp(session),product]);
    try{
      final items=await catalogProductSkusAll(session.token,branchId:branch,productId:product);
      if(scope!=null){try{await localStore!.saveCache(scope,key,items,fetchedAt:DateTime.now(),ttl:const Duration(hours:12));}catch(_){}}
      return (items:items,cached:false);
    }on ErpApiError catch(e){
      if(scope==null||!{0,503,504}.contains(e.status))rethrow;
      try{
        final value=await localStore!.cache(scope,key,now:DateTime.now());
        if(value!=null&&!value.stale&&value.value is List){
          return (items:(value.value as List).map((x)=>Map<String,dynamic>.from(x as Map)).toList(),cached:true);
        }
      }catch(_){}
      rethrow;
    }
  }
  Future<({List<Map<String,dynamic>> items,bool hasMore,bool cached})> localStockPage(IdentitySession session,String branch,String warehouse,int offset)async{
    final scope=localScope(session,branch,warehouse:warehouse),key=jsonEncode(['stock',_grantStamp(session),offset]);
    try{
      final page=await inventoryPage(session.token,'balances',branchId:branch,warehouseId:warehouse,offset:offset);
      if(scope!=null){try{await localStore!.saveCache(scope,key,{'items':page.items,'hasMore':page.hasMore},fetchedAt:DateTime.now(),ttl:const Duration(minutes:30));}catch(_){}}
      return (items:page.items,hasMore:page.hasMore,cached:false);
    }on ErpApiError catch(e){
      if(scope==null||!{0,503,504}.contains(e.status))rethrow;
      try{
        final value=await localStore!.cache(scope,key,now:DateTime.now());
        if(value!=null&&!value.stale&&value.value is Map){
          final data=value.value as Map;
          return (items:(data['items'] as List).map((x)=>Map<String,dynamic>.from(x as Map)).toList(),hasMore:data['hasMore']==true,cached:true);
        }
      }catch(_){}
      rethrow;
    }
  }
  Future<({Map<String,dynamic> settings,bool cached})> localSalesEntrySettings(IdentitySession session,String branch)async{
    final scope=localScope(session,branch);
    final key='sales-settings-'+_grantStamp(session);
    try{
      final settings=await salesEntrySettings(session.token,branch);
      if(scope!=null){
        try{await localStore!.saveCache(scope,key,settings,fetchedAt:DateTime.now(),ttl:const Duration(hours:12));}catch(_){}
      }
      return (settings:settings,cached:false);
    }on ErpApiError catch(e){
      if(scope==null||!{0,503,504}.contains(e.status))rethrow;
      try{
        final entry=await localStore!.cache(scope,key,now:DateTime.now());
        if(entry!=null&&!entry.stale&&entry.value is Map){
          return (settings:Map<String,dynamic>.from(entry.value as Map),cached:true);
        }
      }catch(_){}
      rethrow;
    }
  }
  /// Catalog calls always use the authenticated installation and server-side RBAC.
  Future<List<Map<String,dynamic>>> catalogItems(String token,String resource,{
    String? branchId,String query='',String? itemId,
  })async{
    final params=<String,String>{};
    if(branchId!=null)params['branchId']=branchId;
    if(query.trim().isNotEmpty)params['q']=query.trim();
    if(itemId!=null)params[resource=='r1/skus'?'sellSkuId':'id']=itemId;
    final suffix=params.isEmpty?'':'?${Uri(queryParameters:params).query}';
    final raw=await _request('GET','/v1/catalog/$resource$suffix',token:token);
    return (raw['items'] as List<dynamic>)
      .map((v)=>Map<String,dynamic>.from(v as Map)).toList();
  }
  /// Every selling unit for the exact product, scoped by branch on the server
  /// before pagination. A global SKU page is not safe for changing order UOM.
  Future<List<Map<String,dynamic>>> catalogProductSkusAll(
      String token,{required String branchId,required String productId})=>
    catalogProductDetailsAll(token,'skus',branchId:branchId,productId:productId);

  /// Product-scoped reads for the shared editor. The API filters before LIMIT.
  Future<List<Map<String,dynamic>>> catalogProductDetailsAll(
      String token,String kind,{required String branchId,required String productId})async{
    if(!const {'units','skus','barcodes'}.contains(kind)){
      throw ArgumentError.value(kind,'kind');
    }
    final collected=<Map<String,dynamic>>[];
    final seen=<String>{};
    final seenRows=<String>{};
    final cursorField=kind=='units'?'unitCode':'id';
    String? after;
    while(true){
      final suffix=Uri(queryParameters:{
        'branchId':branchId,'productId':productId,
        if(after!=null)'after':after,
      }).query;
      final raw=await _request('GET','/v1/catalog/r1/$kind?$suffix',token:token);
      final items=(raw['items'] as List<dynamic>)
        .map((v)=>Map<String,dynamic>.from(v as Map)).toList();
      for(final sku in items){
        if(sku['productId']!=productId){
          throw const ErpApiError(502,'Máy chủ trả về SKU sai sản phẩm.');
        }
        final rowKey=sku[cursorField];
        if(rowKey is! String||rowKey.isEmpty||!seenRows.add(rowKey)){
          throw const ErpApiError(502,'Máy chủ trả về dữ liệu danh mục bị lặp.');
        }
        collected.add(sku);
      }
      final next=raw['nextAfter'];
      if(next is! String||next.isEmpty)break;
      if(items.isEmpty||items.last[cursorField]!=next||!seen.add(next)){
        throw const ErpApiError(502,'Trang SKU bị lặp hoặc sai thứ tự.');
      }
      after=next;
    }
    return collected;
  }
  /// Load the whole UOM dictionary by branch-scoped keyset pages. A single
  /// catalogItems() request intentionally returns at most 100 records.
  Future<List<Map<String,dynamic>>> catalogUnitDefinitionsAll(
      String token,{required String branchId,String query=''})async{
    final collected=<Map<String,dynamic>>[];
    final seen=<String>{};
    String? after;
    while(true){
      final suffix=Uri(queryParameters:{
        'branchId':branchId,
        if(query.trim().isNotEmpty)'q':query.trim(),
        if(after!=null)'after':after,
      }).query;
      final raw=await _request('GET',
        '/v1/catalog/unit-definitions?$suffix',token:token);
      final items=(raw['items'] as List<dynamic>)
        .map((x)=>Map<String,dynamic>.from(x as Map)).toList();
      collected.addAll(items);
      final next=raw['nextAfter'];
      if(next is! String||next.isEmpty)break;
      if(!seen.add(next)){
        throw const ErpApiError(502,'Máy chủ trả về trang đơn vị tính lặp.');
      }
      after=next;
    }
    return collected;
  }
  /// Master directories use code-based keyset paging; no first-100 truncation
  /// in customer group / sales region pickers. Codes are never free-form input.
  Future<List<Map<String,dynamic>>> catalogDirectoryAll(
      String token,String resource,{required String branchId,String query=''})async{
    if(!['customer-groups','customer-regions','brands','groups','categories'].contains(resource))
      throw ArgumentError.value(resource,'resource','Danh mục không hỗ trợ');
    final found=<Map<String,dynamic>>[];
    final seen=<String>{};
    String? after;
    while(true){
      final suffix=Uri(queryParameters:{
        'branchId':branchId,
        if(query.trim().isNotEmpty)'q':query.trim(),
        if(after!=null)'after':after,
      }).query;
      final raw=await _request('GET','/v1/catalog/$resource?$suffix',token:token);
      final values=(raw['items'] as List<dynamic>)
        .map((v)=>Map<String,dynamic>.from(v as Map)).toList();
      found.addAll(values);
      final next=raw['nextAfter'];
      if(next is! String||next.isEmpty)break;
      if(!seen.add(next))throw const ErpApiError(502,
        'Danh mục trả về trang bị lặp. Vui lòng tải lại.');
      after=next;
    }
    return found;
  }
  /// R1-B: server parses CSV/XLSX and resolves codes before any write.
  Future<Map<String,dynamic>> bulkInspect(
      String token,Map<String,dynamic> payload)=>
    _request('POST','/v1/catalog/bulk/inspect',token:token,body:payload);

  Future<Map<String,dynamic>> bulkPreview(
      String token,Map<String,dynamic> payload)=>
    _request('POST','/v1/catalog/bulk/preview',token:token,body:payload);

  /// Same key+body after timeout: server replays committed receipt.
  Future<Map<String,dynamic>> bulkApply(
      String token,Map<String,dynamic> payload,{required String key})=>
    _request('POST','/v1/catalog/bulk/apply',token:token,
      body:payload,revision:0,idempotencyKey:key);

  Future<Map<String,dynamic>?> salesLastPurchasePrice(String token,{
    required String branchId,required String customerId,required String sellSkuId,
  })async{
    final query=Uri(queryParameters:{
      'branchId':branchId,'customerId':customerId,'sellSkuId':sellSkuId,
    }).query;
    final response=await _request('GET','/v1/sales/last-purchase?$query',token:token);
    final price=response['price'];
    return price is Map?Map<String,dynamic>.from(price):null;
  }
  Future<Map<String,dynamic>> bulkCsvFile(
      String token,String resource,String branchId,{bool template=false,String format='csv',String? priceListId})async{
    final query=Uri(queryParameters:{'resource':resource,'branchId':branchId,
      if(priceListId!=null)'priceListId':priceListId,
      if(format!='csv')'format':format}).query;
    return _request('GET',
      '/v1/catalog/bulk/${template?'template':'export'}?$query',token:token);
  }

  /// Product write readiness is explicit: catalog 0006/0007 can still be
  /// viewed, but SKU/barcode creation requires the separately migrated R1 schema.
  Future<({List<Map<String,dynamic>> items,bool writeReady})> catalogProducts(
      String token,{required String branchId,String query=''})async{
    final suffix=Uri(queryParameters:{
      'branchId':branchId,if(query.trim().isNotEmpty)'q':query.trim(),
    }).query;
    final raw=await _request('GET','/v1/catalog/products?$suffix',token:token);
    return (
      items:(raw['items'] as List<dynamic>).map((v)=>
        Map<String,dynamic>.from(v as Map)).toList(),
      writeReady:raw['r1ProductReady']==true,
    );
  }
  /// Private R2 media: upload bytes go only to a short-lived signed URL.
  /// Keep the same upload nonce, body and idempotency key after a lost ACK.
  Future<Map<String,dynamic>> uploadProductPhoto(
    String token,String actorId,String branchId,String productId,
    Uint8List bytes,String contentType)async{
    if(bytes.isEmpty||bytes.length>5*1024*1024||
      !['image/png','image/jpeg','image/webp'].contains(contentType)){
      throw const ErpApiError(400,'Ảnh phải là PNG, JPG hoặc WebP, tối đa 5 MB.');
    }
    final scope='$actorId|$branchId|$productId';
    final previous=_mediaPending[scope];
    if(previous!=null){
      final original=previous.bytes;
      var identicalBytes=original.length==bytes.length&&
        previous.body['contentType']==contentType;
      if(identicalBytes){
        for(var i=0;i<bytes.length;i++){
          if(bytes[i]!=original[i]){identicalBytes=false;break;}
        }
      }
      if(!identicalBytes)throw const ErpApiError(409,
        'Ảnh trước chưa có xác nhận server. Hãy chọn lại đúng ảnh đó để kiểm tra.');
    }
    final body=previous?.body??<String,dynamic>{
      'branchId':branchId,'uploadNonce':_nonceUuid(),
      'contentType':contentType,'byteLength':bytes.length,
    };
    final key=previous?.key??_key();
    _mediaPending[scope]=(body:body,key:key,bytes:bytes);
    final prefix='/v1/catalog/products/$productId/media';
    final prepare=await _request('POST','$prefix/prepare',token:token,body:body);
    final url=Uri.tryParse(prepare['putUrl']?.toString()??'');
    if(url==null||url.scheme!='https'||
      !url.host.endsWith('.r2.cloudflarestorage.com'))
      throw const ErpApiError(502,'Địa chỉ lưu ảnh không hợp lệ.');
    try{
      final put=await _http.put(url,
        // Signed If-None-Match prevents any client from overwriting a
        // committed image while its 5-minute PUT URL remains valid.
        headers:{'content-type':contentType,'if-none-match':'*'},body:bytes)
        .timeout(const Duration(seconds:35));
      if(put.statusCode!=412&&
        (put.statusCode<200||put.statusCode>=300)){
        throw const ErpApiError(503,'Chưa tải được ảnh lên kho lưu trữ.');
      }
      // 412 means this immutable key already exists (e.g. lost ACK).
      // Server-side HEAD + magic/length validation will reconcile it.

    }on ErpApiError{rethrow;}
    catch(_){
      throw const ErpApiError(504,
        'Chưa xác minh tải ảnh. Chọn lại ảnh này để thử đúng yêu cầu cũ.');
    }
    try{
      final receipt=await _request('POST','$prefix/complete',
        token:token,body:body,revision:0,idempotencyKey:key);
      _mediaPending.remove(scope);
      return receipt;
    }on ErpApiError catch(e){
      // Definitively rejected bytes cannot be replayed successfully. Keep
      // ambiguous 503/504 and lost ACK commands with their original key.
      if(e.status==400||e.status==413||e.status==415||
         e.code=='IMAGE_UPLOAD_MISMATCH'||
         e.code=='MAX_PRODUCT_IMAGES'||e.code=='PRODUCT_NOT_FOUND'){
        _mediaPending.remove(scope);
      }
      rethrow;
    }
  }
  Future<List<Map<String,dynamic>>> productPhotos(
    String token,String branchId,String productId)async{
    final query=Uri(queryParameters:{'branchId':branchId}).query;
    final result=await _request('GET',
      '/v1/catalog/products/$productId/media?$query',token:token);
    return (result['items'] as List<dynamic>).map(
      (x)=>Map<String,dynamic>.from(x as Map)).toList();
  }

  Future<Map<String,dynamic>> createCatalog(String token,String resource,
    Map<String,dynamic> fields)async{
    return _request('POST','/v1/catalog/$resource',token:token,revision:0,body:fields);
  }
  /// Reuse the exact body/key when a quick-create acknowledgment is lost.
  Future<Map<String,dynamic>> createCatalogWithKey(String token,String resource,
    Map<String,dynamic> fields,{required String key})=>
      _request('POST','/v1/catalog/$resource',token:token,
        body:fields,revision:0,idempotencyKey:key);
  Future<List<Map<String,dynamic>>> r1CatalogItems(String token,String kind,{
      required String branchId,String query='',String? brandId,String? groupId,String? categoryId})async{
    final q=Uri(queryParameters:{'branchId':branchId,
      if(query.trim().isNotEmpty)'q':query.trim(),
      if(brandId!=null)'brandId':brandId,
      if(groupId!=null)'groupId':groupId,
      if(categoryId!=null)'categoryId':categoryId}).query;
    final raw=await _request('GET','/v1/catalog/r1/$kind?$q',token:token);
    return (raw['items'] as List<dynamic>).map(
      (x)=>Map<String,dynamic>.from(x as Map)).toList();
  }
  /// R1 writes retain the same key and body after a lost server acknowledgment.
  Future<Map<String,dynamic>> createR1Catalog(String token,String kind,
    Map<String,dynamic> fields,{required String key})=>
      _request('POST','/v1/catalog/r1/$kind',token:token,body:fields,
        revision:0,idempotencyKey:key);
  /// Append an immutable retirement event; same key/body replays a lost ACK.
  Future<Map<String,dynamic>> retireR1PriceRule(String token,String ruleId,
    Map<String,dynamic> fields,{required String key})=>
      _request('POST','/v1/catalog/r1/rules/$ruleId/retire',token:token,
        body:fields,revision:0,idempotencyKey:key);
  /// Correct lifecycle fields only; SKU/barcode identity and UOM factors
  /// are immutable. Optimistic revision + idempotency are server validated.
  Future<Map<String,dynamic>> updateR1Catalog(
      String token,String kind,String id,int revision,Map<String,dynamic> fields)=>
    _request('PATCH','/v1/catalog/r1/$kind/$id',token:token,
      body:fields,revision:revision);
  /// Price simulation is read-only; it never changes order, stock or money ledger.
  Future<Map<String,dynamic>> r1PriceQuote(String token,
    Map<String,dynamic> context)=>_request(
      'POST','/v1/catalog/r1/resolve',token:token,body:context);
  /// Snapshot-copy a price list together with its current/future rules.
  /// Keep the same key and body when a COMMIT acknowledgment is lost.
  Future<Map<String,dynamic>> clonePriceList(
      String token,String sourceId,Map<String,dynamic> payload,{
        required String key,
      })=>_request('POST','/v1/catalog/price-lists/$sourceId/clone',
        token:token,body:payload,revision:0,idempotencyKey:key);
  /// Scoped price lists are a selection layer on the existing R1 price engine.
  Future<List<Map<String,dynamic>>> priceListAssignments(
      String token,String branchId,{required String priceListId,
      String query=''})async{
    final rows=<Map<String,dynamic>>[];
    for(var offset=0;offset<=100000;offset+=100){
      final suffix=Uri(queryParameters:{'branchId':branchId,
        'priceListId':priceListId,'offset':'$offset',
        if(query.trim().isNotEmpty)'q':query.trim()}).query;
      final raw=await _request('GET','/v1/catalog/price-lists/assignments?$suffix',
        token:token);
      rows.addAll((raw['items'] as List<dynamic>).map(
        (x)=>Map<String,dynamic>.from(x as Map)));
      if(raw['hasMore']!=true)return rows;
    }
    throw const FormatException('ASSIGNMENT_PAGE_LIMIT_EXCEEDED');
  }
  /// Retain the exact payload/key on connection loss, like all R1 commands.
  Future<Map<String,dynamic>> assignPriceList(String token,
      Map<String,dynamic> body,{required String key})=>
    _request('POST','/v1/catalog/price-lists/assignments',
      token:token,body:body,revision:0,idempotencyKey:key);
  Future<Map<String,dynamic>> togglePriceListAssignment(String token,
      String id,String branchId,int revision,bool active,{required String key})=>
    _request('PATCH','/v1/catalog/price-lists/assignments/$id',
      token:token,body:{'branchId':branchId,'active':active},
      revision:revision,idempotencyKey:key);
  /// Every delivery location belongs to one canonical customer in the same branch.
  Future<List<Map<String,dynamic>>> customerLocations(
    String token,String branchId,String customerId)async{
    final response=await _request('GET',
      '/v1/catalog/customers/$customerId/locations?branchId=${Uri.encodeQueryComponent(branchId)}',
      token:token);
    return (response['items'] as List<dynamic>).map(
      (item)=>Map<String,dynamic>.from(item as Map)).toList();
  }
  Future<Map<String,dynamic>> createCustomerLocation(
    String token,String customerId,Map<String,dynamic> body,{required String key})=>
    _request('POST','/v1/catalog/customers/$customerId/locations',
      token:token,body:body,revision:0,idempotencyKey:key);

  Future<Map<String,dynamic>> updateCustomerLocation(
    String token,String customerId,String locationId,int revision,
    Map<String,dynamic> body,{required String key})=>
    _request('PATCH','/v1/catalog/customers/$customerId/locations/$locationId',
      token:token,body:body,revision:revision,idempotencyKey:key);

  /// Optimistic catalog edit: the server checks the exact row revision inside its transaction.
  Future<Map<String,dynamic>> updateCatalog(String token,String resource,
    String id,int expectedRevision,Map<String,dynamic> fields)async{
    return _request('PATCH','/v1/catalog/$resource/$id',
      token:token,revision:expectedRevision,body:fields);
  }
  /// Batch catalog changes keep their per-item idempotency key on ambiguous retries.
  Future<Map<String,dynamic>> updateCatalogWithKey(
    String token,String resource,String id,int expectedRevision,
    Map<String,dynamic> fields,{required String key})=>
      _request('PATCH','/v1/catalog/$resource/$id',
        token:token,revision:expectedRevision,body:fields,idempotencyKey:key);

  /// Price quote is advisory, never confirms order fulfillment or inventory.
  Future<Map<String,dynamic>> catalogPriceQuote(String token,{
    required String branchId,required String priceListId,required String productId,
  })async{
    final query=Uri(queryParameters:{
      'branchId':branchId,'priceListId':priceListId,'productId':productId,
    }).query;
    return _request('GET','/v1/catalog/prices/quote?$query',token:token);
  }
  Future<Map<String,dynamic>> catalogPriceCheck(String token,{
    required String branchId,required String priceListId,
    required String productId,required String expectedPriceEntryId,
  })async{
    return _request('POST','/v1/catalog/prices/check',token:token,
      body:{'branchId':branchId,'priceListId':priceListId,
        'productId':productId,'expectedPriceEntryId':expectedPriceEntryId});
  }
  /// Read-only R1-C price for one selling SKU, customer, channel and quantity.
  /// The order quote and save must still be revalidated by the backend.
  Future<Map<String,dynamic>> salesSkuPrice(String token,{
    required String branchId,required String sellSkuId,
    required String customerId,required String priceListId,
    required String quantity,String? channelId,
  })async{
    final response=await _request('POST','/v1/catalog/r1/resolve',
      token:token,body:{
        'branchId':branchId,'sellSkuId':sellSkuId,
        'customerId':customerId,'priceListId':priceListId,
        'quantity':quantity,if(channelId!=null)'channelId':channelId,
      });
    return Map<String,dynamic>.from(response['quote'] as Map);
  }
  /// Quotes a whole sales basket in one server context, with decimal totals.
  /// This does not create an order or change inventory/receivables.
  Future<Map<String,dynamic>> salesPricePreview(String token,
    Map<String,dynamic> fields)async{
    final r=await _request('POST','/v1/sales/quote',token:token,body:fields);
    return Map<String,dynamic>.from(r['quote'] as Map);
  }
  /// Canonical POS APIs: only an ACK from server means stock issued and paid.
  Future<Map<String,dynamic>?> posCurrentShift(String token,String branch,String warehouse)async{
    final q=Uri(queryParameters:{'branchId':branch,'warehouseId':warehouse}).query;
    final response=await _request('GET','/v1/pos/shifts/current?$q',token:token);
    final shift=response['shift'];
    return shift is Map?Map<String,dynamic>.from(shift):null;
  }
  Future<Map<String,dynamic>> posOpenShift(String token,Map<String,dynamic> fields,{
    required String key,
  })=>_request('POST','/v1/pos/shifts/open',token:token,body:fields,
    revision:0,idempotencyKey:key);
  Future<Map<String,dynamic>> posCloseShift(String token,String id,Map<String,dynamic> fields,{
    required String key,
  })=>_request('POST','/v1/pos/shifts/$id/close',token:token,body:fields,
    revision:0,idempotencyKey:key);
  Future<Map<String,dynamic>> posCheckout(String token,Map<String,dynamic> fields,{
    required String key,
  })=>_request('POST','/v1/pos/checkouts',token:token,body:fields,
    revision:0,idempotencyKey:key);
  Future<Map<String,dynamic>?> posCheckoutRecovery(String token,Map<String,dynamic> fields,{
    required String key,
  })async{
    final response=await _request('POST','/v1/pos/recovery',token:token,
      body:{'checkout':fields},revision:0,idempotencyKey:key);
    final receipt=response['receipt'];
    return receipt is Map?Map<String,dynamic>.from(receipt):null;
  }
  /// Cancels a terminally rejected checkout, serialized with the original
  /// idempotency receipt. May return the paid receipt if checkout won the race.
  Future<Map<String,dynamic>> posCancelCheckout(String token,Map<String,dynamic> fields,{
    required String key,
  })=>_request('POST','/v1/pos/checkouts/cancel',token:token,
    body:{'checkout':fields},revision:0,idempotencyKey:key);
  Future<Map<String,dynamic>> posReturn(String token,Map<String,dynamic> fields,{
    required String key,
  })=>_request('POST','/v1/pos/returns',token:token,body:fields,
    revision:0,idempotencyKey:key);
  Future<List<Map<String,dynamic>>> posCheckouts(String token,String branch,String warehouse)async{
    final q=Uri(queryParameters:{'branchId':branch,'warehouseId':warehouse}).query;
    final raw=await _request('GET','/v1/pos/checkouts?$q',token:token);
    return (raw['items'] as List).map((e)=>Map<String,dynamic>.from(e as Map)).toList();
  }
  Future<Map<String,dynamic>> posReceipt(String token,String branch,String warehouse,String id)async{
    final q=Uri(queryParameters:{'branchId':branch,'warehouseId':warehouse}).query;
    final response=await _request('GET','/v1/pos/checkouts/$id?$q',token:token);
    return Map<String,dynamic>.from(response['receipt'] as Map);
  }
  /// Sales commands retain one idempotency key on lost acknowledgments.
  Future<Map<String,dynamic>> salesEntrySettings(String token,String branchId)async{
    final raw=await _request('GET','/v1/sales/entry-settings?'+
      Uri(queryParameters:{'branchId':branchId}).query,token:token);
    return Map<String,dynamic>.from(raw['settings'] as Map);
  }
  Future<Map<String,dynamic>> prepareSalesWalkIn(String token,String branchId,{required String key})async{
    final raw=await _request('POST','/v1/sales/walk-in',token:token,
      body:{'branchId':branchId},revision:0,idempotencyKey:key);
    return Map<String,dynamic>.from(raw['customer'] as Map);
  }
  Future<List<Map<String,dynamic>>> salesOrders(String token,String branchId,{String query=''})async{
    final q=Uri(queryParameters:{'branchId':branchId,if(query.trim().isNotEmpty)'q':query.trim()}).query;
    final r=await _request('GET','/v1/sales/orders?$q',token:token);
    return (r['items'] as List<dynamic>).map((v)=>Map<String,dynamic>.from(v as Map)).toList();
  }
  Future<Map<String,dynamic>> salesOrder(String token,String id,String branchId)async{
    final q=Uri(queryParameters:{'branchId':branchId}).query;
    final r=await _request('GET','/v1/sales/orders/$id?$q',token:token);
    return Map<String,dynamic>.from(r['order'] as Map);
  }
  Future<Map<String,dynamic>?> salesRecovery(String token,String action,Map<String,dynamic> fields,{
    required String key,required int revision,String? orderId})async{
    final r=await _request('POST','/v1/sales/recovery',token:token,body:{
      'action':action,'body':fields,if(orderId!=null)'orderId':orderId},
      revision:revision,idempotencyKey:key);
    final receipt=r['receipt'];
    return receipt==null?null:Map<String,dynamic>.from(receipt as Map);
  }
  Future<Map<String,dynamic>> createSalesOrder(String token,Map<String,dynamic> fields,{
    required String key,
  })=>_request('POST','/v1/sales/orders',token:token,body:fields,
    revision:0,idempotencyKey:key);
  Future<Map<String,dynamic>> updateSalesOrder(String token,String id,int revision,
    Map<String,dynamic> fields,{required String key})=>
    _request('PATCH','/v1/sales/orders/$id',token:token,body:fields,
      revision:revision,idempotencyKey:key);
  Future<Map<String,dynamic>> salesOrderAction(String token,String id,String action,
    String branchId,int revision,{required String key,String? reason})=>
    _request('POST','/v1/sales/orders/$id/$action',token:token,
      body:{'branchId':branchId,if(reason!=null)'reason':reason},
      revision:revision,idempotencyKey:key);

  /// Warehouse data is always authorized by the backend for one branch/warehouse.
  /// All inventory lists are server-paginated; no SKU can disappear past the first 100.
  Future<({List<Map<String,dynamic>> items,bool hasMore})> inventoryPage(
      String token,String kind,{required String branchId,required String warehouseId,
      String state='ACTIVE',int offset=0})async{
    if(!const {'balances','movements','reservations'}.contains(kind)||
       offset<0||offset%100!=0||
       (kind=='reservations'&&!const {'ACTIVE','RELEASED'}.contains(state))){
      throw const ErpApiError(400,'Trang dữ liệu kho không hợp lệ.');
    }
    final q=Uri(queryParameters:{'branchId':branchId,'warehouseId':warehouseId,
      'offset':'$offset',if(kind=='reservations')'state':state}).query;
    final r=await _request('GET','/v1/inventory/$kind?$q',token:token);
    return (items:(r['items'] as List<dynamic>).map((x)=>
      Map<String,dynamic>.from(x as Map)).toList(),
      hasMore:r['hasMore']==true);
  }
  Future<List<Map<String,dynamic>>> inventoryItems(String token,String kind,{
    required String branchId,required String warehouseId,
  })async=>(await inventoryPage(token,kind,
      branchId:branchId,warehouseId:warehouseId)).items;
  Future<({List<Map<String,dynamic>> items,bool hasMore})> inventoryReservationPage(
      String token,{required String branchId,required String warehouseId,
      required String state,required int offset})=>
    inventoryPage(token,'reservations',branchId:branchId,
      warehouseId:warehouseId,state:state,offset:offset);
  /// T3-B: scoped on-hand and source issues are server-derived facts only.
  Future<Map<String,dynamic>> inventoryStockScopes(String token,{
    required String branchId,required String warehouseId,required String productId})=>
    _request('GET','/v1/inventory/stock-scopes?'+Uri(queryParameters:{
      'branchId':branchId,'warehouseId':warehouseId,'productId':productId}).query,
      token:token);
  Future<List<Map<String,dynamic>>> inventoryDirectIssues(String token,{
    required String branchId,required String warehouseId,required String orderId})async{
    final r=await _request('GET','/v1/inventory/direct-issues?'+Uri(queryParameters:{
      'branchId':branchId,'warehouseId':warehouseId,'orderId':orderId}).query,
      token:token);
    return (r['items'] as List<dynamic>).map((x)=>Map<String,dynamic>.from(x as Map)).toList();
  }
  /// A pending request uses an identical command body and key until the server ACKs.
  // Keep the entire exact request when POST may have COMMITTED without an ACK.
  final Map<String,({Map<String,dynamic> payload,String key,String? action,int? revision})>
    _inventoryPending={};
  ({Map<String,dynamic> payload,String key,String? action,int? revision})?
      pendingInventory(String id){
    final p=_inventoryPending[id];
    return p==null?null:(payload:Map<String,dynamic>.from(p.payload),
      key:p.key,action:p.action,revision:p.revision);
  }
  void retainInventory(String id,Map<String,dynamic> payload,String key,
      {String? action,int? revision}){
    _inventoryPending[id]=(payload:Map<String,dynamic>.from(payload),
      key:key,action:action,revision:revision);
  }
  void clearInventory(String id){_inventoryPending.remove(id);}
  Future<Map<String,dynamic>> inventoryAction(String token,String action,
      Map<String,dynamic> body,{required String key,required int revision})=>
    _request('POST','/v1/inventory/$action',token:token,
      body:body,revision:revision,idempotencyKey:key);

  /// Branch + warehouse scoped purchase orders. Only server-posted receipts alter stock.
  Future<({List<Map<String,dynamic>> items,bool hasMore})> purchasingOrderPage(
      String token,String branchId,String warehouseId,{int offset=0})async{
    if(offset<0||offset%100!=0)throw const ErpApiError(400,'Trang đơn mua không hợp lệ.');
    final q=Uri(queryParameters:{'branchId':branchId,'warehouseId':warehouseId,
      'offset':'$offset'}).query;
    final r=await _request('GET','/v1/purchasing/orders?$q',token:token);
    return (items:(r['items'] as List<dynamic>).map((v)=>
      Map<String,dynamic>.from(v as Map)).toList(),hasMore:r['hasMore']==true);
  }
  Future<List<Map<String,dynamic>>> purchasingOrders(String token,
      String branchId,String warehouseId)async=>
    (await purchasingOrderPage(token,branchId,warehouseId)).items;
  Future<Map<String,dynamic>> purchasingOrder(String token,String id,
      String branchId,String warehouseId)async{
    final q=Uri(queryParameters:{'branchId':branchId,'warehouseId':warehouseId}).query;
    final r=await _request('GET','/v1/purchasing/orders/$id?$q',token:token);
    return Map<String,dynamic>.from(r['order'] as Map);
  }
  Future<Map<String,dynamic>> purchasingCommand(String token,String path,
      Map<String,dynamic> payload,{required int revision,required String key})=>
    _request('POST','/v1/purchasing/$path',token:token,body:payload,
      revision:revision,idempotencyKey:key);
  // Preserve the entire immutable command, not only its body and key.
  final Map<String,({Map<String,dynamic> payload,String key,String path,int revision})> _purchasePending={};
  ({Map<String,dynamic> payload,String key,String path,int revision})? pendingPurchase(String id){
    final p=_purchasePending[id];
    return p==null?null:(payload:Map<String,dynamic>.from(p.payload),
      key:p.key,path:p.path,revision:p.revision);
  }
  void retainPurchase(String id,Map<String,dynamic> payload,String key,{
      required String path,required int revision}){
    _purchasePending[id]=(payload:Map<String,dynamic>.from(payload),
      key:key,path:path,revision:revision);
  }
  void clearPurchase(String id)=>_purchasePending.remove(id);

  /// Transfer-scoped selectors work even without catalog.read permission.
  Future<({List<Map<String,dynamic>> branches,List<Map<String,dynamic>> warehouses})>
      transferScopes(String token,{String? branchId,String query=''})async{
    final q=Uri(queryParameters:{
      if(branchId!=null)'branchId':branchId,
      if(query.isNotEmpty)'q':query,
    }).query;
    final raw=await _request('GET','/v1/inventory/transfers/scopes?$q',token:token);
    List<Map<String,dynamic>> rows(String key)=>(raw[key] as List<dynamic>)
      .map((x)=>Map<String,dynamic>.from(x as Map)).toList();
    return (branches:rows('branches'),warehouses:rows('warehouses'));
  }
  /// Active SKUs for transfer creation; scoped to the source warehouse grant.
  /// Unlike catalog screens this never asks for unrelated catalog.read rights.
  Future<List<Map<String,dynamic>>> transferProducts(String token,{
    required String branchId,required String sourceWarehouseId,String query=''})async{
    final q=Uri(queryParameters:{'branchId':branchId,
      'warehouseId':sourceWarehouseId,if(query.trim().isNotEmpty)'q':query.trim()}).query;
    final raw=await _request('GET','/v1/inventory/transfers/products?$q',
      token:token);
    return (raw['items'] as List<dynamic>).map((x)=>
      Map<String,dynamic>.from(x as Map)).toList();
  }
  /// Transfer lifecycle is separate from sales order and actual accepted stock.
  Future<({List<Map<String,dynamic>> items,bool hasMore})> transferPage(
    String token,{required String branchId,required String warehouseId,int offset=0})async{
    if(offset<0||offset%100!=0)throw const ErpApiError(400,'Trang chuyển kho không hợp lệ.');
    final query=Uri(queryParameters:{'branchId':branchId,
      'warehouseId':warehouseId,'offset':'$offset'}).query;
    final r=await _request('GET','/v1/inventory/transfers?$query',token:token);
    return (items:(r['items'] as List<dynamic>).map((x)=>
      Map<String,dynamic>.from(x as Map)).toList(),hasMore:r['hasMore']==true);
  }
  Future<Map<String,dynamic>> transferDetail(String token,String transferId,{
      required String branchId,required String warehouseId,
      required String sourceWarehouseId,required String destinationWarehouseId})async{
    final q=Uri(queryParameters:{'branchId':branchId,'warehouseId':warehouseId,
      'sourceWarehouseId':sourceWarehouseId,
      'destinationWarehouseId':destinationWarehouseId}).query;
    final r=await _request('GET','/v1/inventory/transfers/$transferId?$q',token:token);
    return Map<String,dynamic>.from(r['transfer'] as Map);
  }
  Future<Map<String,dynamic>> transferCommand(String token,String path,
    Map<String,dynamic> payload,{required int revision,required String key})=>
    _request('POST','/v1/inventory/transfers$path',token:token,body:payload,
       revision:revision,idempotencyKey:key);
  final Map<String,({Map<String,dynamic> payload,String key,String path,int revision})>
    _transferPending={};
  ({Map<String,dynamic> payload,String key,String path,int revision})?
    pendingTransfer(String scope){
    final c=_transferPending[scope];
    return c==null?null:(payload:Map<String,dynamic>.from(c.payload),
       key:c.key,path:c.path,revision:c.revision);
  }
  void retainTransfer(String scope,Map<String,dynamic> payload,String key,{
    required String path,required int revision}){
    _transferPending[scope]=(payload:Map<String,dynamic>.from(payload),
      key:key,path:path,revision:revision);
  }
  void clearTransfer(String scope)=>_transferPending.remove(scope);
  List<String> transferPendingScopes(String actorId,String branchId,String warehouseId)=>
    _transferPending.entries.where((entry){
      final p=entry.value.payload;
      return entry.key.startsWith('$actorId:')&&p['branchId']==branchId&&
        (p['sourceWarehouseId']==warehouseId||p['destinationWarehouseId']==warehouseId);
    }).map((entry)=>entry.key).toList();


  Future<({List<Map<String,dynamic>> branches,List<Map<String,dynamic>> warehouses})>
      stocktakeScopes(String token,{String? branchId,String query=''})async{
    final q=Uri(queryParameters:{if(branchId!=null)'branchId':branchId,
      if(query.isNotEmpty)'q':query}).query;
    final r=await _request('GET','/v1/inventory/stocktakes/scopes?$q',token:token);
    List<Map<String,dynamic>> list(String k)=>(r[k] as List<dynamic>).map((x)=>
      Map<String,dynamic>.from(x as Map)).toList();
    return (branches:list('branches'),warehouses:list('warehouses'));
  }
  Future<({List<Map<String,dynamic>> items,bool hasMore})> stocktakePage(
    String token,{required String branchId,required String warehouseId,int offset=0})async{
    if(offset<0||offset%100!=0)throw const ErpApiError(400,'Trang kiểm kê không hợp lệ.');
    final q=Uri(queryParameters:{'branchId':branchId,'warehouseId':warehouseId,
      'offset':'$offset'}).query;
    final r=await _request('GET','/v1/inventory/stocktakes?$q',token:token);
    return (items:(r['items'] as List<dynamic>).map((x)=>
      Map<String,dynamic>.from(x as Map)).toList(),hasMore:r['hasMore']==true);
  }
  Future<Map<String,dynamic>> stocktakeDetail(String token,String id,{
    required String branchId,required String warehouseId})async{
    final q=Uri(queryParameters:{'branchId':branchId,'warehouseId':warehouseId}).query;
    final r=await _request('GET','/v1/inventory/stocktakes/$id?$q',token:token);
    return Map<String,dynamic>.from(r['stocktake'] as Map);
  }
  Future<Map<String,dynamic>> stocktakeCommand(String token,String suffix,
    Map<String,dynamic> body,{required int revision,required String key})=>
    _request('POST','/v1/inventory/stocktakes$suffix',token:token,
      body:body,revision:revision,idempotencyKey:key);
  final Map<String,({Map<String,dynamic> payload,String key,String suffix,int revision})>
    _stocktakePending={};
  ({Map<String,dynamic> payload,String key,String suffix,int revision})?
      pendingStocktake(String scope){
    final p=_stocktakePending[scope];
    return p==null?null:(payload:Map<String,dynamic>.from(p.payload),
      key:p.key,suffix:p.suffix,revision:p.revision);
  }
  void retainStocktake(String scope,Map<String,dynamic> payload,String key,{
      required String suffix,required int revision}){
    _stocktakePending[scope]=(payload:Map<String,dynamic>.from(payload),
      key:key,suffix:suffix,revision:revision);
  }
  void clearStocktake(String scope)=>_stocktakePending.remove(scope);

  Future<IdentityUser> createUser(String token,String username,String password)async{
    final r=await _request('POST','/v1/admin/users',token:token,revision:0,
      body:{'loginName':username,'password':password});
    return IdentityUser.fromJson(r);
  }
  Future<int> setDisabled(String token,IdentityUser user,bool disabled)async{
    final r=await _request('PATCH','/v1/admin/users/${user.id}',token:token,
      revision:user.revision,body:{'disabled':disabled});
    return r['revision'] as int;
  }
  Future<int> grant(String token,IdentityUser user,{
    required String permission,String? branchId,String? warehouseId,
  })async{
    final r=await _request('POST','/v1/admin/users/${user.id}/grants',token:token,revision:user.revision,
      body:{'permission':permission,'branchId':branchId,'warehouseId':warehouseId});
    return r['revision'] as int;
  }
  Future<int> revoke(String token,IdentityUser user,String roleId)async{
    final r=await _request('DELETE','/v1/admin/users/${user.id}/grants/$roleId',token:token,
      revision:user.revision);
    return r['revision'] as int;
  }
}
