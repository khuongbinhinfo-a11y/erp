import 'dart:js_interop';
import 'package:web/web.dart' as web;

// Dedicated register, same-origin only; never place credentials in the URL.
bool get erpPosStandalone=>Uri.base.queryParameters['erp_pos']=='1';
bool get erpPosWebSupported=>true;
void erpOpenPosTab(){
  web.window.open('/?erp_pos=1'.toJS,'_blank'.toJS,'noopener'.toJS);
}
