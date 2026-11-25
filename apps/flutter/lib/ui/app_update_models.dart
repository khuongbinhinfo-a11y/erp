const erpAndroidPackage='vn.erpdistribution.erp_distribution';
final _hex64=RegExp(r'^[a-f0-9]{64}$');
class ErpAndroidRelease {
  final String packageName,versionName,sha256,signerSha256,notes;
  final int versionCode,size;
  const ErpAndroidRelease({required this.packageName,required this.versionName,
    required this.sha256,required this.signerSha256,required this.notes,
    required this.versionCode,required this.size});
  factory ErpAndroidRelease.parse(Object? value){
    if(value is! Map<String,dynamic>)throw const FormatException('Bản cập nhật không hợp lệ.');
    final version=value['versionCode'],size=value['size'];
    final hash=value['sha256'],signer=value['signerSha256'],name=value['versionName'],notes=value['notes'];
    if(value['packageName']!=erpAndroidPackage||version is! int||version<1||version>999999999||
       size is! int||size<1||size>300*1024*1024||hash is! String||!_hex64.hasMatch(hash)||
       signer is! String||!_hex64.hasMatch(signer)||name is! String||name.isEmpty||
       notes is! String||notes.length>4000)throw const FormatException('Bản cập nhật không hợp lệ.');
    return ErpAndroidRelease(packageName:erpAndroidPackage,versionName:name,sha256:hash,
      signerSha256:signer,notes:notes,versionCode:version,size:size);
  }
  bool canInstall({required String installedPackage,required String installedSigner,required int installedCode})=>
    installedPackage==packageName&&installedSigner==signerSha256&&versionCode>installedCode;
}
Uri erpUpdateTicketUri(String origin,Object? path,Object? expiresAt,{DateTime? now}){
  final base=Uri.tryParse(origin);
  final relative=path is String?Uri.tryParse(path):null;
  final expiration=expiresAt is String?DateTime.tryParse(expiresAt):null;
  final time=now??DateTime.now();
  if(base==null||base.scheme!='https'||base.host.isEmpty||base.userInfo.isNotEmpty||relative==null||
     relative.hasScheme||relative.hasAuthority||relative.hasFragment||
     relative.path!='/v1/app/releases/download'||expiration==null||
     !expiration.isAfter(time)||expiration.isAfter(time.add(const Duration(minutes:6)))||
     relative.queryParameters.length!=3||
     relative.queryParametersAll.values.any((values)=>values.length!=1)||
     !RegExp(r'^[a-f0-9]{64}$').hasMatch(relative.queryParameters['ticket']??'')||
     (int.tryParse(relative.queryParameters['versionCode']??'')??0)<1||
     int.tryParse(relative.queryParameters['expires']??'')!=(expiration.millisecondsSinceEpoch~/1000)){
    throw const FormatException('Liên kết cập nhật không hợp lệ hoặc đã hết hạn.');
  }
  return base.resolveUri(relative);
}
