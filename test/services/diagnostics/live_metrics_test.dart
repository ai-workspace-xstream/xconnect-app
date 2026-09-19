import 'package:flutter_test/flutter_test.dart';
import 'package:xconnect/services/diagnostics/live_metrics.dart';

ProbeSample ok(int ms) => ProbeSample.reached(Duration(milliseconds: ms));
const lost = ProbeSample.timedOut();

void main() {
  group('SegmentWindow', () {
    test('is warming up until five samples arrive', () {
      final w = SegmentWindow();
      for (var i = 0; i < 4; i++) {
        w.add(ok(50));
      }
      expect(w.stats.warmingUp, isTrue);
      w.add(ok(50));
      expect(w.stats.warmingUp, isFalse);
    });

    test('latency is the median of the last five successes', () {
      final w = SegmentWindow();
      for (final ms in [10, 900, 40, 30, 20, 50, 60]) {
        w.add(ok(ms));
      }
      // Last five successes: 40,30,20,50,60 -> median 40.
      expect(w.stats.latencyMs, 40);
    });

    test('a refused connection counts as reachable with its RTT', () {
      final w = SegmentWindow()
        ..add(const ProbeSample.refused(Duration(milliseconds: 12)));
      expect(w.stats.lossRate, 0);
      expect(w.stats.latencyMs, 12);
    });

    test('loss rate is timeouts over all samples in the window', () {
      final w = SegmentWindow();
      for (var i = 0; i < 8; i++) {
        w.add(ok(50));
      }
      w
        ..add(lost)
        ..add(lost);
      expect(w.stats.lossRate, closeTo(0.2, 1e-9));
    });

    test('unavailable samples are neither loss nor latency', () {
      final w = SegmentWindow()
        ..add(ok(50))
        ..add(const ProbeSample.unavailable());
      expect(w.stats.lossRate, 0);
      expect(w.stats.sampleCount, 1);
    });

    test('keeps only the most recent 30 samples', () {
      final w = SegmentWindow();
      for (var i = 0; i < 30; i++) {
        w.add(lost);
      }
      for (var i = 0; i < 30; i++) {
        w.add(ok(50));
      }
      expect(w.stats.lossRate, 0);
      expect(w.stats.sampleCount, 30);
    });

    test('a success at least 800ms above the median counts as a retransmit',
        () {
      final w = SegmentWindow();
      for (var i = 0; i < 9; i++) {
        w.add(ok(50));
      }
      w.add(ok(1100));
      expect(w.stats.retransmitRate, closeTo(0.1, 1e-9));
    });

    test('jitter is the mean absolute difference between successes', () {
      final w = SegmentWindow()
        ..add(ok(10))
        ..add(ok(30))
        ..add(ok(20));
      // |30-10| + |20-30| = 30, over 2 gaps.
      expect(w.stats.jitterMs, 15);
    });

    test('no successes means no latency, and 100% loss', () {
      final w = SegmentWindow()
        ..add(lost)
        ..add(lost);
      expect(w.stats.latencyMs, isNull);
      expect(w.stats.lossRate, 1);
    });
  });

  group('pickPhysicalIPv4', () {
    test('prefers a physical interface over tunnels and loopback', () {
      final picked = pickPhysicalIPv4(const [
        (name: 'lo0', address: '127.0.0.1'),
        (name: 'utun4', address: '198.18.0.1'),
        (name: 'en0', address: '192.168.0.107'),
      ]);
      expect(picked, '192.168.0.107');
    });

    test('ignores every known tunnel interface family', () {
      final picked = pickPhysicalIPv4(const [
        (name: 'utun0', address: '10.0.0.2'),
        (name: 'tun0', address: '10.0.0.3'),
        (name: 'wg0', address: '10.0.0.4'),
        (name: 'ipsec0', address: '10.0.0.5'),
        (name: 'ppp0', address: '10.0.0.6'),
      ]);
      expect(picked, isNull);
    });

    test('ignores link-local addresses', () {
      final picked = pickPhysicalIPv4(const [
        (name: 'en5', address: '169.254.10.1'),
        (name: 'wlan0', address: '10.1.2.3'),
      ]);
      expect(picked, '10.1.2.3');
    });
  });

  group('outboundServerEndpoint', () {
    test('reads the first vnext server of a dialing outbound', () {
      final ep = outboundServerEndpoint({
        'outbounds': [
          {'protocol': 'freedom', 'settings': {}},
          {
            'protocol': 'vless',
            'settings': {
              'vnext': [
                {'address': 'jp-xhttp.svc.plus', 'port': 443},
              ],
            },
          },
        ],
      });
      expect(ep, (host: 'jp-xhttp.svc.plus', port: 443));
    });

    test('also reads servers-style outbounds', () {
      final ep = outboundServerEndpoint({
        'outbounds': [
          {
            'protocol': 'trojan',
            'settings': {
              'servers': [
                {'address': '1.2.3.4', 'port': 8443},
              ],
            },
          },
        ],
      });
      expect(ep, (host: '1.2.3.4', port: 8443));
    });

    test('returns null when no outbound dials a server', () {
      expect(
        outboundServerEndpoint({
          'outbounds': [
            {'protocol': 'freedom', 'settings': {}},
          ],
        }),
        isNull,
      );
    });
  });

  group('liveVerdict', () {
    SegmentStats stats({int? latency, double loss = 0}) => SegmentStats(
          sampleCount: 10,
          latencyMs: latency,
          lossRate: loss,
          retransmitRate: 0,
          jitterMs: 0,
          warmingUp: false,
        );

    test('warming up has no verdict yet', () {
      expect(
        liveVerdict(SegmentStats.empty, tunConflict: false),
        LiveVerdict.sampling,
      );
    });

    test('another tunnel answering locally wins over everything', () {
      expect(
        liveVerdict(stats(latency: 30), tunConflict: true),
        LiveVerdict.tunConflict,
      );
    });

    test('total loss means the node is unreachable', () {
      expect(liveVerdict(stats(loss: 1), tunConflict: false),
          LiveVerdict.unreachable);
    });

    test('loss of 5% or more is unstable', () {
      expect(liveVerdict(stats(latency: 40, loss: 0.05), tunConflict: false),
          LiveVerdict.unstable);
    });

    test('latency of 300ms or more is slow', () {
      expect(liveVerdict(stats(latency: 300), tunConflict: false),
          LiveVerdict.slow);
    });

    test('otherwise good', () {
      expect(liveVerdict(stats(latency: 80, loss: 0.02), tunConflict: false),
          LiveVerdict.good);
    });
  });
}
