# 变更记录 / Changelog

本仓库的**逐版本发布说明以 [Releases](https://github.com/netglimmer/netglimmer-vpn-manage/releases/latest) 页为准**（包含下载资产、校验和与升级注意事项）。
本页只保留版本策略与索引，避免两处描述漂移。

This repository's per-release notes live on the [Releases](https://github.com/netglimmer/netglimmer-vpn-manage/releases/latest) page.
This file documents the versioning policy and indexes releases.

## 版本策略 / Versioning

版本号形如 `v主.次.修订`（`vMAJOR.MINOR.PATCH`）：

| 位 | 递增条件 |
|:--|:--|
| **MAJOR** | 不兼容变更：数据库结构不向后兼容、发布包目录结构调整、授权格式变更 |
| **MINOR** | 向后兼容的功能新增（新页面、新通知渠道、新策略能力） |
| **PATCH** | 向后兼容的缺陷修复、安装脚本健壮性修补、文档更正 |

发布包命名：

```
netglimmer_vpn_install_v<版本>_linux-amd64.tar.xz         完整包（含 offline-debs/）
netglimmer_vpn_install_v<版本>_core_linux-amd64.tar.xz    核心包（不含系统 deb）
```

## 升级兼容性

- 替换 `ocserv-manager` 二进制 + `systemctl restart ocserv-manager` 即完成升级，**授权、用户数据、证书与配置全部保留**。
- 数据库为增量迁移（`CREATE TABLE IF NOT EXISTS` + 容错列补齐），旧库可直接被新版本读取。
- 跨 MAJOR 升级前请先在面板「配置备份」导出一次 ZIP，或直接用安装脚本重装（自带快照与自动回退）。

## 版本索引 / Releases

| 版本 | 说明 |
|:--|:--|
| [v1.8](https://github.com/netglimmer/netglimmer-vpn-manage/releases/tag/v1.8) | 当前版本 |
| 更早版本 | 见 [Releases 列表](https://github.com/netglimmer/netglimmer-vpn-manage/releases) |

> 需要某个版本的具体变更清单？在对应 Release 下留言，或在
> [Issue](https://github.com/netglimmer/netglimmer-vpn-manage/issues) 中标注版本号，供应商会补充说明。
