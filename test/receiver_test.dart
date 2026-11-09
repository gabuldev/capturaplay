import 'dart:async';

import 'package:capturaplay/src/receiver/receiver_client.dart';
import 'package:capturaplay/src/receiver/receiver_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeReceiverClient implements ReceiverClient {
  final StreamController<ReceiverEvent> _events =
      StreamController<ReceiverEvent>.broadcast();
  final List<String> calls = [];

  @override
  Stream<ReceiverEvent> get events => _events.stream;

  @override
  Future<void> start() async {
    calls.add('start');
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
  }

  @override
  Future<void> connectService(String name) async {
    calls.add('service:$name');
  }

  @override
  Future<void> connectHost(String host, int port) async {
    calls.add('host:$host:$port');
  }

  @override
  Future<void> disconnect() async {
    calls.add('disconnect');
  }

  @override
  Future<void> setSmooth(bool smooth) async {
    calls.add('smooth:$smooth');
  }
}

void main() {
  testWidgets('o receptor mostra a busca e o IP manual', (tester) async {
    final client = FakeReceiverClient();
    await tester.pumpWidget(ReceiverApp(client: client));
    await tester.pump();

    expect(find.text('Procurando o Mac na rede'), findsOneWidget);
    expect(find.text('Conectar pelo IP'), findsOneWidget);
    expect(client.calls, contains('start'));

    await tester.enterText(find.byType(TextField), '192.168.0.8:47731');
    await tester.tap(find.text('Conectar pelo IP'));
    await tester.pump();
    expect(client.calls, contains('host:192.168.0.8:47731'));
  });
}
