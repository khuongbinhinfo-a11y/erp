import 'package:material_ui/material_ui.dart';
import 'erp_tokens.dart';
import 'identity_client.dart';

class ErpLogin extends StatefulWidget {
  final ErpIdentityClient client;
  final ValueChanged<IdentitySession> onAuthenticated;
  final VoidCallback onPreview;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode>? onThemeChanged;
  const ErpLogin({super.key,required this.client,required this.onAuthenticated,required this.onPreview,this.themeMode=ThemeMode.system,this.onThemeChanged});
  @override State<ErpLogin> createState()=>_ErpLoginState();
}
class _ErpLoginState extends State<ErpLogin>{
  final username=TextEditingController();
  final password=TextEditingController();
  bool hidden=true,busy=false;
  String? error;
  @override void dispose(){username.dispose();password.dispose();super.dispose();}
  Future<void> submit()async{
    if(busy||!widget.client.configured)return;
    setState((){busy=true;error=null;});
    try{
      final result=await widget.client.login(username.text.trim().toLowerCase(),password.text);
      if(mounted)widget.onAuthenticated(result);
    }on ErpApiError catch(e){if(mounted)setState(()=>error=e.message);}
    catch(_){if(mounted)setState(()=>error='Không thể đăng nhập. Vui lòng thử lại.');}
    finally{if(mounted)setState(()=>busy=false);}
  }
  @override Widget build(BuildContext context){
    final compact=MediaQuery.sizeOf(context).width<850;
    final controls=Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      Row(children:[
        Expanded(child:Text('CỔNG TRUY CẬP ERP',style:TextStyle(
          color:ErpPalette.of(context).primary,letterSpacing:1.8,fontSize:11,fontWeight:FontWeight.w900))),
        if(widget.onThemeChanged!=null)ErpThemeSelector(value:widget.themeMode,onChanged:widget.onThemeChanged!),
      ]),
      const SizedBox(height:12),
      Text('Đăng nhập hệ thống',style:Theme.of(context).textTheme.headlineMedium?.copyWith(
        fontWeight:FontWeight.w900,color:ErpPalette.of(context).ink)),
      const SizedBox(height:8),
      Text('Mỗi khách hàng sử dụng tài khoản và dữ liệu riêng biệt.',
        style:TextStyle(color:ErpPalette.of(context).muted,fontSize:14)),
      const SizedBox(height:28),
      TextField(
        key:const ValueKey('login-name'),
        controller:username,
        autofillHints:const [AutofillHints.username],
        textInputAction:TextInputAction.next,
        decoration:const InputDecoration(labelText:'Tên đăng nhập',prefixIcon:Icon(Icons.person_outline)),
      ),
      const SizedBox(height:14),
      TextField(
        key:const ValueKey('login-password'),
        controller:password,
        obscureText:hidden,
        autofillHints:const [AutofillHints.password],
        onSubmitted:(_)=>submit(),
        decoration:InputDecoration(labelText:'Mật khẩu',prefixIcon:const Icon(Icons.lock_outline),
          suffixIcon:IconButton(
            tooltip:hidden?'Hiện mật khẩu':'Ẩn mật khẩu',
            onPressed:()=>setState(()=>hidden=!hidden),
            icon:Icon(hidden?Icons.visibility_outlined:Icons.visibility_off_outlined),
          )),
      ),
      const SizedBox(height:18),
      if(error!=null)...[
        Text(error!,key:const ValueKey('login-error'),
          style:TextStyle(color:ErpPalette.of(context).danger,fontSize:13)),
        const SizedBox(height:14),
      ],
      if(!widget.client.configured)...[
        Text('Hệ thống đang tạm gián đoạn. Vui lòng liên hệ quản trị.',
          style:TextStyle(color:ErpPalette.of(context).warning,fontSize:12)),
        const SizedBox(height:12),
      ],
      SizedBox(width:double.infinity,child:FilledButton.icon(
        key:const ValueKey('login-submit'),
        onPressed:busy||!widget.client.configured?null:submit,
        icon:busy?const SizedBox(width:18,height:18,child:CircularProgressIndicator(strokeWidth:2)):
          const Icon(Icons.login),
        label:const Text('Đăng nhập'),
      )),

    ]);
    return Scaffold(
      backgroundColor: ErpTokens.sidebar,
      body: SizedBox.expand(child: DecoratedBox(
        key: const ValueKey('login-backdrop'),
        decoration: const BoxDecoration(gradient: LinearGradient(
          begin: Alignment.topLeft, end: Alignment.bottomRight,
          colors: [Color(0xFF0B241C), Color(0xFF154E38), Color(0xFF216F4D)],
        )),
        child: Stack(children: [
          Positioned(top: -240, right: -130, child: IgnorePointer(child: Container(
            width: 620, height: 620,
            decoration: BoxDecoration(shape: BoxShape.circle,
              border: Border.all(color: const Color(0x24D7EF8A), width: 2)),
          ))),
          Positioned(bottom: -290, left: -190, child: IgnorePointer(child: Container(
            width: 740, height: 740,
            decoration: BoxDecoration(shape: BoxShape.circle,
              border: Border.all(color: const Color(0x20FFFFFF), width: 2)),
          ))),
          Positioned.fill(child: SafeArea(child: Center(
            child: SingleChildScrollView(
              padding: EdgeInsets.symmetric(
                horizontal: compact ? 16 : 26, vertical: 28),
              child: Center(child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: compact ? 520 : 1040),
                child: Card(
                  elevation: 18,
                  shadowColor: const Color(0x8A071D15),
                  clipBehavior: Clip.antiAlias,
                  child: Row(children: [
                    if (!compact) Expanded(child: SizedBox(
                      height: 545,
                      child: Stack(fit: StackFit.expand, children: [
                        Image.asset(
                          'assets/images/login_logistics.webp',
                          key: const ValueKey('login-panel-photo'),
                          fit: BoxFit.cover,
                          alignment: Alignment.bottomCenter,
                          filterQuality: FilterQuality.medium,
                          excludeFromSemantics: true,
                        ),
                        DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              stops: [0, 0.52, 1],
                              colors: [
                                const Color(0xEF102E24),
                                const Color(0xC4102E24),
                                ErpPalette.of(context).dark?const Color(0xB0102E24):const Color(0x18102E24),
                              ],
                            ),
                          ),
                        ),
                        const Padding(
                          padding: EdgeInsets.all(40),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(children: [
                                Icon(Icons.grid_view_rounded,
                                  color: ErpTokens.lime, size: 34),
                                SizedBox(width: 12),
                                Text('ERP', style: TextStyle(
                                  color: Colors.white, fontSize: 27,
                                  fontWeight: FontWeight.w900)),
                              ]),
                              SizedBox(height: 68),
                              Text('ĐIỀU HÀNH\nKHÔNG GIỚI HẠN',
                                style: TextStyle(color: Colors.white,
                                  fontSize: 29, fontWeight: FontWeight.w900,
                                  height: 1.28)),
                              SizedBox(height: 20),
                              SizedBox(width: 52, child: Divider(
                                color: ErpTokens.lime, thickness: 4)),
                              SizedBox(height: 20),
                              Text('Công Ty · MCP · Quản trị\nBán Lẻ · Giao Hàng · Đặt Hàng',
                                style: TextStyle(color: ErpTokens.sidebarText,
                                  fontSize: 14, height: 1.7)),
                            ],
                          ),
                        ),
                      ]),
                    )),
                    Expanded(child: Padding(
                      padding: EdgeInsets.all(compact ? 24 : 40),
                      child: controls,
                    )),
                  ]),
                ),
              )),
            ),
          ))),
        ]),
      )),
    );
  }
}
