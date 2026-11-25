import 'package:material_ui/material_ui.dart';
import 'erp_tokens.dart';

/// ERP UI RULE: primary workspace tabs live inside the green title bar,
/// align right; secondary/nested tabs stay left in the content.
class ErpPageHeader extends StatelessWidget {
  final String heading;
  final String subtitle;
  final IconData icon;
  final Widget? trailing;
  const ErpPageHeader({super.key,required this.heading,
    required this.subtitle,required this.icon,this.trailing});

  @override Widget build(BuildContext context) => LayoutBuilder(
    builder:(context,constraints) {
      final stacked=trailing!=null && constraints.maxWidth<850;
      final compact=constraints.maxWidth<600;
      final title=Row(mainAxisSize:MainAxisSize.min,children:[
        Icon(icon,size:23,color:ErpTokens.lime),
        const SizedBox(width:12),
        Flexible(child:Column(mainAxisSize:MainAxisSize.min,
          crossAxisAlignment:CrossAxisAlignment.start,children:[
          Text(heading,maxLines:1,overflow:TextOverflow.ellipsis,
            style:TextStyle(color:Colors.white,fontSize:compact?18:22,
              fontWeight:FontWeight.w800)),
          const SizedBox(height:2),
          Text(subtitle,maxLines:1,overflow:TextOverflow.ellipsis,
            style:TextStyle(color:ErpTokens.sidebarText,fontSize:compact?11:12)),
        ])),
      ]);
      return Container(
        key:const ValueKey('erp-page-header'),
        height:stacked?(compact?116:138):(compact?58:80),
        width:double.infinity,
        padding:EdgeInsets.symmetric(horizontal:stacked?14:20),
        decoration:BoxDecoration(color:ErpPalette.of(context).action,
          borderRadius:BorderRadius.circular(ErpTokens.cardRadius),
          border:const Border(left:BorderSide(color:ErpTokens.lime,width:4))),
        child:stacked
          ? Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
              SizedBox(height:compact?6:10),
              SizedBox(height:compact?54:54,child:Align(alignment:Alignment.centerLeft,
                child:title)),
              const SizedBox(height:4),
              SizedBox(height:compact?48:66,child:trailing),
            ])
          : Row(children:[
              if(trailing==null)
                Expanded(child:Align(alignment:Alignment.centerLeft,child:title))
              else ...[
                ConstrainedBox(constraints:BoxConstraints(
                  maxWidth:constraints.maxWidth<1150?210:260),
                  child:title),
                const SizedBox(width:10),
                Expanded(child:trailing!),
              ],
            ]),
      );
    },
  );
}

/// Green-header primary tabs are a reusable navigation tier across ERP modules.
/// White high-contrast labels and a lime active underline; scroll on narrow widths.
class ErpHeaderTabs<T> extends StatelessWidget {
  final List<ErpSectionTab<T>> items;
  final T selected;
  final ValueChanged<T> onSelected;
  final String keyPrefix;
  const ErpHeaderTabs({super.key,required this.items,required this.selected,
    required this.onSelected,required this.keyPrefix});

  @override Widget build(BuildContext context) {
    final reduceMotion=MediaQuery.of(context).disableAnimations;
    return Semantics(label:'Điều hướng cấp 1',
      child:Align(alignment:Alignment.centerRight,
        child:SingleChildScrollView(
          key:const ValueKey('erp-header-tabs'),
          scrollDirection:Axis.horizontal,
          child:Row(mainAxisSize:MainAxisSize.min,children:items.map((item) {
            final active=item.value==selected;
            return Semantics(selected:active,button:true,
              child:Material(color:Colors.transparent,child:InkWell(
                key:ValueKey('$keyPrefix-${item.value}'),
                onTap:active?null:()=>onSelected(item.value),
                child:ConstrainedBox(
                  constraints:const BoxConstraints(minWidth:86),
                  child:Column(mainAxisSize:MainAxisSize.min,children:[
                    AnimatedContainer(
                      duration:reduceMotion?Duration.zero:ErpTokens.tabMotion,
                      height:45,padding:const EdgeInsets.symmetric(horizontal:10),
                      alignment:Alignment.center,
                      color:active?const Color(0x1CFFFFFF):Colors.transparent,
                      child:Text(item.label,maxLines:1,
                        overflow:TextOverflow.ellipsis,
                        style:TextStyle(color:Colors.white,
                          fontSize:13,fontWeight:active?FontWeight.w800:FontWeight.w600))),
                    Container(height:3,color:active?ErpTokens.lime:Colors.transparent),
                  ]),
                ),
              )),
            );
          }).toList()),
        ),
      ),
    );
  }
}

class ErpSectionTab<T> {
  final T value;
  final String label;
  const ErpSectionTab(this.value, this.label);
}

/// Flat, underline-selected tabs. Fixed widths avoid text-weight layout shifts.
class ErpSectionTabs<T> extends StatelessWidget {
  final List<ErpSectionTab<T>> items;
  final T selected;
  final ValueChanged<T> onSelected;
  final String keyPrefix;
  const ErpSectionTabs({super.key, required this.items, required this.selected,
    required this.onSelected, required this.keyPrefix});

  @override Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: ErpPalette.of(context).border))),
      child: SingleChildScrollView(
        key: const ValueKey('erp-section-tabs'),
        scrollDirection: Axis.horizontal,
        child: Row(children: items.map((item) {
          final active = item.value == selected;
          final tabWidth = item.label.length > 11 ? 148.0 : 116.0;
          return Semantics(selected: active, button: true,
            child: Material(color: Colors.transparent, child: InkWell(
              key: ValueKey('$keyPrefix-${item.value}'),
              onTap: () { if (!active) onSelected(item.value); },
              child: SizedBox(width: tabWidth, height: 46,
                child: Column(children: [
                  Expanded(child: Center(child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(item.label, maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: active ? ErpPalette.of(context).primary : ErpPalette.of(context).muted,
                        fontSize: 13, fontWeight: FontWeight.w600)),
                  ))),
                  SizedBox(width: tabWidth, height: 3,
                    child: AnimatedContainer(
                      duration: reduceMotion ? Duration.zero : ErpTokens.tabMotion,
                      curve: Curves.easeOutCubic,
                      color: active ? ErpPalette.of(context).primary : Colors.transparent)),
                ]),
              ),
            )),
          );
        }).toList()),
      ),
    );
  }
}

/// Reserve the entire content viewport, so switching never reflows the header.
Widget erpStableSwitcherLayout(Widget? current, List<Widget> previous) =>
  Stack(fit: StackFit.expand, children: [...previous, if (current != null) current]);

Widget erpFadeSwitcher(Widget child, Animation<double> animation) =>
  FadeTransition(opacity: animation, child: child);
