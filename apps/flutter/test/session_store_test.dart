import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:erp_distribution/ui/session_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('persistent session survives reload and is removed only by logout',()async {
    SharedPreferences.setMockInitialValues({});
    const token='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmn_12';
    expect(token.length,43);
    expect(await ErpSessionStore.load(),isNull);
    await ErpSessionStore.save(token);
    expect(await ErpSessionStore.load(),token);
    // A new SharedPreferences.getInstance reads the same stored token.
    expect(await ErpSessionStore.load(),token);
    await ErpSessionStore.clear();
    expect(await ErpSessionStore.load(),isNull);
  });

  test('never persist malformed bearer token',()async {
    SharedPreferences.setMockInitialValues({});
    await expectLater(ErpSessionStore.save('not-a-token'),throwsArgumentError);
    expect(await ErpSessionStore.load(),isNull);
  });
}
