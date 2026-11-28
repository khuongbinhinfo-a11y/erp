import 'package:material_ui/material_ui.dart';

import 'erp_tokens.dart';
import 'erp_display.dart';
import 'erp_navigation_ui.dart';
import 'identity_client.dart';
import 'erp_toast.dart';
import 'org_directory_workspace.dart';

class AdminWorkspace extends StatefulWidget {
  final bool previewOnly;
  final ErpIdentityClient? client;
  final IdentitySession? session;
  final Future<void> Function()? onDirectoryChanged;
  const AdminWorkspace({super.key,this.previewOnly=true,this.client,this.session,this.onDirectoryChanged});
  @override State<AdminWorkspace> createState()=>_AdminWorkspaceState();
}

class _AdminWorkspaceState extends State<AdminWorkspace>{
  int selected=0;
  Future<List<IdentityUser>>? usersFuture;
  IdentityScopes? namedScopes;

  Future<List<Map<String,dynamic>>>? permissionsFuture;
  Future<List<Map<String,dynamic>>>? auditFuture;
  bool get canPolicies=>widget.session?.grants.any((g)=>
    g.permission=='inventory.policy.manage'&&g.warehouseId!=null)??false;
  bool get real=>!widget.previewOnly&&widget.session!=null&&widget.client!=null;
  bool allowed(String code)=>widget.session?.grants.any((g)=>g.permission==code)??false;
  String get token=>widget.session!.token;

  @override void initState(){
    super.initState();
    if(real&&allowed('identity.users.read'))usersFuture=widget.client!.users(token);
    if(real&&allowed('identity.roles.manage'))loadScopes();
    if(real&&(allowed('identity.users.read')||allowed('identity.roles.manage')))
      permissionsFuture=widget.client!.permissionCatalog(token);
    if(real&&allowed('identity.roles.manage'))
      auditFuture=widget.client!.auditEvents(token);
  }
  void reload(){
    if(real&&allowed('identity.users.read')){
      setState(()=>usersFuture=widget.client!.users(token));
    }
    if(real&&allowed('identity.roles.manage'))loadScopes();
  }
  Future<void> loadScopes() async {
    try {
      final loaded=await widget.client!.scopes(token);
      if(mounted)setState(()=>namedScopes=loaded);
    } catch (_) {
      if(mounted)setState(()=>namedScopes=null);
    }
  }
  String grantScopeLabel(IdentityGrant grant) {
    final current=namedScopes;
    if(grant.warehouseId!=null){
      if(current==null)return 'Đang tải tên kho';
      for(final warehouse in current.warehouses){
        if(warehouse.id==grant.warehouseId){
          final branchName=current.branches.where((x)=>x.id==warehouse.branchId)
            .map((x)=>x.name).firstOrNull;
          return 'Kho '+warehouse.name+(warehouse.code=='MAIN'?'':' ('+warehouse.code+')')+
            (branchName==null?'':' · '+branchName);
        }
      }
      return 'Kho không còn khả dụng';
    }
    if(grant.branchId!=null){
      if(current==null)return 'Đang tải tên chi nhánh';
      for(final branch in current.branches){
        if(branch.id==grant.branchId)return 'Chi nhánh '+branch.name+(branch.code=='MAIN'?'':' ('+branch.code+')');
      }
      return 'Chi nhánh không còn khả dụng';
    }
    return 'Toàn hệ thống';
  }
  void message(String text,{bool error=false}){
    if(mounted)ErpToast.show(context,text,isError:error);
  }
  Future<void> createUser()async{
    final login=TextEditingController(),password=TextEditingController();
    try{
      final result=await showDialog<Map<String,String>>(context:context,builder:(dialog)=>AlertDialog(
        title:const Text('Tạo tài khoản'),
        content:SizedBox(width:370,child:Column(mainAxisSize:MainAxisSize.min,children:[
          TextField(controller:login,decoration:const InputDecoration(
            labelText:'Tên đăng nhập',hintText:'vd: nhanvien_kho')),
          const SizedBox(height:12),
          TextField(controller:password,obscureText:true,
            decoration:const InputDecoration(labelText:'Mật khẩu mới (ít nhất 12 ký tự)')),
          const SizedBox(height:10),
          Text('Tài khoản mới chưa có quyền. Cấp quyền sau khi tạo.',
            style:TextStyle(color:ErpPalette.of(dialog).muted,fontSize:12)),
        ])),
        actions:[
          TextButton(onPressed:()=>Navigator.of(dialog).pop(),child:const Text('Hủy')),
          FilledButton(onPressed:()=>Navigator.of(dialog).pop({
            'login':login.text.trim().toLowerCase(),'password':password.text,
          }),child:const Text('Tạo tài khoản')),
        ],
      ));
      if(result==null||!mounted)return;
      if(!RegExp(r'^[a-z][a-z0-9._-]{2,79}$').hasMatch(result['login']??'')||
        (result['password']??'').length<12){message('Tên đăng nhập hoặc mật khẩu chưa hợp lệ.',error:true);return;}
      await widget.client!.createUser(token,result['login']!,result['password']!);
      message('Đã tạo tài khoản trên server. Chưa có quyền truy cập.');
      reload();
    }on ErpApiError catch(e){message(e.message,error:true);}
    catch(_){message('Không tạo được tài khoản.',error:true);}
    finally{login.dispose();password.dispose();}
  }
  /// Account stays a login principal. Linking requires both identity and branch HR grants.
  Future<void> linkEmployee(IdentityUser user)async{
    if(!real||!allowed('identity.users.manage'))return;
    try{
      final all=await widget.client!.staffBranches(token);
      if(!mounted)return;
      final branches=all.where((b)=>widget.session!.grants.any((g)=>
        g.permission=='org.employees.manage'&&g.branchId==b.id)).toList();
      if(branches.isEmpty){
        message('Tài khoản chưa có quyền quản lý nhân sự ở chi nhánh nào.',error:true);return;
      }
      // A linked user must be unlinked from the original branch before moving.
      String chosenBranch=user.employeeBranchId!=null&&
        branches.any((b)=>b.id==user.employeeBranchId)
        ?user.employeeBranchId!:branches.first.id;
      final selected=await showDialog<String>(context:context,builder:(c)=>
       StatefulBuilder(builder:(ctx,refresh)=>AlertDialog(
        title:Text('Chi nhánh nhân viên · '+user.loginName),
        content:SizedBox(width:430,child:DropdownButtonFormField<String>(
         initialValue:chosenBranch,isExpanded:true,
         decoration:const InputDecoration(labelText:'Chi nhánh'),
         items:branches.map((b)=>DropdownMenuItem<String>(value:b.id,
           child:Text(b.name,overflow:TextOverflow.ellipsis))).toList(),
         onChanged:user.employeeId!=null?null:(v)=>refresh(()=>chosenBranch=v??chosenBranch))),
        actions:[
         TextButton(onPressed:()=>Navigator.pop(c),child:const Text('Hủy')),
         FilledButton(onPressed:()=>Navigator.pop(c,chosenBranch),
           child:const Text('Tiếp tục')),
        ],
       )));
      if(selected==null||!mounted)return;
      final rows=<Map<String,dynamic>>[];
      for(var offset=0;offset<=100000;offset+=200){
       final page=await widget.client!.staffItems(token,selected,offset:offset);
       rows.addAll(page);
       if(page.length<200)break;
      }
      if(!mounted)return;
      final eligible=rows.where((e)=>e['active']==true||
         e['accountUserId']==user.id).where((e)=>
         e['accountUserId']==null||e['accountUserId']==user.id).toList();
      String employee=user.employeeId??'__none__';
      if(employee!='__none__'&&!eligible.any((e)=>e['id']==employee)){
        message('Liên kết cũ không còn khả dụng. Kiểm tra dữ liệu nhân viên.',error:true);return;
      }
      final approved=await showDialog<String>(context:context,builder:(c)=>
       StatefulBuilder(builder:(ctx,refresh)=>AlertDialog(
        title:Text('Liên kết tài khoản · '+user.loginName),
        content:SizedBox(width:450,child:Column(
         mainAxisSize:MainAxisSize.min,children:[
          const Text('Không bắt buộc mỗi nhân viên có tài khoản ERP. '
           'Chỉ liên kết đúng người sau khi xác minh.'),
          const SizedBox(height:12),
          DropdownButtonFormField<String>(initialValue:employee,isExpanded:true,
           decoration:const InputDecoration(labelText:'Nhân viên'),
           items:[
            const DropdownMenuItem(value:'__none__',child:Text('Không liên kết')),
            ...eligible.map((e)=>DropdownMenuItem<String>(
             value:e['id'].toString(),child:Text(
              e['code'].toString()+' · '+e['fullName'].toString(),
              overflow:TextOverflow.ellipsis))),
           ],onChanged:(v)=>refresh(()=>employee=v??employee)),
         ])),
        actions:[
         TextButton(onPressed:()=>Navigator.pop(c),child:const Text('Hủy')),
         FilledButton(onPressed:()=>Navigator.pop(c,employee),
          child:const Text('Lưu liên kết')),
        ],
       )));
      if(approved==null||!mounted)return;
      if(approved=='__none__'&&user.employeeId==null)return;
      await widget.client!.linkStaffAccount(widget.session!,user,selected,
        approved=='__none__'?null:approved);
      message(approved=='__none__'?'Đã hủy liên kết tài khoản.':
        'Đã liên kết nhân viên với tài khoản.');
      reload();
    }on ErpApiError catch(e){message(e.message,error:true);reload();}
    catch(_){message('Chưa xác minh được liên kết. Tải lại tài khoản trước khi thử.',error:true);reload();}
  }
  Future<void> updateStatus(IdentityUser user)async{
    try{
      await widget.client!.setDisabled(token,user,!user.disabled);
      message(user.disabled?'Đã mở khóa tài khoản.':'Đã khóa tài khoản.');
      reload();
    }on ErpApiError catch(e){message(e.message,error:true);reload();}
  }
  Future<void> addGrant(IdentityUser user)async{
    if(namedScopes==null){
      message('Chưa tải được tên chi nhánh hoặc kho. Hãy thử lại.',error:true);
      await loadScopes();
      return;
    }
    final available=widget.session!.grants.where((g)=>
      g.permission.isNotEmpty&&g.roleId.isNotEmpty).toList();
    if(available.isEmpty){message('Tài khoản quản trị chưa có quyền để cấp.',error:true);return;}
    final chosen=await showDialog<IdentityGrant>(context:context,builder:(dialog){
      var index=0;
      return StatefulBuilder(builder:(ctx,setLocal)=>AlertDialog(
        title:Text('Cấp quyền: ${user.loginName}'),
        content:SizedBox(width:440,child:Column(mainAxisSize:MainAxisSize.min,children:[
          Text('Chỉ được cấp quyền và phạm vi mà tài khoản quản trị hiện sở hữu.',
            style:TextStyle(color:ErpPalette.of(ctx).muted,fontSize:12)),
          const SizedBox(height:16),
          DropdownButtonFormField<int>(
            key:const ValueKey('admin-grant-selector'),
            initialValue:index,
            isExpanded:true,
            decoration:const InputDecoration(labelText:'Quyền / phạm vi'),
            items:List.generate(available.length,(i){
              final g=available[i];
              return DropdownMenuItem(value:i,
                child:Text(erpPermissionLabel(g.permission)+' · '+grantScopeLabel(g),
                  overflow:TextOverflow.ellipsis));
            }),
            onChanged:(i)=>setLocal(()=>index=i??0),
          ),
        ])),
        actions:[
          TextButton(onPressed:()=>Navigator.of(dialog).pop(),child:const Text('Hủy')),
          FilledButton(onPressed:()=>Navigator.of(dialog).pop(available[index]),
            child:const Text('Cấp quyền')),
        ],
      ));
    });
    if(chosen==null||!mounted)return;
    try{
      await widget.client!.grant(token,user,permission:chosen.permission,
        branchId:chosen.branchId,warehouseId:chosen.warehouseId);
      message('Đã cấp quyền sau xác nhận của server.');
      reload();
    }on ErpApiError catch(e){message(e.message,error:true);reload();}
  }
  Future<void> manageGrants(IdentityUser user)async{
    if(namedScopes==null){
      message('Chưa tải được tên chi nhánh hoặc kho. Hãy thử lại.',error:true);
      await loadScopes();
      return;
    }
    List<IdentityGrant> grants;
    try{grants=await widget.client!.grants(token,user.id);}
    on ErpApiError catch(e){message(e.message,error:true);return;}
    if(!mounted)return;
    final roleId=await showDialog<String>(context:context,builder:(dialog)=>AlertDialog(
      title:Text('Thu quyền: ${user.loginName}'),
      content:SizedBox(width:460,height:270,child:grants.isEmpty
        ? const Center(child:Text('Tài khoản chưa có quyền nào.'))
        : ListView.builder(itemCount:grants.length,itemBuilder:(ctx,i){
          final grant=grants[i];
          return ListTile(
            dense:true,
            title:Text(erpPermissionLabel(grant.permission),style:const TextStyle(fontWeight:FontWeight.w600)),
            subtitle:Text(grantScopeLabel(grant)),
            trailing:TextButton(
              onPressed:()=>Navigator.of(dialog).pop(grant.roleId),
              child:const Text('Thu hồi')),
          );
        })),
      actions:[TextButton(onPressed:()=>Navigator.of(dialog).pop(),
        child:const Text('Đóng'))],
    ));
    if(roleId==null||!mounted)return;
    try{
      await widget.client!.revoke(token,user,roleId);
      message('Quyền đã được thu hồi trên server.');
      reload();
    }on ErpApiError catch(e){message(e.message,error:true);reload();}
  }
  Widget usersTable(){
    if(widget.previewOnly){
      return Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        Text('Chưa có dữ liệu',style:TextStyle(color:ErpPalette.of(context).ink,fontWeight:FontWeight.w600)),
        SizedBox(height:6),
        Text('Chỉ admin đã đăng nhập và được cấp quyền mới có thể quản lý tài khoản.',
          style:TextStyle(color:ErpPalette.of(context).muted)),
      ]);
    }
    if(!allowed('identity.users.read'))return const Text(
      'Tài khoản hiện tại không có quyền xem danh sách người dùng.');
    return FutureBuilder<List<IdentityUser>>(
      future:usersFuture,
      builder:(ctx,snapshot){
        if(snapshot.connectionState!=ConnectionState.done)return const Center(
          child:Padding(padding:EdgeInsets.all(22),child:CircularProgressIndicator()));
        if(snapshot.hasError)return Text('Không tải được danh sách người dùng.',
          style:TextStyle(color:ErpPalette.of(ctx).danger));
        final users=snapshot.data??[];
        if(users.isEmpty)return const Text('Chưa có tài khoản trong installation này.');
        return Column(children:users.map((user)=>Container(
          decoration:BoxDecoration(border:Border(bottom:BorderSide(color:ErpPalette.of(ctx).border))),
          padding:const EdgeInsets.symmetric(vertical:9),
          child:Row(children:[
            Icon(Icons.person_outline,color:ErpPalette.of(ctx).primary),
            const SizedBox(width:12),
            Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
              Text(user.loginName,style:TextStyle(fontWeight:FontWeight.w700,color:ErpPalette.of(ctx).ink)),
              Text((user.disabled?'Đã khóa':'Đang hoạt động')+
                (user.employeeName==null?'':' · '+user.employeeName!),
                style:TextStyle(fontSize:12,color:user.disabled?ErpPalette.of(ctx).danger:ErpPalette.of(ctx).muted)),
            ])),
            if(allowed('identity.users.manage')&&widget.session!.grants.any(
               (g)=>g.permission=='org.employees.manage'))
              IconButton(tooltip:'Liên kết nhân viên',
               icon:const Icon(Icons.badge_outlined),
               onPressed:()=>linkEmployee(user)),
            if(allowed('identity.roles.manage'))...[
              IconButton(
                tooltip:'Cấp quyền',icon:const Icon(Icons.security_outlined),
                onPressed:()=>addGrant(user)),
              IconButton(
                tooltip:'Thu quyền',icon:const Icon(Icons.remove_moderator_outlined),
                onPressed:()=>manageGrants(user)),
            ],
            if(allowed('identity.users.manage')&&user.id!=widget.session?.actorId)
              IconButton(
                tooltip:user.disabled?'Mở khóa':'Khóa tài khoản',
                icon:Icon(user.disabled?Icons.lock_open_outlined:Icons.lock_outline),
                onPressed:()=>updateStatus(user)),
          ]),
        )).toList());
      },
    );
  }
  Widget permissionMatrix(){
    if(!real||!(allowed('identity.users.read')||allowed('identity.roles.manage')))
      return const Text('Không có quyền xem danh mục quyền.');
    return FutureBuilder<List<Map<String,dynamic>>>(future:permissionsFuture,
      builder:(ctx,s){
        if(s.connectionState!=ConnectionState.done)
          return const Center(child:CircularProgressIndicator());
        if(s.hasError)return const Text('Không tải được danh mục quyền từ máy chủ.');
        final items=s.data??[];
        if(items.isEmpty)return const Text('Máy chủ chưa công bố quyền.');
        return Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          const Text('Quyền do máy chủ công bố; chỉ đánh dấu quyền đã cấp, không tự cấp thêm.'),
          ...items.map((item){
            final code=item['code']?.toString()??'';
            final scope=item['scope']?.toString()??'';
            final grants=widget.session!.grants.where((g)=>g.permission==code).toList();
            final label=scope=='warehouse'?'Kho':scope=='branch'?'Chi nhánh':'Hệ thống';
            return ListTile(dense:true,
              leading:Icon(grants.isEmpty?Icons.lock_outline:Icons.verified_user_outlined),
              title:Text(erpPermissionLabel(code)),
              subtitle:Text('$'+'{label} · '+(grants.isEmpty?'Chưa được cấp':
                grants.map(grantScopeLabel).join(', '))),
              trailing:Text(grants.isEmpty?'Chưa cấp':'Đã cấp'));
          }),
        ]);
      });
  }
  Widget auditTrail(){
    if(!real||!allowed('identity.roles.manage'))
      return const Text('Không có quyền xem nhật ký.');
    return FutureBuilder<List<Map<String,dynamic>>>(future:auditFuture,builder:(ctx,s){
      if(s.connectionState!=ConnectionState.done)
        return const Center(child:CircularProgressIndicator());
      if(s.hasError)return const Text('Không tải được nhật ký máy chủ.');
      final rows=s.data??[];
      if(rows.isEmpty)return const Text('Chưa có thao tác nào được ghi nhận.');
      return Column(children:rows.map((event)=>ListTile(dense:true,
        leading:const Icon(Icons.history_outlined),
        title:Text(event['actionCode']?.toString()??''),
        subtitle:Text((event['actorLogin']?.toString()??'')+' · '+
          (event['occurredAt']?.toString()??'')),
        trailing:const Text('Đã ghi nhận'))).toList());
    });
  }
  @override Widget build(BuildContext context){
    final mobile=MediaQuery.sizeOf(context).width<720;
    final margin=mobile?16.0:26.0;
    Widget content;
    if(selected==0){
      content=!real||!allowed('identity.roles.manage')
        ?const Text('Không có quyền quản lý tổ chức.')
        :OrgDirectoryWorkspace(client:widget.client!,session:widget.session!,
          onScopesChanged:widget.onDirectoryChanged);
    }else if(selected==3){
      content=!real||!canPolicies
        ?const Text('Không có quyền quản lý chính sách kho.')
        :OrgDirectoryWorkspace(client:widget.client!,session:widget.session!,
          policyOnly:true);
    }else{
      content=Card(child:Padding(padding:const EdgeInsets.all(18),
        child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          Row(children:[
            Expanded(child:Text(selected==1?'Tài khoản người dùng':
              selected==2?'Ma trận quyền':'Nhật ký thao tác',
              style:Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight:FontWeight.w800,color:ErpPalette.of(context).ink))),
            if(selected==1&&real&&allowed('identity.users.manage'))
              FilledButton.icon(onPressed:createUser,
                icon:const Icon(Icons.person_add_alt_1_outlined),
                label:const Text('Thêm tài khoản')),
          ]),
          const SizedBox(height:16),
          if(selected==1)usersTable()
          else if(selected==2)permissionMatrix()
          else auditTrail(),
        ])));
    }
    return Column(children:[
      Padding(padding:EdgeInsets.fromLTRB(margin,16,margin,0),
        child:ErpPageHeader(heading:'Quản trị',
          subtitle:'Tổ chức, tài khoản, quyền và chính sách',
          icon:Icons.admin_panel_settings_outlined,
          trailing:ErpHeaderTabs<int>(keyPrefix:'admin',selected:selected,
            items:const [ErpSectionTab(0,'Tổ chức'),
              ErpSectionTab(1,'Tài khoản'),ErpSectionTab(2,'Phân quyền'),
              ErpSectionTab(3,'Chính sách'),ErpSectionTab(4,'Nhật ký')],
            onSelected:(v)=>setState(()=>selected=v)))),
      Expanded(child:AnimatedSwitcher(
        duration:MediaQuery.of(context).disableAnimations
          ?Duration.zero:ErpTokens.pageMotion,
        layoutBuilder:erpStableSwitcherLayout,transitionBuilder:erpFadeSwitcher,
        child:SingleChildScrollView(key:ValueKey('admin-content-$selected'),
          padding:EdgeInsets.fromLTRB(margin,18,margin,26),child:content))),
    ]);
  }
}
