import 'package:material_ui/material_ui.dart';

/// Searchable, virtualized picker for server-authorized lots and bins. It
/// deliberately does not silently cap available options at the first 100.
class StockScopePicker extends StatelessWidget {
  final String kind;
  final String? selectedId;
  final List<dynamic> items;
  final ValueChanged<String> onChanged;

  const StockScopePicker({super.key,required this.kind,required this.selectedId,
    required this.items,required this.onChanged})
      :assert(kind=='lot'||kind=='location');

  String get label=>kind=='lot'?'Lô hàng':'Vị trí kho';
  String titleOf(Map<dynamic,dynamic> item){
    if(kind=='lot'){
      final text=(item['lotCode']??'').toString();
      final expiry=item['expiryDate'];
      return expiry==null?text:text+' · HSD '+expiry.toString().split('T').first;
    }
    return (item['code']??'').toString()+' · '+(item['name']??'').toString();
  }

  @override Widget build(BuildContext context){
    final selected=items.whereType<Map>().where((x)=>x['id']==selectedId).firstOrNull;
    return OutlinedButton.icon(
      icon:Icon(kind=='lot'?Icons.qr_code:Icons.place_outlined),
      label:Text(selected==null?'Chọn $label':titleOf(selected),
        overflow:TextOverflow.ellipsis,maxLines:1),
      onPressed:()async{
        final query=TextEditingController();
        try{
          final route=DialogRoute<String>(
            context:context,
            builder:(dialog)=>StatefulBuilder(builder:(dialog,refresh){
              final term=query.text.trim().toLowerCase();
              final matches=items.whereType<Map>().where((x)=>
                term.isEmpty||titleOf(x).toLowerCase().contains(term)).toList();
              return AlertDialog(
                title:Text('Chọn $label'),
                content:SizedBox(width:480,height:430,child:Column(children:[
                  TextField(
                    key:ValueKey('stock-scope-search-$kind'),
                    controller:query,
                    autofocus:true,
                    onChanged:(_)=>refresh((){}),
                    decoration:InputDecoration(
                      prefixIcon:const Icon(Icons.search),
                      labelText:'Tìm mã hoặc tên $label',
                      border:const OutlineInputBorder())),
                  const SizedBox(height:12),
                  Expanded(child:matches.isEmpty
                    ?Center(child:Text('Không tìm thấy $label phù hợp.'))
                    :ListView.builder(
                      itemCount:matches.length,
                      itemBuilder:(ctx,i){
                        final item=matches[i];
                        final id=item['id'].toString();
                        return ListTile(
                          key:ValueKey('stock-scope-choice-$kind-$id'),
                          selected:id==selectedId,
                          title:Text(titleOf(item)),
                          onTap:()=>Navigator.of(dialog).pop(id));
                      })),
                ])),
                actions:[
                  TextButton(onPressed:()=>Navigator.of(dialog).pop(),
                    child:const Text('Đóng')),
                  TextButton(onPressed:()=>Navigator.of(dialog).pop(''),
                    child:const Text('Bỏ chọn')),
                ],
              );
            }),
          );
          final chosen=await Navigator.of(context,rootNavigator:true).push(route);
          await route.completed;
          if(chosen!=null&&context.mounted)onChanged(chosen);
        }finally{
          query.dispose();
        }
      },
    );
  }
}
