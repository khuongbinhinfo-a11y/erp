import 'dart:async';
import 'dart:js_interop';
import 'package:web/web.dart' as web;

bool get erpSalesWebPrintSupported=>true;

/// Open the browser's native print / Save as PDF dialog directly.
/// Print a separate local, escaped HTML document without showing an
/// intermediary white HTML tab or printing the Flutter application shell.
/// The browser (not the ERP web app) owns printer, paper, margins and PDF.
void erpOpenSalesPrint(String html){
  if(!html.startsWith('<!doctype html>')||
    html.toLowerCase().contains('<script')){
    throw const FormatException('Chứng từ in không hợp lệ.');
  }
  final body=web.document.body;
  if(body==null)throw StateError('Không tìm thấy trang để mở hộp thoại in.');

  final blob=web.Blob([html.toJS].toJS,
    web.BlobPropertyBag(type:'text/html;charset=utf-8'));
  final url=web.URL.createObjectURL(blob);
  final frame=web.HTMLIFrameElement()
    ..src=url
    ..title='ERP - Phiếu xuất kho';
  frame.style.cssText='position:fixed;left:-10000px;top:0;'
    'width:794px;height:1123px;border:0;opacity:0;pointer-events:none';
  frame.setAttribute('aria-hidden','true');
  var disposed=false;
  void dispose(){
    if(disposed)return;
    disposed=true;
    frame.remove();
    web.URL.revokeObjectURL(url);
  }
  frame.addEventListener('load',((web.Event event){
    if(disposed)return;
    final frameWindow=frame.contentWindow;
    if(frameWindow==null){dispose();return;}
    frameWindow.addEventListener('afterprint',((web.Event event){
      Timer(const Duration(seconds:2),dispose);
    }).toJS);
    // The native dialog offers the printer, paper size and Save as PDF.
    // It does not tell us whether the user actually printed or saved.
    try{
      frameWindow.focus();
      frameWindow.print();
    }catch(_){dispose();}
  }).toJS);
  try{
    body.append(frame);
  }catch(_){
    dispose();
    rethrow;
  }
  // Some browsers omit afterprint when print is cancelled/blocked.
  Timer(const Duration(minutes:5),dispose);
}
