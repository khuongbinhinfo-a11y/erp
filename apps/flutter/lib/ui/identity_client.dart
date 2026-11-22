import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

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
  final String actorId,token,loginName;
  final DateTime expiresAt;
  final List<IdentityGrant> grants;
  const IdentitySession({required this.actorId,required this.token,
    this.loginName='',required this.expiresAt,required this.grants});
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
  int _sequence=0;
  // One unresolved R1 command per actor/branch/resource is retained in the
  // authenticated client across workspace navigation; never store auth tokens.
  final Map<String,({Map<String,dynamic> payload,String key})> _r1Pending={};
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
  ErpIdentityClient({this.apiOrigin=erpApiOrigin,http.Client? httpClient}):_http=httpClient??http.Client();
  bool get configured=>Uri.tryParse(apiOrigin)?.scheme=='https'&&
    Uri.tryParse(apiOrigin)?.host.isNotEmpty==true;
  void dispose(){_r1Pending.clear();_inventoryPending.clear();_purchasePending.clear();_transferPending.clear();_stocktakePending.clear();_http.close();}
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
      final response=await http.Response.fromStream(await _http.send(req).timeout(Duration(seconds:path=='/v1/auth/login'?18:10)));
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
      _r1Pending.clear();
      return IdentitySession(actorId:actor,token:token,
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
    return IdentitySession(actorId:r['actorId'] as String,token:token,
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
  /// Catalog calls always use the authenticated installation and server-side RBAC.
  Future<List<Map<String,dynamic>>> catalogItems(String token,String resource,{
    String? branchId,String query='',
  })async{
    final params=<String,String>{};
    if(branchId!=null)params['branchId']=branchId;
    if(query.trim().isNotEmpty)params['q']=query.trim();
    final suffix=params.isEmpty?'':'?${Uri(queryParameters:params).query}';
    final raw=await _request('GET','/v1/catalog/$resource$suffix',token:token);
    return (raw['items'] as List<dynamic>)
      .map((v)=>Map<String,dynamic>.from(v as Map)).toList();
  }
  Future<Map<String,dynamic>> createCatalog(String token,String resource,
    Map<String,dynamic> fields)async{
    return _request('POST','/v1/catalog/$resource',token:token,revision:0,body:fields);
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
  /// Price simulation is read-only; it never changes order, stock or money ledger.
  Future<Map<String,dynamic>> r1PriceQuote(String token,
    Map<String,dynamic> context)=>_request(
      'POST','/v1/catalog/r1/resolve',token:token,body:context);
  /// Optimistic catalog edit: the server checks the exact row revision inside its transaction.
  Future<Map<String,dynamic>> updateCatalog(String token,String resource,
    String id,int expectedRevision,Map<String,dynamic> fields)async{
    return _request('PATCH','/v1/catalog/$resource/$id',
      token:token,revision:expectedRevision,body:fields);
  }
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
  /// Quotes a whole sales basket in one server context, with decimal totals.
  /// This does not create an order or change inventory/receivables.
  Future<Map<String,dynamic>> salesPricePreview(String token,
    Map<String,dynamic> fields)async{
    final r=await _request('POST','/v1/sales/quote',token:token,body:fields);
    return Map<String,dynamic>.from(r['quote'] as Map);
  }
  /// Sales commands retain one idempotency key on lost acknowledgments.
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
