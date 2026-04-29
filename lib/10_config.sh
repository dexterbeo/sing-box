#!/usr/bin/env bash
# ============================================================
# 模块: 10_config.sh
# 职责: 配置文件加载/校验/应用/回滚/重启服务
# 依赖: 00_base.sh, 01_utils.sh
# ============================================================

config_min_template() {
  cat <<'JSON'
{
  "log": {"level": "info", "output": "/var/log/sing-box/access.log", "timestamp": true},
  "inbounds": [],
  "outbounds": [
    {"type": "direct", "tag": "direct"},
    {"type": "block", "tag": "reject"}
  ],
  "route": {"rules": [], "final": "reject"}
}
JSON
}

config_normalize() {
  local json="$1"
  if [ -z "$json" ]; then
    config_min_template
    return 0
  fi
  echo "$json" | jq '
    if type != "object" then
      {
        "log": {"level":"info","output":"/var/log/sing-box/access.log","timestamp":true},
        "inbounds": [],
        "outbounds": [
          {"type":"direct","tag":"direct"},
          {"type":"block","tag":"reject"}
        ],
        "route": {"rules": [], "final": "reject"}
      }
    else . end
    | .log = (.log // {"level":"info","output":"/var/log/sing-box/access.log","timestamp":true})
    | .inbounds = (.inbounds // [])
    | .outbounds = (.outbounds // [])
    | .route = (.route // {"rules": [], "final": "reject"})
    | .route.rules = (.route.rules // [])
    | .route.final = "reject"
    | if (.outbounds | any((.tag // "")=="direct")) then . else .outbounds += [{"type":"direct","tag":"direct"}] end
    | if (.outbounds | any((.tag // "")=="reject")) then . else .outbounds += [{"type":"block","tag":"reject"}] end
  '
}

config_load() {
  if [ -s "$CONFIG_FILE" ] && jq -e . "$CONFIG_FILE" >/dev/null 2>&1; then
    config_normalize "$(cat "$CONFIG_FILE")"
  else
    config_min_template
  fi
}

config_ensure_exists() {
  mkdir -p /etc/sing-box
  chmod 700 /etc/sing-box 2>/dev/null || true
  if [ ! -e "$CONFIG_FILE" ] || [ ! -s "$CONFIG_FILE" ]; then
    warn "未发现配置文件，将写入最小模板：$CONFIG_FILE"
    config_min_template | jq . > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true
    return 0
  fi

  if ! jq -e . "$CONFIG_FILE" >/dev/null 2>&1; then
    local ts broken
    ts="$(date +%Y%m%d_%H%M%S)"
    broken="${CONFIG_FILE}.broken.${ts}"
    cp -a "$CONFIG_FILE" "$broken" 2>/dev/null || true
    warn "检测到配置文件不是合法 JSON，已备份到：$broken"
    config_min_template | jq . > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true
    return 0
  fi
}

check_config_or_print() {
  if ! has_cmd sing-box; then
    err "未找到 sing-box 命令。请先安装。"
    return 1
  fi
  if [ ! -f "$CONFIG_FILE" ]; then
    err "未找到配置文件：$CONFIG_FILE"
    return 1
  fi
  if sing-box check -c "$CONFIG_FILE" >/dev/null 2>&1; then
    ok "配置校验通过：sing-box check -c $CONFIG_FILE"
    return 0
  fi
  err "配置校验失败：sing-box check -c $CONFIG_FILE"
  sing-box check -c "$CONFIG_FILE" 2>&1 | sed 's/^/  /'
  return 1
}

restart_singbox_safe() {
  if ! check_config_or_print; then
    err "已阻止重启：请先修复配置。"
    return 1
  fi
  case "$INIT_SYSTEM" in
    systemd)
      systemctl reload sing-box 2>/dev/null || systemctl restart sing-box
      ;;
    openrc)
      rc-service sing-box restart
      ;;
    *)
      err "未识别的 init 系统，无法重启 sing-box。"
      return 1
      ;;
  esac
  ok "sing-box 已重启。"
}

enable_now_singbox_safe() {
  if ! check_config_or_print; then
    err "已阻止启动/自启：请先修复配置。"
    return 1
  fi
  case "$INIT_SYSTEM" in
    systemd)
      systemctl enable --now sing-box
      ;;
    openrc)
      rc-update add sing-box default
      rc-service sing-box start
      ;;
    *)
      err "未识别的 init 系统，无法启动 sing-box。"
      return 1
      ;;
  esac
  ok "sing-box 已启用自启并启动。"
}

config_apply() {
  # 并发保护：通过 _CONFIG_LOCK_HELD 哨兵防止重入死锁
  # - 交互侧（菜单）首次进入：阻塞等待 lock
  # - cron 的 user_watch_run 已持锁时，内部间接调用 config_apply 会命中哨兵，跳过加锁直接执行
  if [ "${_CONFIG_LOCK_HELD:-0}" = "1" ]; then
    _config_apply_body "$@"
    return $?
  fi
  local _lock_fd _rc=0
  # 注意：exec 行的尾部重定向是永久作用于当前 shell 的，不能写成
  # `exec {_lock_fd}>"$SB_LOCK_FILE" 2>/dev/null`（会把整个 shell 的
  # stderr 永久关闭到 /dev/null，后续 err/warn/read -p 提示全丢失）。
  # 必须用命令组 { ... } 2>/dev/null，把重定向锚定在组作用域内。
  if { exec {_lock_fd}>"$SB_LOCK_FILE"; } 2>/dev/null; then
    flock "$_lock_fd"
    _CONFIG_LOCK_HELD=1
    _config_apply_body "$@"
    _rc=$?
    _CONFIG_LOCK_HELD=0
    { exec {_lock_fd}>&-; } 2>/dev/null || true
  else
    # 锁文件不可创建时降级为无锁模式（不阻塞功能）
    _config_apply_body "$@"
    _rc=$?
  fi
  return $_rc
}

_config_apply_body() {
  local json="$1"
  local normalized
  normalized="$(config_normalize "$json")"

  if ! echo "$normalized" | jq -e 'type=="object"' >/dev/null 2>&1; then
    err "内部错误：即将写入的配置不是 JSON object。"
    return 1
  fi

  if ! echo "$normalized" | jq -e '
    (.route.final // "") as $final
    | ($final == "" or ([.outbounds[]? | (.tag // "")] | index($final) != null))
  ' >/dev/null 2>&1; then
    err "配置校验失败：route.final 指向的 outbound 不存在。"
    return 1
  fi

  sync_user_usage_counters || true

  local tmp_file
  tmp_file="$(mktemp /etc/sing-box/config.json.tmp.XXXXXX)" || {
    err "创建临时配置文件失败。"
    return 1
  }

  echo "$normalized" | jq . > "$tmp_file" || {
    err "JSON 格式化失败，未写入配置。"
    rm -f "$tmp_file" >/dev/null 2>&1 || true
    return 1
  }

  if ! has_cmd sing-box; then
    err "未找到 sing-box，无法校验配置。"
    rm -f "$tmp_file" >/dev/null 2>&1 || true
    return 1
  fi

  if ! sing-box check -c "$tmp_file" >/dev/null 2>&1; then
    err "sing-box check 校验未通过，未写入配置。"
    sing-box check -c "$tmp_file" 2>&1 | sed 's/^/  /'
    rm -f "$tmp_file" >/dev/null 2>&1 || true
    return 1
  fi

  local ts backup prev_tmp
  ts="$(date +%Y%m%d_%H%M%S)"
  backup="/etc/sing-box/config.json.bak.fail.$ts"
  prev_tmp="/tmp/singbox_config_prev.$$"

  if [ -f "$CONFIG_FILE" ]; then
    cp -a "$CONFIG_FILE" "$prev_tmp"
  else
    : > "$prev_tmp"
  fi

  mv -f "$tmp_file" "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE" 2>/dev/null || true

  if restart_singbox_safe; then
    case "$INIT_SYSTEM" in
      systemd) systemctl enable sing-box >/dev/null 2>&1 || true ;;
      openrc)  rc-update add sing-box default >/dev/null 2>&1 || true ;;
    esac
    rm -f "$prev_tmp" >/dev/null 2>&1 || true
    # 自动清理旧备份，保留最近 1 个
    ls -1t /etc/sing-box/config.json.bak.fail.* 2>/dev/null | tail -n +2 | xargs rm -f -- 2>/dev/null || true
    ok "配置已应用。"
    return 0
  fi

  err "重启失败：正在回滚。"
  if [ -f "$prev_tmp" ] && [ -s "$prev_tmp" ]; then
    cp -a "$prev_tmp" "$backup"
    cp -a "$prev_tmp" "$CONFIG_FILE"
    warn "已生成失败备份：$backup"
  else
    cp -a "$CONFIG_FILE" "$backup" 2>/dev/null || true
    warn "无旧配置可回滚，已保存失败现场：$backup"
  fi
  rm -f "$prev_tmp" >/dev/null 2>&1 || true
  if ! restart_singbox_safe; then
    err "回滚后重启仍失败，sing-box 当前处于停止状态。"
    warn "手动恢复命令："
    case "$INIT_SYSTEM" in
      systemd) warn "  systemctl start sing-box" ;;
      openrc)  warn "  rc-service sing-box start" ;;
    esac
    warn "如需恢复到失败前的配置，请检查：$backup"
  fi
  return 1
}

config_reset() {
  config_apply "$(config_min_template)"
}

init_manager_env() {
  # 幂等哨兵：首次执行后标记，避免菜单循环重复跑 require_root/has_cmd/磁盘读
  [ "${_MANAGER_ENV_READY:-0}" = "1" ] && return 0
  require_root
  has_cmd jq || { err "未找到 jq，请先安装/更新 sing-box（会自动装依赖）。"; exit 1; }
  has_cmd curl || { err "未找到 curl，请先安装/更新 sing-box（会自动装依赖）。"; exit 1; }
  has_cmd openssl || { err "未找到 openssl，请先安装/更新 sing-box（会自动装依赖）。"; exit 1; }
  has_cmd sing-box || { err "未找到 sing-box，请先安装。"; exit 1; }
  [ "$INIT_SYSTEM" = "unknown" ] && { err "未识别的 init 系统（需要 systemd 或 OpenRC）。"; exit 1; }
  config_ensure_exists
  _MANAGER_ENV_READY=1
}
