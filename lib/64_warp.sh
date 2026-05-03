#!/usr/bin/env bash
# ============================================================
# 模块: 64_warp.sh
# 职责: WARP WireProxy 服务管理与 sing-box 出站/分流投影
# 依赖: 00_base.sh, 01_utils.sh, 10_config.sh, 30_route.sh, 50_v2ray_api.sh
# ============================================================

WARP_DIR="/etc/wireguard"
WARP_ACCOUNT_FILE="${WARP_DIR}/warp-account.conf"
WARP_WG_FILE="${WARP_DIR}/warp.conf"
WARP_PROXY_FILE="${WARP_DIR}/proxy.conf"
WARP_BIN="/usr/bin/wireproxy"
WARP_SERVICE="wireproxy"
WARP_DEFAULT_PORT="40000"
WARP_RULE_BASE_URL="https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set"
WARP_RULE_LOOKUP_URL="https://github.com/SagerNet/sing-geosite/tree/rule-set"

warp_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    s390x) echo "s390x" ;;
    *) return 1 ;;
  esac
}

warp_meta_json() {
  meta_load | jq -c '.warp // {mode:"off", rules:[]}'
}

warp_meta_mode() {
  warp_meta_json | jq -r '.mode // "off"'
}

warp_meta_rules_json() {
  warp_meta_json | jq -c '[.rules[]? | select((.tag // "") != "" and (.file // "") != "")] | unique_by(.tag)'
}

warp_meta_save_obj() {
  local warp_json="$1" meta_json
  meta_json="$(meta_load)"
  meta_json="$(echo "$meta_json" | jq --argjson w "$warp_json" '.warp = $w')" || return 1
  meta_save "$meta_json"
}

warp_meta_set_mode() {
  local mode="$1" warp_json
  case "$mode" in off|global|rules) ;; *) mode="off" ;; esac
  warp_json="$(warp_meta_json | jq --arg mode "$mode" '.mode = $mode | .rules = (.rules // [])')" || return 1
  warp_meta_save_obj "$warp_json"
}

warp_meta_clear() {
  warp_meta_save_obj '{"mode":"off","rules":[]}'
}

warp_port() {
  if [ -s "$WARP_PROXY_FILE" ]; then
    awk -F: '/^[[:space:]]*BindAddress[[:space:]]*=/{gsub(/[[:space:]]/,"",$NF); print $NF; exit}' "$WARP_PROXY_FILE"
  fi
}

warp_effective_port() {
  local port
  port="$(warp_port)"
  [ -n "$port" ] && echo "$port" || echo "$WARP_DEFAULT_PORT"
}

warp_rule_tag_for_file() {
  local file="$1" base tag
  base="${file%.srs}"
  tag="${base//[^A-Za-z0-9_-]/-}"
  echo "warp-${tag}"
}

warp_rule_url_for_file() {
  echo "${WARP_RULE_BASE_URL}/$1"
}

warp_normalize_rule_file() {
  local raw="${1:-}" value
  value="$(printf '%s' "$raw" | tr -d '[:space:]')"
  [ -n "$value" ] || return 1
  if [[ "$value" == *"://"* ]]; then
    err "请输入 rule-set 文件名，不要输入完整 URL。"
    return 1
  fi
  [[ "$value" == geosite-* ]] || value="geosite-${value}"
  [[ "$value" == *.srs ]] || value="${value}.srs"
  [[ "$value" =~ ^geosite-[A-Za-z0-9._@!+-]+\.srs$ ]] || {
    err "规则名格式无效：$value"
    return 1
  }
  echo "$value"
}

warp_validate_rule_file() {
  local file="$1" url
  url="$(warp_rule_url_for_file "$file")"
  curl -fsIL --connect-timeout 10 --max-time 20 "$url" >/dev/null 2>&1
}

warp_rule_add_meta() {
  local name="$1" file="$2" tag url warp_json
  tag="$(warp_rule_tag_for_file "$file")"
  url="$(warp_rule_url_for_file "$file")"
  warp_json="$(warp_meta_json | jq --arg name "$name" --arg file "$file" --arg tag "$tag" --arg url "$url" '
    .mode = "rules"
    | .rules = ((.rules // []) + [{name:$name,file:$file,tag:$tag,url:$url}])
    | .rules |= unique_by(.tag)
  ')" || return 1
  warp_meta_save_obj "$warp_json"
}

warp_rule_remove_meta_by_tags_json() {
  local tags_json="$1" warp_json
  warp_json="$(warp_meta_json | jq --argjson tags "$tags_json" '
    .rules = [(.rules // [])[] | select(($tags | index(.tag // "")) == null)]
    | if ((.rules // []) | length) == 0 and (.mode // "off") == "rules" then .mode = "off" else . end
  ')" || return 1
  warp_meta_save_obj "$warp_json"
}

warp_rule_clear_meta() {
  local warp_json
  warp_json="$(warp_meta_json | jq '.rules = [] | if (.mode // "off") == "rules" then .mode = "off" else . end')" || return 1
  warp_meta_save_obj "$warp_json"
}

warp_service_file_exists() {
  case "$INIT_SYSTEM" in
    systemd) [ -e "/lib/systemd/system/${WARP_SERVICE}.service" ] || [ -e "/etc/systemd/system/${WARP_SERVICE}.service" ] ;;
    openrc)  [ -e "/etc/init.d/${WARP_SERVICE}" ] ;;
    *)       return 1 ;;
  esac
}

warp_service_installed() {
  [ -x "$WARP_BIN" ] && [ -s "$WARP_PROXY_FILE" ] && warp_service_file_exists
}

warp_service_running() {
  case "$INIT_SYSTEM" in
    systemd) systemctl is-active --quiet "$WARP_SERVICE" 2>/dev/null ;;
    openrc)  openrc_service_running "$WARP_SERVICE" ;;
    *)       return 1 ;;
  esac
}

warp_service_status_text() {
  if ! warp_service_installed; then
    echo "未安装"
  elif warp_service_running; then
    echo "运行中"
  else
    echo "已安装，未运行"
  fi
}

warp_mode_text() {
  case "$(warp_meta_mode)" in
    global) echo "全局 WARP（普通直连流量）" ;;
    rules)  echo "常用网站分流" ;;
    *)      echo "未使用" ;;
  esac
}

warp_install_deps() {
  install_pkg curl
  install_pkg tar
  install_pkg iproute2 || true
}

warp_download_wireproxy() {
  local arch="$1" tmp_dir="$2" latest url fallback
  latest="$(curl -fsSL --connect-timeout 5 --max-time 10 "https://api.github.com/repos/pufferffish/wireproxy/releases/latest" 2>/dev/null | jq -r '.tag_name // empty' | sed 's/^v//' || true)"
  [ -n "$latest" ] || latest="1.0.9"
  url="https://github.com/pufferffish/wireproxy/releases/download/v${latest}/wireproxy_linux_${arch}.tar.gz"
  fallback="https://gitlab.com/fscarmen/warp/-/raw/main/wireproxy/wireproxy_linux_${arch}.tar.gz"

  if ! curl -fL --connect-timeout 20 --retry 3 "$url" -o "${tmp_dir}/wireproxy.tar.gz"; then
    curl -fL --connect-timeout 20 --retry 3 "$fallback" -o "${tmp_dir}/wireproxy.tar.gz"
  fi
  tar -xzf "${tmp_dir}/wireproxy.tar.gz" -C "$tmp_dir"
  [ -x "${tmp_dir}/wireproxy" ] || return 1
  install -m 755 "${tmp_dir}/wireproxy" "$WARP_BIN"
}

warp_api_register() {
  curl --retry 50 --retry-delay 1 --max-time 2 --silent --location --fail "https://warp.cloudflare.nyc.mn/?run=register"
}

warp_api_cancel() {
  [ -s "$WARP_ACCOUNT_FILE" ] || return 0
  local device_id token
  device_id="$(jq -r '.id // empty' "$WARP_ACCOUNT_FILE" 2>/dev/null || true)"
  token="$(jq -r '.token // empty' "$WARP_ACCOUNT_FILE" 2>/dev/null || true)"
  [ -n "$device_id" ] && [ -n "$token" ] || return 0
  curl --request DELETE "https://api.cloudflareclient.com/v0a2158/reg/${device_id}" \
    --head --silent --location \
    --header 'User-Agent: okhttp/3.12.1' \
    --header 'CF-Client-Version: a-6.10-2158' \
    --header 'Content-Type: application/json' \
    --header "Authorization: Bearer ${token}" >/dev/null 2>&1 || true
}

warp_write_configs() {
  local port="$1" private_key address6 endpoint dns mtu="1280"
  private_key="$(jq -r '.private_key // empty' "$WARP_ACCOUNT_FILE")"
  address6="$(jq -r '.config.interface.addresses.v6 // empty' "$WARP_ACCOUNT_FILE")"
  endpoint="$(jq -r '.config.peers[0].endpoint.host // "engage.cloudflareclient.com:2408"' "$WARP_ACCOUNT_FILE")"
  [ -n "$private_key" ] && [ -n "$address6" ] || {
    err "WARP 账号信息不完整，无法生成 WireProxy 配置。"
    return 1
  }
  dns="1.1.1.1,8.8.8.8,8.8.4.4,2606:4700:4700::1111,2001:4860:4860::8888,2001:4860:4860::8844"

  mkdir -p "$WARP_DIR"
  chmod 700 "$WARP_DIR" 2>/dev/null || true
  cat > "$WARP_WG_FILE" <<EOF
[Interface]
PrivateKey = $private_key
Address = 172.16.0.2/32
Address = ${address6}/128
DNS = 8.8.8.8
MTU = $mtu

[Peer]
PublicKey = bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=
AllowedIPs = 0.0.0.0/0
AllowedIPs = ::/0
Endpoint = $endpoint
EOF
  chmod 600 "$WARP_WG_FILE" 2>/dev/null || true

  cat > "$WARP_PROXY_FILE" <<EOF
[Interface]
Address = 172.16.0.2/32, ${address6}/128
MTU = $mtu
PrivateKey = $private_key
DNS = $dns

[Peer]
PublicKey = bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=
Endpoint = $endpoint

[Socks5]
BindAddress = 127.0.0.1:$port

[Resolve]
ResolveStrategy = auto
EOF
  chmod 600 "$WARP_PROXY_FILE" 2>/dev/null || true
}

warp_write_service() {
  case "$INIT_SYSTEM" in
    systemd)
      cat > "/lib/systemd/system/${WARP_SERVICE}.service" <<EOF
[Unit]
Description=WireProxy for WARP
After=network.target
Documentation=https://gitlab.com/fscarmen/warp
Documentation=https://github.com/pufferffish/wireproxy

[Service]
ExecStart=${WARP_BIN} -c ${WARP_PROXY_FILE}
RemainAfterExit=yes
Restart=always

[Install]
WantedBy=multi-user.target
EOF
      systemctl daemon-reload >/dev/null 2>&1 || true
      ;;
    openrc)
      cat > "/etc/init.d/${WARP_SERVICE}" <<EOF
#!/sbin/openrc-run

description="WireProxy for WARP"
command="${WARP_BIN}"
command_args="-c ${WARP_PROXY_FILE}"
command_background=true
pidfile="/var/run/${WARP_SERVICE}.pid"
output_log="/var/log/${WARP_SERVICE}.log"
error_log="/var/log/${WARP_SERVICE}.log"
EOF
      chmod +x "/etc/init.d/${WARP_SERVICE}"
      ;;
    *)
      err "未识别的 init 系统，无法创建 WireProxy 服务。"
      return 1
      ;;
  esac
}

warp_start_service() {
  case "$INIT_SYSTEM" in
    systemd)
      systemctl daemon-reload >/dev/null 2>&1 || true
      systemctl enable --now "$WARP_SERVICE"
      ;;
    openrc)
      openrc_enable_service "$WARP_SERVICE" default >/dev/null 2>&1
      openrc_start_service "$WARP_SERVICE"
      ;;
    *)
      err "未识别的 init 系统，无法启动 WARP。"
      return 1
      ;;
  esac
}

warp_restart_service() {
  case "$INIT_SYSTEM" in
    systemd) systemctl restart "$WARP_SERVICE" ;;
    openrc)  rc-service "$WARP_SERVICE" restart ;;
    *)       err "未识别的 init 系统，无法重启 WARP。"; return 1 ;;
  esac
}

warp_stop_service() {
  case "$INIT_SYSTEM" in
    systemd) systemctl disable --now "$WARP_SERVICE" >/dev/null 2>&1 || true ;;
    openrc)
      openrc_stop_service "$WARP_SERVICE" >/dev/null 2>&1 || true
      openrc_disable_service "$WARP_SERVICE" default >/dev/null 2>&1 || true
      ;;
  esac
}

warp_trace() {
  local port result flag
  port="$(warp_effective_port)"
  for flag in -4 -6 ""; do
    result="$(curl $flag -fsS --connect-timeout 8 --max-time 15 -x "socks5h://127.0.0.1:${port}" "https://www.cloudflare.com/cdn-cgi/trace" 2>/dev/null || true)"
    if echo "$result" | awk -F= '$1=="warp" && ($2=="on" || $2=="plus") {found=1} END {exit !found}'; then
      echo "$result"
      return 0
    fi
  done
  return 1
}

warp_socks_listening() {
  local port
  port="$(warp_effective_port)"
  ss -nltp 2>/dev/null | awk -v p=":${port}" '$4 ~ p {found=1} END {exit !found}'
}

warp_wait_socks_listener() {
  local i max=5
  for ((i=1; i<=max; i++)); do
    if warp_service_running && warp_socks_listening; then
      return 0
    fi
    sleep 1
  done
  return 1
}

warp_verify_trace_with_retries() {
  local i max=5
  say "后台获取 WARP 出口中，最大尝试 ${max} 次..."
  for ((i=1; i<=max; i++)); do
    if warp_service_running && warp_trace >/dev/null 2>&1; then
      return 0
    fi
    [ "$i" -lt "$max" ] || break
    warn "第 ${i} 次检测失败，正在重试..."
    warp_restart_service >/dev/null 2>&1 || true
    sleep 1
  done
  return 1
}

warp_start_service_checked() {
  warp_start_service || return 1
  warp_wait_socks_listener
}

warp_restart_service_checked() {
  warp_restart_service || return 1
  warp_wait_socks_listener
}

warp_warn_if_trace_failed() {
  if warp_verify_trace_with_retries; then
    return 0
  fi
  warn "WARP 服务已启动，但出口检测失败。"
  warn "常见原因：NAT 机 UDP 出站受限、Cloudflare WARP endpoint 不通，或当前 IPv4/IPv6 栈不可达。"
  return 1
}

warp_require_trace_for_routing() {
  warp_verify_trace_with_retries && return 0
  err "WARP 服务已启动，但出口检测失败，暂不应用全局/分流策略。"
  warn "请先在 4. 测试 WARP 出口 IP 中确认 WARP 可用。"
  pause
  return 1
}

warp_test_print() {
  local trace ip loc warp port
  port="$(warp_effective_port)"
  if ! warp_service_installed; then
    err "WARP 未安装，无法测试出口。"
    pause
    return 1
  fi
  if ! warp_service_running; then
    err "WARP 未运行，请先在 WARP 服务管理中启动。"
    pause
    return 1
  fi
  trace="$(warp_trace)" || {
    err "WARP 出口测试失败，请检查 WireProxy 服务。"
    pause
    return 1
  }
  ip="$(echo "$trace" | awk -F= '$1=="ip"{print $2; exit}')"
  loc="$(echo "$trace" | awk -F= '$1=="loc"{print $2; exit}')"
  warp="$(echo "$trace" | awk -F= '$1=="warp"{print $2; exit}')"
  echo "WARP SOCKS：127.0.0.1:${port}"
  echo "出口 IP：${ip:-未知}"
  echo "地区：${loc:-未知}"
  echo "WARP 状态：${warp:-未知}"
  pause
}

warp_config_project_json() {
  local json="$1" mode="$2" rules_json="$3" installed="$4" port="$5"
  echo "$json" | jq \
    --arg mode "$mode" \
    --argjson rules "$rules_json" \
    --argjson installed "$installed" \
    --argjson port "$port" '
    def rule_set_array:
      ((.rule_set // []) | if type == "array" then . else [.] end);
    .route = (.route // {"rules":[],"final":"reject"})
    | .route.rules = (.route.rules // [])
    | .route.rules = (
        .route.rules
        | map(select(
            ((.outbound // "") != "warp")
            and ((rule_set_array | any(startswith("warp-geosite-"))) | not)
          ))
      )
    | .route.rule_set = (
        ((.route.rule_set // []) | map(select(((.tag // "") | startswith("warp-geosite-")) | not)))
        + (if $mode == "rules" then
            ($rules | map({type:"remote", tag:.tag, format:"binary", url:.url, download_detour:"direct"}))
          else [] end)
      )
    | .outbounds = (
        ((.outbounds // []) | map(select((.tag // "") != "warp")))
        + (if $installed then [{type:"socks", tag:"warp", server:"127.0.0.1", server_port:$port, version:"5"}] else [] end)
      )
  '
}

warp_apply_current_state() {
  local json mode rules_json installed port projected rebuilt
  json="$(config_load)"
  mode="$(warp_meta_mode)"
  rules_json="$(warp_meta_rules_json)"
  installed=false
  warp_service_installed && installed=true
  port="$(warp_effective_port)"
  projected="$(warp_config_project_json "$json" "$mode" "$rules_json" "$installed" "$port")" || return 1
  rebuilt="$(route_rebuild "$projected")" || return 1
  _CONFIG_APPLY_QUIET_OK=1 config_apply_no_usage_sync "$rebuilt"
}

warp_apply_removed_state() {
  local json projected rebuilt
  json="$(config_load)"
  projected="$(warp_config_project_json "$json" off '[]' false "$(warp_effective_port)")" || return 1
  rebuilt="$(route_rebuild "$projected")" || return 1
  _CONFIG_APPLY_QUIET_OK=1 config_apply_no_usage_sync "$rebuilt"
}

warp_install_and_start() {
  local port arch tmp_dir account
  if warp_service_installed; then
    if ! warp_start_service_checked; then
      err "WireProxy 服务启动失败。"
      pause
      return 1
    fi
    ok "WARP 已启动。"
    warp_warn_if_trace_failed || true
    warp_apply_current_state || return 1
    return 0
  fi

  ask_port_or_return "请输入 WARP 本地 SOCKS 端口 [默认${WARP_DEFAULT_PORT}]: " "$WARP_DEFAULT_PORT" port || return 1
  arch="$(warp_arch)" || {
    err "当前架构暂不支持 WireProxy：$(uname -m)"
    pause
    return 1
  }
  warp_install_deps || return 1

  tmp_dir="$(mktemp -d /tmp/sb-warp.XXXXXX)" || return 1
  say "下载 WireProxy..."
  if ! warp_download_wireproxy "$arch" "$tmp_dir"; then
    rm -rf "$tmp_dir"
    err "WireProxy 下载或安装失败。"
    pause
    return 1
  fi
  rm -rf "$tmp_dir"

  mkdir -p "$WARP_DIR"
  chmod 700 "$WARP_DIR" 2>/dev/null || true
  say "注册 WARP 账号..."
  account="$(warp_api_register)" || account=""
  if ! echo "$account" | jq -e '.id and .private_key' >/dev/null 2>&1; then
    err "WARP 账号注册失败。"
    pause
    return 1
  fi
  echo "$account" | jq . > "$WARP_ACCOUNT_FILE"
  chmod 600 "$WARP_ACCOUNT_FILE" 2>/dev/null || true

  warp_write_configs "$port" || return 1
  warp_write_service || return 1
  warp_start_service_checked || {
    err "WireProxy 服务启动失败。"
    pause
    return 1
  }
  warp_apply_current_state || return 1
  ok "WARP 已安装并启动。"
  echo "本地 SOCKS：127.0.0.1:${port}"
  warp_warn_if_trace_failed || true
  pause
}

warp_disable_keep_config() {
  warn "停用 WARP 会关闭 sing-box 中的 WARP 使用策略，并停止 WireProxy；账号和配置会保留。"
  ask_confirm_yn "确认停用 WARP？(y/N): " || return 0
  warp_meta_set_mode off || return 1
  warp_apply_current_state || return 1
  warp_stop_service
  ok "WARP 已停用，配置已保留。"
  pause
}

warp_uninstall_all() {
  warn "卸载 WARP 会删除 WireProxy 服务、WARP 账号和 /etc/wireguard 下由 WARP 生成的配置。"
  ask_confirm_yes "输入 YES 确认彻底卸载 WARP，其它任意输入取消: " || { warn "已取消卸载。"; pause; return 0; }

  warp_meta_clear || return 1
  warp_apply_removed_state || return 1
  warp_stop_service
  warp_api_cancel || true

  rm -f "$WARP_BIN" \
    "/lib/systemd/system/${WARP_SERVICE}.service" \
    "/etc/systemd/system/${WARP_SERVICE}.service" \
    "/etc/init.d/${WARP_SERVICE}" \
    "/var/log/${WARP_SERVICE}.log" \
    "/var/run/${WARP_SERVICE}.pid" >/dev/null 2>&1 || true
  rm -f "$WARP_ACCOUNT_FILE" "$WARP_WG_FILE" "$WARP_PROXY_FILE" \
    "${WARP_DIR}/menu.sh" "${WARP_DIR}/language" \
    "${WARP_DIR}/NonGlobalUp.sh" "${WARP_DIR}/NonGlobalDown.sh" \
    "${WARP_DIR}/warp_unlock.sh" "${WARP_DIR}/up" "${WARP_DIR}/down" >/dev/null 2>&1 || true
  if [ -L /usr/bin/warp ] && [ "$(readlink /usr/bin/warp 2>/dev/null || true)" = "${WARP_DIR}/menu.sh" ]; then
    rm -f /usr/bin/warp >/dev/null 2>&1 || true
  fi
  [ -d "$WARP_DIR" ] && rmdir "$WARP_DIR" 2>/dev/null || true
  case "$INIT_SYSTEM" in
    systemd) systemctl daemon-reload >/dev/null 2>&1 || true ;;
  esac
  ok "WARP 已卸载并清理完成。"
  pause
}

warp_require_ready_or_install() {
  local reason="$1" next_func="$2" act
  if ! warp_service_installed; then
    echo "当前未安装 WARP，无法${reason}。"
    echo
    echo "需要先安装并启动 WARP 服务。"
    echo -e "  ${C}1.${NC} 立即安装并启动 WARP"
    echo -e "  ${R}0.${NC} 返回上一级"
    read -r -p "请选择操作: " act
    case "${act:-}" in
      1) warp_install_and_start && warp_require_trace_for_routing && "$next_func" ;;
      *) return 0 ;;
    esac
    return 0
  fi
  if ! warp_service_running; then
    echo "当前 WARP 已安装但未运行，无法${reason}。"
    echo
    echo -e "  ${C}1.${NC} 启动 WARP 后继续"
    echo -e "  ${R}0.${NC} 返回上一级"
    read -r -p "请选择操作: " act
    case "${act:-}" in
      1)
        if warp_start_service_checked; then
          ok "WARP 已启动。"
          warp_require_trace_for_routing && "$next_func"
        else
          err "WireProxy 服务启动失败。"
          pause
        fi
        ;;
      *) return 0 ;;
    esac
    return 0
  fi
  warp_require_trace_for_routing && "$next_func"
}

warp_global_menu_body() {
  local act
  if [ "$(warp_meta_mode)" = "global" ]; then
    echo "当前已开启全局 WARP。"
    echo "普通直连流量都在使用 WARP，中转节点不受影响。"
    echo
    echo -e "  ${C}1.${NC} 关闭全局 WARP"
    echo -e "  ${C}2.${NC} 切换为常用网站 WARP 分流"
    echo -e "  ${R}0.${NC} 返回上一级"
    read -r -p "请选择操作: " act
    case "${act:-}" in
      1)
        warp_meta_set_mode off && warp_apply_current_state && ok "已关闭全局 WARP。"
        pause
        ;;
      2)
        warp_common_rules_from_global
        ;;
    esac
    return 0
  fi

  echo "启用后：普通直连流量会走 WARP，中转节点保持原有出站。"
  echo "route.final 仍保持 reject，用户管理的禁用/授权逻辑不变。"
  ask_confirm_yn "确认开启全局 WARP？(y/N): " || return 0
  warp_meta_set_mode global || return 1
  warp_apply_current_state || return 1
  ok "全局 WARP 已开启。"
  pause
}

warp_global_menu() {
  warp_require_ready_or_install "设置全局出站" warp_global_menu_body
}

warp_preset_rule() {
  case "$1" in
    1) echo "AI 服务（海外聚合）|geosite-category-ai-!cn.srs" ;;
    2) echo "Netflix|geosite-netflix.srs" ;;
    3) echo "Disney+|geosite-disney.srs" ;;
    4) echo "YouTube|geosite-youtube.srs" ;;
    5) echo "TikTok|geosite-tiktok.srs" ;;
    *) return 1 ;;
  esac
}

warp_add_preset_rules() {
  local raw="$1" picks=() pick item name file
  mapfile -t picks < <(parse_plus_selections "$raw")
  [ "${#picks[@]}" -gt 0 ] || return 1
  for pick in "${picks[@]}"; do
    if ! [[ "$pick" =~ ^[1-5]$ ]]; then
      err "只能使用 1-5，并用 + 连接。"
      pause
      return 1
    fi
  done
  for pick in "${picks[@]}"; do
    item="$(warp_preset_rule "$pick")" || return 1
    name="${item%%|*}"
    file="${item#*|}"
    warp_rule_add_meta "$name" "$file" || return 1
  done
  warp_meta_set_mode rules || return 1
  warp_apply_current_state || return 1
  ok "WARP 分流规则已应用。"
  pause
}

warp_custom_rule_menu() {
  local raw file name
  echo "请先在以下页面查找规则名："
  echo "$WARP_RULE_LOOKUP_URL"
  echo
  read -r -p "请输入规则名，例如：openai / geosite-openai / geosite-openai.srs: " raw
  file="$(warp_normalize_rule_file "$raw")" || { pause; return 1; }
  say "校验规则文件：$file"
  if ! warp_validate_rule_file "$file"; then
    err "未在 SagerNet rule-set 中找到：$file"
    pause
    return 1
  fi
  name="自定义：${file%.srs}"
  warp_rule_add_meta "$name" "$file" || return 1
  warp_meta_set_mode rules || return 1
  warp_apply_current_state || return 1
  ok "自定义 WARP 分流已添加：$file"
  pause
}

warp_rules_print() {
  local rules_json count
  rules_json="$(warp_meta_rules_json)"
  count="$(echo "$rules_json" | jq 'length')"
  if [ "$count" -eq 0 ]; then
    echo "当前没有常用网站 WARP 分流。"
    return 0
  fi
  echo "当前 WARP 分流："
  echo "$rules_json" | jq -r '.[] | "  - \(.name)：\(.file)"'
}

warp_rules_view_menu() {
  warp_rules_print
  pause
}

warp_rules_delete_menu() {
  local rules_json count raw tags_json
  local -a idx=()
  rules_json="$(warp_meta_rules_json)"
  count="$(echo "$rules_json" | jq 'length')"
  [ "$count" -gt 0 ] || { warn "当前没有可删除的 WARP 分流。"; pause; return 0; }
  echo "$rules_json" | jq -r 'to_entries[] | "  \(.key + 1). \(.value.name)：\(.value.file)"'
  read -r -p "请输入要删除的编号，多个用+连接: " raw
  mapfile -t idx < <(parse_plus_selections "$raw")
  tags_json="$(
    {
      local n
      for n in "${idx[@]}"; do
        if ! [[ "$n" =~ ^[0-9]+$ ]] || [ "$n" -lt 1 ] || [ "$n" -gt "$count" ]; then
          err "编号超出范围：$n"
          return 1
        fi
        echo "$rules_json" | jq -r --argjson i "$((n-1))" '.[$i].tag'
      done
    } | jq -R . | jq -s '.'
  )" || { pause; return 1; }
  warp_rule_remove_meta_by_tags_json "$tags_json" || return 1
  warp_apply_current_state || return 1
  ok "已删除指定 WARP 分流。"
  pause
}

warp_rules_clear_menu() {
  ask_confirm_yn "确认清空全部常用网站 WARP 分流？(y/N): " || return 0
  warp_rule_clear_meta || return 1
  warp_apply_current_state || return 1
  ok "已清空全部常用网站 WARP 分流。"
  pause
}

warp_common_rules_menu_body() {
  local act
  while true; do
    clear
    print_rect_title "常用网站 WARP 分流"
    warp_rules_print
    echo
    echo -e "  ${C}1.${NC} AI 服务（海外聚合）"
    echo -e "  ${C}2.${NC} Netflix"
    echo -e "  ${C}3.${NC} Disney+"
    echo -e "  ${C}4.${NC} YouTube"
    echo -e "  ${C}5.${NC} TikTok"
    echo -e "  ${C}6.${NC} 自定义网站规则"
    echo -e "  ${C}7.${NC} 查看当前分流"
    echo -e "  ${C}8.${NC} 删除指定分流"
    echo -e "  ${C}9.${NC} 清空全部分流"
    echo -e "  ${R}0.${NC} 返回上一级"
    echo
    echo "1-5支持用+连接，例如：1+3+5"
    read -r -p "请选择操作: " act
    case "${act:-}" in
      0|q|Q|"") return 0 ;;
      6) warp_custom_rule_menu || true ;;
      7) warp_rules_view_menu || true ;;
      8) warp_rules_delete_menu || true ;;
      9) warp_rules_clear_menu || true ;;
      *+*|[1-5]) warp_add_preset_rules "$act" || true ;;
      *) warn "无效输入：$act"; sleep 1 ;;
    esac
  done
}

warp_common_rules_from_global() {
  local act
  echo "当前已开启：全局 WARP"
  echo "所有普通直连流量都在使用 WARP。"
  echo
  echo "如果只想让常用网站使用 WARP，需要先关闭全局 WARP。"
  echo "WARP 服务会保留，用于常用网站分流。"
  echo
  echo -e "  ${C}1.${NC} 关闭全局 WARP，并设置常用网站分流"
  echo -e "  ${R}0.${NC} 返回上一级"
  read -r -p "请选择操作: " act
  case "${act:-}" in
    1)
      warp_meta_set_mode off || return 1
      warp_apply_current_state || return 1
      ok "已关闭全局 WARP。"
      sleep 1
      warp_common_rules_menu_body
      ;;
  esac
}

warp_common_rules_menu() {
  warp_require_ready_or_install "设置网站分流" _warp_common_rules_entry
}

_warp_common_rules_entry() {
  if [ "$(warp_meta_mode)" = "global" ]; then
    warp_common_rules_from_global
  else
    warp_common_rules_menu_body
  fi
}

warp_service_manage_menu() {
  local act
  while true; do
    clear
    print_rect_title "WARP 服务管理"
    echo "当前状态：$(warp_service_status_text)"
    if warp_service_installed; then
      echo "本地 SOCKS：127.0.0.1:$(warp_effective_port)"
    fi
    echo
    if ! warp_service_installed; then
      echo -e "  ${C}1.${NC} 安装并启动 WARP"
    elif warp_service_running; then
      echo -e "  ${C}1.${NC} 重启 WARP"
      echo -e "  ${C}2.${NC} 停用 WARP"
    else
      echo -e "  ${C}1.${NC} 启动 WARP"
      echo -e "  ${C}2.${NC} 停用 WARP"
    fi
    echo -e "  ${R}0.${NC} 返回上一级"
    read -r -p "请选择操作: " act
    case "${act:-}" in
      1)
        if ! warp_service_installed; then
          warp_install_and_start || true
        elif warp_service_running; then
          if warp_restart_service_checked; then
            ok "WARP 已重启。"
            warp_warn_if_trace_failed || true
          else
            err "WireProxy 服务重启失败。"
          fi
          pause
        else
          if warp_start_service_checked; then
            ok "WARP 已启动。"
            warp_warn_if_trace_failed || true
            warp_apply_current_state || true
          else
            err "WireProxy 服务启动失败。"
          fi
          pause
        fi
        ;;
      2)
        warp_service_installed && warp_disable_keep_config || { warn "WARP 尚未安装。"; sleep 1; }
        ;;
      0|q|Q|"") return 0 ;;
      *) warn "无效输入：$act"; sleep 1 ;;
    esac
  done
}

warp_cleanup_menu() {
  local act
  while true; do
    clear
    print_rect_title "清理/卸载 WARP"
    echo "当前状态：$(warp_service_status_text)"
    echo "当前模式：$(warp_mode_text)"
    echo
    echo -e "  ${C}1.${NC} 停用 WARP（保留配置）"
    echo -e "  ${C}2.${NC} 卸载 WARP（删除配置）"
    echo -e "  ${R}0.${NC} 返回上一级"
    read -r -p "请选择操作: " act
    case "${act:-}" in
      1) warp_disable_keep_config || true ;;
      2) warp_uninstall_all || true ;;
      0|q|Q|"") return 0 ;;
      *) warn "无效输入：$act"; sleep 1 ;;
    esac
  done
}

warp_manager_menu() {
  local act
  init_manager_env || { pause; return 0; }
  while true; do
    clear
    print_rect_title "WARP 解锁管理"
    echo "服务状态：$(warp_service_status_text)"
    echo "使用模式：$(warp_mode_text)"
    if warp_service_installed; then
      echo "本地 SOCKS：127.0.0.1:$(warp_effective_port)"
    fi
    echo
    echo -e "  ${C}1.${NC} WARP 服务管理"
    echo -e "  ${C}2.${NC} 全局使用 WARP 出站（适合 IPv6 only）"
    echo -e "  ${C}3.${NC} 常用网站 WARP 分流"
    echo -e "  ${C}4.${NC} 测试 WARP 出口 IP"
    echo -e "  ${C}5.${NC} 清理/卸载 WARP"
    echo -e "  ${R}0.${NC} 返回上一级"
    read -r -p "请选择操作: " act
    case "${act:-}" in
      1) warp_service_manage_menu || true ;;
      2) warp_global_menu || true ;;
      3) warp_common_rules_menu || true ;;
      4) warp_test_print || true ;;
      5) warp_cleanup_menu || true ;;
      0|q|Q|"") return 0 ;;
      *) warn "无效输入：$act"; sleep 1 ;;
    esac
  done
}
