import 'package:flutter_test/flutter_test.dart';
import 'package:brandmen_windows/updater.dart';

void main() {
  test('compareVersions compares numeric components', () {
    expect(AppUpdater.compareVersions('0.110.0', '0.99.0'), greaterThan(0));
    expect(AppUpdater.compareVersions('0.9.0', '0.110.0'), lessThan(0));
    expect(AppUpdater.compareVersions('v0.110.0', '0.110.0'), 0);
    expect(AppUpdater.compareVersions('0.110', '0.110.0'), 0);
  });
}
