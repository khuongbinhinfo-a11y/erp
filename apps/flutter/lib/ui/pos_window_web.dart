import 'package:web/web.dart' as web;

// Same-origin POS route: no session, actor, or other credentials in URL.
bool get erpPosStandalone=>Uri.base.queryParameters['erp_pos']=='1';
bool get erpPosWebSupported=>true;
void erpOpenPosTab(){
  web.window.open('/?erp_pos=1','_blank','noopener');
}
