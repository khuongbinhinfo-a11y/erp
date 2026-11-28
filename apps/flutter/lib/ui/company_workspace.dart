import 'package:material_ui/material_ui.dart';
import 'erp_tokens.dart';
import 'erp_navigation_ui.dart';
import 'catalog_workspace.dart';
import 'inventory_workspace.dart';
import 'purchasing_workspace.dart';
import 'transfer_workspace.dart';
import 'stocktake_workspace.dart';
import 'sales_workspace.dart';
import 'delivery_trip_workspace.dart';
import 'staff_workspace.dart';
import 'erp_toast.dart';
import 'identity_client.dart';

/// Design-only screens until the installation has authenticated, migrated APIs.
enum CompanySection {
  overview('Tổng quan', 'Tình trạng hệ thống', Icons.dashboard_outlined),
  customers('Khách hàng', 'Danh mục khách hàng', Icons.groups_outlined),
  products('Sản phẩm', 'Danh mục sản phẩm', Icons.inventory_2_outlined),
  prices('Bảng giá', 'Chính sách giá bán', Icons.sell_outlined),
  warehouses('Kho hàng', 'Nhập, xuất và tồn kho', Icons.warehouse_outlined),
  purchases('Mua hàng', 'Đơn mua và nhận hàng nhà cung cấp', Icons.shopping_cart_outlined),
  transfers('Chuyển kho', 'Xuất, đang đi đường và nhận hàng', Icons.swap_horiz_outlined),
  stocktakes('Kiểm kê', 'Kiểm đếm và ghi chênh lệch', Icons.fact_check_outlined),
  orders('Đơn hàng', 'Đơn hàng và chứng từ', Icons.receipt_long_outlined),
  deliveryTrips('Chuyến giao', 'Điều phối tài xế, xe và điểm giao', Icons.route_outlined),
  employees('Nhân viên', 'Hồ sơ nhân viên toàn Công Ty', Icons.badge_outlined),
  receivables('Công nợ', 'Phải thu và thanh toán', Icons.account_balance_wallet_outlined),
  reports('Báo cáo', 'Báo cáo và đối soát', Icons.bar_chart_outlined);

  const CompanySection(this.label, this.subtitle, this.icon);
  final String label;
  final String subtitle;
  final IconData icon;
}

/// Company navigation is grouped by workflows, never a flat catalog of pages.
/// A page remains the typed, RBAC-checked destination for deep links.
enum CompanyGroup {
  overview('Tổng quan'),
  sales('Bán hàng'),
  purchasing('Mua hàng'),
  warehouse('Kho'),
  delivery('Giao nhận'),
  finance('Tài chính'),
  catalog('Danh mục'),
  personnel('Nhân sự'),
  reports('Báo cáo');
  const CompanyGroup(this.label);
  final String label;
}

extension CompanySectionGroup on CompanySection {
  CompanyGroup get group=>switch(this){
    CompanySection.overview=>CompanyGroup.overview,
    CompanySection.orders=>CompanyGroup.sales,
    CompanySection.deliveryTrips=>CompanyGroup.delivery,
    CompanySection.employees=>CompanyGroup.personnel,
    CompanySection.purchases=>CompanyGroup.purchasing,
    CompanySection.warehouses||CompanySection.transfers||CompanySection.stocktakes
      =>CompanyGroup.warehouse,
    CompanySection.receivables=>CompanyGroup.finance,
    CompanySection.customers||CompanySection.products||CompanySection.prices
      =>CompanyGroup.catalog,
    CompanySection.reports=>CompanyGroup.reports,
  };
}

bool erpCanViewCompanySection(CompanySection target,List<IdentityGrant> grants,{bool previewOnly=false}){
    if(previewOnly)return true;
    final p=grants.map((x)=>x.permission).toSet();
    bool has(String code)=>p.contains(code);
    return switch(target){
      CompanySection.overview=>true,
      CompanySection.customers||CompanySection.products||CompanySection.prices=>
        has('catalog.read')||has('catalog.write'),
      CompanySection.warehouses=>has('inventory.read')||has('inventory.post'),
      CompanySection.purchases=>has('purchase.read')||has('purchase.create'),
      CompanySection.transfers=>has('inventory.transfer.read')||has('inventory.transfer.create'),
      CompanySection.stocktakes=>has('inventory.stocktake.read')||has('inventory.stocktake.create'),
      CompanySection.orders=>has('orders.read')||has('orders.create'),
      CompanySection.deliveryTrips=>has('delivery.read')&&has('inventory.read')&&has('orders.read'),
      CompanySection.employees=>has('org.employees.read')||has('org.employees.manage'),
      CompanySection.receivables=>has('finance.receivables.read')||has('finance.payments.record'),
      // Reports have no released API yet; a catalog.read grant must never
      // implicitly expose finance or stock reporting.
      CompanySection.reports=>has('reports.read'),
    };
}

class CompanyWorkspace extends StatefulWidget {
  final bool previewOnly;
  final List<IdentityGrant> grants;
  final IdentitySession? session;
  final ErpIdentityClient? client;
  final ValueChanged<bool>? onNavigationLockChanged;
  final bool mobileNavigation;
  final CompanySection? requestedSection;
  final ValueChanged<CompanySection>? onSectionChanged;
  const CompanyWorkspace({super.key,this.previewOnly=true,this.grants=const [],
    this.session,this.client,this.onNavigationLockChanged,this.mobileNavigation=false,
    this.requestedSection,this.onSectionChanged});
  @override
  State<CompanyWorkspace> createState() => _CompanyWorkspaceState();
}

class _CompanyWorkspaceState extends State<CompanyWorkspace> {
  CompanySection section = CompanySection.overview;
  bool salesNavigationLocked=false;
  Map<String,dynamic>? _warehouseOrder;
  @override void initState(){
    super.initState();
    final requested=widget.requestedSection;
    if(requested!=null&&canView(requested))section=requested;
  }
  @override void didUpdateWidget(covariant CompanyWorkspace oldWidget){
    super.didUpdateWidget(oldWidget);
    if(oldWidget.session?.token!=widget.session?.token||oldWidget.client!=widget.client)_warehouseOrder=null;
    final requested=widget.requestedSection;
    if(requested!=null&&requested!=section&&requested!=oldWidget.requestedSection&&canView(requested)&&!salesNavigationLocked){
      section=requested;filter='';search.clear();_warehouseOrder=null;
    }
  }
  bool canView(CompanySection target)=>erpCanViewCompanySection(target,widget.grants,previewOnly:widget.previewOnly);
  List<CompanySection> get visibleSections=>CompanySection.values.where(canView).toList();
  List<CompanyGroup> get visibleGroups=>CompanyGroup.values.where((group)=>
    visibleSections.any((section)=>section.group==group)).toList();
  void selectGroup(CompanyGroup group){
    final destinations=visibleSections.where((section)=>section.group==group);
    if(destinations.isNotEmpty)select(destinations.first);
  }
  String filter = '';
  final TextEditingController search = TextEditingController();

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  void select(CompanySection value) {
    if(!canView(value)||section==value)return;
    if(section==CompanySection.orders&&value!=section&&salesNavigationLocked){
      ErpToast.show(context,'Đang xử lý đơn hàng. Hãy kiểm tra kết quả trên máy chủ trước khi chuyển mục.',isError:true);
      return;
    }
    setState(() {
      section = value;
      if(value!=CompanySection.warehouses)_warehouseOrder=null;
      filter = '';
      search.clear();
    });
    widget.onSectionChanged?.call(value);
  }

  @override Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 760;
    final sections = visibleSections;
    final groups = visibleGroups;
    final active = sections.contains(section) ? section : CompanySection.overview;
    final activeGroup=active.group;
    final groupSections=sections.where((item)=>item.group==activeGroup).toList();
    final margin = widget.mobileNavigation ? 8.0 : narrow ? 16.0 : 26.0;
    return Column(children: [
      if(!widget.mobileNavigation)Padding(padding: EdgeInsets.fromLTRB(margin, 16, margin, 0),
        child: ErpPageHeader(
          heading: 'Công Ty',
          subtitle: 'Điều hành phân phối · quản lý tập trung',
          icon: Icons.domain_outlined,
          trailing: ErpHeaderTabs<CompanyGroup>(
            keyPrefix: 'company',
            selected: activeGroup,
            items: groups.map((g) => ErpSectionTab(g, g.label)).toList(),
            onSelected: selectGroup))),
      // Tier 2 stays left below the green heading; tier 3 belongs to the
      // selected workspace (for example CatalogWorkspace product/price tabs).
      if(!widget.mobileNavigation&&activeGroup!=CompanyGroup.overview)
        Padding(
          padding:EdgeInsets.fromLTRB(margin,10,margin,0),
          child:ErpSectionTabs<CompanySection>(
            keyPrefix:'company-sub',selected:active,
            items:groupSections.map((item)=>ErpSectionTab(item,item.label)).toList(),
            onSelected:select)),
      Expanded(child: AnimatedSwitcher(
        duration: MediaQuery.of(context).disableAnimations
          ? Duration.zero : ErpTokens.pageMotion,
        reverseDuration: MediaQuery.of(context).disableAnimations
          ? Duration.zero : const Duration(milliseconds: 100),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        layoutBuilder: erpStableSwitcherLayout,
        transitionBuilder: erpFadeSwitcher,
        child: SingleChildScrollView(
          key: ValueKey('company-content-${active.name}'),
          padding: EdgeInsets.fromLTRB(margin, widget.mobileNavigation?4:18, margin, 26),
          child: active == CompanySection.overview
            ? _Overview(onSelect: select,
                areas: sections.where((s) => s != CompanySection.overview).toList())
            : (active == CompanySection.orders && !widget.previewOnly &&
                widget.client != null && widget.session != null)
              ? SalesWorkspace(key:const ValueKey('sales-workspace'),
                  client:widget.client!,session:widget.session!,
                  onNavigationLockChanged:(locked){
                    if(mounted)setState(()=>salesNavigationLocked=locked);
                    widget.onNavigationLockChanged?.call(locked);
                  },
                  onOpenWarehouse:(order){
                    if(!canView(CompanySection.warehouses)||salesNavigationLocked)return;
                    setState(()=>_warehouseOrder=order);
                    select(CompanySection.warehouses);
                  },
                  onOpenCatalog:(area)=>select(switch(area){
                    'customers'=>CompanySection.customers,
                    'products'=>CompanySection.products,
                    _=>CompanySection.prices,
                  }))
            : (active == CompanySection.warehouses && !widget.previewOnly &&
                widget.client != null && widget.session != null)
              ? InventoryWorkspace(key:ValueKey(_warehouseOrder==null?'inventory-workspace':
                  'inventory-workspace-${_warehouseOrder!['id']}'),
                  client:widget.client!,session:widget.session!,initialOrder:_warehouseOrder)
            : (active == CompanySection.deliveryTrips && !widget.previewOnly &&
                widget.client != null && widget.session != null)
              ? DeliveryTripWorkspace(key:const ValueKey('delivery-trip-workspace'),
                  client:widget.client!,session:widget.session!)
            : (active == CompanySection.employees && !widget.previewOnly &&
                widget.client != null && widget.session != null)
              ? StaffWorkspace(key:const ValueKey('staff-workspace'),
                  client:widget.client!,session:widget.session!)
            : (active == CompanySection.purchases && !widget.previewOnly &&
                widget.client != null && widget.session != null)
              ? PurchasingWorkspace(key:const ValueKey('purchasing-workspace'),
                  client:widget.client!,session:widget.session!)
            : (active == CompanySection.transfers && !widget.previewOnly &&
                widget.client != null && widget.session != null)
              ? TransferWorkspace(key:const ValueKey('transfer-workspace'),
                  client:widget.client!,session:widget.session!)
            : (active == CompanySection.stocktakes && !widget.previewOnly &&
                widget.client != null && widget.session != null)
              ? StocktakeWorkspace(key:const ValueKey('stocktake-workspace'),
                  client:widget.client!,session:widget.session!)
            : (!widget.previewOnly && widget.client != null && widget.session != null &&
               const [CompanySection.customers,CompanySection.products,
                 CompanySection.prices].contains(active))
              ? CatalogWorkspace(
                  key: ValueKey('catalog-workspace-${active.name}'),
                  area: switch(active){
                    CompanySection.customers=>'customers',
                    CompanySection.products=>'products',
                    CompanySection.prices=>'price-lists',
                    CompanySection.warehouses=>'warehouses',
                    _=>'customers',
                  },
                  client:widget.client!,session:widget.session!,
                )
              : _Register(section: active, filter: filter, search: search,
                  onFilter: (value) => setState(() => filter = value.trim())),
        ),
      )),
    ]);
  }
}

class _Overview extends StatelessWidget {
  final ValueChanged<CompanySection> onSelect;
  final List<CompanySection> areas;
  const _Overview({required this.onSelect,required this.areas});

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final cols = width >= 1200 ? 4 : (width >= 700 ? 2 : 1);
    final metrics = const [
      ('Đơn hàng', Icons.receipt_long_outlined),
      ('Tồn kho', Icons.warehouse_outlined),
      ('Phải thu', Icons.account_balance_wallet_outlined),
      ('Doanh thu', Icons.trending_up_outlined),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Tổng quan điều hành', style: Theme.of(context).textTheme.titleLarge?.copyWith(
        fontWeight: FontWeight.w700, color: ErpPalette.of(context).ink,
      )),
      const SizedBox(height: 6),
      const SizedBox(height: 16),
      LayoutBuilder(builder: (context, constraints) {
        const spacing = 12.0;
        final cardWidth = (constraints.maxWidth - (cols - 1) * spacing) / cols;
        return Wrap(
          spacing: spacing, runSpacing: spacing,
          children: metrics.map((metric) => SizedBox(
            width: cardWidth,
            child: _Metric(title: metric.$1, icon: metric.$2),
          )).toList(),
        );
      }),
      const SizedBox(height: 26),
      Text('Truy cập nhanh', style: Theme.of(context).textTheme.titleMedium?.copyWith(
        color: ErpPalette.of(context).ink, fontWeight: FontWeight.w800)),
      const SizedBox(height: 12),
      LayoutBuilder(builder: (context, constraints) {
        final columns = constraints.maxWidth >= 1100 ? 3 : (constraints.maxWidth >= 650 ? 2 : 1);
        const spacing = 12.0;
        final itemWidth = (constraints.maxWidth - (columns - 1) * spacing) / columns;
        return Wrap(spacing: spacing, runSpacing: spacing, children: areas.map((item) => SizedBox(
          width: itemWidth,
          child: Card(
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: ValueKey('quick-${item.name}'),
              onTap: () => onSelect(item),
              child: Padding(padding: const EdgeInsets.all(18), child: Row(children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: ErpPalette.of(context).dark?ErpPalette.of(context).mint:ErpTokens.lime, borderRadius: BorderRadius.circular(ErpTokens.controlRadius)),
                  child: Icon(item.icon, color: ErpPalette.of(context).primary),
                ),
                const SizedBox(width: 14),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(item.label, style: TextStyle(color: ErpPalette.of(context).ink,
                    fontWeight: FontWeight.w700, fontSize: 15)),
                  const SizedBox(height: 4),
                  Text(item.subtitle, style: TextStyle(color: ErpPalette.of(context).muted, fontSize: 12)),
                ])),
                Icon(Icons.chevron_right, color: ErpPalette.of(context).muted),
              ])),
            ),
          ),
        )).toList());
      }),
    ]);
  }
}

class _Metric extends StatelessWidget {
  final String title;
  final IconData icon;
  const _Metric({required this.title, required this.icon});
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(padding: const EdgeInsets.all(18), child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Icon(icon, color: ErpPalette.of(context).primary, size: 22),
          const SizedBox(width: 9),
          Expanded(child: Text(title, style: TextStyle(color: ErpPalette.of(context).muted, fontSize: 13))),
        ]),
        const SizedBox(height: 12),
        Text('—', style: TextStyle(color: ErpPalette.of(context).ink, fontSize: 28, fontWeight: FontWeight.w800)),
        Text('Chưa có dữ liệu đối soát', style: TextStyle(color: ErpPalette.of(context).muted, fontSize: 12)),
      ],
    )),
  );
}

class _Register extends StatelessWidget {
  final CompanySection section;
  final String filter;
  final TextEditingController search;
  final ValueChanged<String> onFilter;
  const _Register({
    required this.section, required this.filter, required this.search, required this.onFilter,
  });

  @override
  Widget build(BuildContext context) {
    final cols = switch(section) {
      CompanySection.customers => const ['Mã khách hàng', 'Tên khách hàng', 'Nhóm', 'Trạng thái'],
      CompanySection.products => const ['SKU', 'Tên sản phẩm', 'Đơn vị', 'Trạng thái'],
      CompanySection.prices => const ['Mã bảng giá', 'Áp dụng từ', 'Kênh bán', 'Trạng thái'],
      CompanySection.warehouses => const ['Mã kho', 'Chi nhánh', 'Hàng tồn', 'Trạng thái'],
      CompanySection.transfers => const ['Kho xuất', 'Kho nhận', 'SL', 'Trạng thái'],
      CompanySection.stocktakes => const ['Mã phiếu', 'Kho', 'Chênh lệch', 'Trạng thái'],
      CompanySection.purchases => const ['Mã đơn mua', 'Nhà cung cấp', 'Kho', 'Trạng thái'],
      CompanySection.orders => const ['Mã đơn hàng', 'Ngày tạo', 'Khách hàng', 'Trạng thái'],
      CompanySection.deliveryTrips => const ['Mã chuyến', 'Tài xế', 'Xe', 'Điểm giao', 'Trạng thái'],
      CompanySection.employees => const ['Mã NV', 'Họ tên', 'Chi nhánh', 'Trạng thái'],
      CompanySection.receivables => const ['Mã chứng từ', 'Khách hàng', 'Ngày ghi sổ', 'Số dư'],
      CompanySection.reports => const ['Tên báo cáo', 'Kỳ dữ liệu', 'Lần đối soát', 'Trạng thái'],
      CompanySection.overview => const <String>[],
    };
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(section.icon, color: ErpPalette.of(context).primary),
            const SizedBox(width: 10),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(section.subtitle, style: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: ErpPalette.of(context).ink, fontWeight: FontWeight.w700)),
              const SizedBox(height: 3),
              Text('Danh sách và thông tin theo quyền tài khoản.',
                style: TextStyle(color: ErpPalette.of(context).muted, fontSize: 13)),
            ])),
            Tooltip(
              message: 'Chức năng này chưa thể sử dụng',
              child: FilledButton.icon(
                onPressed: null,
                icon: Icon(Icons.add),
                label: Text('Tạo mới'),
              ),
            ),
          ]),
          const SizedBox(height: 16),
          TextField(
            key: const ValueKey('company-search'),
            controller: search,
            onChanged: onFilter,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              labelText: 'Tìm trong ${section.label.toLowerCase()}',
              hintText: 'Nhập mã hoặc tên',
              suffixIcon: filter.isEmpty ? null : IconButton(
                tooltip: 'Xóa tìm kiếm',
                onPressed: () { search.clear(); onFilter(''); },
                icon: const Icon(Icons.close),
              ),
            ),
          ),
          const SizedBox(height: 18),
          ClipRRect(borderRadius: BorderRadius.circular(ErpTokens.controlRadius), child: Container(
            decoration: BoxDecoration(border: Border(top: BorderSide(color: ErpPalette.of(context).fresh, width: 3))),
            child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: DataTable(
              headingRowColor: WidgetStatePropertyAll(ErpPalette.of(context).mint),
              headingTextStyle: TextStyle(fontWeight: FontWeight.w700, color: ErpPalette.of(context).ink),
              columns: cols.map((c) => DataColumn(label: Text(c))).toList(),
              rows: const [],
            )),
          )),
          const SizedBox(height: 8),
          Center(child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 28),
            child: Column(children: [
              Icon(Icons.inbox_outlined, color: ErpPalette.of(context).muted, size: 34),
              const SizedBox(height: 9),
              Text('Chưa có dữ liệu',
                style: TextStyle(color: ErpPalette.of(context).ink, fontWeight: FontWeight.w700)),
              const SizedBox(height: 5),
              Text(filter.isEmpty
                ? 'Chưa có thông tin để hiển thị.'
                : 'Không có dữ liệu để tìm với từ khóa: $filter',
                textAlign: TextAlign.center,
                style: TextStyle(color: ErpPalette.of(context).muted, fontSize: 13)),
            ]),
          )),
        ]),
      ),
    );
  }
}
