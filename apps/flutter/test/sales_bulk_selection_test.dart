import 'package:flutter_test/flutter_test.dart';
import 'package:erp_distribution/ui/sales_bulk_selection.dart';

void main(){
  const confirmed={
    'id':'confirmed','status':'CONFIRMED','versionStatus':'CONFIRMED',
    'documentNo':'SO-20261128-000002'};
  const amending={
    'id':'amending','status':'AMENDING','versionStatus':'DRAFT',
    'documentNo':'SO-20261124-000001'};
  test('Can select confirmed AND adjusting order, like legacy table',(){
    final ids=erpBulkSelectableIds([confirmed,amending]);
    expect(ids,['confirmed','amending']);
    final selected=erpBulkToggleVisible(<String>{},ids);
    expect(selected,{'confirmed','amending'});
    expect(selected.length,2);
    expect(erpBulkToggleVisible(selected,ids),isEmpty);
  });
  test('Header select all adds missing and deselects only visible page',(){
    final first=erpBulkToggleVisible({'older-filter'},['confirmed']);
    expect(first,{'older-filter','confirmed'});
    final all=erpBulkToggleVisible(first,['confirmed','amending']);
    expect(all,{'older-filter','confirmed','amending'});
    final after=erpBulkToggleVisible(all,['confirmed','amending']);
    expect(after,{'older-filter'});
    expect(erpBulkToggleVisible(after,[]),after);
  });
  test('Draft and changing documents selected but never printable',(){
    expect(erpBulkPrintEligible(confirmed),isTrue);
    expect(erpBulkPrintEligible(amending),isFalse);
    expect(erpBulkPrintEligible({...confirmed,'versionStatus':'DRAFT'}),isFalse);
    expect(erpBulkPrintEligible({...confirmed,'documentNo':'invalid'}),isFalse);
  });
  test('Empty/null IDs cannot enter the selected set',(){
    final rows=[confirmed,<String,dynamic>{'id':''},
      <String,dynamic>{'id':null},amending,confirmed];
    expect(erpBulkSelectableIds(rows),['confirmed','amending']);
  });
}
