#!/bin/sh
# TGEEK MosDNS v2.1 stable-candidate
# Upgrade from TGEEK v2.0 OR clean install for compatible sbwml UCI MosDNS v5.
# Requires jsonfilter for structural JSON verification, curl/wget for downloads.
# Does not change listen ports, remote DNS, firewall, Nikki, mwan3.
set -eu
umask 077

VERSION=2.1.0
BASE=/etc/mosdns
RULE="$BASE/rule/whitelist.txt"
CUSTOM="$BASE/rule/tgeek-force-local-custom.txt"
CFG=/etc/config/mosdns
LIVE=/var/etc/mosdns.json
BIN=/usr/bin/tgeek-mosdns
CRON=/etc/crontabs/root
BACK="$BASE/tgeek-v21-safe-backup"
INITIAL="$BACK/initial"
LATEST="$BACK/latest"
LOCK=/var/lock/tgeek-mosdns-v21.lock
START='# >>> TGEEK-MOSDNS-MANAGED RULES >>>'
END='# <<< TGEEK-MOSDNS-MANAGED RULES <<<'
OLDCRON='# TGEEK-MOSDNS-AUTO-UPDATE'
NEWCRON='# TGEEK-MOSDNS-V21-WEEKLY'
SOURCE=https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release
MIRROR=https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release
WORK=''
STAGE=''
ACTIVE=0
COMMITTED=0

say(){ printf '[TGEEK v%s] %s\n' "$VERSION" "$*"; }
fail(){ printf '[TGEEK v%s] ERROR: %s\n' "$VERSION" "$*" >&2; exit 1; }
exists(){ command -v "$1" >/dev/null 2>&1; }
backup_one(){
  name="$1"; dir="$2"
  # absolute path mapped to a flat, unambiguous backup key
  key="$(printf '%s' "$name" | sed 's#/#_#g')"
  if [ -f "$name" ]; then cp -p "$name" "$dir/$key"; else : > "$dir/$key.absent"; fi
}
restore_one(){
  name="$1"; dir="$2"
  key="$(printf '%s' "$name" | sed 's#/#_#g')"
  if [ -f "$dir/$key" ]; then
    mkdir -p "$(dirname "$name")"
    cp -p "$dir/$key" "$name"
  elif [ -f "$dir/$key.absent" ]; then
    rm -f "$name"
  else
    return 1
  fi
}
snapshot(){
  dest="$1"
  [ ! -e "$dest" ] || fail "备份已存在，拒绝覆盖：$dest"
  mkdir -p "$dest"
  backup_one "$CFG" "$dest"
  backup_one "$RULE" "$dest"
  backup_one "$CUSTOM" "$dest"
  backup_one "$CRON" "$dest"
  backup_one "$BIN" "$dest"
  backup_one "$BASE/cache.dump" "$dest"
  : > "$dest/complete"
}
restore(){
  dest="$1"
  [ -f "$dest/complete" ] || { say "缺少完整备份：$dest"; return 1; }
  restore_one "$CFG" "$dest" || return 1
  restore_one "$RULE" "$dest" || return 1
  restore_one "$CUSTOM" "$dest" || return 1
  restore_one "$CRON" "$dest" || return 1
  restore_one "$BIN" "$dest" || return 1
  restore_one "$BASE/cache.dump" "$dest" || return 1
  # remove uncommitted UCI delta, then restart with restored original files
  uci revert mosdns >/dev/null 2>&1 || true
  [ -f "$CRON" ] && crontab "$CRON" >/dev/null 2>&1 || true
  /etc/init.d/mosdns restart || return 1
  return 0
}
cleanup(){
  code=$?
  trap - EXIT HUP INT TERM
  set +e
  if [ "$ACTIVE" -eq 1 ] && [ "$COMMITTED" -ne 1 ]; then
    if [ -f "$LATEST" ]; then
      d="$(cat "$LATEST")"
      say "执行失败，自动恢复事务前状态：$d"
      restore "$d"
      if [ $? -ne 0 ]; then
        say "自动回滚没有完成！请用备份目录手工恢复：$d"
      fi
    fi
  fi
  [ -n "$WORK" ] && rm -rf "$WORK"
  [ -n "$STAGE" ] && rm -rf "$STAGE"
  rmdir "$LOCK" >/dev/null 2>&1 || true
  exit "$code"
}
lock(){
  mkdir "$LOCK" 2>/dev/null || fail "已有更新任务正在运行：$LOCK"
  trap cleanup EXIT HUP INT TERM
}
json(){ jsonfilter -i "$LIVE" -e "$1" 2>/dev/null; }
# Parse rather than grep serialized JSON: normalized URLs and escaped slashes are handled.
plugin_index(){
  wanted="$1"
  i=0
  tags="$(json '@.plugins[*].tag')" || return 1
  for tag in $tags; do
    if [ "$tag" = "$wanted" ]; then printf '%s' "$i"; return 0; fi
    i=$((i+1))
  done
  return 1
}
check_runtime(){
  [ -f "$CFG" ] && [ -f "$LIVE" ] || fail '找不到 MosDNS UCI/JSON 配置'
  exists jsonfilter || fail '缺少 jsonfilter，请先安装 jsonfilter 软件包'
  exists uci || fail '缺少 uci'
  exists pidof || fail '缺少 pidof'
  [ "$(uci -q get mosdns.config.configfile || true)" = "$LIVE" ] || fail '当前非 sbwml UCI 自动生成模式，停止（不修改 YAML）'
  p="$(pidof mosdns 2>/dev/null | awk '{print $1}')"
  [ -n "$p" ] || fail 'MosDNS 未运行'
  cmd="$(tr '\000' ' ' < "/proc/$p/cmdline")"
  case "$cmd" in *" -c $LIVE "*) : ;; *) fail '正在运行的 MosDNS 未加载预期 JSON';; esac
  tags="$(json '@.plugins[*].tag')" || fail 'JSON 解析失败'
  [ -n "$tags" ] || fail 'JSON 没有有效插件'
  idxwl="$(plugin_index whitelist)" || fail '找不到 whitelist 插件'
  idxlocal="$(plugin_index forward_local)" || fail '找不到 forward_local 插件'
  idxremote="$(plugin_index forward_remote)" || fail '找不到 forward_remote 插件'
  idxmain="$(plugin_index main_sequence)" || fail '找不到 main_sequence 插件'
  idxqwl="$(plugin_index query_is_whitelist_domain)" || fail '找不到 query_is_whitelist_domain 插件'
  f="$(json "@.plugins[$idxwl].args.files[0]")"
  [ "$f" = "$RULE" ] || fail "白名单文件不是预期路径：$f"
  match="$(json "@.plugins[$idxqwl].args[*].matches")"
  printf '%s\n' "$match" | grep -Fq 'qname $whitelist' || fail '白名单 sequence 没有 qname 匹配'
  execs="$(json "@.plugins[$idxqwl].args[*].exec")"
  printf '%s\n' "$execs" | grep -Fq '$forward_local' || fail '白名单没有走 forward_local'
  order="$(json "@.plugins[$idxmain].args[*].exec")"
  printf '%s\n' "$order" | grep -Fq '$query_is_whitelist_domain' || fail '主流程没有调用白名单'
  before="$(printf '%s\n' "$order" | awk '/\$query_is_whitelist_domain/{exit} /\$query_is_no_local_domain/{print "bad";exit}')"
  [ -z "$before" ] || fail '国外域名规则优先于白名单，停止'
  port="$(json '@.plugins[*].args.listen' | awk -F: 'NF>1 {print $NF;exit}')"
  [ -n "$port" ] || port="$(uci -q get mosdns.config.listen_port || true)"
  say "运行 JSON 正常；端口=${port:-未知}；白名单=$RULE；转发链路已识别"
}
check_doh(){
  idx="$(plugin_index forward_local)" || return 1
  ips="$(json "@.plugins[$idx].args.upstreams[*].addr")" || return 1
  [ -n "$ips" ] || return 1
  for addr in $ips; do
    case "$addr" in https://*|h3://*) : ;; *) say "国内明文/非 DoH 上游: $addr"; return 1;; esac
  done
  json "@.plugins[$idx].args.upstreams[*].insecure_skip_verify" | grep -qx 'true' && return 1
  return 0
}
audit(){
  check_runtime
  say "国内业务上游：$(json "@.plugins[$idxlocal].args.upstreams[*].addr" | tr '\n' ' ')"
  say "国外业务上游：$(json "@.plugins[$idxremote].args.upstreams[*].addr" | tr '\n' ' ')"
  if check_doh; then say '国内转发器上游全部为 DoH'; else say '国内转发器仍包含非 DoH（安装时切换）'; fi
  for name in forward_xinfeng_udp forward_stream_media; do
    if i="$(plugin_index "$name")"; then
      addrs="$(json "@.plugins[$i].args.upstreams[*].addr" | tr '\n' ' ')"
      say "$name 上游：$addrs（仅审计，不修改）"
    fi
  done
  if grep -Fq "$START" "$RULE" 2>/dev/null; then say '发现 v2.0 规则管理区块，支持原地升级'; else say '未发现 v2.0 管理区块，走首次安装/原名单增量合并'; fi
  say '提示：Bootstrap 以及终端自带 DNS 不在本补丁的零明文保障范围'
}
fetch(){
  f="$1"
  if exists curl; then
    curl -fsSL --connect-timeout 12 --max-time 180 "$SOURCE/$f" -o "$WORK/$f" && return 0
    curl -fsSL --connect-timeout 12 --max-time 180 "$MIRROR/$f" -o "$WORK/$f" && return 0
  elif exists wget; then
    wget -q -T 180 -O "$WORK/$f" "$SOURCE/$f" && return 0
    wget -q -T 180 -O "$WORK/$f" "$MIRROR/$f" && return 0
  fi
  fail "下载失败：$f；旧配置未改动"
}
prepare(){
  WORK="$(mktemp -d /tmp/tgeek-mosdns-XXXXXX)" || fail '无法创建临时目录'
  fetch china-list.txt
  fetch apple-cn.txt
  fetch google-cn.txt
  for f in china-list.txt apple-cn.txt google-cn.txt; do
    [ -s "$WORK/$f" ] || fail "$f 为空"
    ! grep -Eiq '<html|<\!doctype|404: Not Found|Bad Gateway' "$WORK/$f" || fail "$f 返回了网页"
  done
  awk '
    {gsub(/\r/,"");gsub(/^[ \t]+|[ \t]+$/,"");if($0==""||$0~/^#/)next;
     if($0~/^(domain|full):[A-Za-z0-9._-]+$/)print tolower($0);
     else if($0~/^[A-Za-z0-9._-]+$/)print "domain:"tolower($0);
     else bad++}
    END{if(bad)exit 3}
  ' "$WORK/china-list.txt" "$WORK/apple-cn.txt" "$WORK/google-cn.txt" > "$WORK/github" || fail '规则格式异常'
  [ "$(wc -l < "$WORK/china-list.txt")" -gt 50000 ] || fail 'china-list 内容过少'
  [ "$(wc -l < "$WORK/apple-cn.txt")" -gt 20 ] || fail 'apple-cn 内容过少'
  [ "$(wc -l < "$WORK/google-cn.txt")" -gt 20 ] || fail 'google-cn 内容过少'
  [ "$(wc -l < "$WORK/github")" -gt 50000 ] || fail '规则数量异常'
  if [ -n "${TGEEK_CUSTOM_STAGE:-}" ] && [ -f "$TGEEK_CUSTOM_STAGE" ]; then
    cp "$TGEEK_CUSTOM_STAGE" "$WORK/custom_source"
  elif [ -f "$CUSTOM" ]; then
    cp "$CUSTOM" "$WORK/custom_source"
  else
    printf '# TGEEK custom forced local DNS\ndomain:epsonconnect.com\n' > "$WORK/custom_source"
  fi
  awk '
    {gsub(/\r/,"");gsub(/^[ \t]+|[ \t]+$/,"");if($0==""||$0~/^#/)next;
     if($0~/^(domain|full):[A-Za-z0-9._-]+$/)print tolower($0);
     else if($0~/^[A-Za-z0-9._-]+$/)print "domain:"tolower($0);
     else bad++}
    END{if(bad)exit 3}
  ' "$WORK/custom_source" > "$WORK/custom_rules" || fail '自定义规则有无效行'
  cat "$WORK/github" "$WORK/custom_rules" | LC_ALL=C sort -u > "$WORK/managed"
  # Ensure Epson remains included even if user removed it from custom.
  grep -Fqx 'domain:epsonconnect.com' "$WORK/managed" || {
    printf 'domain:epsonconnect.com\n' >> "$WORK/managed"
    LC_ALL=C sort -u "$WORK/managed" > "$WORK/managed.new"
    mv "$WORK/managed.new" "$WORK/managed"
  }
  say "规则校验完成：$(wc -l < "$WORK/managed" | tr -d ' ') 条"
}
check_markers(){
  [ -f "$RULE" ] || return 0
  a="$(grep -Fxc "$START" "$RULE" || true)"
  b="$(grep -Fxc "$END" "$RULE" || true)"
  if [ "$a" -eq 0 ] && [ "$b" -eq 0 ]; then return 0; fi
  [ "$a" -eq 1 ] && [ "$b" -eq 1 ] || fail '原 v2.0 管理区块标记损坏，停止以防误删'
  awk -v s="$START" -v e="$END" '$0==s {a=NR} $0==e {b=NR} END{exit !(a>0 && b>a)}' "$RULE" || fail '规则管理区块次序损坏'
}
compose(){
  check_markers
  if [ -f "$RULE" ]; then
    awk -v s="$START" -v e="$END" '$0==s{skip=1;next}$0==e{skip=0;next}!skip{print}' "$RULE" > "$WORK/base"
  else
    : > "$WORK/base"
  fi
  {
    cat "$WORK/base"
    printf '\n%s\n' "$START"
    printf '# TGEEK v2.1; Loyalsoldier china-list apple-cn google-cn\n'
    cat "$WORK/managed"
    printf '%s\n' "$END"
  } > "$WORK/whitelist.new"
}
set_doh(){
  uci -q delete mosdns.config.local_dns || true
  uci add_list mosdns.config.local_dns='https://dns.alidns.com/dns-query'
  uci add_list mosdns.config.local_dns='https://doh.pub/dns-query'
  uci set mosdns.config.custom_local_dns='1'
  uci set mosdns.config.insecure_skip_verify='0'
  # Remove the active Apple branch that can fallback to 114.x.x.x plaintext DNS.
  uci set mosdns.config.apple_optimization='0'
  uci commit mosdns
}
verify(){
  /etc/init.d/mosdns restart || return 1
  sleep 3
  # Strict JSON parser; avoid textual false negative on escaped \/.
  check_runtime || return 1
  check_doh || return 1
  # v2.0 had an Apple fallback over UDP, so reject it if still called by main.
  m="$(plugin_index main_sequence)" || return 1
  json "@.plugins[$m].args[*].exec" | grep -Fq '$query_is_apple_domain' && return 1
  [ "$(uci -q get mosdns.config.apple_optimization || true)" = 0 ] || return 1
  [ -f "$RULE" ] && grep -Fqx "$END" "$RULE" || return 1
  pidof mosdns >/dev/null 2>&1 || return 1
  return 0
}
set_cron(){
  [ -f "$CRON" ] && awk -v a="$OLDCRON" -v b="$NEWCRON" '
     $0==a || $0==b {skip=1;next}
     skip && /tgeek-mosdns update/ {skip=0;next}
     !skip{print}
  ' "$CRON" > "$WORK/cron.base" || : > "$WORK/cron.base"
  {
    cat "$WORK/cron.base"
    printf '%s\n' "$NEWCRON"
    printf '17 4 * * 0 /usr/bin/tgeek-mosdns update >/tmp/tgeek-mosdns-update.log 2>&1\n'
  } > "$WORK/cron.new"
  cp "$WORK/cron.new" "$CRON"
  crontab "$CRON" >/dev/null 2>&1 || true
}
write_update(){
  check_runtime
  [ -d "$BASE/rule" ] || fail "缺少 $BASE/rule 目录"
  check_markers
  prepare
  compose
  # Compare the managed block, not unrelated user whitelist lines.
  if [ -f "$RULE" ]; then
    awk -v s="$START" -v e="$END" '$0==s{f=1;next}$0==e{exit}f&&$0!~/^#/&&NF{print}' "$RULE" > "$WORK/current"
  else
    : > "$WORK/current"
  fi
  migrate=0
  [ -f "$CRON" ] && grep -Fq "$NEWCRON" "$CRON" || migrate=1
  [ -f "$CRON" ] && grep -Fq "$OLDCRON" "$CRON" && migrate=1 || true
  if [ -f "$BIN" ]; then
    grep -Fq 'VERSION=2.1.0' "$BIN" || migrate=1
  else
    migrate=1
  fi
  apple_ok=0
  [ "$(uci -q get mosdns.config.apple_optimization || true)" = '0' ] && apple_ok=1
  if cmp -s "$WORK/current" "$WORK/managed" && check_doh && [ "$migrate" -eq 0 ] && [ "$apple_ok" -eq 1 ]; then
    say '地址库无变化且已安装 v2.1，无需重启'
    return 0
  fi
  mkdir -p "$BACK"
  stamp="$(date +%Y%m%d-%H%M%S)-$$"
  temp="$BACK/.transaction-$stamp"
  snapshot "$temp"
  if [ ! -f "$INITIAL/complete" ]; then
    cp -a "$temp" "$BACK/.initial-$stamp"
    mv "$BACK/.initial-$stamp" "$INITIAL"
  fi
  printf '%s\n' "$temp" > "$LATEST"
  ACTIVE=1
  # Only now mutate persistent files, after the complete transaction snapshot.
  cp "$WORK/custom_source" "$CUSTOM.tmp"
  mv "$CUSTOM.tmp" "$CUSTOM"
  cp "$WORK/whitelist.new" "$RULE.tmp"
  mv "$RULE.tmp" "$RULE"
  set_doh
  verify || fail 'DNS 重启/解析链路验证失败；即将自动回滚'
  # Replace the old v2.0 binary only after DNS checks passed.
  [ "$0" = "$BIN" ] || {
    cp "$0" "$BIN.tmp"
    chmod 755 "$BIN.tmp"
    mv "$BIN.tmp" "$BIN"
  }
  set_cron
  COMMITTED=1
  say 'v2.1 已安装/更新成功；失败回滚快照保留'
}
status(){
  say "MosDNS PID: $(pidof mosdns 2>/dev/null || echo stopped)"
  say "UCI configfile: $(uci -q get mosdns.config.configfile || true)"
  say "DNS 端口: $(uci -q get mosdns.config.listen_port || echo unknown)"
  say "API 端口: $(uci -q get mosdns.config.listen_port_api || echo unknown)"
  say "国内上游: $(uci -q get mosdns.config.local_dns || true)"
  say "上一事务: $([ -f "$LATEST" ] && cat "$LATEST" || echo none)"
  say "初始备份: $([ -f "$INITIAL/complete" ] && echo present || echo absent)"
  [ -f "$RULE" ] && grep -Fxc "$START" "$RULE" || true
}
rollback(){
  target="${1:-last}"
  case "$target" in
    initial) d="$INITIAL";;
    last) [ -f "$LATEST" ] || fail '没有最近事务快照'; d="$(cat "$LATEST")";;
    *) fail 'rollback 用法: rollback [last|initial]' ;;
  esac
  [ -f "$d/complete" ] || fail "备份不存在：$d"
  ACTIVE=0
  restore "$d" || fail "恢复失败，请检查 $d"
  say "已恢复：$d"
}
add_remove(){
  action="$1"; d="${2:-}"
  [ -n "$d" ] || fail '请提供域名'
  case "$d" in *[!A-Za-z0-9._-]*|'') fail '域名格式错误';; esac
  d="$(printf '%s' "$d" | tr 'A-Z' 'a-z')"
  printf '%s\n' "$d" | grep -Eq '^[a-z0-9]([a-z0-9.-]*[a-z0-9])?\.[a-z]{2,}$' || fail '必须提供规范域名'
  check_runtime
  # Stage edit before network fetch, never touch live CUSTOM on failure.
  stage="$(mktemp -d /tmp/tgeek-domain-XXXXXX)"
  STAGE="$stage"
  if [ -f "$CUSTOM" ]; then cp "$CUSTOM" "$stage/source"; else printf 'domain:epsonconnect.com\n' > "$stage/source"; fi
  if [ "$action" = add ]; then
    grep -Fqx "domain:$d" "$stage/source" || printf 'domain:%s\n' "$d" >> "$stage/source"
  else
    awk -v d="$d" '$0!="domain:"d && $0!="full:"d && $0!=d{print}' "$stage/source" > "$stage/new"
    mv "$stage/new" "$stage/source"
  fi
  # Use a staged custom list, and remove it on completion/failure.
  export TGEEK_CUSTOM_STAGE="$stage/source"
  write_update
  rm -rf "$stage"
  STAGE=''
  unset TGEEK_CUSTOM_STAGE
}
case "${1:-}" in
  audit) audit;;
  status) status;;
  install|upgrade|update) lock; write_update;;
  add|remove) lock; add_remove "$@";;
  rollback) lock; rollback "${2:-last}";;
  uninstall) lock; rollback initial;;
  *) echo 'Usage: sh tgeek-mosdns-v2.1.sh {audit|install|upgrade|update|status|add DOMAIN|remove DOMAIN|rollback [last|initial]|uninstall}'; exit 2;;
esac
