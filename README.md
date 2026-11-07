# IP Record：离线 IP 归属地数据

当前完成的是全球离线数据库和本地查询工具，macOS 菜单栏应用尚未实现。

应用设计已封版为v1.0，入口见 [设计文档](docs/design/README.md)。文档包含15项已确认需求、技术路线、界面与IP展示、运行与数据合同，以及7个前置验收门和38个场景。当前尚未开发原生应用；下一阶段从技术前置验收开始。

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

后续原生 macOS 应用可以读取相同的 XDB 文件；这里的 Python 脚本用于验证和手动查询，
不要求最终应用打包 Python 运行时。
