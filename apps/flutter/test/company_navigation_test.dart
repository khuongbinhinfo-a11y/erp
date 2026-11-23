import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:erp_distribution/ui/company_workspace.dart';
import 'package:erp_distribution/ui/identity_client.dart';
import 'package:erp_distribution/ui/erp_tokens.dart';

void main(){
  testWidgets('Company groups real pages under tier 1 and tier 2 without fake modules',
    (tester)async{
      tester.view.devicePixelRatio=1;
      tester.view.physicalSize=const Size(1440,900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(theme:erpTheme(touch:false),
        home:const Scaffold(body:CompanyWorkspace(previewOnly:true))));
      expect(find.byKey(const ValueKey('company-CompanyGroup.catalog')),findsOneWidget);
      expect(find.byKey(const ValueKey('company-CompanyGroup.warehouse')),findsOneWidget);
      expect(find.byKey(const ValueKey('company-sub-CompanySection.products')),findsNothing);
      await tester.tap(find.byKey(const ValueKey('company-CompanyGroup.catalog')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('company-sub-CompanySection.customers')),findsOneWidget);
      expect(find.byKey(const ValueKey('company-sub-CompanySection.products')),findsOneWidget);
      expect(find.byKey(const ValueKey('company-sub-CompanySection.prices')),findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('company-sub-CompanySection.prices')));
      await tester.pumpAndSettle();
      expect(find.text('Chính sách giá bán'),findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('company-CompanyGroup.warehouse')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('company-sub-CompanySection.transfers')),findsOneWidget);
      expect(find.byKey(const ValueKey('company-sub-CompanySection.stocktakes')),findsOneWidget);
      expect(find.byKey(const ValueKey('company-sub-CompanySection.prices')),findsNothing);
      expect(tester.takeException(),isNull);
    });

  testWidgets('RBAC filters out unrelated Company business groups',
    (tester)async{
      const grants=[IdentityGrant(roleId:'catalog',permission:'catalog.read',
        branchId:'00000000-0000-4000-8000-000000000001')];
      await tester.pumpWidget(MaterialApp(home:Scaffold(body:CompanyWorkspace(
        previewOnly:false,grants:grants))));
      expect(find.byKey(const ValueKey('company-CompanyGroup.catalog')),findsOneWidget);
      expect(find.byKey(const ValueKey('company-CompanyGroup.sales')),findsNothing);
      expect(find.byKey(const ValueKey('company-CompanyGroup.warehouse')),findsNothing);
      expect(find.byKey(const ValueKey('company-CompanyGroup.purchasing')),findsNothing);
      expect(find.byKey(const ValueKey('company-CompanyGroup.finance')),findsNothing);
      expect(find.byKey(const ValueKey('company-CompanyGroup.reports')),findsNothing);
      await tester.tap(find.byKey(const ValueKey('company-CompanyGroup.catalog')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('company-sub-CompanySection.customers')),findsOneWidget);
      expect(tester.takeException(),isNull);
    });

  testWidgets('Company tier menus remain usable on 360px viewport',
    (tester)async{
      tester.view.devicePixelRatio=1;
      tester.view.physicalSize=const Size(360,740);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(theme:erpTheme(touch:true),
        home:const Scaffold(body:CompanyWorkspace(previewOnly:true))));
      final catalog=find.byKey(const ValueKey('company-CompanyGroup.catalog'));
      await tester.ensureVisible(catalog);
      await tester.tap(catalog);
      await tester.pumpAndSettle();
      final product=find.byKey(const ValueKey('company-sub-CompanySection.products'));
      await tester.ensureVisible(product);
      await tester.tap(product);
      await tester.pumpAndSettle();
      expect(find.text('Danh mục sản phẩm'),findsOneWidget);
      expect(tester.takeException(),isNull);
    });
}
