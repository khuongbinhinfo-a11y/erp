import 'package:material_ui/material_ui.dart';
import 'identity_client.dart';
bool get erpAndroidUpdateSupported=>false;
Future<void> showErpAndroidUpdate(BuildContext context,ErpIdentityClient client,
  IdentitySession session,bool Function() isCurrent) async {}

Future<String?> erpAndroidQuietUpdateVersion(ErpIdentityClient client,IdentitySession session)async=>null;
