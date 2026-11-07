# macOS 技术可行性与证据

日期：2026-11-07（Asia/Taipei）。用途：为 IP Record 设计决策提供依据。

本文区分官方能力、设计推论与尚未执行的实机验证。只做文档、SDK 头文件和上游源代码核查；没有构建应用、注册登录项、改变网络配置或向公网 IP 探测端点发起请求。

## 1. 已知范围与建议路线

用户已确认仅在自己的 Apple Silicon Mac 上使用；记录应用按系统网络实际访问探测服务时的公网出口，不另外区分直连和代理；历史在 IP 或网络状态变化时新增。菜单 IPv4 优先，IPv6 与其他接口展开查看。补充系统报告的网关、DNS 和代理配置，不记录 Wi-Fi 名；首次使用后希望登录启动；历史长期保存，可以手动清空。

建议采用 Swift 原生单进程应用，AppKit 管理菜单栏与窗口生命周期，可用 SwiftUI 编写历史和设置内容；SQLite 保存历史，ip2region C 读取器查询已下载的双栈 XDB。无需 Python 运行时、浏览器容器、root 后台进程或网络扩展。这是设计建议，不是已经完成的应用验证。

本机探查：macOS 27.0.1，arm64，Swift 6.4，当前活动开发目录为 `/Library/Developer/CommandLineTools`。本机自用的支持声明可先限定此环境；如项目把部署目标设为 macOS 13 或 14，仍不意味着已经验证旧系统兼容性。`SMAppService` 自 macOS 13 提供，现代 `NSApplication.activate()` 自 macOS 14 提供。[SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)、[activate()](https://developer.apple.com/documentation/appkit/nsapplication/activate())

## 2. 菜单栏、窗口与退出

| 能力 | 官方事实 | 对设计的影响 |
| --- | --- | --- |
| 无 Dock 图标 | `LSUIElement` 表示在后台运行、不显示 Dock 图标的 agent app | 在应用 Info.plist 中设为 true；这里的 agent app 是 macOS 应用类型，不是额外 helper |
| 菜单栏 | `NSStatusItem` 支持图标按钮、菜单及可选行为；默认不允许用户交互移除 | 推荐 `NSStatusItem + NSMenu`，保留强引用，使用固定宽度模板图标 |
| SwiftUI 替代 | `MenuBarExtra` 支持菜单或 window 样式；仅有菜单栏 extra 的应用在用户移除 extra 时会自动终止 | 可以使用，但不能把图标移除当作无关展示变化；本项目不需要这个额外语义 |
| 关闭窗口 | delegate 返回 false 时，关闭最后一个窗口不会终止应用 | 关闭历史／设置窗口继续记录；只有明确“退出”停止进程 |

依据：[LSUIElement](https://developer.apple.com/documentation/bundleresources/information-property-list/lsuielement)、[NSStatusItem](https://developer.apple.com/documentation/appkit/nsstatusitem)、[terminationOnRemoval](https://developer.apple.com/documentation/appkit/nsstatusitem/behavior-swift.struct/terminationonremoval)、[MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra)、[applicationShouldTerminateAfterLastWindowClosed](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationshouldterminateafterlastwindowclosed(_:))。

建议使用标准 NSMenu 展示当前摘要及展开子菜单，历史和设置各复用一个窗口。用户点击菜单或重新打开应用时才请求窗口激活；后台启动、定时检查、唤醒不抢焦点。macOS 27 已将 `activate(ignoringOtherApps:)` 标记废弃；使用 `activate()` 配合窗口显示，但官方明确该调用不保证一定获得前台，因此“无 Dock 情况下窗口能正确出现且接收键盘”须实机验证。[旧激活方法](https://developer.apple.com/documentation/appkit/nsapplication/activate(ignoringotherapps:))、[新激活方法](https://developer.apple.com/documentation/appkit/nsapplication/activate())

## 3. 登录启动、签名与本机安装

`SMAppService.mainApp` 对应主应用本身的登录启动，不要求引入独立 helper。注册后在后续登录时启动；注销主应用登录项不会把当前主进程立即结束。这符合“退出就停止，下一次登录再启动”的产品语义，而不是守护进程自动重启语义。[SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)、[register()](https://developer.apple.com/documentation/servicemanagement/smappservice/register())

登录设置必须读取系统实际 `status`：`notRegistered`、`enabled`、`requiresApproval`、`notFound`；不能只读本地 Boolean。当用户在系统设置撤销允许时，可能变为 `requiresApproval`。在应用启动、打开设置以及从系统设置返回时刷新状态；注册失败应保留手动启动和记录能力，不显示已成功自启动，也不能循环注册覆盖用户的系统选择。[requiresApproval](https://developer.apple.com/documentation/servicemanagement/smappservice/status-swift.enum/requiresapproval)、[迁移与状态检查](https://developer.apple.com/documentation/servicemanagement/updating-helper-executables-from-earlier-versions-of-macos)

**签名是一个必须先验证的实现门。** 本机 SDK 的 `ServiceManagement.framework/Headers/SMAppService.h` 第 49 行要求调用应用签名，第 168 行说明签名不合要求会返回 `kSMErrorInvalidSignature`；公开错误说明也有此条件。不能从“可以运行 ad hoc 签名的 .app”推导“当前系统一定接受其自动注册登录项”，也不能反过来断言本机自用必须购买 Developer ID。[签名错误](https://developer.apple.com/documentation/servicemanagement/ksmerrorinvalidsignature)

存在不增加 helper 的退路：用户在系统设置 → 通用 → 登录项与扩展 → 登录时打开，手动添加安装好的 `.app`。Apple 的 macOS 27 支持文档明确支持选择应用。此模式由系统手动管理，不能仅凭 `SMAppService.status` 判定手动登录项是否存在；界面应显示“在系统设置中管理”，避免同时以两种模式重复配置。[手动登录项](https://support.apple.com/en-ie/guide/mac-help/mh15189/27/mac/27)

CLT 提供 macOS SDK 和工具链，支持在 Xcode 以外构建；但 `xcodebuild`、`xctrace` 不属于独立 CLT 套件。SwiftPM 可管理 Swift 和 C target，额外构建脚本负责 `.app/Contents/MacOS`、Info.plist、资源和本地签名。这只是构建路线可行性，仍须验证应用 bundle 身份、资源定位、启动和签名。当前不研究商店上架或对外公证。[CLT 官方说明](https://developer.apple.com/documentation/xcode/installing-the-command-line-tools)、[SwiftPM](https://docs.swift.org/main/documentation/packagemanagerdocs/)

建议固定安装位置和 Bundle ID，不从构建临时目录注册登录项。应用替换后重验登录启动；是否需要重新注册以实测和系统状态为准，避免在每次启动时无条件注销再注册。

## 4. 网络状态和本机地址

`NWPathMonitor` 监听可用网络路径变化；它不是公网出口变化通知，也不包含本机全部地址清单。`NWPath.availableInterfaces` 是路径可用接口的偏好列表，不是某次 HTTP 请求实际经过的唯一接口。由此推论：不能用第一项接口、`usesInterfaceType` 或 `satisfied` 分别证明真实出接口、公网地址或互联网可达性。[NWPathMonitor](https://developer.apple.com/documentation/network/nwpathmonitor/)、[availableInterfaces](https://developer.apple.com/documentation/network/nwpath/availableinterfaces)

使用公开 `getifaddrs` 获取本机地址、接口名、flags、netmask 等，必须检查空指针、只读取对应地址族的结构，并释放链表。一次快照包含多个接口及同一接口的多个 IPv6 地址；不要假设 en0 必为 Wi-Fi，或“本机接口地址”必是 RFC1918 私网地址。IPv6 link-local 地址需要保留 scope；虚拟接口、临时 IPv6、回环和隧道地址应有明确的分类和显示规则。[getifaddrs 手册](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/getifaddrs.3.html)

使用 `SCDynamicStoreSetNotificationKeys` 监听公开网络状态键的变化，以补充地址、DNS、代理配置变化。回调只调度合并后的采集，不逐个事件立即发请求；定时采集仍然需要保留，因为路由器 NAT 出口或远端代理变化可能没有本机系统配置变化。[通知键](https://developer.apple.com/documentation/systemconfiguration/scdynamicstoresetnotificationkeys(_:_:_:))

睡眠与唤醒使用 `NSWorkspace.shared.notificationCenter` 上的 willSleep/didWake 事件，不能错用普通默认 notification center；屏幕熄灭事件也不等同机器睡眠。睡眠取消在途轮次并停止调度，唤醒后去抖采集一次，不补做睡眠期间所有轮次。[didWakeNotification](https://developer.apple.com/documentation/appkit/nsworkspace/didwakenotification)、[NSWorkspace](https://developer.apple.com/documentation/appkit/nsworkspace)

## 5. 网关、DNS 和代理：只能承诺系统配置视图

### 5.1 公开读取路径

`SCDynamicStore` 提供运行系统的配置和网络状态键值；`SCSchemaDefinitions` 定义下表涉及的公开实体和字段。应使用公开 key 构造函数／常量，不依赖 `scutil` 文本、私有符号或下划线开头的未公开键。[SCDynamicStore](https://developer.apple.com/documentation/systemconfiguration/scdynamicstore-gb2)、[SCSchemaDefinitions](https://developer.apple.com/documentation/systemconfiguration/scschemadefinitions)

| 信息 | 公开数据视图 | 记录合同与限制 |
| --- | --- | --- |
| 主服务／主接口 | `State:/Network/Global/IPv4` 与 IPv6 实体中的 `PrimaryService`、`PrimaryInterface` | 每地址族独立，可不存在，不证明所有目的地址都走这个接口 |
| 系统报告网关 | global IPv4/IPv6 与对应 service IPv4/IPv6 实体中的 `Router` | 记录地址族、来源作用域、接口（已知时）；缺失时未知，不从相邻 IP 推算 |
| DNS 配置 | global DNS 和 service DNS 实体中的 `ServerAddresses`、`SearchDomains`、`DomainName`、`SupplementalMatchDomains`、`SupplementalMatchOrders` | 记录有出处的配置项；没有完整有效解析器列表保证 |
| 系统代理配置 | `SCDynamicStoreCopyProxies`；公开 HTTP/HTTPS/SOCKS/PAC/WPAD 与例外字段 | 白名单提取，不整份 dump；返回 nil 可能是无配置或错误，不能直接解释为全部关闭 |

主服务字段有独立公开文档；本机 macOS 27 SDK `SCSchemaDefinitions.h` 声明了上述 DNS、Router、代理字段。[PrimaryService](https://developer.apple.com/documentation/systemconfiguration/kscdynamicstorepropnetprimaryservice-swift.var)、[SCDynamicStoreCopyProxies](https://developer.apple.com/documentation/systemconfiguration/scdynamicstorecopyproxies(_:))

### 5.2 必须保留的语义

- 网关标题建议为“系统报告网关”。VPN、TUN、分流路由下，它不等价于任意请求的实际下一跳。IPv6 网关若为 link-local，仅在已知匹配接口时绑定 scope，未知则不猜测。
- DNS 标题为“系统 DNS 配置”，不是“实际 DNS 上游”。可见配置可能是本机代理地址，也可能存在作用域、补充分域或网络扩展配置；本应用不主动执行 DNS 泄漏测试，也不枚举每个域名的实际解析选择。基础返回合同建议始终为 `coverage=partial`，另外使用 `available/not_observed/unavailable` 表达可见值和读取结果。
- `ServerAddresses` 顺序可能表达配置优先次序，不能为去重而排序；同一个地址在不同 service／匹配域下不能合并成一个没有出处的地址。缺少可见 DNS 服务器不等价于机器无法解析域名。
- 代理配置开关不证明探测请求是否命中某条 PAC 规则，更不证明全机流量都使用代理。保存 enabled/host/port、自动代理开关、例外规则的安全投影即可；不评估 PAC、不请求 PAC URL、不记录认证字段。
- PAC 完整 URL 可能包含 userinfo、路径 token 和查询参数。若需变化检测，可只保留移除凭证的 `scheme://host:port` 和设备本地密钥参与的 HMAC 指纹，不保存原始 URL、PAC JavaScript 或账号。使用普通 SHA-256 的 URL 指纹也不能被描述为消除了可猜测 URL 的泄漏风险。若产品不要求识别同源路径变化，仅记录 origin 与开关更简单。

以上为保守设计合同，不是宣称这些公开 API 在所有 VPN、DoH、MDM 和未来系统组合下都能完整观察配置。实际字段缺失和配置切换行为列入早期验收。

## 6. 公网探测、地址族与代理

### 6.1 探测端点

ipify 官方说明提供下列 HTTPS 纯文本端点。本次只阅读说明，未调用它们：

| 用途 | 端点 | 约束 |
| --- | --- | --- |
| IPv4 出口 | `https://api.ipify.org` | 响应必须验证为 IPv4 |
| IPv6 出口 | `https://api6.ipify.org` | 官方说明没有 IPv6 时请求失败；响应必须验证为 IPv6 |
| 单次择一 | `https://api64.ipify.org` | 只返回选中地址族的一条地址，不能代替双族分别检查 |

官方提供无密钥调用并声明不记录访问者信息；这是供应商声明，不是本项目核验过的隐私或可用性保证。[ipify 官方文档](https://www.ipify.org/)

v1 建议一个供应商、每族一个端点；没有经过实测和官方文档核实的独立备用时，不伪装成已有冗余。IPv4-only 端点不能充当 IPv6 备用。端点不可达时记录查询失败，继续本机地址采集、离线归属查询和历史查看。不要悄悄轮流调用多个供应商、把分流出口变化混成用户 IP 变化。

### 6.2 网络实现合同

建议专用 ephemeral `URLSession`，禁止持久缓存、cookies 和凭据存储，不用后台传输会话；保留默认系统代理行为，不自动读取浏览器代理或 shell 环境变量代替系统网络。系统配置变化后如需更新会话策略，应创建新 session，因为配置在 session 初始化时复制。[URLSessionConfiguration](https://developer.apple.com/documentation/foundation/urlsessionconfiguration)

`connectionProxyDictionary=nil` 使用系统设置；更现代的 `proxyConfigurations` 默认空数组也使用系统设置，**空数组不是禁用代理**。当前用户要求按系统出口，无需覆盖这两项。[connectionProxyDictionary](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/connectionproxydictionary)、[proxyConfigurations](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/proxyconfigurations)

`URLSession` 没有应当在这里假定存在的“强制本机 AF_INET/AF_INET6 并证明整个路径”的通用开关。分族主机名配合响应地址族验证满足“记录服务看到的 v4/v6 出口”；代理可能在另一地址族上连向服务，所以 `api6` 成功不能单独证明 Mac 有原生 IPv6。HTTP 代理是否开启、TUN 路由与本地接口地址族也是不同事实。Apple 建议应用优先使用可按名称连接的 URLSession／Network framework，而不是为取 IP 自己实现 DNS、Happy Eyeballs 和 TLS。[Apple IPv6 支持](https://developer.apple.com/support/ipv6)、[TN3151](https://developer.apple.com/documentation/technotes/tn3151-choosing-the-right-networking-api)

可选保存 `URLSessionTaskTransactionMetrics.localAddress` 与 `isProxyConnection` 作为诊断观测。它们仅描述具体连接；前者可能 nil，后者不检测全部 VPN／TUN。不能把 metrics 关联接口推论成完整流量追踪。[localAddress](https://developer.apple.com/documentation/foundation/urlsessiontasktransactionmetrics/localaddress)、[isProxyConnection](https://developer.apple.com/documentation/foundation/urlsessiontasktransactionmetrics/isproxyconnection)

失败要区分 DNS、连接、TLS、超时、HTTP 状态、响应超长／非法地址。没有 IPv6 响应统一表达“IPv6 出口未确认”，不武断表达“电脑没有 IPv6”。本地 path satisfied 但探测失败时显示“公网查询失败”，不是“断网”。设计中须规定响应体上限、拒绝非预期重定向、完整轮次 deadline、取消与过期轮次隔离；这些属于实现合同，尚未实测。

## 7. ip2region 原生接入

官方 v3.18.0 的 C 读取器通过 `xdb_api.h`、`xdb_searcher.c`、`xdb_util.c` 支持 IPv4／IPv6，头文件有 `__APPLE__` 分支，并使用标准 C 与系统 socket 地址解析。可建立单独 C target，通过 module map 暴露一个窄 Swift 封装；不需要移植 Python 或重写 XDB 格式。[官方 C 文档](https://github.com/lionsoul2014/ip2region/blob/v3.18.0/binding/c/README.md)、[C 接口](https://github.com/lionsoul2014/ip2region/blob/v3.18.0/binding/c/xdb_api.h)、[Swift module map](https://docs.swift.org/main/documentation/packagemanagerdocs/modulemaps/)

官方支持文件模式、512 KiB 向量索引缓存和全文件缓存。对每 5 分钟且地址变化才查询的负载，建议每个地址族一个文件模式 searcher，并在同一串行执行域内使用；不要跨线程无保护地共享文件句柄。每次查询管理并释放 region buffer，查询结束后把 UTF-8 文本复制成 Swift 值。若以后使用 Swift actor，C 指针和句柄的隔离／Sendable 合同必须显式实现，不能仅因 actor 存在就忽略 C 并发规则。[查询实现](https://github.com/lionsoul2014/ip2region/blob/v3.18.0/binding/c/xdb_searcher.c)

现有数据：IPv4 11,122,036 字节，IPv6 37,277,813 字节，格式 v3；生成时间分别为 2026-08-28 和 2026-08-14，来源和 SHA-256 已在 `data/ip2region/manifest.json` 保存。既有 `verification.json` 是 Python 本地查询功能样例，不是 Swift/C 集成或定位准确率验收。

上游 region 字段是国家、省／地区、城市、运营商、国家代码；没有 ASN。`0` 或空字段映射为 unknown，外国地区保留原文，不补造缺失城市。已有地区数据不能被当成位置精度证明，也不支持由本库推断用户街道。[上游说明](https://github.com/lionsoul2014/ip2region/blob/v3.18.0/README.md)

本地已保留顶级许可证，仓库声明 Apache-2.0 OR MIT；上游代码文件有 Apache 风格版权注释，集成时原样保留。不能仅从库代码许可推导任意来源的数据库都可任意再分发；当前只用官方仓库固定版本自带数据，不混入商业订阅数据。上游说明社区数据不定期更新。[许可证](https://github.com/lionsoul2014/ip2region/blob/v3.18.0/LICENSE.md)

`xdb_verify` 检查兼容结构版本与可寻址文件大小，不是完整文件真实性验证，也不替代 SHA、长度、地址族和必要结构检查。v1 建议随应用捆绑已校验数据；未来替换应在临时路径检查两个库与匹配读取器，成功后切换，失败保留旧版本。C 文件模式读取器以 seek/read 查询，文件缺失、截断和查询错误应降级为“归属未知”，不丢弃已记录 IP。[校验实现](https://github.com/lionsoul2014/ip2region/blob/v3.18.0/binding/c/xdb_util.c)

## 8. 数据路径与权限

使用 FileManager 的用户域 Application Support 目录；非沙盒自用应用对应 `~/Library/Application Support/<BundleID>/`，不要写应用 bundle、源代码目录或临时构建目录。SQLite 历史与可变数据在该目录；捆绑 XDB 和许可证保持只读。具体 bundle resource 访问路径必须由打包验证确认，不能把开发机绝对路径编入应用。[Application Support](https://developer.apple.com/documentation/foundation/url/applicationsupportdirectory)、[文件系统使用建议](https://developer.apple.com/documentation/foundation/using-the-file-system-effectively)

当前范围不需要 Core Location，也不获取 Wi-Fi SSID/BSSID。Apple DTS 提醒现代 macOS 的 WLAN 信息受位置权限约束；以后如果增加该功能，必须重新讨论权限与降级，不能用 shell 工具绕过它。[Apple DTS 说明](https://developer.apple.com/forums/thread/748161)

建议本机应用先不启用 App Sandbox，以免对本地数据位置、导出和后续签名形成未经验证的承诺；这是一项工程取舍，而不是必须绕过系统保护。是否采用 sandbox 不影响“不请求定位、不安装网络扩展、不请求 root”的产品范围。私有历史文件应限制为当前用户可读写，日志不要 dump 配置或历史；导出由用户选择保存路径。若以后改变分发或沙盒策略，必须单独设计历史迁移。

## 9. 开发早期必须通过的验收门

设计闭环不能替代这些实现结果；必须在主要界面开发之前完成，失败时按既定降级方案收敛，不把风险拖到最后。

| 门 | 最小检查 | 通过条件／失败处理 |
| --- | --- | --- |
| 原生构建与资源 | CLT 构建、打包、签名、Finder 打开、读取两个捆绑库 | 无开发机路径依赖；当前 Mac 正常运行；否则先修构建路线 |
| 菜单和窗口生命周期 | 菜单点击、窗口首次打开、复用、关闭、重复启动、退出 | 不出现多图标／多实例写入，不抢焦点，关闭窗口不退出，明确退出停止采集 |
| 登录启动 | `mainApp` 注册及状态、真实重新登录、系统撤销、应用替换 | 只有真实登录成功才标验收通过；签名失败可切换手工系统登录项模式，不能显示虚假成功 |
| 本机增强快照 | 正常网卡、VPN/TUN、修改 DNS/代理、缺失字段 | 只使用公开 API，字段来源明确，未知值不冒充关闭，DNS 保留 partial 合同 |
| 双地址族探测 | 用户实际网络下 v4/v6、代理开启、单族失败、超时 | 返回地址族与源可追溯；不混淆代理传输族和出口族；本报告没有执行这些外部探测 |
| Swift/C 查询 | 双栈、非公网地址、字段缺失、文件缺失／截断 | 不崩溃、不泄漏 buffer、不阻塞主线程，未知归属不影响 IP 历史 |
| 调度与睡眠 | 高频系统事件、睡眠中断、唤醒、暂停、取消后返回 | 同时最多一个采集轮次；旧结果不覆盖新状态，不追赶睡眠期间轮次 |
| 耗电与存储 | 稳态后台、窗口关闭、长历史、连续失败 | 依据最终设计的预算实测；不得把 Python 样例或上游微基准称作本应用性能 |

## 10. 对主设计的结论

路线具备充分的官方能力依据，适合本机自用和轻量化目标。必须优先防止的语义错误是：把公网探测出口称为全机唯一 IP；把 IPv6 请求失败说成无 IPv6；把 DNS／代理配置说成实际流量证据；把构建成功说成登录启动成功；把现有 Python 验证说成原生集成完成。

设计可以把 UI、状态模型、失败处理和退路明确下来，但签名登录项、窗口焦点、真实网络分族行为及增强配置采集仍需要开发早期实测。完成这些验收后，才可对运行行为作更强承诺。
