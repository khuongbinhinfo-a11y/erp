import 'package:flutter_test/flutter_test.dart';
import 'package:erp_distribution/ui/sales_workspace.dart';

void main(){
  test('reconciliation keeps edits, starts fresh server revision and drops stale signatures',(){
    final latest=<String,dynamic>{
      'id':'order','revision':3,'branchId':'b','customerId':'old',
      'lines':[{'sellSkuId':'s','quantity':'1','unitPrice':'10','discountRate':'0',
        'taxRate':'0','priceSnapshot':{'trace':['old']}}],
    };
    final old={'body':{
      'branchId':'b','customerId':'new','priceListId':'list','note':'keep me',
      'lines':[{'sellSkuId':'s','quantity':'2','unitPrice':'15','discountRate':'0',
        'expectedPriceSignature':'old-stale-signature','overrideReason':'approved'}],
    }};
    final result=erpSalesReconciliationOrder(latest,old);
    expect(result['revision'],3);
    expect(result['customerId'],'new');
    expect(result['note'],'keep me');
    final line=(result['lines'] as List).single as Map;
    expect(line['quantity'],'2');
    expect(line['unitPrice'],'15');
    expect(line['expectedPriceSignature'],isNull);
    expect((line['priceSnapshot'] as Map)['restoreOverride'],true);
    expect((line['priceSnapshot'] as Map)['discountOverride'],true);
    expect((line['priceSnapshot'] as Map)['overrideReason'],'approved');
  });
}
