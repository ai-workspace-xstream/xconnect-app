# TEAM-2：团队受管连接同步

项目：https://github.com/orgs/ai-workspace-xstream/projects/1

本批次限本地自测与 UAT 测试，不访问或变更生产 Web SaaS、PROD 主机，本轮 PR 保持候选状态，不发布生产版本。

沿用同一 XConnect App。登录后先请求 `/api/auth/network-access`，再请求授权节点列表；个人模式保留手动连接，团队模式只能使用当前服务端、账号、团队和授权快照中的受管节点。服务端账号 ID 用作配置归属，SQLite 与 JSON 都保存节点归属字段。

账号/服务端切换、退出、授权撤销、权威空列表及团队节点故障会使受管连接失效，停止受影响的连接并删除受管节点与配置文件。保留专属模式标记，离线/旧服务端不能自动恢复公共资源。手动导入的节点在团队模式下不能显示或启动。启动时先恢复会话范围，再加载节点；旧磁盘配置不能恢复为可用团队节点。

同步请求绑定会话 generation；旧会话在途响应不能应用到新账号。正常同团队同步保留可用连接；服务到期有本地定时撤销，服务端仍是最终授权来源。原生启动完成前后都检查权限，防止切账号期间的启动继续成功。

自测：`flutter analyze`；`flutter test test/sync/team_access_sync_test.dart test/sync/xray_config_writer_test.dart test/services/vpn_config_legacy_node_test.dart test/screens/home_connection_state_test.dart`。

UAT 必须验证两账号切换、公共旧节点缓存、授权空列表、节点故障、到期、移除成员、在途同步和真实隧道断开。macOS/iOS 签名、真机和安装验证分别留证，静态检查与单元测试不能替代。
