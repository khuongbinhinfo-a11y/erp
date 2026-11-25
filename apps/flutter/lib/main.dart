import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'ui/erp_shell.dart';
import 'ui/erp_tokens.dart';
import 'ui/erp_login.dart';
import 'ui/identity_client.dart';
import 'ui/session_store.dart';
import 'local/local_store.dart';

Future<ThemeMode> loadErpThemeMode() async {
  try {
    final saved=(await SharedPreferences.getInstance()).getString('erp.themeMode');
    return ThemeMode.values.firstWhere((m)=>m.name==saved,orElse:()=>ThemeMode.system);
  }catch(_){return ThemeMode.system;}
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  String? token;
  try {token=await ErpSessionStore.load();}catch(_){/* Storage unavailable: login normally. */}
  final mode=await loadErpThemeMode();
  runApp(ErpApp(initialToken:token,localStore:ErpLocalStore.platform(),initialThemeMode:mode));
}

class ErpApp extends StatefulWidget {
  final bool previewMode;
  final String? initialToken;
  final ErpIdentityClient? client;
  final ErpLocalStore? localStore;
  final ThemeMode initialThemeMode;
  const ErpApp({super.key,this.previewMode=false,this.initialToken,this.client,this.localStore,this.initialThemeMode=ThemeMode.system});
  @override State<ErpApp> createState()=>_ErpAppState();
}
class _ErpAppState extends State<ErpApp>{
  late final ErpIdentityClient _identity=widget.client??ErpIdentityClient(localStore:widget.localStore);
  IdentitySession? _session;
  bool _preview=false;
  bool _restoring=false;
  bool _restoreBusy=false;
  String? _pendingToken;
  Timer? _reauthorize;
  late ThemeMode _themeMode=widget.initialThemeMode;
  Future<void> _themeWrite=Future.value();
  Future<void> _saveTheme(ThemeMode mode) {
    if(!mounted)return Future.value();
    setState(()=>_themeMode=mode);
    // Serialize cosmetic writes so rapid changes cannot persist an older mode.
    return _themeWrite=_themeWrite.then((_)async{
      try{await (await SharedPreferences.getInstance()).setString('erp.themeMode',mode.name);}catch(_){}
    });
  }

  @override void initState() {
    super.initState();
    if(!widget.previewMode && widget.initialToken!=null){
      _pendingToken=widget.initialToken;
      _restoring=true;
      _restoreBusy=true;
      unawaited(_restore());
    }
  }

  @override void dispose(){
    _reauthorize?.cancel();
    if(widget.client==null)_identity.dispose();
    super.dispose();
  }

  Future<void> _restore() async {
    final token=_pendingToken;
    if(token==null)return;
    if(mounted)setState(()=>_restoreBusy=true);
    try{
      final session=await _identity.restore(token);
      if(mounted&&_pendingToken==token)authenticated(session);
    }on ErpApiError catch(e){
      if(!mounted||_pendingToken!=token)return;
      if(e.status==401||e.status==403){
        await ErpSessionStore.clear();
        if(mounted)setState((){_pendingToken=null;_restoring=false;});
      }else{
        // Network/503 must NOT delete a stored session or force login.
        setState(()=>_restoring=true);
      }
    }catch(_){
      // Offline browser reload: retain token and expose retry, not logout.
      if(mounted)setState(()=>_restoring=true);
    }finally{
      if(mounted&&_pendingToken==token)setState(()=>_restoreBusy=false);
    }
  }

  void authenticated(IdentitySession session){
    _reauthorize?.cancel();
    if(!session.expiresAt.isAfter(DateTime.now()))return;
    setState((){_session=session;_preview=false;_restoring=false;_restoreBusy=false;_pendingToken=null;});
    unawaited(ErpSessionStore.save(session.token).catchError((Object _){}));
    _reauthorize=Timer.periodic(const Duration(minutes:2),(_)=>reauthorize());
  }

  Future<void> reauthorize()async{
    final current=_session;
    if(current==null)return;
    try{
      final fresh=await _identity.refresh(current);
      if(mounted&&_session?.token==current.token)setState(()=>_session=fresh);
    }on ErpApiError catch(e){
      // Only explicit invalidation/disabled account ends the session; transient
      // provider downtime preserves the user's browser session.
      if((e.status==401||e.status==403)&&mounted&&_session?.token==current.token){
        // Session expiry is not an explicit logout: pending business commands
        // remain in the client until the same actor reauthenticates and replays.
        _reauthorize?.cancel();
        setState((){_session=null;_preview=false;_pendingToken=null;});
        try{await ErpSessionStore.clear();}catch(_){}
      }
    }catch(_){/* Retry next health cycle; never logout for offline error. */}
  }

  Future<void> logout()async{
    _reauthorize?.cancel();
    final token=_session?.token;
    final pending=_pendingToken;
    setState((){_session=null;_preview=false;_restoring=false;_restoreBusy=false;_pendingToken=null;});
    try{await ErpSessionStore.clear();}catch(_){/* Local UI cleared. */}
    if(token!=null||pending!=null){
      try{await _identity.logout(token??pending!);}catch(_){/* Local session cleared. */}
    }
  }
  @override Widget build(BuildContext context){
    final view=WidgetsBinding.instance.platformDispatcher.views.first;
    final width=MediaQuery.maybeSizeOf(context)?.width??view.physicalSize.width/view.devicePixelRatio;
    final preview=widget.previewMode||_preview;
    return MaterialApp(
      title:'ERP phân phối',debugShowCheckedModeBanner:false,
      theme:erpTheme(touch:width<=780),
      darkTheme:erpTheme(touch:width<=780,dark:true),
      themeMode:_themeMode,
      themeAnimationDuration:Duration.zero,
      builder:(context,child){
        final dark=Theme.of(context).brightness==Brightness.dark;
        final brandLogin=!_restoring&&!preview&&_session==null;
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value:SystemUiOverlayStyle(
            statusBarColor:Colors.transparent,
            statusBarIconBrightness:(dark||brandLogin)?Brightness.light:Brightness.dark,
            systemNavigationBarColor:brandLogin?ErpTokens.sidebar:ErpPalette.of(context).surface,
            systemNavigationBarIconBrightness:(dark||brandLogin)?Brightness.light:Brightness.dark,
          ),child:child!);
      },
      home:_restoring
        ? Scaffold(body:Center(child:Column(mainAxisSize:MainAxisSize.min,children:[
            if(_restoreBusy)
              const CircularProgressIndicator()
            else
              const Icon(Icons.wifi_off_outlined,size:28),
            const SizedBox(height:14),
            Text(_restoreBusy?'Đang khôi phục phiên ERP...':
              'Tạm mất kết nối ERP. Phiên đăng nhập vẫn được giữ.'),
            const SizedBox(height:16),
            TextButton(onPressed:()=>unawaited(_restore()),child:const Text('Kết nối lại')),
            TextButton(onPressed:()=>unawaited(logout()),child:const Text('Đăng xuất')),
          ])))
        : preview||_session!=null
          ? ErpShell(previewOnly:preview,session:_session,client:_identity,
              onLogout:()=>unawaited(logout()),themeMode:_themeMode,onThemeChanged:(mode)=>unawaited(_saveTheme(mode)))
          : ErpLogin(client:_identity,onAuthenticated:authenticated,
              onPreview:()=>setState(()=>_preview=true),themeMode:_themeMode,onThemeChanged:(mode)=>unawaited(_saveTheme(mode))),
    );
  }
}
