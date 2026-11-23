import 'package:material_ui/material_ui.dart';
import 'erp_tokens.dart';

/// Top-right transient notices; callers still own the server-ACK contract.
abstract final class ErpToast {
  static void show(BuildContext context,String text,{bool isError=false}){
    final overlay=Overlay.maybeOf(context,rootOverlay:true);
    if(overlay==null)return;
    late OverlayEntry entry;
    var removed=false;
    void remove(){
      if(removed)return;
      removed=true;
      entry.remove();
      entry.dispose();
    }
    entry=OverlayEntry(builder:(ctx)=>Positioned(
      top:18,right:18,left:MediaQuery.sizeOf(ctx).width<500?18:null,
      child:ConstrainedBox(
        constraints:const BoxConstraints(maxWidth:380),
        child:ErpToastNotice(
          key:const ValueKey('erp-active-toast'),
          message:text,isError:isError,onDismiss:remove),
      ),
    ));
    overlay.insert(entry);
  }
}

/// One reusable motion pattern for startup and business notifications.
/// Slide/fade in from the right; the green timer runs to zero then exits.
class ErpToastNotice extends StatefulWidget {
  final String? title;
  final String message;
  final bool isError;
  final VoidCallback onDismiss;
  final Key? closeKey;
  const ErpToastNotice({super.key,this.title,required this.message,
    required this.onDismiss,this.closeKey,this.isError=false});

  @override
  State<ErpToastNotice> createState()=>_ErpToastNoticeState();
}

class _ErpToastNoticeState extends State<ErpToastNotice>
    with TickerProviderStateMixin {
  late final AnimationController _entry=AnimationController(
    vsync:this,duration:const Duration(milliseconds:290),
    reverseDuration:const Duration(milliseconds:210));
  // Preserve reading time even when the OS disables decorative animations.
  late final AnimationController _lifetime=AnimationController(
    vsync:this,duration:ErpTokens.toastDuration,
    animationBehavior:AnimationBehavior.preserve);
  late final Animation<double> _fade=CurvedAnimation(
    parent:_entry,curve:Curves.easeOutCubic,reverseCurve:Curves.easeInCubic);
  late final Animation<Offset> _slide=Tween<Offset>(
    begin:const Offset(1.12,0),end:Offset.zero).animate(_fade);
  bool _closing=false;

  @override void initState(){
    super.initState();
    _entry.forward();
    _lifetime.addStatusListener(_onLifetime);
    _lifetime.forward();
  }

  void _onLifetime(AnimationStatus status){
    if(status==AnimationStatus.completed){_dismiss();}
  }

  Future<void> _dismiss() async {
    if(_closing)return;
    _closing=true;
    _lifetime.stop();
    if(MediaQuery.of(context).disableAnimations){
      widget.onDismiss();
      return;
    }
    await _entry.reverse();
    if(mounted)widget.onDismiss();
  }

  @override void dispose(){
    _lifetime.removeStatusListener(_onLifetime);
    _entry.dispose();
    _lifetime.dispose();
    super.dispose();
  }

  @override Widget build(BuildContext context){
    final reduceMotion=MediaQuery.of(context).disableAnimations;
    return Semantics(
      liveRegion:true,
      child:SlideTransition(
        position:reduceMotion?const AlwaysStoppedAnimation(Offset.zero):_slide,
        child:FadeTransition(
          opacity:reduceMotion?const AlwaysStoppedAnimation(1.0):_fade,
          child:Material(
            elevation:10,
            shadowColor:const Color(0x330F3023),
            color:ErpTokens.surface,
            borderRadius:BorderRadius.circular(10),
            clipBehavior:Clip.antiAlias,
            child:Column(mainAxisSize:MainAxisSize.min,children:[
              Container(
                decoration:BoxDecoration(border:Border(left:BorderSide(
                  color:widget.isError?ErpTokens.danger:ErpTokens.fresh,width:4))),
                padding:const EdgeInsets.fromLTRB(12,8,4,8),
                child:Row(mainAxisSize:MainAxisSize.min,children:[
                  Icon(widget.isError?Icons.error_outline:Icons.info_outline,
                    color:widget.isError?ErpTokens.danger:ErpTokens.primary,size:22),
                  const SizedBox(width:10),
                  Expanded(child:Column(
                    crossAxisAlignment:CrossAxisAlignment.start,
                    mainAxisSize:MainAxisSize.min,children:[
                      if(widget.title!=null)Text(widget.title!,
                        style:const TextStyle(color:ErpTokens.ink,
                          fontSize:13,fontWeight:FontWeight.w800)),
                      if(widget.title!=null)const SizedBox(height:3),
                      Text(widget.message,style:TextStyle(
                        color:widget.title==null?ErpTokens.ink:ErpTokens.muted,
                        fontSize:13,height:1.35,
                        fontWeight:widget.title==null
                          ?FontWeight.w600:FontWeight.w400)),
                    ])),
                  IconButton(
                    key:widget.closeKey,
                    onPressed:_dismiss,tooltip:'Đóng thông báo',
                    icon:const Icon(Icons.close,size:18),
                    color:ErpTokens.muted,
                    visualDensity:VisualDensity.compact),
                ]),
              ),
              AnimatedBuilder(animation:_lifetime,builder:(context,_)=>
                LinearProgressIndicator(
                  key:const ValueKey('erp-toast-time-progress'),
                  value:1-_lifetime.value,minHeight:3,
                  backgroundColor:ErpTokens.mint,
                  color:ErpTokens.fresh,
                )),
            ]),
          ),
        ),
      ),
    );
  }
}
