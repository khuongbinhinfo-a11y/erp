import 'package:material_ui/material_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:erp_distribution/main.dart';
import 'package:erp_distribution/ui/erp_shell.dart';
import 'package:erp_distribution/ui/company_workspace.dart';
import 'package:erp_distribution/ui/identity_client.dart';

void main() {
  testWidgets('ERP shell shows safe empty state and main module', (tester) async {
    await tester.pumpWidget(const ErpApp(previewMode:true));
    expect(find.text('Tổng quan điều hành'), findsOneWidget);
    expect(find.text('Chưa có dữ liệu đối soát'), findsNWidgets(4));
    expect(find.text('Công Ty'), findsWidgets);
  });

  testWidgets('mobile shell opens bottom navigation and More modules', (tester) async {
    tester.view.devicePixelRatio=1;
    tester.view.physicalSize=const Size(390,844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const ErpApp(previewMode:true));
    await tester.tap(find.byKey(const ValueKey('erp-mobile-more')));
    await tester.pumpAndSettle();
    final scroll=find.descendant(of:find.byKey(const ValueKey('erp-mobile-more-list')),matching:find.byType(Scrollable)).first;
    for(final module in [1,4,5]){
      final target=find.byKey(ValueKey('erp-mobile-more-module-$module'));
      await tester.scrollUntilVisible(target,150,scrollable:scroll);
      expect(target,findsOneWidget);
    }
    expect(find.byType(Drawer),findsNothing);
  });

  // P0 UI regression: navigate without ever displaying fabricated business records.
testWidgets('Công Ty quick navigation opens typed empty register and search is local', (tester) async {
  await tester.pumpWidget(const ErpApp(previewMode:true));
  final quick = find.byKey(const ValueKey('quick-customers'));
  await tester.ensureVisible(quick);
  await tester.tap(quick);
  await tester.pumpAndSettle();
  expect(find.text('Danh mục khách hàng'), findsOneWidget);
  expect(find.text('Chưa có dữ liệu'), findsOneWidget);
  expect(find.text('Tạo mới'), findsOneWidget);
  await tester.enterText(find.byKey(const ValueKey('company-search')), 'KH-001');
  await tester.pumpAndSettle();
  expect(find.text('Không có dữ liệu để tìm với từ khóa: KH-001'), findsOneWidget);
});

testWidgets('Quản trị shows roles as read-only and does not invent users', (tester) async {
  tester.view.devicePixelRatio=1;
  tester.view.physicalSize=const Size(390,844);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(const ErpApp(previewMode:true));
  await tester.tap(find.byKey(const ValueKey('erp-mobile-more')));
  await tester.pumpAndSettle();
  final moreScroll=find.descendant(of:find.byKey(const ValueKey('erp-mobile-more-list')),matching:find.byType(Scrollable)).first;
  final admin=find.byKey(const ValueKey('erp-mobile-more-module-2'));
  await tester.scrollUntilVisible(admin,150,scrollable:moreScroll);
  // Extra tier adds a row: bring tap target clear of the modal viewport edge.
  await tester.drag(moreScroll,const Offset(0,-120));
  await tester.pumpAndSettle();
  await tester.tap(admin);
  await tester.pumpAndSettle();
  expect(find.text('Tổ chức, tài khoản, quyền và chính sách'), findsOneWidget);
  expect(find.text('Không có quyền quản lý tổ chức.'), findsOneWidget);
  // The non-modal startup toast closes before interacting with pinned tabs.
  await tester.pump(const Duration(seconds: 5));
  await tester.pump(const Duration(milliseconds: 250));
  expect(find.byKey(const ValueKey('erp-startup-toast')), findsNothing);
  await tester.tap(find.byKey(const ValueKey('admin-1')));
  await tester.pumpAndSettle();
  expect(find.text('Tài khoản người dùng'), findsOneWidget);
  expect(find.text('Chưa có dữ liệu'), findsOneWidget);
  expect(find.byKey(const ValueKey('admin-2')),findsOneWidget);
});

  testWidgets('old persistent notices are replaced by a dismissible upper-right toast', (tester) async {
    await tester.pumpWidget(const ErpApp(previewMode:true));
    expect(find.byKey(const ValueKey('erp-startup-toast')), findsOneWidget);
    expect(find.text('Đang xem giao diện'), findsOneWidget);
    // The notice starts off-canvas; wait for the entrance before tapping.
    await tester.pump(const Duration(milliseconds:16));
    await tester.pump(const Duration(milliseconds:320));
    await tester.tap(find.byKey(const ValueKey('erp-toast-close')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds:260));
    expect(find.byKey(const ValueKey('erp-startup-toast')), findsNothing);
    expect(find.text('Tổng quan điều hành'), findsOneWidget);
  });

  testWidgets('toast auto dismisses once and never reappears on navigation', (tester) async {
    tester.view.devicePixelRatio=1;
    tester.view.physicalSize=const Size(390,844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const ErpApp(previewMode:true));
    expect(find.byKey(const ValueKey('erp-startup-toast')), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byKey(const ValueKey('erp-startup-toast')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('erp-mobile-more')));
    await tester.pumpAndSettle();
    final moreScroll=find.descendant(of:find.byKey(const ValueKey('erp-mobile-more-list')),matching:find.byType(Scrollable)).first;
    final mcp=find.byKey(const ValueKey('erp-mobile-more-module-1'));
    await tester.scrollUntilVisible(mcp,150,scrollable:moreScroll);
    await tester.tap(mcp);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('erp-startup-toast')), findsNothing);
  });

  testWidgets('desktop sidebar collapses without losing administration navigation', (tester) async {
    // Set the actual test view metrics; shell breakpoint depends on MediaQuery.
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1600, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const ErpApp(previewMode:true));
    expect(tester.view.physicalSize.width / tester.view.devicePixelRatio, greaterThan(960));
    expect(find.text('ERP'), findsOneWidget);
    expect(find.text('RRP'), findsNothing);
    final logoAsset=find.descendant(
      of:find.byKey(const ValueKey('erp-sidebar-logo')),
      matching:find.byType(Image));
    expect(logoAsset,findsOneWidget);
    expect((tester.widget<Image>(logoAsset).image as AssetImage).assetName,
      'assets/images/erp_sidebar_logo.webp');
    expect(find.text('product by KB'), findsOneWidget);
    expect(find.byType(CustomPaint), findsWidgets);
    final toggle=find.byKey(const ValueKey('erp-sidebar-toggle'));
    final logo=find.byKey(const ValueKey('erp-sidebar-logo'));
    expect(toggle,findsOneWidget);
    expect(tester.getRect(toggle).center.dy,lessThan(tester.getRect(logo).bottom),
      reason:'Nút thu gọn phải nằm cạnh logo ở đầu menu');
    expect(tester.getRect(toggle).left,greaterThan(tester.getRect(logo).right));
    await tester.tap(toggle);
    await tester.pump();
    expect(find.byKey(const ValueKey('nav-0')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('nav-2')));
    await tester.pumpAndSettle();
    expect(find.text('Tổ chức, tài khoản, quyền và chính sách'), findsOneWidget);
  });

  testWidgets('desktop sidebar floats on three canvas edges and animates collapse',
    (tester)async{
    tester.view.devicePixelRatio=1;
    tester.view.physicalSize=const Size(1280,800);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const ErpApp(previewMode:true));
    final frame=find.byKey(const ValueKey('erp-floating-sidebar-frame'));
    expect(frame,findsOneWidget);
    final menu=find.descendant(of:frame,matching:find.byType(Material)).first;
    final bounds=tester.getRect(menu);
    expect(bounds.left,greaterThanOrEqualTo(12));
    expect(bounds.top,greaterThanOrEqualTo(12));
    expect(bounds.bottom,lessThanOrEqualTo(788));
    expect(tester.widget<Material>(menu).elevation,greaterThan(0));
    final expandedWidth=tester.getSize(frame).width;
    await tester.tap(find.byKey(const ValueKey('erp-sidebar-toggle')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds:340));
    expect(tester.getSize(frame).width,lessThan(expandedWidth));
    expect(find.byKey(const ValueKey('erp-nav-surface-0')),findsOneWidget);
    expect(find.byKey(const ValueKey('nav-2')),findsOneWidget);
  });

  testWidgets('hover moves unselected tab and selected tab has curved surface',
    (tester)async{
    tester.view.devicePixelRatio=1;
    tester.view.physicalSize=const Size(1440,900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const ErpApp(previewMode:true));
    await tester.pump();
    await tester.pump(const Duration(milliseconds:260));
    expect(find.byKey(const ValueKey('erp-nav-selection-0')),findsOneWidget);
    final moving=find.byKey(const ValueKey('erp-nav-motion-1'));
    expect(tester.widget<AnimatedSlide>(moving).offset,Offset.zero);
    final mouse=await tester.createGesture(kind:PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location:const Offset(800,800));
    await mouse.moveTo(tester.getCenter(find.byKey(const ValueKey('nav-1'))));
    await tester.pump();
    expect(tester.widget<AnimatedSlide>(moving).offset.dx,greaterThan(0),
      reason:'Hover phải làm mục menu trượt nhẹ sang phải');
    await tester.pump(const Duration(milliseconds:250));
    await tester.tap(find.byKey(const ValueKey('nav-1')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds:250));
    expect(find.byKey(const ValueKey('erp-nav-selection-1')),findsOneWidget);
    expect(tester.widget<AnimatedSlide>(moving).offset,Offset.zero,
      reason:'Tab được chọn trở về đúng vị trí nổi');
  });

  testWidgets('hover at left edge stays stable in expanded and compact sidebar',
    (tester)async{
    tester.view.devicePixelRatio=1;
    tester.view.physicalSize=const Size(1440,900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const ErpApp(previewMode:true));
    final hoverTarget=find.byKey(const ValueKey('erp-nav-motion-1'));
    final mouse=await tester.createGesture(kind:PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location:const Offset(1000,800));
    Future<void> checkEdge()async{
      final region=tester.getRect(find.byKey(const ValueKey('nav-1')));
      await mouse.moveTo(Offset(region.left+2,region.center.dy));
      await tester.pump();
      await tester.pump(const Duration(milliseconds:250));
      expect(tester.widget<AnimatedSlide>(hoverTarget).offset.dx,greaterThan(0));
      await tester.pump(const Duration(milliseconds:400));
      expect(tester.widget<AnimatedSlide>(hoverTarget).offset.dx,greaterThan(0),
        reason:'Vùng bấm không được rung khi icon trượt ra khỏi mép trái');
      await mouse.moveTo(const Offset(1000,800));
      await tester.pump();
      await tester.pump(const Duration(milliseconds:230));
    }
    await checkEdge();
    await tester.tap(find.byKey(const ValueKey('erp-sidebar-toggle')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds:350));
    await checkEdge();
  });

  testWidgets('unauthed production shows login and preview is explicit', (tester) async{
    await tester.pumpWidget(const ErpApp());
    expect(find.text('Đăng nhập hệ thống'),findsOneWidget);
    expect(find.text('Tổng quan điều hành'),findsNothing);
    expect(find.byKey(const ValueKey('login-preview')),findsNothing);
    expect(find.text('Tổng quan điều hành'),findsNothing);
    expect(find.text('Đăng nhập hệ thống'),findsOneWidget);
  });

  testWidgets('IA-B policy-only grant opens Administration but never Company', (tester) async {
    tester.view.devicePixelRatio=1;
    tester.view.physicalSize=const Size(1280,800);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session=IdentitySession(
      actorId:'00000000-0000-4000-8000-000000000003',
      token:'example-token-not-for-network',
      expiresAt:DateTime.now().add(const Duration(hours:1)),
      grants:const [
        IdentityGrant(roleId:'policy-role',permission:'inventory.policy.manage',
          branchId:'00000000-0000-4000-8000-000000000001',
          warehouseId:'00000000-0000-4000-8000-000000000002'),
      ]);
    await tester.pumpWidget(MaterialApp(home:ErpShell(
      session:session,previewOnly:false)));
    expect(find.byKey(const ValueKey('nav-0')),findsNothing);
    expect(find.byKey(const ValueKey('nav-2')),findsOneWidget);
    expect(find.text('Tổ chức, tài khoản, quyền và chính sách'),findsOneWidget);
    expect(find.text('Không có quyền quản lý tổ chức.'),findsOneWidget);
  });

  testWidgets('authenticated module menu hides unauthorized Company features', (tester) async {
    final session=IdentitySession(
      actorId:'00000000-0000-4000-8000-000000000001',
      token:'example-token-not-for-network',
      expiresAt:DateTime.now().add(const Duration(hours:2)),
      grants:const [
        IdentityGrant(roleId:'role-1',permission:'identity.users.read'),
      ],
    );
    tester.view.devicePixelRatio=1;
    tester.view.physicalSize=const Size(1280,800);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(home:ErpShell(session:session,previewOnly:false)));
    expect(find.text('Tổ chức, tài khoản, quyền và chính sách'),findsOneWidget);
    expect(find.text('Tổng quan điều hành'),findsNothing);
  });
  testWidgets('current username remains beside logout; collapse control stays at logo',
    (tester)async{
    tester.view.devicePixelRatio=1;
    tester.view.physicalSize=const Size(1280,800);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session=IdentitySession(
      actorId:'00000000-0000-4000-8000-000000000001',
      token:'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmn_12',
      loginName:'admin',
      expiresAt:DateTime.now().add(const Duration(days:365)),
      grants:const [
        IdentityGrant(roleId:'role-1',permission:'identity.users.read'),
      ]);
    await tester.pumpWidget(MaterialApp(home:ErpShell(
      session:session,previewOnly:false,onLogout:(){})));
    expect(find.text('admin'),findsOneWidget);
    final user=find.byKey(const ValueKey('erp-current-user'));
    final logout=find.byKey(const ValueKey('erp-session-exit'));
    expect((tester.getCenter(user).dy-tester.getCenter(logout).dy).abs(),
      lessThan(10),reason:'Tên người dùng và đăng xuất phải ở cùng một hàng');
    final logo=find.byKey(const ValueKey('erp-sidebar-logo'));
    final toggle=find.byKey(const ValueKey('erp-sidebar-toggle'));
    expect(tester.getRect(toggle).center.dy,lessThan(tester.getRect(logo).bottom));
    await tester.tap(toggle);
    // Keep this a sidebar geometry assertion. Other tabs may have a live
    // loading indicator and therefore must not be awaited with pumpAndSettle.
    await tester.pump();
    await tester.pump(const Duration(milliseconds:400));
    expect(find.byKey(const ValueKey('erp-session-exit')),findsOneWidget);
  });

  testWidgets('login has a full viewport backdrop', (tester) async {
    await tester.pumpWidget(const ErpApp());
    expect(find.byKey(const ValueKey('login-backdrop')), findsOneWidget);
    expect(find.text('Đăng nhập hệ thống'), findsOneWidget);
  });

  testWidgets('company workflow tiers keep header pinned and expose typed destinations', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 800);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(home:Scaffold(body:CompanyWorkspace(previewOnly:true))));
    final header = find.byKey(const ValueKey('erp-page-header'));
    final y = tester.getTopLeft(header).dy;
    expect(find.byType(ChoiceChip), findsNothing);
    expect(find.byKey(const ValueKey('erp-header-tabs')), findsOneWidget);
    expect(find.byKey(const ValueKey('erp-section-tabs')), findsNothing);
    final headerRect=tester.getRect(header);
    final firstTabRect=tester.getRect(
      find.byKey(const ValueKey('company-CompanyGroup.catalog')));
    expect(firstTabRect.center.dy,greaterThan(headerRect.top));
    expect(firstTabRect.center.dy,lessThan(headerRect.bottom));
    expect(firstTabRect.left,greaterThan(headerRect.left+180),
      reason:'Cấp 1 phải nằm về bên phải của tiêu đề xanh');
    await tester.ensureVisible(find.byKey(const ValueKey('company-CompanyGroup.catalog')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('company-CompanyGroup.catalog')));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(header).dy, y);
    expect(find.byKey(const ValueKey('company-sub-CompanySection.customers')), findsOneWidget);
    expect(find.byKey(const ValueKey('company-sub-CompanySection.products')), findsOneWidget);
    expect(find.text('Danh mục khách hàng'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('company-sub-CompanySection.products')));
    await tester.pumpAndSettle();
    expect(find.text('Danh mục sản phẩm'), findsOneWidget);
    // Header tabs scroll horizontally when there are more business sections.
    final overview=find.byKey(const ValueKey('company-CompanyGroup.overview'));
    await tester.ensureVisible(overview);
    await tester.pumpAndSettle();
    await tester.tap(overview);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(header).dy, y);
    expect(find.text('Tổng quan điều hành'), findsOneWidget);
  });

  testWidgets('desktop login renders the supplied logistics art beneath copy', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 800);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const ErpApp());
    final imageFinder = find.byKey(const ValueKey('login-panel-photo'));
    expect(imageFinder, findsOneWidget);
    final image = tester.widget<Image>(imageFinder);
    expect((image.image as AssetImage).assetName, 'assets/images/login_logistics.webp');
    expect(find.text('Đăng nhập hệ thống'), findsOneWidget);
  });

  testWidgets('mobile login keeps the form readable without the desktop art panel', (tester) async {
    tester.view.devicePixelRatio=1;
    tester.view.physicalSize=const Size(390,844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const ErpApp());
    expect(find.byKey(const ValueKey('login-panel-photo')), findsNothing);
    expect(find.byKey(const ValueKey('login-name')), findsOneWidget);
    expect(find.byKey(const ValueKey('login-password')), findsOneWidget);
  });

}
