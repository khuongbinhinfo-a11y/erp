import 'dart:async';

/// In-memory, per actor/branch signed photo URL cache. Never serialize a signed
/// URL into the SKU, cart, offline catalog or logs. Queue at most four requests
/// concurrently, deduplicate selling units sharing the same product.
class PosProductPhotoCache {
  PosProductPhotoCache(this.load,{DateTime Function()? clock}):_clock=clock??DateTime.now;
  final Future<List<Map<String,dynamic>>> Function(String) load;
  final DateTime Function() _clock;
  final _entries=<String,({Future<String?> future,DateTime until})>{};
  final _queue=<({String id,Completer<String?> result})>[];
  int _active=0;
  bool _disposed=false;

  Future<String?> urlFor(String id){
    if(_disposed||!RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(id))return Future.value(null);
    final now=_clock();
    final previous=_entries[id];
    if(previous!=null&&previous.until.isAfter(now))return previous.future;
    _entries.removeWhere((_,entry)=>!entry.until.isAfter(now));
    if(_entries.length>=200)return Future.value(null);
    final result=Completer<String?>();
    _entries[id]=(future:result.future,until:now.add(const Duration(minutes:4)));
    _queue.add((id:id,result:result));
    _drain();
    return result.future;
  }
  void _drain(){
    while(!_disposed&&_active<4&&_queue.isNotEmpty){
      final job=_queue.removeAt(0);
      _active++;
      unawaited(_fetch(job.id,job.result));
    }
  }
  Future<void> _fetch(String id,Completer<String?> result)async{
    String? url;
    try{
      final photos=await load(id);
      // Server returns primary first. Prefer primary explicitly even when
      // the server order changes; never treat an arbitrary SKU URL as media.
      final selected=[...photos.where((x)=>x['isPrimary']==true),
        ...photos.where((x)=>x['isPrimary']!=true)];
      for(final photo in selected){
        final raw=photo['downloadUrl'];
        if(raw is! String)continue;
        final uri=Uri.tryParse(raw);
        if(uri!=null&&uri.scheme=='https'&&uri.host.isNotEmpty&&uri.userInfo.isEmpty){
          url=raw;break;
        }
      }
    }catch(_){ /* Images are optional and must never block checkout. */ }
    finally{
      if(_disposed)url=null;
      final entry=_entries[id];
      if(!_disposed&&entry?.future==result.future){
        _entries[id]=(future:result.future,until:_clock().add(
          url==null?const Duration(seconds:30):const Duration(minutes:4)));
      }
      result.complete(url);
      _active--;
      _drain();
    }
  }
  void dispose(){
    _disposed=true;
    _entries.clear();
    for(final job in _queue){job.result.complete(null);}
    _queue.clear();
  }
}
