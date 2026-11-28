/// Selection is independent of document lifecycle. Operators can select draft,
/// amended and confirmed rows; the server validates every posting separately.
List<String> erpBulkSelectableIds(Iterable<Map<String,dynamic>> rows){
  final ids=<String>[];
  final seen=<String>{};
  for(final row in rows){
    final id=row['id'];
    if(id is String&&id.isNotEmpty&&seen.add(id))ids.add(id);
  }
  return ids;
}

/// "Select all" toggles only the currently visible, loaded results. Previously
/// selected IDs from another filter/page are preserved until explicitly cleared.
Set<String> erpBulkToggleVisible(Set<String> current,Iterable<String> visible){
  final ids=visible.where((id)=>id.isNotEmpty).toSet();
  final next=<String>{...current};
  if(ids.isEmpty)return next;
  if(ids.every(next.contains))next.removeAll(ids);
  else next.addAll(ids);
  return next;
}

bool erpBulkPrintEligible(Map<String,dynamic> order)=>
  order['status']=='CONFIRMED'&&order['versionStatus']=='CONFIRMED'&&
  order['documentNo'] is String &&
  RegExp(r'^SO-\d{8}-\d{6}$').hasMatch(order['documentNo'] as String);
