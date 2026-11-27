import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:erp_distribution/ui/stock_scope_picker.dart';

void main(){
 testWidgets('T3-B searchable stock picker accesses lot beyond 100 without truncation',(tester)async{
  String? selected;
  final items=List.generate(115,(n)=>{'id':'lot-$n','lotCode':'LOT-$n'});
  await tester.pumpWidget(MaterialApp(home:Scaffold(body:Center(
    child:StockScopePicker(kind:'lot',selectedId:'',items:items,
      onChanged:(v)=>selected=v)))));
  await tester.tap(find.text('Chọn Lô hàng'));
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('stock-scope-search-lot')),findsOneWidget);
  await tester.enterText(find.byKey(const ValueKey('stock-scope-search-lot')),'LOT-114');
  await tester.pumpAndSettle();
  expect(find.text('LOT-114'),findsOneWidget);
  await tester.tap(find.text('LOT-114'));
  await tester.pumpAndSettle();
  expect(selected,'lot-114');
 });
 testWidgets('T3-B selecting a bin can be explicitly cleared',(tester)async{
  String? selected='bin-1';
  final items=[{'id':'bin-1','code':'A01','name':'Kệ A'}];
  await tester.pumpWidget(MaterialApp(home:Scaffold(body:Center(
    child:StockScopePicker(kind:'location',selectedId:selected,items:items,
      onChanged:(v)=>selected=v)))));
  await tester.tap(find.text('A01 · Kệ A'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Bỏ chọn'));
  await tester.pumpAndSettle();
  expect(selected,'');
 });
}
