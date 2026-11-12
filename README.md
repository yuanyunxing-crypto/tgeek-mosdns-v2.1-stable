TGEEK MosDNS v2.1 稳定候选版
支持场景
全新安装：兼容 sbwml / LuCI MosDNS v5 的 OpenWrt（原生 UCI 生成 /var/etc/mosdns.json，已有 whitelist → forward_local 规则入口）。
v2.0 升级：保留 v2.0 原有白名单管理标记与用户自定义域名，接管每日更新任务改为每周日 04:17；备份并替换 /usr/bin/tgeek-mosdns。
其它端口：不会修改 DNS 53、5335 或其它自定义端口，也不会修改 API 端口；审计从运行 JSON 自动读取。
非兼容 YAML：本版不自动修改，安全退出。不能宣称支持任意 MosDNS v5 YAML。
DNS 策略
国内上游：https://dns.alidns.com/dns-query、https://doh.pub/dns-query，两个都为 DoH。
国外上游：保留原有配置，不做自动重写。
Apple 优化：将 apple_optimization=0，防止启用旧 Apple UDP 备用解析；验证主查询流程不再调用 Apple 专用分支。异常即回滚。
视频专用 DNS：只检查，不做配置替换。TLS/DoT 本身是加密的，不要混淆为明文。
Bootstrap、终端自带 DoH/DoT、其它服务的 DNS 不在“没有明文 DNS”的保证范围。
安装
将 .sh 上传到 /root/tgeek-mosdns-v2.1-stable.sh：
```
sh -n /root/tgeek-mosdns-v2.1-stable.sh
```
```
sh /root/tgeek-mosdns-v2.1-stable.sh audit
```
```
sh /root/tgeek-mosdns-v2.1-stable.sh install
```
如使用早期 v2.0：同样执行 install，或 upgrade，自动识别已有 v2.0 管理区块。

维护
```
tgeek-mosdns status
```
```
tgeek-mosdns audit
```
```
tgeek-mosdns update
```
```
tgeek-mosdns add example.com
```
```
tgeek-mosdns remove example.com
```
```
tgeek-mosdns rollback last
```
```
tgeek-mosdns rollback initial
```
```
tgeek-mosdns uninstall
```
rollback last：恢复最近一次成功执行变更前的状态。
rollback initial：恢复首次安装 v2.1 之前的状态；如果从 v2.0 升级，就恢复到升级前的 v2.0 管理脚本、UCI、白名单及定时任务。
uninstall：与 rollback initial 等价。
首次快照位置：/etc/mosdns/tgeek-v21-safe-backup/initial。
每次变更快照：/etc/mosdns/tgeek-v21-safe-backup/.transaction-*。
上一次快照指针：/etc/mosdns/tgeek-v21-safe-backup/latest。
限制与安全说明
运行前需要 jsonfilter、uci、pidof、curl 或 wget。若缺少 JSON 解析器，脚本停止而不会以 grep 猜测配置。
脚本只修改 UCI 国内上游、Apple 优化、证书验证选项、白名单、自定义名单、计划任务和补丁管理命令。不会更改国外 DNS、DNS 端口、DNS 劫持、防火墙、Nikki 或 mwan3。
更新先下载和校验全部规则，再保存事务前快照和修改；下载失败不会触碰旧规则。更新使用临时文件并通过 mv 替换。只有新的运行 JSON 解析通过且国内上游都是 DoH，才将事务标记为成功。
自动回滚是尽力恢复，并非断电级事务。遭遇系统断电、磁盘故障、kill -9 等情况，无法保证自动执行回滚，仍可手工使用快照。
rollback initial 会撤销安装 v2.1 后在被管理文件上的后续人工修改。需要长期保存个人新增规则，请另行备份。
重要： 该版完成静态语法检查，没有在所有 OpenWrt 型号和 sbwml 版本上进行完整实机验证，先在一台已备份设备测试。
