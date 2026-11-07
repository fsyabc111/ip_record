# 原生前置验收记录

日期：2026-11-08，当前 Apple Silicon Mac / macOS 27.0.1 / Swift 6.4。
这份记录是实际执行的早期原生门，完整行为验证见后续交付报告。

| 门 | 实际证据与状态 |
| --- | --- |
| G01 | SwiftPM、官方 C target、arm64 release 编译、标准 `.app`、ad hoc 签名及 `codesign --verify --strict` 通过。安装至 `~/Applications/IP Record.app`，LaunchServices 启动进程。资源从 bundle 读取。CLT 27 默认 swiftbuild 的 Testing 宏插件未解析，构建脚本明确使用可用的 native backend；测试补上 CLT 自带 Testing.framework 搜索路径。 |
| G02 | NSStatusItem + NSMenu 最小壳已运行，无 Dock（LSUIElement/accessory）。原生交互工具两次超时，键盘、辅助功能、焦点及窗口关闭的人工交互未验收；继续做程序级生命周期验证，最终壳采用 popover。 |
| G03 | 原生 Swift→C 双族查询通过自动化测试。缺失／截断／非法头在 C 前拒用。首次安装因录入的 v4 可信哈希多一个字符被正确拒用；已按基线 manifest 修复并重测。buffer 使用长度限定 UTF-8、defer 释放。 |
| G04 | 当前系统只读快照实测取得17个非回环启用接口地址、8个 DNS 配置组，代理投影读取成功。没有修改日常网络；未验证其他物理连接和真实 DNS／代理切换。 |
| G05 | 安装后的原生 URLSession：IPv4 confirmed；IPv6 timeout，独立失败。无绕过系统代理配置。真实 IPv6 成功、代理切换、DNS/PAC 墙钟边界仍未覆盖。 |
| G06 | 固定安装路径、ad hoc 签名下 SMAppService.mainApp.register 实测 accepted，系统 status=enabled。不是重新登录验收；系统撤销、替换后重登录待验证。 |
| G07 | 最小壳短时 ps 测得 RSS 约124 MiB、CPU 0.0%采样；超过80 MiB后台预算，尚不能通过。需要继续定位最终应用稳态并做30分钟采样，不以物理 footprint 代替 RSS。 |

降级与停止线说明：CLT 构建器采用同工具链的 native backend；没有改产品语义。
G02 原生交互工具不可用、G06需用户重登录、G07资源超标均明确保留；独立核心开发继续，不能据此宣布最终验收通过。
报告不保留实机 IP、DNS、代理端点或 PAC 原文。
