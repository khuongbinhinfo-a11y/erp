import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:erp_distribution/ui/erp_toast.dart';
import 'package:erp_distribution/ui/erp_tokens.dart';

void main(){
  testWidgets('top-right toast slides in, counts down in green and auto dismisses',
    (tester)async{
    tester.view.devicePixelRatio=1;
    tester.view.physicalSize=const Size(1280,800);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(home:Scaffold(
      body:Builder(builder:(context)=>TextButton(
        onPressed:()=>ErpToast.show(context,'Đã lưu sau khi server xác nhận'),
        child:const Text('Hiện thông báo'))))));
    await tester.tap(find.text('Hiện thông báo'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds:16));
    final notice=find.byKey(const ValueKey('erp-active-toast'));
    expect(notice,findsOneWidget);
    final slide=find.descendant(of:notice,
      matching:find.byType(SlideTransition)).first;
    final startX=tester.widget<SlideTransition>(slide).position.value.dx;
    final progress=find.byKey(const ValueKey('erp-toast-time-progress'));
    expect(tester.widget<LinearProgressIndicator>(progress).color,ErpTokens.fresh);
    await tester.pump(const Duration(milliseconds:350));
    expect(tester.widget<SlideTransition>(slide).position.value.dx,
      lessThan(startX),reason:'Thông báo phải trượt từ bên phải vào');
    await tester.pump(const Duration(seconds:2));
    final remaining=tester.widget<LinearProgressIndicator>(progress).value!;
    expect(remaining,greaterThan(0));
    expect(remaining,lessThan(0.7));
    await tester.pump(const Duration(seconds:2));
    await tester.pump();
    await tester.pump(const Duration(milliseconds:260));
    expect(notice,findsNothing);
  });

  testWidgets('reduce motion skips movement but preserves four-second reading time',
    (tester)async{
    var dismissed=0;
    await tester.pumpWidget(MaterialApp(home:MediaQuery(
      data:const MediaQueryData(disableAnimations:true),
      child:Scaffold(body:ErpToastNotice(
        message:'Cần thời gian để đọc',
        onDismiss:()=>dismissed++)))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds:300));
    expect(dismissed,0);
    await tester.pump(const Duration(seconds:3));
    expect(dismissed,0);
    await tester.pump(const Duration(seconds:1));
    expect(dismissed,1);
  });

  testWidgets('close toast slides out immediately without changing app state',
    (tester)async{
    await tester.pumpWidget(MaterialApp(home:Scaffold(
      body:Builder(builder:(context)=>TextButton(
        onPressed:()=>ErpToast.show(context,'Lưu ý kiểm tra giá',isError:true),
        child:const Text('Thông báo lỗi'))))));
    await tester.tap(find.text('Thông báo lỗi'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds:320));
    expect(find.byKey(const ValueKey('erp-active-toast')),findsOneWidget);
    await tester.tap(find.byTooltip('Đóng thông báo'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds:250));
    expect(find.byKey(const ValueKey('erp-active-toast')),findsNothing);
    expect(find.text('Thông báo lỗi'),findsOneWidget);
  });
}
