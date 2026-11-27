import 'dart:html' as html;

// Same-origin route; no session, actor or credentials are placed into the URL.
// The existing browser session must still authenticate and pass server-side RBAC.
bool get erpPosStandalone=>Uri.base.queryParameters['erp_pos']=='1';
bool get erpPosWebSupported=>true;
void erpOpenPosTab(){
  html.window.open('/?erp_pos=1','_blank','noopener');
}
