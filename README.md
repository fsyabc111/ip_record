# IP Record

供当前 Apple Silicon Mac 使用的原生菜单栏应用，记录公网出口、本机 IPv4／IPv6 和系统可见网络配置。默认约5分钟检查；地址或网络状态变化才新增历史。没有 Dock 图标、通知、定位或云同步。

已实现 Swift 6 + AppKit / SwiftUI 单进程应用、SQLite 历史、官方 C 读取器的离线双栈归属、筛选、CSV／JSON 导出、暂停持久化、空档标记和登录项管理。设计依据见 [封版 v1.0](docs/design/README.md)；实测范围与未验收事项见 [验证报告](docs/verification/v1.0-report.md)。

后续内存优化的范围、测量方法与验收标准见 [内存优化规划](docs/plans/memory-optimization.md)，目前仅规划，尚未实施。

## 构建与安装

当前验证环境：Apple Silicon、macOS 27.0.1、Apple Swift 6.4 / Command Line Tools 27。无需完整 Xcode、Python 运行时或外部 Swift 包。

```sh
cd /Users/fsy/code/ip_record
./scripts/test.sh
./scripts/install-app.sh --open
./scripts/verify-bundle.sh "$HOME/Applications/IP Record.app"
```

构建产物为 `dist/IP Record.app`；固定安装到 `~/Applications/IP Record.app`。替换前从应用菜单明确退出，安装脚本会拒绝覆盖运行中的进程。
应用使用本地 ad hoc 签名；`IPRECORD_SIGN_IDENTITY` 可指定本机已有签名身份。无需为本机使用购买证书。脚本会校验签名，不等于登录启动已通过重新登录验收。

CLT 27 默认 `swiftbuild` 未正确定位自带的 Testing 插件，且未提供新版 SwiftUI State 宏插件。脚本使用当前可用的 SwiftPM native backend，测试显式定位 CLT 的 Testing.framework；界面用 SDK 现有的 State 属性包装器。没有联网拉取依赖。

首次主动打开会显示说明，“登录时启动”预选，点击“开始记录”。以后从菜单栏网络图标查看当前状态、历史和设置。关闭窗口继续记录，`⌘Q` 或“退出 IP Record”结束进程；暂停跨退出保留。

数据位于 `~/Library/Application Support/local.fsy.iprecord/`，目录0700，SQLite及其附属文件限制当前用户访问。设置位于 Bundle ID 对应的 UserDefaults。清空历史保留当前状态、设置和归属数据库，不是磁盘安全擦除。

公网查询仅访问 `https://api.ipify.org` 和 `https://api6.ipify.org`，沿用系统网络及代理；失败保留上次成功事实但不冒充当前确认。IPv6 出口查询失败不能说明本机没有 IPv6。DNS、代理和网关只是公开系统配置视图，不能证明全部流量路径。

## 使用与排错

- 历史默认最近7天，每页100条，可按类型、时间、IP、接口或归属筛选；JSON保留首次观测与确认摘要，CSV为带公式防护的摘要。
- “无法保存记录”会停止后续公网检查，保留上次已保存状态；可在菜单或设置重试。不要删除或覆盖故障原库以掩盖问题。
- 登录项状态来自系统。注册失败时可在设置中切换“由系统设置管理”，再在系统设置 → 通用 → 登录项与扩展中手工添加固定安装路径。手工项无法由应用可靠读取状态。
- 菜单栏空间不足时，图标可能被系统隐藏；可先关闭部分其他菜单栏项目后重新打开应用。
- 卸载前明确退出并移除登录项；删除 `.app` 不会自动删除历史。历史长期保留，不自动裁剪。

## 验证命令

```sh
./scripts/test.sh
./scripts/build-app.sh
# 隔离目录中的程序级窗口／真实网络检查，不是人工交互验收：
'dist/IP Record.app/Contents/MacOS/IPRecord' --self-check "$PWD/.artifacts/shell-check"
# 30分钟真实后台采样，隔离历史、无窗口、不修改日常网络：
python3 scripts/measure-resources.py "$HOME/Applications/IP Record.app/Contents/MacOS/IPRecord" "$PWD/.artifacts/resources"
```

验证模式不修改正式历史或登录项。真实地址与配置仅留在本地忽略的 `.artifacts/`，提交报告只保留状态、计数和资源摘要。睡眠／重登录步骤见验证报告。

## 数据范围

使用 [ip2region 官方仓库 v3.18.0](https://github.com/lionsoul2014/ip2region/tree/v3.18.0)
提供的全球 IPv4、IPv6 XDB 数据。中国地区主要为中文，其他地区主要为英文。
字段为国家、省／地区、城市、运营商和国家代码；本数据不包含 ASN。
全球数据并不意味着每个 IP 都有完整城市信息，缺失字段以 `null` 表示。

| 文件 | 大小 | XDB 头中的生成时间（UTC+8） |
| --- | ---: | --- |
| `data/ip2region/ip2region_v4.xdb` | 11,122,036 字节（约 10.6 MiB） | 2026-08-28 12:43:01 |
| `data/ip2region/ip2region_v6.xdb` | 37,277,813 字节（约 35.6 MiB） | 2026-08-14 13:38:41 |

下载来源、版本、下载时间、文件大小和 SHA-256 保存在
`data/ip2region/manifest.json`。生成时间不代表每条归属数据的采集时间；
上游社区数据不定期更新，归属结果是估计，可能缺失或过时。

## 本地查询

需要 Python 3.7 或更新版本，无需 pip 安装依赖。在任意目录运行：

```sh
python3 /Users/fsy/code/ip_record/scripts/lookup_ip.py 113.118.113.77
python3 /Users/fsy/code/ip_record/scripts/lookup_ip.py 1.2.3.4 81.2.69.142 2604:a840:3::a04d
```

每行输出一个 JSON 结果，包含 `country`、`province`、`city`、`isp` 等字段。
私网、回环及其他非公网单播地址返回 `non_public`，不尝试推断地理位置。
合法地址未命中返回 `not_found`；非法输入或文件错误返回 `error`，进程以非零状态退出。
查询使用官方 Python 读取器的文件读取模式，不会将整个数据库加载到内存。
此脚本不使用网络，也不获取本机当前公网 IP；当前公网出口的发现仍需要联网。

## 来源与维护

- `vendor/ip2region/ip2region/`：原样保留的官方 Python 读取器（`searcher.py`、`util.py`）。
- `vendor/ip2region/LICENSE.md`：上游许可证全文。
- `vendor/ip2region/UPSTREAM_README.md`、`PYTHON_README.md`：同版本官方说明。

更新时从官方版本重新获取数据库与匹配的读取器，校验文件、执行 IPv4／IPv6
查询后再替换，并更新 manifest。历史记录应保留查询当时的数据版本，
避免库更新后直接覆盖历史归属信息。

原生应用捆绑相同的 XDB 文件及同版本官方 C 读取器。Python 脚本只用于手动查询，不随应用运行。
