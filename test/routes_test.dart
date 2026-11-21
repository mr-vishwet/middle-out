import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:middle_out/app.dart';
import 'package:middle_out/core/routes.dart';

void main() {
  group('AppRoutes', () {
    test('all 30 V7 routes exist and are unique', () {
      expect(AppRoutes.all.length, 30);
      expect(AppRoutes.all.toSet().length, 30);
    });

    test('every route generates a page', () {
      for (final name in AppRoutes.all) {
        final arguments = switch (name) {
          AppRoutes.frameDetail => 0,
          AppRoutes.historyDetail => 'demo-podcast',
          AppRoutes.authUpgrade => 30000000000,
          AppRoutes.authCreate => 'ada@example.com',
          _ => null,
        };
        final route = generateAppRoute(
          RouteSettings(name: name, arguments: arguments),
        );
        expect(route, isNotNull, reason: 'route $name');
      }
    });

    test('unknown names fall back to the shell', () {
      final route = generateAppRoute(
        const RouteSettings(name: '/no-such-route'),
      );
      expect(route, isNotNull);
    });
  });
}
