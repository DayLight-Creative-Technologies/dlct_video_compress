import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_compress_example/main.dart';

void main() {
  testWidgets('the home page offers compress, cancel and thumbnail',
      (tester) async {
    await tester.pumpWidget(const MyApp());

    expect(find.text('Pick a video to compress'), findsOneWidget);
    expect(find.byTooltip('Compress a video'), findsOneWidget);
    expect(find.byTooltip('Cancel compression'), findsOneWidget);
    expect(find.widgetWithText(ElevatedButton, 'Test thumbnail'),
        findsOneWidget);
  });
}
