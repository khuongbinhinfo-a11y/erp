import 'package:flutter_test/flutter_test.dart';
import 'package:erp_distribution/ui/app_update_models.dart';
void main(){
  final manifest={'packageName':erpAndroidPackage,'versionCode':2,'versionName':'1.0.1',
    'size':500,'sha256':'a'*64,'signerSha256':'b'*64,'notes':'Bản mới'};
  test('ERP release checks package, signer, monotonic version and hash',(){
    final r=ErpAndroidRelease.parse(manifest);
    expect(r.canInstall(installedPackage:erpAndroidPackage,installedSigner:'b'*64,installedCode:1),isTrue);
    expect(r.canInstall(installedPackage:erpAndroidPackage,installedSigner:'c'*64,installedCode:1),isFalse);
    expect(r.canInstall(installedPackage:erpAndroidPackage,installedSigner:'b'*64,installedCode:2),isFalse);
    expect(()=>ErpAndroidRelease.parse({...manifest,'sha256':'broken'}),throwsFormatException);
    expect(()=>ErpAndroidRelease.parse({...manifest,'packageName':'foreign.app'}),throwsFormatException);
  });
  test('download ticket accepts only same-origin authenticated path',(){
    final now=DateTime.utc(2026,11,24),expiration=now.add(const Duration(minutes:5));
    final expires=expiration.toIso8601String();
    final path='/v1/app/releases/download?versionCode=2&ticket=${'a'*64}&expires=${expiration.millisecondsSinceEpoch~/1000}';
    expect(erpUpdateTicketUri('https://erp.example',path,expires,now:now).host,'erp.example');
    for(final bad in ['https://other.example$path','//$path','/v1/catalog/secret']){
      expect(()=>erpUpdateTicketUri('https://erp.example',bad,expires,now:now),throwsFormatException);
    }
    expect(()=>erpUpdateTicketUri('https://erp.example',path,now.toIso8601String(),now:now),throwsFormatException);
    for(final invalid in [
      path.replaceFirst('expires=', 'expires=1&expires='),
      path.replaceFirst('versionCode=2','versionCode=0'),
      path.replaceFirst('expires=', 'expires=1'),
      path+'&unexpected=1',
    ]) {
      expect(()=>erpUpdateTicketUri('https://erp.example',invalid,expires,now:now),throwsFormatException);
    }
  });
}
