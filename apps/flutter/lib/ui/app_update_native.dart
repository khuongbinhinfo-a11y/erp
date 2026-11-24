import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'app_update_models.dart';
import 'identity_client.dart';

bool get erpAndroidUpdateSupported=>Platform.isAndroid;
const _bridge=MethodChannel('erp/android_update');
/// Automatic Android-only check at session start, without blocking ERP work.
Future<String?> erpAndroidQuietUpdateVersion(ErpIdentityClient client,IdentitySession session)async{
  if(!Platform.isAndroid||!session.expiresAt.isAfter(DateTime.now()))return null;
  final origin=Uri.tryParse(client.apiOrigin);
  if(origin==null||origin.scheme!='https'||origin.host.isEmpty||origin.userInfo.isNotEmpty)return null;
  final httpClient=http.Client();
  try{
    final installed=await _bridge.invokeMapMethod<String,dynamic>('installed');
    if(installed==null||installed['packageName']!=erpAndroidPackage||
       installed['versionCode'] is! int||installed['signerSha256'] is! String)return null;
    final req=http.Request('GET',origin.resolve('/v1/app/releases/latest'))
      ..followRedirects=false
      ..headers.addAll({'authorization':'Bearer ${session.token}','accept':'application/json'});
    final response=await httpClient.send(req).timeout(const Duration(seconds:10));
    if(response.statusCode!=200)return null;
    final payload=await http.Response.fromStream(response).timeout(const Duration(seconds:10));
    if(!session.expiresAt.isAfter(DateTime.now()))return null;
    final data=jsonDecode(payload.body);
    if(data is! Map<String,dynamic>||data['release']==null)return null;
    final next=ErpAndroidRelease.parse(data['release']);
    if(!next.canInstall(installedPackage:installed['packageName'] as String,
      installedSigner:installed['signerSha256'] as String,
      installedCode:installed['versionCode'] as int))return null;
    return next.versionName;
  }catch(_){return null;}
  finally{httpClient.close();}
}
Future<void> showErpAndroidUpdate(BuildContext context,ErpIdentityClient client,
  IdentitySession session,bool Function() isCurrent) async {
  if(!erpAndroidUpdateSupported||!isCurrent())return;
  await showDialog<void>(context:context,builder:(_)=>_UpdateDialog(
    origin:client.apiOrigin,session:session,isCurrent:isCurrent));
}
class _UpdateDialog extends StatefulWidget{
  final String origin;
  final IdentitySession session;
  final bool Function() isCurrent;
  const _UpdateDialog({required this.origin,required this.session,required this.isCurrent});
  @override State<_UpdateDialog> createState()=>_UpdateDialogState();
}
class _UpdateDialogState extends State<_UpdateDialog>{
  final _control=http.Client();
  http.Client? _download;
  ErpAndroidRelease? _release;
  Map<String,dynamic>? _installed;
  bool _busy=false,_cancel=false;
  String? _error,_message;
  double _progress=0;
  String? _readyPath;
  @override void initState(){super.initState();unawaited(_check());}
  @override void dispose(){_cancel=true;_download?.close();_control.close();super.dispose();}
  void _ensureScope(){
    if(!mounted||!widget.isCurrent()||_cancel)throw const FormatException('Đã dừng cập nhật.');
  }
  Map<String,String> get _headers=>{'authorization':'Bearer ${widget.session.token}','accept':'application/json'};
  Uri _api(String path){
    final base=Uri.tryParse(widget.origin);
    if(base==null||base.scheme!='https'||base.host.isEmpty||base.userInfo.isNotEmpty)throw const FormatException('Không thể kết nối.');
    return base.resolve(path);
  }
  Future<Map<String,dynamic>> _json(String method,String path,[Map<String,dynamic>? body])async{
    _ensureScope();
    final request=http.Request(method,_api(path))..followRedirects=false..headers.addAll(_headers);
    if(body!=null){request.headers['content-type']='application/json';request.body=jsonEncode(body);}
    final streamed=await _control.send(request).timeout(const Duration(seconds:20));
    final response=await http.Response.fromStream(streamed).timeout(const Duration(seconds:20));
    _ensureScope();
    if(response.statusCode!=200)throw const FormatException('Không thể kiểm tra bản cập nhật. Hãy thử lại.');
    final data=jsonDecode(response.body);
    if(data is! Map<String,dynamic>)throw const FormatException('Bản cập nhật không hợp lệ.');
    return data;
  }
  Future<void> _check()async{
    if(_busy)return;
    setState((){_busy=true;_cancel=false;_error=null;_message=null;_readyPath=null;_release=null;_progress=0;});
    try{
      final installed=await _bridge.invokeMapMethod<String,dynamic>('installed');
      _ensureScope();
      if(installed==null||installed['packageName']!=erpAndroidPackage||
         installed['versionCode'] is! int||installed['signerSha256'] is! String||
         installed['cacheDir'] is! String)throw const FormatException('Không xác minh được ứng dụng đang cài.');
      final response=await _json('GET','/v1/app/releases/latest');
      final raw=response['release'];
      final next=raw==null?null:ErpAndroidRelease.parse(raw);
      _ensureScope();
      if(next!=null&&next.versionCode>(installed['versionCode'] as int)&&
        !next.canInstall(installedPackage:installed['packageName'] as String,
          installedSigner:installed['signerSha256'] as String,installedCode:installed['versionCode'] as int)){
        throw const FormatException('Chữ ký bản mới không khớp. Không thể cài đặt.');
      }
      setState((){_installed=installed;_release=next!=null&&next.versionCode>(installed['versionCode'] as int)?next:null;
        _message=next==null?'Chưa có bản cập nhật được phát hành.':_release==null?'Ứng dụng đã ở phiên bản mới nhất.':null;});
    }catch(e){if(mounted)setState(()=>_error=e is FormatException?e.message:'Không thể kiểm tra phiên bản. Hãy thử lại.');}
    finally{if(mounted)setState(()=>_busy=false);}
  }
  Future<bool> _verified(File file,ErpAndroidRelease release)async=>
    await file.exists()&&await file.length()==release.size&&
      (await sha256.bind(file.openRead()).first).toString()==release.sha256;
  Future<void> _fetch()async{
    final release=_release,installed=_installed;
    if(_busy||release==null||installed==null)return;
    setState((){_busy=true;_cancel=false;_error=null;_message=null;_readyPath=null;});
    IOSink? sink;
    try{
      _ensureScope();
      final dir=Directory('${installed['cacheDir']}/erp-updates');
      await dir.create(recursive:true);
      final actor=sha256.convert(utf8.encode('${widget.origin}|${widget.session.actorId}')).toString();
      final part=File('${dir.path}/$actor-${release.sha256}.part');
      final apk=File('${dir.path}/$actor-${release.sha256}.apk');
      if(!await _verified(apk,release)){
        if(await apk.exists())await apk.delete();
        var offset=await part.exists()?await part.length():0;
        if(offset>release.size){await part.delete();offset=0;}
        if(offset==release.size&&!await _verified(part,release)){await part.delete();offset=0;}
        if(offset<release.size){
          final ticket=await _json('POST','/v1/app/releases/ticket',{'versionCode':release.versionCode});
          final uri=erpUpdateTicketUri(widget.origin,ticket['path'],ticket['expiresAt']);
          if(uri.queryParameters['versionCode']!='${release.versionCode}')throw const FormatException('Phiên bản đã thay đổi.');
          final client=http.Client();_download=client;
          final request=http.Request('GET',uri)..followRedirects=false..headers.addAll(_headers);
          if(offset>0)request.headers['range']='bytes=$offset-';
          final response=await client.send(request).timeout(const Duration(seconds:25));
          _ensureScope();
          final expected=offset>0?206:200;
          if(response.statusCode!=expected||response.contentLength!=release.size-offset||
              (offset>0&&response.headers['content-range']!='bytes $offset-${release.size-1}/${release.size}')){
            throw const FormatException('Không thể tiếp tục tải. Hãy kiểm tra lại phiên bản.');
          }
          final writer=part.openWrite(mode:offset>0?FileMode.append:FileMode.write);
          sink=writer;
          await for(final chunk in response.stream.timeout(const Duration(seconds:30))){
            _ensureScope();
            if(offset+chunk.length>release.size)throw const FormatException('Dung lượng bản tải không hợp lệ.');
            writer.add(chunk);await writer.flush();offset+=chunk.length;
            if(mounted)setState(()=>_progress=offset/release.size);
          }
          await writer.close();sink=null;
        }
        _ensureScope();
        if(!await _verified(part,release)){
          if(await part.exists()&&await part.length()>=release.size)await part.delete();
          throw const FormatException('Tệp tải chưa đủ hoặc không đúng mã kiểm tra. Hãy thử lại.');
        }
        await part.rename(apk.path);
      }
      _ensureScope();
      await _bridge.invokeMethod<void>('inspect',_arguments(apk.path,release));
      _ensureScope();
      setState((){_readyPath=apk.path;_progress=1;_message='Bản cập nhật đã được xác minh.';});
    }catch(e){if(mounted)setState(()=>_error=_cancel?'Đã dừng tải. Có thể tiếp tục sau.':
      e is FormatException?e.message:'Không thể tải hoặc xác minh. Hãy thử lại.');}
    finally{
      try{await sink?.close();}catch(_){}
      _download?.close();_download=null;
      if(mounted)setState(()=>_busy=false);
    }
  }
  Map<String,dynamic> _arguments(String path,ErpAndroidRelease release)=>{'path':path,
    'versionCode':release.versionCode,'size':release.size,'sha256':release.sha256,
    'signerSha256':release.signerSha256};
  Future<void> _install()async{
    final path=_readyPath,release=_release;
    if(path==null||release==null||_busy)return;
    setState((){_busy=true;_error=null;});
    try{
      _ensureScope();
      final opened=await _bridge.invokeMethod<bool>('install',_arguments(path,release));
      _ensureScope();
      if(opened!=true)setState(()=>_message='Hãy cho phép cài đặt từ nguồn này rồi bấm Cài đặt lại.');
      else setState(()=>_message='Xác nhận cài đè trong cửa sổ Android.');
    }catch(_){if(mounted)setState(()=>_error='Không thể cài đặt bản cập nhật.');}
    finally{if(mounted)setState(()=>_busy=false);}
  }
  @override Widget build(BuildContext context){
    final installed=_installed,next=_release;
    return AlertDialog(title:const Text('Cập nhật ứng dụng'),
      content:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,
        crossAxisAlignment:CrossAxisAlignment.start,children:[
        if(installed!=null)Text('Đang sử dụng: ${installed['versionName']} (${installed['versionCode']})'),
        if(next!=null)...[const SizedBox(height:8),Text('Bản mới: ${next.versionName} (${next.versionCode})'),
          Text('Dung lượng: ${(next.size/1048576).toStringAsFixed(1)} MB'),Text(next.notes)],
        if(_busy)...[const SizedBox(height:12),LinearProgressIndicator(value:next!=null?_progress:null),
          if(next!=null)Text('${(_progress*100).toStringAsFixed(0)}%')],
        if(_message!=null)Text(_message!),if(_error!=null)Text(_error!,style:TextStyle(color:Theme.of(context).colorScheme.error)),
      ])),actions:[
        TextButton(onPressed:()=>Navigator.of(context).pop(),child:const Text('Đóng')),
        if(_busy&&_download!=null)TextButton(onPressed:(){_cancel=true;_download?.close();},child:const Text('Dừng tải')),
        if(!_busy)TextButton(onPressed:_check,child:const Text('Kiểm tra')),
        if(!_busy&&next!=null&&_readyPath==null)FilledButton(onPressed:_fetch,child:const Text('Tải / tiếp tục')),
        if(!_busy&&_readyPath!=null)FilledButton(onPressed:_install,child:const Text('Cài đặt')),
      ]);
  }
}
