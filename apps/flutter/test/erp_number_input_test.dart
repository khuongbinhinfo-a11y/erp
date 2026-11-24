import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:erp_distribution/ui/erp_number_input.dart';

void main(){
  test('group decimal strings without losing significant digits',(){
    expect(erpGroupedDecimalText('9800.000000'),'9,800');
    expect(erpGroupedDecimalText('12.500000'),'12.5');
    expect(erpGroupedDecimalText('0.125000'),'0.125');
    expect(erpGroupedDecimalText('-1250.000'),'-1,250');
    expect(erpGroupedDecimalText('123456789012345678.000001'),'123,456,789,012,345,678.000001');
    expect(erpGroupedDecimalText('0.000000'),'0');
    expect(erpGroupedVndText('9800.000000'),'9,800 ₫');
    expect(erpNumberCanonical('1,250.125'),'1250.125');
  });
  test('grouping preserves typing, paste and exact canonical value',(){
    const formatter=ErpGroupedNumberFormatter();
    const empty=TextEditingValue();
    final value=formatter.formatEditUpdate(empty,const TextEditingValue(
      text:'9800',selection:TextSelection.collapsed(offset:4)));
    expect(value.text,'9,800');
    expect(value.selection.extentOffset,5);
    final fraction=formatter.formatEditUpdate(value,const TextEditingValue(
      text:'9,800.',selection:TextSelection.collapsed(offset:6)));
    expect(fraction.text,'9,800.');
    final pasted=formatter.formatEditUpdate(empty,const TextEditingValue(
      text:'1,250.1250',selection:TextSelection.collapsed(offset:10)));
    expect(pasted.text,'1,250.1250');
    expect(erpNumberCanonical(pasted.text),'1250.1250');
    expect(formatter.formatEditUpdate(pasted,const TextEditingValue(
      text:'1,250.12501',selection:TextSelection.collapsed(offset:11))),pasted);
    expect(formatter.formatEditUpdate(pasted,empty).text,'');
  });
  test('consecutive backspaces across grouping separator keep caret',(){
    const formatter=ErpGroupedNumberFormatter();
    final first=formatter.formatEditUpdate(
      const TextEditingValue(text:'1,234,567',selection:TextSelection.collapsed(offset:6)),
      const TextEditingValue(text:'1,234567',selection:TextSelection.collapsed(offset:5)));
    expect(first.text,'123,567');
    expect(first.selection.extentOffset,3);
    final second=formatter.formatEditUpdate(first,
      const TextEditingValue(text:'12,567',selection:TextSelection.collapsed(offset:2)));
    expect(second.text,'12,567');
    expect(second.selection.extentOffset,2);
  });
  test('forward delete at a grouping comma removes the next digit',(){
    const formatter=ErpGroupedNumberFormatter();
    final result=formatter.formatEditUpdate(
      const TextEditingValue(text:'1,234',selection:TextSelection.collapsed(offset:1)),
      const TextEditingValue(text:'1234',selection:TextSelection.collapsed(offset:1)));
    expect(result.text,'134');
    expect(result.selection.extentOffset,1);
    final next=formatter.formatEditUpdate(result,
      const TextEditingValue(text:'14',selection:TextSelection.collapsed(offset:1)));
    expect(next.text,'14');
    expect(next.selection.extentOffset,1);
  });
}
