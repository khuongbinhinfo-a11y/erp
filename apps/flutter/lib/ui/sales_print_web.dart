import 'dart:async';
import 'dart:js_interop';
import 'package:web/web.dart' as web;

bool get erpSalesWebPrintSupported=>true;

/// Open the escaped local document from the user click. It contains no
/// external assets or bearer token. The print button is in the document.
void erpOpenSalesPrint(String html){
  final blob=web.Blob([html.toJS].toJS,web.BlobPropertyBag(type:'text/html;charset=utf-8'));
  final url=web.URL.createObjectURL(blob);
  final anchor=web.HTMLAnchorElement()..href=url..target='_blank'..rel='noopener noreferrer';
  try{web.document.body?.append(anchor);anchor.click();}
  finally{anchor.remove();Timer(const Duration(minutes:1),()=>web.URL.revokeObjectURL(url));}
}
