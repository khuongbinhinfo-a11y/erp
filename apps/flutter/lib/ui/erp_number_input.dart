import 'package:flutter/services.dart';
import 'erp_display.dart';

/// Exact decimal presentation; never use floating-point arithmetic for money.
String erpGroupedDecimalText(Object? value) {
  final decimal=erpDecimalText(value);
  return _group(decimal);
}

String erpGroupedVndText(Object? value) =>
    value==null?'Chưa có giá':erpGroupedDecimalText(value)+' ₫';

String erpNumberCanonical(String input)=>input.replaceAll(',','').trim();

String _group(String input) {
  final match=RegExp(r'^(-?)(\d*)(?:\.(\d*))?$').firstMatch(input);
  if(match==null)return input;
  final whole=match.group(2)!.replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'),(_)=>',');
  return match.group(1)!+whole+
    (match.group(3)==null?'':'.'+match.group(3)!);
}

/// Group the integral portion as the operator types, without changing the
/// canonical value or treating a thousands comma as a decimal separator.
class ErpGroupedNumberFormatter extends TextInputFormatter {
  final int maxIntegerDigits;
  final int maxFractionDigits;
  final bool allowNegative;
  const ErpGroupedNumberFormatter({this.maxIntegerDigits=14,
    this.maxFractionDigits=4,this.allowNegative=false});
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue,
      TextEditingValue newValue) {
    if(newValue.composing.isValid&&!newValue.composing.isCollapsed)return newValue;
    var raw=erpNumberCanonical(newValue.text);
    int? removedRawIndex;
    // Deleting only a grouping comma should delete the adjacent digit instead
    // of repeatedly reinserting the same separator.
    final previous=erpNumberCanonical(oldValue.text);
    final offset=newValue.selection.extentOffset;
    if(raw==previous&&oldValue.text.length==newValue.text.length+1&&
        oldValue.selection.isCollapsed&&offset>=0&&
        offset<oldValue.text.length&&oldValue.text[offset]==','){
      final digitsBefore=oldValue.text.substring(0,offset).replaceAll(',','').length;
      final oldOffset=oldValue.selection.extentOffset;
      final isBackspace=oldOffset==offset+1;
      final isForwardDelete=oldOffset==offset;
      final index=isBackspace?digitsBefore-1:isForwardDelete?digitsBefore:-1;
      if(index>=0&&index<raw.length&&RegExp(r'\d').hasMatch(raw[index])){
        removedRawIndex=index;
        raw=raw.substring(0,index)+raw.substring(index+1);
      }
    }
    final match=RegExp(r'^(-?)(\d*)(?:\.(\d*))?$').firstMatch(raw);
    if(match==null||(!allowNegative&&match.group(1)=='-')||
        match.group(2)!.length>maxIntegerDigits||
        (match.group(3)?.length??0)>maxFractionDigits||
        (maxFractionDigits==0&&match.group(3)!=null))return oldValue;
    final formatted=_group(raw);
    int mapOffset(int source) {
      if(source<0)return formatted.length;
      var target=newValue.text.substring(0,source.clamp(0,newValue.text.length).toInt())
        .replaceAll(',','').length;
      final removed=removedRawIndex;
      if(removed!=null&&target>removed)target--;
      target=target.clamp(0,raw.length).toInt();
      if(target==0)return 0;
      var count=0;
      for(var i=0;i<formatted.length;i++){
        if(formatted[i]!=',')count++;
        if(count==target)return i+1;
      }
      return formatted.length;
    }
    return TextEditingValue(text:formatted,selection:TextSelection(
      baseOffset:mapOffset(newValue.selection.baseOffset),
      extentOffset:mapOffset(newValue.selection.extentOffset)));
  }
}
