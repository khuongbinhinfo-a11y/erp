import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:erp_distribution/main.dart';
import 'package:erp_distribution/ui/erp_shell.dart';
import 'package:erp_distribution/ui/erp_tokens.dart';
import 'package:erp_distribution/ui/identity_client.dart';

double contrast(Color a,Color b){
  final x=a.computeLuminance(),y=b.computeLuminance();
  return x>y?(x+.05)/(y+.05):(y+.05)/(x+.05);
}

void main(){
  for(final dark in [false,true]){
    test('semantic palette passes contrast gates (dark=$dark)',(){
      final p=ErpPalette(dark);
      final backgrounds=[p.canvas,p.surface,p.popup,p.mint];
      final foregrounds=[p.ink,p.muted,p.primary,p.danger,p.warning,p.fresh];
      for(final bg in backgrounds){
        for(final fg in foregrounds){
          expect(contrast(fg,bg),greaterThanOrEqualTo(4.5),reason:'$fg on $bg');
        }
        expect(contrast(p.controlBorder,bg),greaterThanOrEqualTo(3),reason:'control on $bg');
      }
      expect(contrast(p.onAction,p.action),greaterThanOrEqualTo(4.5));
      expect(contrast(p.onSidebarActive,p.sidebarActive),greaterThanOrEqualTo(4.5));
      final t=erpTheme(touch:true,dark:dark);
      expect(t.brightness,dark?Brightness.dark:Brightness.light);
      expect(t.scaffoldBackgroundColor,p.canvas);
      expect(t.cardTheme.color,p.surface);
      expect(t.dialogTheme.backgroundColor,p.popup);
      expect(t.popupMenuTheme.color,p.popup);
      expect(t.bottomSheetTheme.modalBackgroundColor,p.popup);
      expect(t.inputDecorationTheme.fillColor,p.surface);
      expect(t.snackBarTheme.backgroundColor,p.popup);
      expect(t.navigationBarTheme.backgroundColor,p.surface);
      if(dark){
        for(final bg in backgrounds){expect(bg.computeLuminance(),lessThan(.1));}
      }
    });
  }

  testWidgets('mobile nav five permitted destinations and theme switch preserves search',(tester)async{
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(360,760));
    addTearDown(()=>tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const ErpApp(previewMode:true,initialThemeMode:ThemeMode.light));
    await tester.pumpAndSettle();
    final bar=find.byKey(const ValueKey('erp-mobile-navigation'));
    expect(tester.widget<NavigationBar>(bar).destinations.length,5);
    expect(find.byType(Drawer),findsNothing);
    await tester.tap(find.byKey(const ValueKey('erp-mobile-CompanySection.customers')));
    await tester.pumpAndSettle();
    final search=find.byKey(const ValueKey('company-search'));
    expect(search,findsOneWidget);
    await tester.enterText(search,'KH-001');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('erp-theme-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tối').last);
    await tester.pumpAndSettle();
    expect(Theme.of(tester.element(search)).brightness,Brightness.dark);
    expect(tester.widget<TextField>(search).controller!.text,'KH-001');
    expect(tester.widget<NavigationBar>(bar).selectedIndex,3);
    final saved=await tester.runAsync(loadErpThemeMode);
    expect(saved,ThemeMode.dark);
    expect(tester.takeException(),isNull);
  });

  testWidgets('system mode follows OS brightness and explicit light overrides it',(tester)async{
    SharedPreferences.setMockInitialValues({});
    tester.binding.platformDispatcher.platformBrightnessTestValue=Brightness.dark;
    addTearDown(tester.binding.platformDispatcher.clearPlatformBrightnessTestValue);
    await tester.binding.setSurfaceSize(const Size(390,844));
    addTearDown(()=>tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const ErpApp(previewMode:true,initialThemeMode:ThemeMode.system));
    await tester.pumpAndSettle();
    final bar=find.byKey(const ValueKey('erp-mobile-navigation'));
    expect(Theme.of(tester.element(bar)).brightness,Brightness.dark);
    await tester.tap(find.byKey(const ValueKey('erp-theme-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sáng').last);
    await tester.pumpAndSettle();
    expect(Theme.of(tester.element(bar)).brightness,Brightness.light);
    expect(tester.takeException(),isNull);
  });

  testWidgets('restricted actor only gets authorized More destinations',(tester)async{
    await tester.binding.setSurfaceSize(const Size(320,720));
    addTearDown(()=>tester.binding.setSurfaceSize(null));
    final session=IdentitySession(
      actorId:'00000000-0000-4000-8000-000000000001',
      token:'example-token-not-for-network',
      expiresAt:DateTime.now().add(const Duration(hours:2)),
      grants:const [IdentityGrant(roleId:'role-1',permission:'identity.users.read')],
    );
    await tester.pumpWidget(MaterialApp(theme:erpTheme(touch:true,dark:true),
      home:ErpShell(session:session,previewOnly:false)));
    final more=find.byKey(const ValueKey('erp-mobile-more'));
    expect(more,findsOneWidget);
    expect(find.byKey(const ValueKey('erp-mobile-3')),findsNothing);
    expect(find.byKey(const ValueKey('erp-mobile-CompanySection.orders')),findsNothing);
    await tester.tap(more);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('erp-mobile-more-module-2')),findsOneWidget);
    expect(find.byKey(const ValueKey('erp-mobile-more-products')),findsNothing);
    expect(find.byKey(const ValueKey('erp-mobile-more-warehouses')),findsNothing);
    expect(tester.takeException(),isNull);
  });
}
