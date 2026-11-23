import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:erp_distribution/main.dart';
import 'package:erp_distribution/ui/erp_shell.dart';
import 'package:erp_distribution/ui/identity_client.dart';

void main() {
  testWidgets('ERP shell shows safe empty state and main module', (tester) async {
    await tester.pumpWidget(const ErpApp(previewMode:true));
    expect(find.text('Tổng quan điều hành'), findsOneWidget);
    expect(find.text('Chưa có dữ liệu đối soát'), findsNWidgets(4));
    expect(find.text('Công Ty'), findsWidgets);
  });

  testWidgets('mobile shell opens navigation to all six modules', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const ErpApp(previewMode:true));
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    expect(find.text('MCP'), findsOneWidget);
    expect(find.text('Giao Hàng'), findsOneWidget);
    expect(find.text('Đặt Hàng'), findsOneWidget);
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
  await tester.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(const ErpApp(previewMode:true));
  await tester.tap(find.byIcon(Icons.menu));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Quản trị').first);
  await tester.pumpAndSettle();
  expect(find.text('Người dùng và phân quyền'), findsOneWidget);
  expect(find.text('Chưa có dữ liệu'), findsOneWidget);
  // The non-modal startup toast closes before interacting with pinned tabs.
  await tester.pump(const Duration(seconds: 5));
  expect(find.byKey(const ValueKey('erp-startup-toast')), findsNothing);
  await tester.tap(find.byKey(const ValueKey('admin-1')));
  await tester.pumpAndSettle();
  expect(find.text('Danh sách quyền'), findsOneWidget);
  expect(find.textContaining('Xem tồn kho, ghi nhận tồn đầu kỳ'), findsOneWidget);
  expect(find.textContaining('inventory.read'), findsNothing);
});

  testWidgets('old persistent notices are replaced by a dismissible upper-right toast', (tester) async {
    await tester.pumpWidget(const ErpApp(previewMode:true));
    expect(find.byKey(const ValueKey('erp-startup-toast')), findsOneWidget);
    expect(find.text('Đang xem giao diện'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('erp-toast-close')));
    await tester.pump();
    expect(find.byKey(const ValueKey('erp-startup-toast')), findsNothing);
    expect(find.text('Tổng quan điều hành'), findsOneWidget);
  });

  testWidgets('toast auto dismisses once and never reappears on navigation', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const ErpApp(previewMode:true));
    expect(find.byKey(const ValueKey('erp-startup-toast')), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    expect(find.byKey(const ValueKey('erp-startup-toast')), findsNothing);
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.tap(find.text('MCP'));
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
    expect(find.text('RRP'), findsOneWidget);
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
    expect(find.text('Người dùng và phân quyền'), findsOneWidget);
  });

  testWidgets('unauthed production shows login and preview is explicit', (tester) async{
    await tester.pumpWidget(const ErpApp());
    expect(find.text('Đăng nhập hệ thống'),findsOneWidget);
    expect(find.text('Tổng quan điều hành'),findsNothing);
    expect(find.byKey(const ValueKey('login-preview')),findsNothing);
    expect(find.text('Tổng quan điều hành'),findsNothing);
    expect(find.text('Đăng nhập hệ thống'),findsOneWidget);
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
    expect(find.text('Người dùng và phân quyền'),findsOneWidget);
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
    await tester.pumpWidget(const ErpApp(previewMode: true));
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
    await tester.tap(find.byKey(const ValueKey('company-CompanyGroup.catalog')));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(header).dy, y);
    expect(find.byKey(const ValueKey('company-sub-CompanySection.customers')), findsOneWidget);
    expect(find.byKey(const ValueKey('company-sub-CompanySection.products')), findsOneWidget);
    expect(find.text('Danh mục khách hàng'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('company-sub-CompanySection.products')));
    await tester.pumpAndSettle();
    expect(find.text('Danh mục sản phẩm'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('company-CompanyGroup.overview')));
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
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const ErpApp());
    expect(find.byKey(const ValueKey('login-panel-photo')), findsNothing);
    expect(find.byKey(const ValueKey('login-name')), findsOneWidget);
    expect(find.byKey(const ValueKey('login-password')), findsOneWidget);
  });

}
