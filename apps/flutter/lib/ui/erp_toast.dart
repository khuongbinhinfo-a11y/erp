import 'dart:async';
import 'package:material_ui/material_ui.dart';
import 'erp_tokens.dart';

/// Transient top-right notices only; no success claim before server ACK.
abstract final class ErpToast {
  static void show(BuildContext context,String text,{bool isError=false}){
    final overlay=Overlay.maybeOf(context,rootOverlay:true);
    if(overlay==null)return;
    late OverlayEntry entry;
    Timer? timer;
    bool closed=false;
    void close(){
      if(closed)return;
      closed=true;
      timer?.cancel();
      entry.remove();
      entry.dispose();
    }
    entry=OverlayEntry(builder:(ctx)=>Positioned(
      top:18,right:18,left:MediaQuery.sizeOf(ctx).width<500?18:null,
      child:ConstrainedBox(
        constraints:const BoxConstraints(maxWidth:380),
        child:Material(
          elevation:8,color:ErpTokens.surface,
          borderRadius:BorderRadius.circular(ErpTokens.cardRadius),
          child:Container(
            decoration:BoxDecoration(
              border:Border(left:BorderSide(
                color:isError?ErpTokens.danger:ErpTokens.fresh,width:4))),
            padding:const EdgeInsets.fromLTRB(12,8,4,8),
            child:Row(children:[
              Icon(isError?Icons.error_outline:Icons.check_circle_outline,
                color:isError?ErpTokens.danger:ErpTokens.primary,size:22),
              const SizedBox(width:10),
              Expanded(child:Text(text,style:const TextStyle(
                color:ErpTokens.ink,fontSize:13,fontWeight:FontWeight.w600))),
              IconButton(onPressed:close,tooltip:'Đóng thông báo',
                icon:const Icon(Icons.close,size:18)),
            ]),
          ),
        ),
      ),
    ));
    overlay.insert(entry);
    timer=Timer(ErpTokens.toastDuration,close);
  }
}
