import 'package:flutter_test/flutter_test.dart';
import 'package:xconnect/services/diagnostics/live_metrics.dart';

SegmentStats s({int? latency, double loss = 0, bool warming = false}) =>
    SegmentStats(
      sampleCount: 10,
      latencyMs: latency,
      lossRate: loss,
      retransmitRate: 0,
      jitterMs: 0,
      warmingUp: warming,
    );

void main() {
  group('attributePath', () {
    test('router hop and router-to-node hop are split by subtraction', () {
      final p = attributePath(
        local: s(latency: 3, loss: 0.10),
        node: s(latency: 161, loss: 0.10),
      );
      expect(p.local.latencyMs, 3);
      expect(p.local.lossRate, closeTo(0.10, 1e-9));
      expect(p.upstream.latencyMs, 158);
      expect(p.upstream.lossRate, 0);
      expect(p.culprit, Culprit.local);
    });

    test('upstream is to blame when the local hop is clean', () {
      final p = attributePath(
        local: s(latency: 2),
        node: s(latency: 420, loss: 0.08),
      );
      expect(p.culprit, Culprit.upstream);
      expect(p.upstream.level, DiagLevel.bad);
    });

    test('a slow but lossless LAN hop above 50ms is the culprit', () {
      final p = attributePath(local: s(latency: 60), node: s(latency: 120));
      expect(p.local.level, DiagLevel.bad);
      expect(p.culprit, Culprit.local);
    });

    test('everything healthy has no culprit', () {
      final p = attributePath(local: s(latency: 3), node: s(latency: 90));
      expect(p.culprit, Culprit.none);
      expect(p.local.level, DiagLevel.good);
      expect(p.upstream.level, DiagLevel.good);
    });

    test('an unmeasurable router never shows up as 100% loss', () {
      final p = attributePath(
        local: null,
        localUnmeasurable: true,
        node: s(latency: 90),
      );
      expect(p.local.state, SegmentState.unmeasurable);
      expect(p.local.lossRate, isNull);
      expect(p.upstream.latencyMs, 90);
    });

    test('unknown gateway reports the whole path as one segment', () {
      final p = attributePath(local: null, node: s(latency: 90));
      expect(p.local.state, SegmentState.unknown);
      expect(p.upstream.latencyMs, 90);
      expect(p.upstream.state, SegmentState.measured);
    });

    test('warming up assigns no blame', () {
      final p = attributePath(
        local: s(latency: 200, loss: 0.5, warming: true),
        node: s(latency: 400, warming: true),
      );
      expect(p.culprit, Culprit.none);
      expect(p.local.state, SegmentState.warmingUp);
    });
  });

  group('acceptGateway', () {
    test('accepts a private gateway on the physical subnet', () {
      expect(acceptGateway('192.168.0.1', physical: '192.168.0.107'), isTrue);
    });

    test('rejects a gateway on another network (e.g. a tunnel peer)', () {
      expect(acceptGateway('198.18.0.1', physical: '192.168.0.107'), isFalse);
    });

    test('rejects missing values and the host itself', () {
      expect(acceptGateway(null, physical: '192.168.0.107'), isFalse);
      expect(
          acceptGateway('192.168.0.107', physical: '192.168.0.107'), isFalse);
      expect(acceptGateway('192.168.0.1', physical: null), isFalse);
    });
  });
}
