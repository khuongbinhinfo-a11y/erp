import 'package:material_ui/material_ui.dart';
import 'identity_client.dart';
import 'trip_execution_panel.dart';

/// Driver-only, assigned trips. No broad dispatcher trip/price list access.
class DriverTripWorkspace extends StatefulWidget{
 final ErpIdentityClient client;final IdentitySession session;
 const DriverTripWorkspace({super.key,required this.client,required this.session});
 @override State<DriverTripWorkspace> createState()=>_DriverTripWorkspaceState();
}
class _DriverTripWorkspaceState extends State<DriverTripWorkspace>{
 List<IdentityScope> scopes=[];
 List<Map<String,dynamic>> trips=[];
 String? warehouse,branch,selected,error;
 bool loading=true,more=false,loadingMore=false;
 int epoch=0,offset=0;
 @override void initState(){super.initState();_start();}
 @override void didUpdateWidget(covariant DriverTripWorkspace old){
  super.didUpdateWidget(old);
  if(old.session.token!=widget.session.token||
      old.session.actorId!=widget.session.actorId||
      old.session.installationId!=widget.session.installationId||
      old.client!=widget.client){
   ++epoch;scopes=[];trips=[];warehouse=null;branch=null;selected=null;
   _start();
  }
 }
 Future<void> _start()async{
  final current=++epoch;
  if(mounted)setState((){loading=true;error=null;});
  try{
   final rows=await widget.client.deliveryDriverScopes(widget.session);
   if(!mounted||current!=epoch)return;
   final chosen=rows.where((x)=>x.id==warehouse).firstOrNull??rows.firstOrNull;
   setState((){scopes=rows;warehouse=chosen?.id;branch=chosen?.branchId;});
   if(chosen==null)setState(()=>loading=false);
   else await _load();
  }on ErpApiError catch(e){
   if(mounted&&current==epoch)setState((){loading=false;error=e.message;});
  }catch(_){
   if(mounted&&current==epoch)setState((){loading=false;error='Không tải được chuyến giao.';});
  }
 }
 Future<void> _load({bool append=false})async{
  final w=warehouse,b=branch,current=++epoch;
  if(w==null||b==null)return;
  if(mounted)setState((){loading=true;error=null;});
  try{
   final at=append?offset:0;
   final rows=await widget.client.deliveryDriverTrips(widget.session,
    branchId:b,warehouseId:w,offset:at);
   if(!mounted||current!=epoch||warehouse!=w||branch!=b)return;
   setState((){
    final seen=append?trips.map((x)=>x['id']).toSet():<dynamic>{};
    trips=[if(append)...trips,...rows.where((x)=>seen.add(x['id']))];
    offset=at+100;more=rows.length==100&&offset<=100000;
    loading=false;loadingMore=false;
   });
  }on ErpApiError catch(e){
   if(mounted&&current==epoch)setState((){loading=false;loadingMore=false;error=e.message;});
  }catch(_){
   if(mounted&&current==epoch)setState((){loading=false;loadingMore=false;error='Không thể tải chuyến.';});
  }
 }
 @override Widget build(BuildContext context){
  final narrow=MediaQuery.sizeOf(context).width<700;
  return Padding(padding:const EdgeInsets.all(12),
   child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
    Wrap(spacing:12,runSpacing:8,alignment:WrapAlignment.spaceBetween,children:[
     Text('Chuyến giao của tôi',style:Theme.of(context).textTheme.titleLarge),
     TextButton.icon(onPressed:loading?null:()=>_load(),
      icon:const Icon(Icons.refresh),label:const Text('Làm mới')),
    ]),
    const SizedBox(height:12),
    if(scopes.isNotEmpty)ConstrainedBox(constraints:const BoxConstraints(maxWidth:400),
     child:DropdownButtonFormField<String>(initialValue:warehouse,
      isExpanded:true,decoration:const InputDecoration(isDense:true,labelText:'Kho xuất phát'),
      items:scopes.map((x)=>DropdownMenuItem(value:x.id,child:Text(x.name))).toList(),
      onChanged:loading?null:(v){
       if(v==null)return;
       final found=scopes.firstWhere((x)=>x.id==v);
       setState((){warehouse=v;branch=found.branchId;selected=null;trips=[];offset=0;});
       _load();
      })),
    if(error!=null)Padding(padding:const EdgeInsets.symmetric(vertical:8),
     child:Text(error!,style:TextStyle(color:Theme.of(context).colorScheme.error))),
    if(loading)const Center(child:Padding(padding:EdgeInsets.all(20),
     child:CircularProgressIndicator())),
    if(!loading&&scopes.isEmpty)const Padding(padding:EdgeInsets.all(20),
     child:Text('Chưa được phân chuyến hoặc chưa có quyền kho.')),
    if(!loading&&scopes.isNotEmpty&&trips.isEmpty)
     const Padding(padding:EdgeInsets.all(12),child:Text('Không có chuyến được phân.')),
    if(!loading&&trips.isNotEmpty)...[
     const SizedBox(height:8),
     for(final trip in trips)InkWell(
      key:ValueKey('driver-trip-${trip['id']}'),
      onTap:()=>setState(()=>selected=trip['id']?.toString()),
      child:Container(padding:const EdgeInsets.symmetric(vertical:12,horizontal:8),
       decoration:BoxDecoration(border:Border(bottom:BorderSide(color:Theme.of(context).dividerColor))),
       child:Row(children:[const Icon(Icons.local_shipping_outlined,size:22),
        const SizedBox(width:10),
        Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
         Text(trip['tripNo']?.toString()??'Chuyến giao',
          style:const TextStyle(fontWeight:FontWeight.w700)),
         Text('${trip['plannedDate']} · ${trip['stopCount']} điểm',
          style:const TextStyle(fontSize:12))
        ])),
        if(trip['id']==selected)const Icon(Icons.check_circle_outline)
        else const Icon(Icons.chevron_right),
       ]))),
     if(more)TextButton(onPressed:loadingMore?null:(){
      setState(()=>loadingMore=true);_load(append:true);
     },child:Text(loadingMore?'Đang tải':'Xem thêm chuyến')),
     if(selected!=null&&branch!=null&&warehouse!=null)...[
      const Divider(),
      TripExecutionPanel(key:ValueKey('driver-execution-$selected'),
       client:widget.client,session:widget.session,
       branchId:branch!,warehouseId:warehouse!,tripId:selected!),
     ],
    ],
   ]));
 }
}
