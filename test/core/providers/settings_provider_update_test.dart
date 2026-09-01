import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/business_test_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('disables official update notices by default', () async {
    final harness = await createBusinessTestHarness();
    final settings = SettingsProvider(harness.preferences);

    await settings.loaded;

    expect(settings.showAppUpdates, isFalse);
  });

  test('preserves an explicit update notice preference', () async {
    final harness = await createBusinessTestHarness(
      initial: const {'display_show_app_updates_v1': true},
    );
    final settings = SettingsProvider(harness.preferences);

    await settings.loaded;

    expect(settings.showAppUpdates, isTrue);
    await settings.setShowAppUpdates(false);
    expect(harness.preferences.getBool('display_show_app_updates_v1'), isFalse);
  });
}
