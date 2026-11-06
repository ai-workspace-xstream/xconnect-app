/// Fixed-version Chinese mainland (CN) domain ruleset for Smart Routing.
///
/// Source: Curated offline ruleset aligned with v2fly/domain-list-community (@cn data subset).
/// License: MIT (https://github.com/v2fly/domain-list-community/blob/master/LICENSE)
/// Upstream reference: v2fly/domain-list-community (master snapshot)
///
/// Embedded offline rules eliminate the need to load external binary geosite.dat
/// assets at runtime, reducing memory footprint and avoiding missing-asset
/// startup failures in memory-sensitive packet tunnel extensions.
class CnDomainRules {
  static const String source =
      'v2fly/domain-list-community (curated CN ruleset)';
  static const String license = 'MIT';
  static const String upstreamReference =
      'v2fly/domain-list-community (master snapshot data/cn subset)';
  static const String geositeCompatTag = 'geosite:cn';

  /// Immutable list of Chinese mainland domain routing rules.
  ///
  /// Covers:
  /// 1. Top-level and second-level .cn domains (`domain:cn`, `regexp:^.*\.cn$`).
  /// 2. Major Chinese mainland commercial, social, e-commerce, cloud, and media
  ///    services operating under .com, .net, .org, or other generic TLDs.
  /// 3. Apple mainland CDN endpoints (`apple.com`, `icloud.com`, `apple-dns.net`)
  ///    which are routed directly in Smart mode and routed via VPN in Global mode.
  static const List<String> defaultRules = <String>[
    // TLD and second-level .cn domains
    'domain:cn',
    r'regexp:^.*\.cn$',

    // Search, Portals & Community
    'domain:baidu.com',
    'domain:bdstatic.com',
    'domain:bcebos.com',
    'domain:baidupcs.com',
    'domain:sohu.com',
    'domain:sina.com.cn',
    'domain:sina.cn',
    'domain:weibo.com',
    'domain:weibo.cn',
    'domain:zhihu.com',
    'domain:zhimg.com',
    'domain:csdn.net',
    'domain:gitee.com',
    'domain:oschina.net',
    'domain:douban.com',
    'domain:doubanio.com',

    // Tencent / WeChat
    'domain:qq.com',
    'domain:tencent.com',
    'domain:wechat.com',
    'domain:weixin.com',
    'domain:qpic.cn',
    'domain:gtimg.com',
    'domain:gtimg.cn',
    'domain:qlogo.cn',
    'domain:tenpay.com',
    'domain:tencent-cloud.com',
    'domain:tencent-cloud.net',

    // Alibaba / Ant Group
    'domain:taobao.com',
    'domain:alipay.com',
    'domain:alibaba.com',
    'domain:aliyun.com',
    'domain:tmall.com',
    'domain:tbcdn.cn',
    'domain:alicdn.com',
    'domain:1688.com',
    'domain:cainiao.com',
    'domain:alipayobjects.com',
    'domain:etao.com',

    // ByteDance
    'domain:bytedance.com',
    'domain:douyin.com',
    'domain:douyincdn.com',
    'domain:toutiao.com',
    'domain:feishu.cn',
    'domain:feishu.net',
    'domain:pstatp.com',
    'domain:byteimg.com',
    'domain:zijieapi.com',

    // E-commerce & Life Services
    'domain:jd.com',
    'domain:360buy.com',
    'domain:360buyimg.com',
    'domain:jdcloud.com',
    'domain:pinduoduo.com',
    'domain:yangkeduo.com',
    'domain:meituan.com',
    'domain:meituan.net',
    'domain:dianping.com',
    'domain:ele.me',

    // Video, Music & Streaming
    'domain:bilibili.com',
    'domain:hdslb.com',
    'domain:bilivideo.com',
    'domain:bilivideo.cn',
    'domain:iqiyi.com',
    'domain:iqiyipic.com',
    'domain:youku.com',
    'domain:ykimg.com',
    'domain:163.com',
    'domain:126.net',
    'domain:netease.com',
    'domain:kuaishou.com',
    'domain:yximgs.com',
    'domain:xiaohongshu.com',
    'domain:xhscdn.com',

    // Telecom, Travel & Navigation
    'domain:10010.com',
    'domain:189.cn',
    'domain:10086.cn',
    'domain:12306.cn',
    'domain:trip.com',
    'domain:ctrip.com',
    'domain:amap.com',
    'domain:autonavi.com',

    // Hardware & Device OEMs
    'domain:xiaomi.com',
    'domain:mi.com',
    'domain:xiaomi.net',
    'domain:huawei.com',
    'domain:vmall.com',
    'domain:dbankcdn.com',
    'domain:oppo.com',
    'domain:vivo.com',
    'domain:hihonor.com',

    // Financial & Payments
    'domain:unionpay.com',
    'domain:95516.com',

    // Apple China CDN / Services
    'domain:apple.com',
    'domain:icloud.com',
    'domain:apple-dns.net',
  ];

  /// Checks whether [domainOrRule] matches known CN domain patterns.
  static bool matches(String domainOrRule) {
    final lower = domainOrRule.trim().toLowerCase();
    if (lower.isEmpty) return false;
    if (lower.endsWith('.cn') || lower == 'cn') return true;
    for (final rule in defaultRules) {
      if (rule.startsWith('domain:')) {
        final target = rule.substring(7);
        if (lower == target || lower.endsWith('.$target')) return true;
      } else if (rule.startsWith('full:')) {
        if (lower == rule.substring(5)) return true;
      }
    }
    return false;
  }
}
