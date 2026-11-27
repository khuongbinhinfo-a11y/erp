import 'dart:async';
import 'package:material_ui/material_ui.dart';

import 'erp_tokens.dart';
import 'erp_navigation_ui.dart';
import 'company_workspace.dart';
import 'retail_pos_workspace.dart';
import 'pos_window_stub.dart' if (dart.library.js_interop) 'pos_window_web.dart';
import 'admin_workspace.dart';
import 'identity_client.dart';
import 'erp_toast.dart';
import 'app_update.dart';

class ErpFeature {
  final String title;
  final String subtitle;
  final IconData icon;
  const ErpFeature(this.title, this.subtitle, this.icon);
}

const erpFeatures = <ErpFeature>[
  ErpFeature('Công Ty', 'Điều hành, chứng từ và báo cáo', Icons.domain_outlined),
  ErpFeature('MCP', 'Tuyến bán hàng và chăm sóc điểm bán', Icons.route_outlined),
  ErpFeature('Quản trị', 'Tài khoản, vai trò và cấu hình', Icons.admin_panel_settings_outlined),
  ErpFeature('Bán Lẻ', 'Giao dịch tại điểm bán', Icons.storefront_outlined),
  ErpFeature('Giao Hàng', 'Chuyến hàng và xác nhận giao nhận', Icons.local_shipping_outlined),
  ErpFeature('Đặt Hàng', 'Giỏ hàng và yêu cầu đặt hàng', Icons.shopping_bag_outlined),
];

class ErpShell extends StatefulWidget {
  final IdentitySession? session;
  final ErpIdentityClient? client;
  final bool previewOnly;
  final VoidCallback? onLogout;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode>? onThemeChanged;
  const ErpShell({super.key,this.session,this.client,this.previewOnly=true,this.onLogout,this.themeMode=ThemeMode.system,this.onThemeChanged});

  @override
  State<ErpShell> createState() => _ErpShellState();
}

class _ErpShellState extends State<ErpShell> {
  int selected = 0;
  late List<int> visibleModules;
  bool collapsed = false;
  bool showIntroToast = true;
  bool companyNavigationLocked = false;
  String? _checkedUpdateSession;
  bool _initialLayout=false;
  CompanySection _mobileSection=CompanySection.overview;


  @override
  void initState() {
    super.initState();
    showIntroToast=widget.previewOnly;
    visibleModules=List<int>.generate(erpFeatures.length,(i)=>i)
      .where((i)=>widget.previewOnly||hasModuleAccess(i)).toList();
    if(visibleModules.isNotEmpty) selected=visibleModules.first;
    _scheduleQuietUpdateCheck();
  }

  bool _isMobile(BuildContext context)=>MediaQuery.sizeOf(context).width<760||erpAndroidUpdateSupported;

  @override void didChangeDependencies(){
    super.didChangeDependencies();
    if(!_initialLayout){
      _initialLayout=true;
      if(!widget.previewOnly&&_isMobile(context)&&visibleModules.contains(3))selected=3;
    }
  }

  @override
  void didUpdateWidget(covariant ErpShell oldWidget){
    super.didUpdateWidget(oldWidget);
    if(oldWidget.session?.token!=widget.session?.token||
       oldWidget.previewOnly!=widget.previewOnly)companyNavigationLocked=false;
    if(oldWidget.session!=widget.session||oldWidget.previewOnly!=widget.previewOnly){
      _scheduleQuietUpdateCheck();
      if(oldWidget.session?.actorId!=widget.session?.actorId)_mobileSection=CompanySection.overview;
      visibleModules=List<int>.generate(erpFeatures.length,(i)=>i)
        .where((i)=>widget.previewOnly||hasModuleAccess(i)).toList();
      if(!canCompanySection(_mobileSection))_mobileSection=CompanySection.overview;
      if(visibleModules.isNotEmpty&&!visibleModules.contains(selected)){
        selected=visibleModules.first;
      }
    }
  }

  void _scheduleQuietUpdateCheck(){
    if(!_canUpdate)return;
    final session=widget.session!;
    if(_checkedUpdateSession==session.token)return;
    _checkedUpdateSession=session.token;
    WidgetsBinding.instance.addPostFrameCallback((_){
      if(!mounted||widget.session?.token!=session.token||!_canUpdate)return;
      unawaited(erpAndroidQuietUpdateVersion(widget.client!,session).then((version){
        if(mounted&&version!=null&&widget.session?.token==session.token&&
          !companyNavigationLocked){
          ErpToast.show(context,'Có bản cập nhật ERP '+version+
            '. Mở menu Cập nhật ứng dụng để xem và cài đặt.');
        }
      }));
    });
  }
  void protectedLogout(){
    if(companyNavigationLocked){
      ErpToast.show(context,
        'Đơn hàng đang xử lý. Hãy kiểm tra xác nhận trên máy chủ trước khi đăng xuất.',
        isError:true);
      return;
    }
    widget.onLogout?.call();
  }
  bool get _canUpdate=>erpAndroidUpdateSupported&&widget.session!=null&&
    widget.client!=null&&!widget.previewOnly;
  Future<void> openUpdate()async{
    if(!_canUpdate)return;
    if(companyNavigationLocked){
      ErpToast.show(context,'Hãy kiểm tra đơn hàng đang xử lý trước khi cập nhật.',isError:true);
      return;
    }
    final session=widget.session!;
    await showErpAndroidUpdate(context,widget.client!,session,
      ()=>mounted&&widget.session?.token==session.token&&widget.session?.actorId==session.actorId&&!companyNavigationLocked);
  }
  void dismissToast() {
    if (showIntroToast) setState(() => showIntroToast = false);
  }

  Widget withToast(Widget content) => Stack(children: [
    Positioned.fill(child: content),
    if (showIntroToast)
      Positioned(
        top: 16,
        right: 16,
        left: MediaQuery.sizeOf(context).width < 500 ? 16 : null,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 370),
          child: _IntroToast(onDismiss: dismissToast),
        ),
      ),
  ]);

  bool canCompanySection(CompanySection section)=>visibleModules.contains(0)&&
    erpCanViewCompanySection(section,widget.session?.grants??const [],previewOnly:widget.previewOnly);

  void _selectSection(CompanySection section){
    if(!canCompanySection(section))return;
    if(selected==0&&_mobileSection==section)return;
    if(companyNavigationLocked){
      ErpToast.show(context,'Đơn hàng đang xử lý. Hãy kiểm tra kết quả trước khi chuyển mục.',isError:true);
      return;
    }
    setState((){selected=0;_mobileSection=section;});
  }

  List<({String label,IconData icon,Object target})> get _mobileDestinations=>[
    if(visibleModules.contains(3))(label:'Bán lẻ',icon:Icons.storefront_outlined,target:3),
    if(canCompanySection(CompanySection.orders))(label:'Đơn hàng',icon:Icons.receipt_long_outlined,target:CompanySection.orders),
    if(canCompanySection(CompanySection.products))(label:'Sản phẩm',icon:Icons.inventory_2_outlined,target:CompanySection.products),
    if(canCompanySection(CompanySection.customers))(label:'Khách hàng',icon:Icons.groups_outlined,target:CompanySection.customers),
    (label:'Thêm',icon:Icons.more_horiz,target:'more'),
  ];

  Future<void> _openMore()async{
    final target=await showModalBottomSheet<Object>(
      context:context,isScrollControlled:true,
      builder:(ctx)=>SafeArea(child:ConstrainedBox(
        constraints:BoxConstraints(maxHeight:MediaQuery.sizeOf(ctx).height*.82),
        child:ListView(key:const ValueKey('erp-mobile-more-list'),shrinkWrap:true,padding:const EdgeInsets.all(12),children:[
          Padding(padding:const EdgeInsets.all(12),child:Text('Thêm',style:Theme.of(ctx).textTheme.titleLarge)),
          if(widget.session!=null)ListTile(
            leading:const Icon(Icons.account_circle_outlined),
            title:Text(widget.session!.loginName),subtitle:const Text('Tài khoản')),
          if(widget.onThemeChanged!=null)ListTile(
            leading:const Icon(Icons.palette_outlined),title:const Text('Giao diện'),
            trailing:ErpThemeSelector(value:widget.themeMode,onChanged:(mode)=>Navigator.pop(ctx,mode))),
          for(final section in CompanySection.values.where((s)=>canCompanySection(s)&&!const [CompanySection.orders,CompanySection.products,CompanySection.customers].contains(s)))
            ListTile(key:ValueKey('erp-mobile-more-${section.name}'),
              leading:Icon(section.icon),title:Text(section.label),
              onTap:()=>Navigator.pop(ctx,section)),
          for(final module in visibleModules.where((i)=>i!=0&&i!=3))
            ListTile(key:ValueKey('erp-mobile-more-module-$module'),leading:Icon(erpFeatures[module].icon),title:Text(erpFeatures[module].title),
              onTap:()=>Navigator.pop(ctx,module)),
          if(_canUpdate)ListTile(key:const ValueKey('erp-android-update'),
            leading:const Icon(Icons.system_update),title:const Text('Cập nhật ứng dụng'),
            onTap:()=>Navigator.pop(ctx,'update')),
          if(widget.onLogout!=null)ListTile(key:const ValueKey('erp-session-exit'),
            leading:const Icon(Icons.logout),title:const Text('Đăng xuất'),
            onTap:()=>Navigator.pop(ctx,'logout')),
        ]),
      )),
    );
    if(!mounted||target==null)return;
    if(target is CompanySection){_selectSection(target);}
    else if(target is ThemeMode){widget.onThemeChanged?.call(target);}
    else if(target is int){select(target);}
    else if(target=='update'){await openUpdate();}
    else if(target=='logout'){protectedLogout();}
  }

  Widget _mobileBar(){
    final destinations=_mobileDestinations;
    if(destinations.length==1)return SafeArea(top:false,child:ListTile(
      key:const ValueKey('erp-mobile-more'),leading:const Icon(Icons.more_horiz),
      title:const Text('Thêm'),onTap:_openMore));
    final index=destinations.indexWhere((d)=>d.target==(selected==0?_mobileSection:selected));
    return NavigationBar(
      key:const ValueKey('erp-mobile-navigation'),
      height:MediaQuery.textScalerOf(context).scale(1)>1.3?80:68,
      selectedIndex:index<0?destinations.length-1:index,
      onDestinationSelected:(i){
        final target=destinations[i].target;
        if(target is CompanySection){_selectSection(target);}
        else if(target is int){select(target);}
        else{unawaited(_openMore());}
      },
      destinations:destinations.map((d)=>NavigationDestination(
        key:ValueKey('erp-mobile-${d.target}'),icon:Icon(d.icon),label:d.label)).toList(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mobile=_isMobile(context);
    if(erpPosStandalone&&!widget.previewOnly){
      // The new tab restores normal same-origin authentication; no URL token.
      return Scaffold(body:widget.session!=null&&widget.client!=null&&hasModuleAccess(3)
        ?RetailPosWorkspace(key:const ValueKey('erp-pos-dedicated-tab'),
          client:widget.client!,session:widget.session!)
        :const Center(child:Text('Không có quyền truy cập quầy Bán Lẻ.')));
    }
    final posFullscreen=mobile&&selected==3&&!widget.previewOnly;
    final desktop = !mobile&&MediaQuery.sizeOf(context).width >= 960;
    // Keep the same keyed Row/Expanded content slot across responsive
    // breakpoints. Moving between desktop and mobile must NOT dispose a
    // pending sales create/update/confirm state machine.
    return Scaffold(
      appBar:desktop||posFullscreen?null:AppBar(toolbarHeight:mobile?52:56,title:Text(visibleModules.isEmpty
        ? 'Truy cập bị giới hạn':mobile&&selected==0?_mobileSection.label:erpFeatures[selected].title),
        actions:[if(widget.onThemeChanged!=null)ErpThemeSelector(value:widget.themeMode,onChanged:widget.onThemeChanged!)]),
      bottomNavigationBar:mobile&&!posFullscreen?_mobileBar():null,
      drawer:desktop||mobile?null:Drawer(
        backgroundColor:ErpPalette.of(context).sidebar,
        child:_Navigation(
          selected:selected,visibleModules:visibleModules,
          onLogout:widget.onLogout==null?null:protectedLogout,
          loginName:widget.session?.loginName,
          onUpdate:_canUpdate?openUpdate:null,
          collapsed:false,
          onSelect:(value){
            Navigator.of(context).pop();
            select(value);
          },
        ),
      ),
      body:withToast(Row(children:[
        if(desktop)AnimatedContainer(
          key:const ValueKey('erp-floating-sidebar-frame'),
          duration:MediaQuery.of(context).disableAnimations
            ?Duration.zero:ErpTokens.drawerMotion,
          curve:Curves.easeOutCubic,
          width:collapsed?96:268,
          // Canvas margins on three sides make the menu a floating surface.
          padding:const EdgeInsets.fromLTRB(12,12,0,12),
          child:Material(
            elevation:13,
            shadowColor:const Color(0x55102E24),
            color:ErpPalette.of(context).sidebar,
            borderRadius:const BorderRadius.only(
              topLeft:Radius.circular(19),
              bottomLeft:Radius.circular(19),
              topRight:Radius.circular(14),
              bottomRight:Radius.circular(14)),
            clipBehavior:Clip.antiAlias,
            child:_Navigation(selected:selected,onSelect:select,
              visibleModules:visibleModules,
              onLogout:widget.onLogout==null?null:protectedLogout,
              loginName:widget.session?.loginName,
          onUpdate:_canUpdate?openUpdate:null,
              themeMode:widget.themeMode,onThemeChanged:widget.onThemeChanged,
              collapsed:collapsed,
              onToggle:()=>setState(()=>collapsed=!collapsed)),
          ),
        ),
        Expanded(key:const ValueKey('erp-content-slot'),
          child:_selectedContent(mobile)),
      ])),
    );
  }

  Widget _selectedContent(bool mobile) {
    if (visibleModules.isEmpty) return Center(child: Text(
      'Chưa có quyền truy cập phân hệ. Liên hệ quản trị viên.',
      style: TextStyle(color: ErpPalette.of(context).ink)));
    final Widget content;
    if (selected == 0) {
      content = CompanyWorkspace(
        previewOnly: widget.previewOnly,
        mobileNavigation:mobile,requestedSection:mobile?_mobileSection:null,
        onSectionChanged:(section){if(mounted&&section!=_mobileSection)setState(()=>_mobileSection=section);},
        grants: widget.session?.grants ?? const [],
        session: widget.session,
        client: widget.client,
        onNavigationLockChanged:(locked){
          if(mounted&&companyNavigationLocked!=locked){
            setState(()=>companyNavigationLocked=locked);
          }
        });
    } else if (selected == 2) {
      content = AdminWorkspace(
        previewOnly: widget.previewOnly, client: widget.client, session: widget.session);
    } else if(selected==3){
      // Dedicated supermarket-style POS surface: no distribution order list
      // or order form is mounted in the Bán Lẻ module.
      content=widget.previewOnly||widget.client==null||widget.session==null
        ?const _MobileRetailEntry()
        :RetailPosWorkspace(
            key:const ValueKey('erp-mobile-retail-workspace'),
            client:widget.client!,session:widget.session!,
            onOpenTab:erpPosWebSupported&&!erpPosStandalone?erpOpenPosTab:null,
            onExit:mobile&&visibleModules.any((i)=>i!=3)
              ?()=>select(visibleModules.firstWhere((i)=>i!=3)):null);
    } else {
      content = _FeaturePage(feature: erpFeatures[selected],mobile:mobile);
    }
    return AnimatedSwitcher(
      duration: MediaQuery.of(context).disableAnimations
        ? Duration.zero : ErpTokens.pageMotion,
      reverseDuration: MediaQuery.of(context).disableAnimations
        ? Duration.zero : const Duration(milliseconds: 100),
      layoutBuilder: erpStableSwitcherLayout,
      transitionBuilder: erpFadeSwitcher,
      child: KeyedSubtree(key: ValueKey('erp-module-$selected'), child: content));
  }

  bool hasModuleAccess(int index){
    final grants=widget.session?.grants??const <IdentityGrant>[];
    bool allowed(String prefix)=>grants.any((g)=>g.permission.startsWith(prefix));
    return switch(index){
      0=>allowed('catalog.')||allowed('orders.')||allowed('inventory.')||allowed('finance.')||allowed('purchase.')||allowed('reports.'),
      1=>allowed('orders.')||allowed('catalog.'),
      2=>allowed('identity.'),
      3=>allowed('orders.create'),
      4=>allowed('delivery.'),
      5=>allowed('orders.create'),
      _=>false,
    };
  }
  void select(int index) {
    if(index!=selected&&companyNavigationLocked){
      ErpToast.show(context,
        'Đơn hàng đang xử lý. Hãy kiểm tra kết quả trước khi chuyển phân hệ.',
        isError:true);
      return;
    }
    if (visibleModules.contains(index)&&index != selected) setState(() {selected=index;if(index==0)_mobileSection=CompanySection.overview;});
  }
}

class _IntroToast extends StatelessWidget {
  final VoidCallback onDismiss;
  const _IntroToast({required this.onDismiss});

  @override
  Widget build(BuildContext context) => ErpToastNotice(
    key:const ValueKey('erp-startup-toast'),
    title:'Đang xem giao diện',
    message:'Hãy đăng nhập để sử dụng chức năng.',
    onDismiss:onDismiss,
    closeKey:const ValueKey('erp-toast-close'),
  );
}

/// Concave-right selection outline inspired by the supplied navigation
/// reference. The color stays inside ERP's green palette.
class _SidebarWavePainter extends CustomPainter {
  final double progress;
  final bool dark;
  const _SidebarWavePainter(this.progress,this.dark);
  @override void paint(Canvas canvas,Size size){
    if(progress<=0.001)return;
    final w=size.width,h=size.height;
    final shape=Path()
      ..moveTo(15,1)
      ..quadraticBezierTo(1,1,1,13)
      ..lineTo(1,h-13)
      ..quadraticBezierTo(1,h-1,15,h-1)
      ..lineTo(w-27,h-1)
      ..cubicTo(w-17,h-1,w-14,h-10,w-10,h-16)
      ..cubicTo(w-5,h-21,w-2,h-23,w-2,h/2)
      ..cubicTo(w-2,h-23,w-5,21,w-10,16)
      ..cubicTo(w-14,10,w-17,1,w-27,1)
      ..close();
    final shader=LinearGradient(
      begin:Alignment.centerLeft,end:Alignment.centerRight,
      // Gentle translucent wave over the dark ERP green.
      colors:dark?const [Color(0xFF294D38),Color(0xFF253E30)]:const [Color(0xC0F1FFF2),Color(0xB8D7F2E0)],
    ).createShader(Offset.zero & size);
    canvas.drawPath(shape,Paint()
      ..shader=shader..color=Color.fromRGBO(255,255,255,progress));
    canvas.drawPath(shape,Paint()
      ..color=Color.fromRGBO(110,205,151,progress*.34)
      ..style=PaintingStyle.stroke..strokeWidth=1);
  }
  @override bool shouldRepaint(covariant _SidebarWavePainter old)=>
    old.progress!=progress||old.dark!=dark;
}

/// Real pointer hover and active-tab transitions share a single entry.
class _SidebarNavTile extends StatefulWidget {
  final int index;
  final ErpFeature feature;
  final bool compact;
  final bool active;
  final ValueChanged<int> onSelect;
  const _SidebarNavTile({super.key,required this.index,required this.feature,
    required this.compact,required this.active,required this.onSelect});
  @override State<_SidebarNavTile> createState()=>_SidebarNavTileState();
}
class _SidebarNavTileState extends State<_SidebarNavTile>{
  bool hovered=false;
  @override Widget build(BuildContext context){
    final noMotion=MediaQuery.of(context).disableAnimations;
    final duration=noMotion?Duration.zero:ErpTokens.menuMotion;
    final active=widget.active;
    final compact=widget.compact;
    final index=widget.index;
    return Padding(
      padding:const EdgeInsets.symmetric(vertical:3),
      child:Tooltip(message:compact?widget.feature.title:'',
        child:Semantics(selected:active,button:true,
          // InkWell remains still; only its contents slide on hover.
          // Moving the hit-test region would flicker at the left edge.
          child:AnimatedContainer(
            key:ValueKey('erp-nav-surface-$index'),
            duration:duration,curve:Curves.easeOutCubic,
            decoration:BoxDecoration(
              color:!active&&hovered?const Color(0xFF24563E):Colors.transparent,
              borderRadius:BorderRadius.circular(12)),
            child:TweenAnimationBuilder<double>(
              key:ValueKey('erp-nav-selection-$index'),
              tween:Tween<double>(begin:0,end:active?1:0),
              duration:duration,curve:Curves.easeOutCubic,
              builder:(context,amount,child)=>CustomPaint(
                painter:_SidebarWavePainter(amount,ErpPalette.of(context).dark),
                child:child),
              child:Material(
                color:Colors.transparent,
                child:InkWell(
                  key:ValueKey('nav-$index'),
                  onTap:()=>widget.onSelect(index),
                  onHover:(v){if(mounted&&v!=hovered)setState(()=>hovered=v);},
                  borderRadius:BorderRadius.circular(12),
                  child:AnimatedSlide(
                    key:ValueKey('erp-nav-motion-$index'),
                    duration:duration,curve:Curves.easeOutCubic,
                    offset:hovered&&!active&&!noMotion
                      ?const Offset(.035,0):Offset.zero,
                    child:Row(children:[
                      SizedBox(height:54,width:compact?3:7),
                      AnimatedScale(
                        duration:duration,curve:Curves.easeOutBack,
                        scale:active?1.10:(hovered?1.08:1),
                        child:AnimatedContainer(
                          duration:duration,curve:Curves.easeOutCubic,
                          width:39,height:39,
                          alignment:Alignment.center,
                          decoration:BoxDecoration(
                            color:active?ErpPalette.of(context).action
                              :(hovered?const Color(0xFF2D8860):Colors.transparent),
                            shape:BoxShape.circle,
                            boxShadow:active?[
                              BoxShadow(color:const Color(0x8825B97B),
                                blurRadius:11,spreadRadius:1),
                            ]:const []),
                          child:Icon(widget.feature.icon,
                            color:active||hovered
                              ?Colors.white:ErpTokens.sidebarText,size:20),
                        ),
                      ),
                      if(!compact)...[
                        const SizedBox(width:10),
                        Expanded(child:Text(widget.feature.title,
                          maxLines:1,overflow:TextOverflow.ellipsis,
                          style:TextStyle(
                            color:active?ErpPalette.of(context).onSidebarActive
                              :(hovered?ErpTokens.lime:Colors.white),
                            fontSize:14,
                            fontWeight:active?FontWeight.w800:FontWeight.w500))),
                        if(active)Icon(Icons.chevron_right,
                          size:19,color:ErpPalette.of(context).onSidebarActive),
                        const SizedBox(width:12),
                      ],
                    ]),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Navigation extends StatelessWidget {
  final int selected;
  final ValueChanged<int> onSelect;
  final List<int> visibleModules;
  final VoidCallback? onLogout;
  final String? loginName;
  final VoidCallback? onUpdate;
  final bool collapsed;
  final VoidCallback? onToggle;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode>? onThemeChanged;
  const _Navigation({required this.selected, required this.onSelect,
    required this.visibleModules, required this.collapsed, this.onToggle,
    this.onLogout,this.loginName,this.onUpdate,this.themeMode=ThemeMode.system,this.onThemeChanged});

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder:(context,limits){
    final compact=collapsed||limits.maxWidth<160;
    return DecoratedBox(
    decoration: BoxDecoration(gradient: LinearGradient(
      begin: Alignment.topLeft, end: Alignment.bottomRight,
      colors: [ErpPalette.of(context).sidebar, ErpPalette.of(context).sidebarBottom],
    )),
    child: SafeArea(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: EdgeInsets.fromLTRB(compact?2:16,16,compact?2:10,18),
        child: Row(children: [
          SizedBox(
            key:const ValueKey('erp-sidebar-logo'),
            height:compact?36:45,width:compact?36:45,
            child:Image.asset('assets/images/erp_sidebar_logo.webp',
              fit:BoxFit.contain,semanticLabel:'Biểu tượng ERP',
              filterQuality:FilterQuality.medium),
          ),
          if (!compact) ...[
            const SizedBox(width: 10),
            const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('ERP', style: TextStyle(color: Colors.white, fontSize: 21,
                fontWeight: FontWeight.w800)),
              Text('product by KB', style: TextStyle(color: ErpTokens.sidebarText,
                fontSize: 10, letterSpacing: 1.35)),
            ])),
          ],
          if(onToggle!=null)SizedBox(
            width:32,height:40,
            child:IconButton(
              key:const ValueKey('erp-sidebar-toggle'),
              constraints:const BoxConstraints.tightFor(width:32,height:40),
              visualDensity:VisualDensity.compact,
              padding:EdgeInsets.zero,
              iconSize:18,
              tooltip:compact?'Mở rộng menu':'Thu gọn menu',
              onPressed:onToggle,
              icon:Icon(compact?Icons.keyboard_double_arrow_right:
                Icons.keyboard_double_arrow_left,color:ErpTokens.sidebarText))),
        ]),
      ),
      if (!compact)
        const Padding(padding: EdgeInsets.fromLTRB(20, 10, 8, 8),
          child: Text('KHÔNG GIAN LÀM VIỆC', style: TextStyle(color: Color(0xFFA7BDB0),
            fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 1.1))),
      Expanded(child: ListView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 9),
        itemCount: visibleModules.length,
        itemBuilder: (context, position) {
          final index=visibleModules[position];
          final feature = erpFeatures[index];
          return _SidebarNavTile(
            key:ValueKey('erp-nav-tile-$index'),
            index:index,feature:feature,active:selected==index,
            compact:compact,onSelect:onSelect);
        },
      )),
      if(onThemeChanged!=null)Align(alignment:Alignment.centerLeft,child:IconTheme(
        data:const IconThemeData(color:ErpTokens.sidebarText),
        child:ErpThemeSelector(value:themeMode,onChanged:onThemeChanged!))),
      if(onUpdate!=null)ListTile(
        key:const ValueKey('erp-android-update'),
        leading:const Icon(Icons.system_update,color:ErpTokens.lime),
        title:compact?null:const Text('Cập nhật ứng dụng',style:TextStyle(color:ErpTokens.sidebarText)),
        onTap:onUpdate),
      const Divider(color: Color(0xFF4F7860), height: 1),
      if(onLogout!=null)
        Padding(
          padding:EdgeInsets.symmetric(horizontal:compact?6:12,vertical:10),
          child:Row(children:[
            if(!compact)...[
              const Icon(Icons.account_circle_outlined,
                size:22,color:ErpTokens.sidebarText),
              const SizedBox(width:9),
              Expanded(child:Text(
                (loginName?.trim().isNotEmpty??false)?loginName!:'Chế độ xem',
                key:const ValueKey('erp-current-user'),
                maxLines:1,overflow:TextOverflow.ellipsis,
                style:const TextStyle(color:Colors.white,fontSize:13,
                  fontWeight:FontWeight.w700))),
            ],
            IconButton(
              key:const ValueKey('erp-session-exit'),
              tooltip:'Đăng xuất',
              onPressed:onLogout,
              icon:const Icon(Icons.logout,color:ErpTokens.lime,size:20),
            ),
          ]),
        )
      else
        const Padding(padding: EdgeInsets.all(18),
          child: Text('ERP · product by KB',
            style: TextStyle(color: ErpTokens.sidebarText,
              letterSpacing: 1.3, fontSize: 10))),
    ])),
    );
  });
}

class _FeaturePage extends StatelessWidget {
  final ErpFeature feature;
  final bool mobile;
  const _FeaturePage({required this.feature,this.mobile=false});

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      if(!mobile)Padding(padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
        child: ErpPageHeader(
          heading: feature.title, subtitle: feature.subtitle, icon: feature.icon))
      else Padding(padding:const EdgeInsets.fromLTRB(16,8,16,0),child:Text(feature.subtitle)),
      Expanded(child: SingleChildScrollView(
        padding: EdgeInsets.all(mobile?12:24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const SizedBox(height: 20),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(Icons.table_chart_outlined, color: ErpPalette.of(context).primary),
                    SizedBox(width: 8),
                    Expanded(child: Text('Danh sách nghiệp vụ',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: ErpPalette.of(context).ink))),
                  ]),
                  const SizedBox(height: 12),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(ErpTokens.controlRadius),
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border(top: BorderSide(color: ErpPalette.of(context).fresh, width: 3)),
                      ),
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: DataTable(
                          headingRowColor: WidgetStatePropertyAll(ErpPalette.of(context).mint),
                          headingTextStyle: TextStyle(color: ErpPalette.of(context).ink, fontWeight: FontWeight.w700),
                          columns: const [
                            DataColumn(label: Text('Mã chứng từ')),
                            DataColumn(label: Text('Ngày lập')),
                            DataColumn(label: Text('Trạng thái')),
                            DataColumn(label: Text('Người phụ trách')),
                          ],
                          rows: const [],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Center(
                    child: Padding(
                      padding: EdgeInsets.symmetric(vertical: 18),
                      child: Column(children: [
                        Icon(Icons.inbox_outlined, color: ErpPalette.of(context).muted, size: 30),
                        SizedBox(height: 8),
                        Text('Chưa có thông tin',
                          style: TextStyle(color: ErpPalette.of(context).ink, fontWeight: FontWeight.w600)),
                        SizedBox(height: 4),
                        Text('',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: ErpPalette.of(context).muted, fontSize: 13)),
                      ]),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ]),
      )),
    ]);
  }
}

class _MobileRetailEntry extends StatelessWidget {
  const _MobileRetailEntry();
  @override Widget build(BuildContext context)=>ListView(
    padding:const EdgeInsets.all(16),children:[
      const Text('Quầy Bán Lẻ có giỏ và tra giá riêng. Thanh toán chỉ mở khi API POS xuất kho và thu tiền được kiểm chứng.'),
    ],
  );
}
