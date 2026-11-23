import 'package:material_ui/material_ui.dart';

import 'erp_tokens.dart';
import 'erp_navigation_ui.dart';
import 'company_workspace.dart';
import 'admin_workspace.dart';
import 'identity_client.dart';
import 'erp_toast.dart';

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
  const ErpShell({super.key,this.session,this.client,this.previewOnly=true,this.onLogout});

  @override
  State<ErpShell> createState() => _ErpShellState();
}

class _ErpShellState extends State<ErpShell> {
  int selected = 0;
  late List<int> visibleModules;
  bool collapsed = false;
  bool showIntroToast = true;
  bool companyNavigationLocked = false;

  @override
  void initState() {
    super.initState();
    showIntroToast=widget.previewOnly;
    visibleModules=List<int>.generate(erpFeatures.length,(i)=>i)
      .where((i)=>widget.previewOnly||hasModuleAccess(i)).toList();
    if(visibleModules.isNotEmpty) selected=visibleModules.first;
  }

  @override
  void didUpdateWidget(covariant ErpShell oldWidget){
    super.didUpdateWidget(oldWidget);
    if(oldWidget.session?.token!=widget.session?.token||
       oldWidget.previewOnly!=widget.previewOnly)companyNavigationLocked=false;
    if(oldWidget.session!=widget.session||oldWidget.previewOnly!=widget.previewOnly){
      visibleModules=List<int>.generate(erpFeatures.length,(i)=>i)
        .where((i)=>widget.previewOnly||hasModuleAccess(i)).toList();
      if(visibleModules.isNotEmpty&&!visibleModules.contains(selected)){
        selected=visibleModules.first;
      }
    }
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

  @override
  Widget build(BuildContext context) {
    final desktop = MediaQuery.sizeOf(context).width >= 960;
    // Keep the same keyed Row/Expanded content slot across responsive
    // breakpoints. Moving between desktop and mobile must NOT dispose a
    // pending sales create/update/confirm state machine.
    return Scaffold(
      appBar:desktop?null:AppBar(title:Text(visibleModules.isEmpty
        ? 'Truy cập bị giới hạn':erpFeatures[selected].title)),
      drawer:desktop?null:Drawer(
        backgroundColor:ErpTokens.sidebar,
        child:_Navigation(
          selected:selected,visibleModules:visibleModules,
          onLogout:widget.onLogout==null?null:protectedLogout,
          loginName:widget.session?.loginName,
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
            color:ErpTokens.sidebar,
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
              collapsed:collapsed,
              onToggle:()=>setState(()=>collapsed=!collapsed)),
          ),
        ),
        Expanded(key:const ValueKey('erp-content-slot'),
          child:_selectedContent()),
      ])),
    );
  }

  Widget _selectedContent() {
    if (visibleModules.isEmpty) return const Center(child: Text(
      'Chưa có quyền truy cập phân hệ. Liên hệ quản trị viên.',
      style: TextStyle(color: ErpTokens.ink)));
    final Widget content;
    if (selected == 0) {
      content = CompanyWorkspace(
        previewOnly: widget.previewOnly,
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
    } else {
      content = _FeaturePage(feature: erpFeatures[selected]);
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
      0=>allowed('catalog.')||allowed('orders.')||allowed('inventory.')||allowed('finance.'),
      1=>allowed('orders.')||allowed('catalog.'),
      2=>allowed('identity.'),
      3=>allowed('orders.create'),
      4=>allowed('delivery.'),
      5=>allowed('orders.create'),
      _=>false,
    };
  }
  void select(int index) {
    if(index!=selected&&selected==0&&companyNavigationLocked){
      ErpToast.show(context,
        'Đơn hàng đang xử lý. Hãy kiểm tra kết quả trước khi chuyển phân hệ.',
        isError:true);
      return;
    }
    if (visibleModules.contains(index)&&index != selected) setState(() => selected = index);
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

class _RrpMarkPainter extends CustomPainter {
  const _RrpMarkPainter();

  @override
  void paint(Canvas canvas, Size size) {
    // Draw an original geometric route/box mark at device-native resolution.
    // Paths stay sharp in the expanded and collapsed sidebar on Retina.
    canvas.save();
    canvas.scale(size.width / 32, size.height / 32);
    final paint = Paint()
      ..color = ErpTokens.sidebar
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final path = Path()
      ..moveTo(5, 25)
      ..lineTo(5, 7)
      ..lineTo(12, 7)
      ..quadraticBezierTo(19, 7, 19, 13)
      ..quadraticBezierTo(19, 19, 12, 19)
      ..lineTo(5, 19)
      ..moveTo(13, 19)
      ..lineTo(19, 26)
      ..moveTo(23, 7)
      ..lineTo(28, 7)
      ..lineTo(28, 19)
      ..lineTo(23, 19)
      ..moveTo(23, 19)
      ..lineTo(23, 26);
    canvas.drawPath(path, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _RrpMarkPainter oldDelegate) => false;
}

class _Navigation extends StatelessWidget {
  final int selected;
  final ValueChanged<int> onSelect;
  final List<int> visibleModules;
  final VoidCallback? onLogout;
  final String? loginName;
  final bool collapsed;
  final VoidCallback? onToggle;
  const _Navigation({required this.selected, required this.onSelect,
    required this.visibleModules, required this.collapsed, this.onToggle,
    this.onLogout,this.loginName});

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder:(context,limits){
    final compact=collapsed||limits.maxWidth<160;
    return DecoratedBox(
    decoration: const BoxDecoration(gradient: LinearGradient(
      begin: Alignment.topLeft, end: Alignment.bottomRight,
      colors: [ErpTokens.sidebar, ErpTokens.sidebarBottom],
    )),
    child: SafeArea(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: EdgeInsets.fromLTRB(compact?2:16,16,compact?2:10,18),
        child: Row(children: [
          Container(
            key:const ValueKey('erp-sidebar-logo'),
            height:compact?32:39,width:compact?32:39,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: ErpTokens.lime,
              borderRadius: BorderRadius.circular(5)),
            child: const CustomPaint(size: Size(26, 26),
              painter: _RrpMarkPainter()),
          ),
          if (!compact) ...[
            const SizedBox(width: 10),
            const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('RRP', style: TextStyle(color: Colors.white, fontSize: 21,
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
          final active = selected == index;
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Tooltip(message: compact ? feature.title : '',
              child: Semantics(
                selected: active,
                button: true,
                child: AnimatedContainer(
                  key:ValueKey('erp-nav-surface-$index'),
                  duration:MediaQuery.of(context).disableAnimations
                    ?Duration.zero:ErpTokens.menuMotion,
                  curve:Curves.easeOutCubic,
                  decoration:BoxDecoration(
                    color:active?const Color(0xFF285C42):Colors.transparent,
                    borderRadius:BorderRadius.circular(13),
                    border:Border.all(color:active
                      ?const Color(0x667CCB9D):Colors.transparent)),
                  child:Material(
                    color:Colors.transparent,
                    child:InkWell(
                      key: ValueKey('nav-$index'),
                      borderRadius: BorderRadius.circular(13),
                      onTap: () => onSelect(index),
                      child: Row(children: [
                        SizedBox(height:46,width:compact?3:7),
                        AnimatedContainer(
                          duration:MediaQuery.of(context).disableAnimations
                            ?Duration.zero:ErpTokens.menuMotion,
                          curve:Curves.easeOutBack,
                          width:compact?37:35,height:35,
                          alignment:Alignment.center,
                          decoration:BoxDecoration(
                            color:active?ErpTokens.fresh:Colors.transparent,
                            shape:BoxShape.circle),
                          child:Icon(feature.icon,color:active
                            ?Colors.white:ErpTokens.sidebarText,size:20)),
                        if (!compact) ...[
                          const SizedBox(width: 10),
                          Expanded(child: Text(feature.title,
                            maxLines:1,overflow:TextOverflow.ellipsis,
                            style: TextStyle(color: Colors.white, fontSize: 14,
                              fontWeight: active ? FontWeight.w800 : FontWeight.w500))),
                          if (active)const Icon(Icons.chevron_right,
                            color: ErpTokens.lime, size: 18),
                          const SizedBox(width: 8),
                        ],
                      ]),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      )),
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
          child: Text('RRP · product by KB',
            style: TextStyle(color: ErpTokens.sidebarText,
              letterSpacing: 1.3, fontSize: 10))),
    ])),
    );
  });
}

class _FeaturePage extends StatelessWidget {
  final ErpFeature feature;
  const _FeaturePage({required this.feature});

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Padding(padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
        child: ErpPageHeader(
          heading: feature.title, subtitle: feature.subtitle, icon: feature.icon)),
      Expanded(child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const SizedBox(height: 20),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(children: [
                    Icon(Icons.table_chart_outlined, color: ErpTokens.primary),
                    SizedBox(width: 8),
                    Expanded(child: Text('Danh sách nghiệp vụ',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: ErpTokens.ink))),
                  ]),
                  const SizedBox(height: 12),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(ErpTokens.controlRadius),
                    child: Container(
                      decoration: const BoxDecoration(
                        border: Border(top: BorderSide(color: ErpTokens.fresh, width: 3)),
                      ),
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: DataTable(
                          headingRowColor: const WidgetStatePropertyAll(ErpTokens.mint),
                          headingTextStyle: const TextStyle(color: ErpTokens.ink, fontWeight: FontWeight.w700),
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
                  const Center(
                    child: Padding(
                      padding: EdgeInsets.symmetric(vertical: 18),
                      child: Column(children: [
                        Icon(Icons.inbox_outlined, color: ErpTokens.muted, size: 30),
                        SizedBox(height: 8),
                        Text('Chưa có thông tin',
                          style: TextStyle(color: ErpTokens.ink, fontWeight: FontWeight.w600)),
                        SizedBox(height: 4),
                        Text('',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: ErpTokens.muted, fontSize: 13)),
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
