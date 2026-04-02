#!/usr/bin/env bash
# ============================================================
# 模块: 80_installer.sh
# 职责: sing-box 安装/更新/卸载、systemd 服务、cron、系统工具
# 依赖: 00_base.sh, 01_utils.sh, 10_config.sh, 50_v2ray_api.sh
# ============================================================

# ---------- 依赖安装 ----------

ensure_deps_for_installer() {
  require_root
  has_cmd apt-get || { err "未找到 apt-get，本脚本按 Debian/Ubuntu APT 方式设计。"; exit 1; }
  say "检查并安装必要依赖..."
  install_pkg_apt sudo
  install_pkg_apt ca-certificates
  install_pkg_apt curl
  install_pkg_apt gnupg
  install_pkg_apt jq
  install_pkg_apt openssl
  install_pkg_apt tar
  install_pkg_apt gzip
}

ensure_sagernet_repo() { :; }

# ---------- 版本管理 ----------

get_release_latest_tag() {
  local repo="${SINGBOX_RELEASE_REPO:-Tangfffyx/sing-box}"
  curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null | jq -r '.tag_name // empty'
}

normalize_release_tag() {
  local v="${1:-}"
  v="${v#v}"
  echo "$v"
}

get_candidate_version() {
  normalize_release_tag "$(get_release_latest_tag)"
}

get_installed_version() {
  local stamp ver
  if [ -s "$SINGBOX_VERSION_STAMP" ]; then
    stamp="$(cat "$SINGBOX_VERSION_STAMP" 2>/dev/null || true)"
    stamp="${stamp#v}"
    [ -n "$stamp" ] && { echo "$stamp"; return 0; }
  fi
  if [ -x "$SINGBOX_BIN" ]; then
    ver="$("$SINGBOX_BIN" version 2>/dev/null | awk '/^sing-box version / {print $3; exit}')"
    ver="${ver#v}"
    [ "$ver" != "unknown" ] && [ -n "$ver" ] && { echo "$ver"; return 0; }
  fi
  echo ""
}

show_versions() {
  local inst cand
  inst="$(get_installed_version)"
  cand="$(get_candidate_version)"
  echo -e "${W}-------- 版本信息 --------${NC}"
  echo -e " Installed : ${inst:-<not installed>}"
  echo -e " Candidate : ${cand:-<none>}"
  echo -e "${W}--------------------------${NC}"
}

# ---------- 脚本自身管理 ----------

script_version_of_file() {
  local f="${1:-}"
  [ -f "$f" ] || return 1
  grep -E '^[[:space:]]*SCRIPT_VERSION=' "$f" 2>/dev/null | head -n1 | sed -E 's/^[^"]*"([^"]+)".*$/\1/'
}

sync_runtime_script_entrypoints() {
  local current="${SCRIPT_SELF:-${BASH_SOURCE[0]:-$0}}"
  local resolved current_ver target_ver
  resolved="$(readlink -f "$current" 2>/dev/null || echo "$current")"
  current_ver="${SCRIPT_VERSION:-}"
  target_ver="$(script_version_of_file "$SB_TARGET_SCRIPT" || true)"

  if [[ "$resolved" == /dev/fd/* ]] || [[ "$resolved" == /proc/self/fd/* ]] || [[ "$0" == /dev/fd/* ]] || [[ "$0" == /proc/self/fd/* ]]; then
    if [ ! -s "$SB_TARGET_SCRIPT" ] || [ "$target_ver" != "$current_ver" ]; then
      curl -Ls "$REMOTE_SCRIPT_URL" -o "$SB_TARGET_SCRIPT" >/dev/null 2>&1 || true
    fi
  else
    if [ "$resolved" != "$SB_TARGET_SCRIPT" ] && { [ ! -s "$SB_TARGET_SCRIPT" ] || [ "$target_ver" != "$current_ver" ]; }; then
      cp -f "$resolved" "$SB_TARGET_SCRIPT" >/dev/null 2>&1 || true
    fi
  fi

  chmod +x "$SB_TARGET_SCRIPT" >/dev/null 2>&1 || true
  install_sb_shortcut >/dev/null 2>&1 || true
}

install_script_self() {
  mkdir -p /usr/local/bin
  local current="${SCRIPT_SELF:-${BASH_SOURCE[0]:-$0}}"
  if [[ "$0" == /dev/fd/* ]] || [[ "$0" == /proc/self/fd/* ]] || [[ "$current" == /dev/fd/* ]] || [[ "$current" == /proc/self/fd/* ]]; then
    curl -Ls "$REMOTE_SCRIPT_URL" -o "$SB_TARGET_SCRIPT" || {
      warn "快捷命令 s 安装失败：无法下载脚本到 $SB_TARGET_SCRIPT"
      return 1
    }
  else
    current="$(readlink -f "$current" 2>/dev/null || echo "$current")"
    if [ "$current" != "$SB_TARGET_SCRIPT" ]; then
      cp -f "$current" "$SB_TARGET_SCRIPT" || {
        warn "快捷命令 s 安装失败：无法复制脚本到 $SB_TARGET_SCRIPT"
        return 1
      }
    fi
  fi
  chmod +x "$SB_TARGET_SCRIPT" >/dev/null 2>&1 || true
}

install_sb_shortcut() {
  cat > "$SB_SHORTCUT" <<'EOF2'
#!/bin/sh
exec bash /root/sing-box.sh "$@"
EOF2
  chmod +x "$SB_SHORTCUT" >/dev/null 2>&1 || true
}

ensure_sb_shortcut() {
  install_script_self || return 1
  install_sb_shortcut
  ok "已创建脚本快捷键：s"
}

# ---------- 日志维护 ----------

maintain_script_log_file() {
  local log_file="${1:-$SCRIPT_LOG_FILE}" max_bytes="${2:-$LOG_MAX_BYTES}"
  [ -n "$log_file" ] || return 0
  [ -f "$log_file" ] || return 0
  [ -s "$log_file" ] || return 0

  local size tmp
  size="$(wc -c < "$log_file" 2>/dev/null || echo 0)"
  [[ "$size" =~ ^[0-9]+$ ]] || size=0
  [ "$size" -le "$max_bytes" ] && return 0

  tmp="$(mktemp)"
  tail -c "$max_bytes" "$log_file" > "$tmp" 2>/dev/null || {
    rm -f "$tmp" >/dev/null 2>&1 || true
    return 1
  }
  cat "$tmp" > "$log_file"
  rm -f "$tmp" >/dev/null 2>&1 || true
  return 0
}

maintain_logs() {
  maintain_script_log_file "$SCRIPT_LOG_FILE" "$LOG_MAX_BYTES" || true
  return 0
}

config_force_access_log_settings() {
  [ -s "$CONFIG_FILE" ] || return 0
  mkdir -p /var/log/sing-box >/dev/null 2>&1 || true
  local json updated
  json="$(config_load)" || return 1
  updated="$(echo "$json" | jq '.log = (.log // {}) | .log.level = "info" | .log.output = "/var/log/sing-box/access.log" | .log.timestamp = true')" || return 1
  config_apply "$updated" || return 1
}

# ---------- Cron 管理 ----------

install_log_maintain_cron() {
  has_cmd crontab || return 1
  local tmp
  tmp="$(mktemp)"
  crontab -l 2>/dev/null | grep -v "${LOG_MAINTAIN_CRON_MARK}" > "$tmp" || true
  echo "${LOG_MAINTAIN_CRON_SCHEDULE} bash ${SB_TARGET_SCRIPT} --maintain-logs >/dev/null 2>&1" >> "$tmp"
  crontab "$tmp"
  rm -f "$tmp"
}

remove_log_maintain_cron() {
  has_cmd crontab || return 0
  local tmp
  tmp="$(mktemp)"
  crontab -l 2>/dev/null | grep -v "${LOG_MAINTAIN_CRON_MARK}" > "$tmp" || true
  if [ -s "$tmp" ]; then
    crontab "$tmp"
  else
    crontab -r 2>/dev/null || true
  fi
  rm -f "$tmp"
}

install_user_watch_cron() {
  has_cmd crontab || return 1
  local tmp
  tmp="$(mktemp)"
  crontab -l 2>/dev/null | grep -v "${USER_WATCH_CRON_MARK}" > "$tmp" || true
  echo "${USER_WATCH_CRON_SCHEDULE} bash ${SB_TARGET_SCRIPT} --user-watch >/dev/null 2>&1" >> "$tmp"
  crontab "$tmp"
  rm -f "$tmp"
}

remove_user_watch_cron() {
  has_cmd crontab || return 0
  local tmp
  tmp="$(mktemp)"
  crontab -l 2>/dev/null | grep -v "${USER_WATCH_CRON_MARK}" > "$tmp" || true
  if [ -s "$tmp" ]; then
    crontab "$tmp"
  else
    crontab -r 2>/dev/null || true
  fi
  rm -f "$tmp"
}

# ---------- Systemd 服务管理 ----------

remove_all_singbox_service_units() {
  say "清理 sing-box service（包含官方残留）..."
  systemctl stop sing-box >/dev/null 2>&1 || true
  systemctl disable sing-box >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/sing-box.service >/dev/null 2>&1 || true
  rm -f /usr/lib/systemd/system/sing-box.service >/dev/null 2>&1 || true
  rm -f /lib/systemd/system/sing-box.service >/dev/null 2>&1 || true
  systemctl daemon-reload >/dev/null 2>&1 || true
  ok "sing-box service 已清理。"
}

write_managed_singbox_service() {
  mkdir -p /etc/systemd/system /var/lib/sing-box /etc/sing-box
  cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${SINGBOX_BIN} -D /var/lib/sing-box -c ${CONFIG_FILE} run
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

ensure_command_compat_links() {
  mkdir -p /usr/bin
  ln -sf "${SINGBOX_BIN}" /usr/bin/sing-box
}

migrate_legacy_user_db_if_needed() {
  if [ ! -e "$USER_DB_FILE" ] && [ -e "/etc/sing-box/user-manager.json" ]; then
    mkdir -p "$(dirname "$USER_DB_FILE")"
    mv -f /etc/sing-box/user-manager.json "$USER_DB_FILE" 2>/dev/null || cp -f /etc/sing-box/user-manager.json "$USER_DB_FILE"
  fi
}

is_script_managed_environment() {
  [ -f /etc/systemd/system/sing-box.service ] || return 1
  grep -Fq "ExecStart=${SINGBOX_BIN} -D /var/lib/sing-box -c /etc/sing-box/config.json run" /etc/systemd/system/sing-box.service 2>/dev/null || return 1
  [ -f /usr/local/bin/s ] && grep -Fq 'exec bash /root/sing-box.sh "$@"' /usr/local/bin/s 2>/dev/null || return 1
  return 0
}

prepare_script_runtime() {
  say "准备脚本运行环境..."
  migrate_legacy_user_db_if_needed
  write_managed_singbox_service
  ensure_command_compat_links
  mkdir -p /var/log/sing-box >/dev/null 2>&1 || true
  systemctl daemon-reload
  ok "脚本运行环境已就绪。"
}

# ---------- 安装/更新 sing-box ----------

install_or_update_singbox() {
  clear
  echo -e "${B}+----------------------------------------------+${NC}"
  echo -e "${B}|           Sing-box Installer / Updater       |${NC}"
  echo -e "${B}+----------------------------------------------+${NC}"

  ensure_deps_for_installer

  sync_user_usage_counters || true

  local arch file tag latest_ver inst ans tmp_dir base_url download_url sha_url managed_env
  arch="$(uname -m)"
  case "$arch" in
    x86_64) file="sing-box-linux-amd64.tar.gz" ;;
    aarch64|arm64) file="sing-box-linux-arm64.tar.gz" ;;
    armv7l|armv7) file="sing-box-linux-armv7.tar.gz" ;;
    i386|i686) file="sing-box-linux-386.tar.gz" ;;
    *)
      err "不支持的架构：$arch"
      pause
      return 1
      ;;
  esac

  tag="$(get_release_latest_tag)"
  latest_ver="$(normalize_release_tag "$tag")"

  managed_env="0"
  inst=""
  if is_script_managed_environment; then
    managed_env="1"
    inst="$(get_installed_version)"
  fi

  if [ -z "${latest_ver:-}" ]; then
    err "未获取到 GitHub Release 最新版本。"
    pause
    return 1
  fi

  if [ "${managed_env}" != "1" ] && command -v sing-box >/dev/null 2>&1; then
    ui_echo "[WARN] 检测到已有非本脚本安装的 sing-box 环境，请先执行"卸载 sing-box"后再安装。"
    pause >&2
    return 0
  fi

  if [ "${managed_env}" = "1" ]; then
    echo -e "当前版本：${G}${inst:-未知}${NC}"
    echo -e "最新版本：${G}${latest_ver}${NC}"
    if [ -n "${inst:-}" ] && ! dpkg --compare-versions "$inst" lt "$latest_ver"; then
      ok "当前已是最新版本。"
      pause
      return 0
    fi
    if [ -n "${inst:-}" ]; then
      read -r -p "检测到新版本，是否升级？[Y/n]: " ans
      case "${ans:-Y}" in
        [Nn]*) return 0 ;;
      esac
    else
      echo -e "当前状态：${Y}本脚本环境，但未识别到已安装版本${NC}"
      echo -e "将安装版本：${G}${latest_ver}${NC}"
    fi
  else
    echo -e "当前状态：${Y}未安装 sing-box${NC}"
    echo -e "将安装版本：${G}${latest_ver}${NC}"
  fi

  tmp_dir="$(mktemp -d)"
  base_url="https://github.com/${SINGBOX_RELEASE_REPO:-Tangfffyx/sing-box}/releases/download/${tag}"
  download_url="${base_url}/${file}"
  sha_url="${base_url}/sha256sum.txt"

  say "下载：${download_url}"
  if ! curl -fL --connect-timeout 20 --retry 3 "$download_url" -o "$tmp_dir/$file"; then
    rm -rf "$tmp_dir"
    err "下载失败。"
    pause
    return 1
  fi

  say "下载校验文件..."
  if curl -fL --connect-timeout 20 --retry 3 "$sha_url" -o "$tmp_dir/sha256sum.txt" >/dev/null 2>&1; then
    expected_sha="$(awk -v f="$file" '{n=$2; sub(/^.*\//,"",n); if (n==f) {print $1; exit}}' "$tmp_dir/sha256sum.txt")"
    actual_sha="$(sha256sum "$tmp_dir/$file" | awk '{print $1}')"
    if [ -n "$expected_sha" ] && [ "$expected_sha" = "$actual_sha" ]; then
      ok "文件校验通过。"
    else
      rm -rf "$tmp_dir"
      err "校验失败。"
      pause
      return 1
    fi
  else
    warn "未获取到 sha256sum.txt，跳过校验。"
  fi

  tar -xzf "$tmp_dir/$file" -C "$tmp_dir" || {
    rm -rf "$tmp_dir"
    err "解压失败。"
    pause
    return 1
  }

  [ -f "$tmp_dir/sing-box" ] || {
    rm -rf "$tmp_dir"
    err "安装包中未找到 sing-box 可执行文件。"
    pause
    return 1
  }

  mkdir -p "$SINGBOX_INSTALL_DIR" /etc/sing-box
  if [ -x "$SINGBOX_BIN" ]; then
    cp -f "$SINGBOX_BIN" "${SINGBOX_BIN}.bak" 2>/dev/null || true
  fi
  install -m 755 "$tmp_dir/sing-box" "$SINGBOX_BIN" || {
    rm -rf "$tmp_dir"
    err "安装失败。"
    pause
    return 1
  }
  echo "$tag" > "$SINGBOX_VERSION_STAMP"
  rm -rf "$tmp_dir"

  if ! "$SINGBOX_BIN" version | grep -q 'with_v2ray_api'; then
    err "当前安装的 sing-box 未检测到 with_v2ray_api。"
    pause
    return 1
  fi

  ok "sing-box 安装/更新完成。"
  say "准备流量统计依赖..."
  ensure_grpcurl_logged || true
  ensure_v2ray_api_proto_files || true

  prepare_script_runtime
  config_ensure_exists
  config_force_access_log_settings || true
  enable_now_singbox_safe || true
  ensure_sb_shortcut || true
  install_user_watch_cron || true
  install_log_maintain_cron || true
  show_versions
  pause
}

# ---------- 时间同步 ----------

sync_system_time_chrony() {
  require_root
  clear
  echo -e "${R}--- 一键同步系统时间 ---${NC}"
  if ! has_cmd chronyc; then
    warn "未检测到 chrony，开始安装..."
    apt_update_once
    apt-get install -y chrony || { err "chrony 安装失败。"; pause; return 1; }
  fi
  systemctl stop systemd-timesyncd >/dev/null 2>&1 || true
  systemctl disable systemd-timesyncd >/dev/null 2>&1 || true
  if chronyc tracking >/dev/null 2>&1 && [ "$(systemctl is-active chrony 2>/dev/null)" = "active" ]; then
    ok "chrony 已正常运行。"
  else
    warn "开始修复 chrony 服务状态..."
    systemctl stop chrony >/dev/null 2>&1 || true
    pkill -9 chronyd >/dev/null 2>&1 || true
    rm -f /run/chrony/chronyd.pid >/dev/null 2>&1 || true
    systemctl reset-failed chrony >/dev/null 2>&1 || true
    systemctl start chrony >/dev/null 2>&1 || true
    sleep 2
  fi
  systemctl enable chrony >/dev/null 2>&1 || true
  chronyc -a makestep >/dev/null 2>&1 || true
  ok "时间同步完成。"
  systemctl status chrony --no-pager -l || true
  pause
}

# ---------- 卸载 ----------

uninstall_singbox_keep_config() {
  require_root
  clear
  echo -e "${R}--- 卸载 sing-box（保留 /etc/sing-box/ 配置）---${NC}"
  echo -e "${Y}注意：该操作将卸载接管层、官方安装残留、cron 与运行文件，但保留配置、用户数据、日志文件。${NC}"
  ask_confirm_yes || { warn "已取消卸载。"; pause; return 0; }

  has_cmd apt-get || { err "未找到 apt-get。"; pause; return 1; }
  sync_user_usage_counters || true
  remove_user_watch_cron || true
  remove_log_maintain_cron || true
  systemctl stop sing-box >/dev/null 2>&1 || true
  systemctl disable sing-box >/dev/null 2>&1 || true
  remove_all_singbox_service_units
  rm -f "$SINGBOX_BIN" /usr/bin/sing-box "$SINGBOX_VERSION_STAMP" "$GRPCURL_BIN" >/dev/null 2>&1 || true
  if pkg_installed sing-box || pkg_installed sing-box-beta; then
    pkg_installed sing-box && apt-get remove -y sing-box || true
    pkg_installed sing-box-beta && apt-get remove -y sing-box-beta || true
    pkg_installed sing-box && apt-get purge -y sing-box || true
    pkg_installed sing-box-beta && apt-get purge -y sing-box-beta || true
    ok "已清理脚本运行层并卸载官方包残留（如存在）。"
  else
    ok "已清理脚本运行层（如存在）。"
  fi
  [ -d /etc/sing-box ] && ok "配置目录仍存在：/etc/sing-box" || warn "未找到 /etc/sing-box"
  [ -d "$(dirname "$USER_DB_FILE")" ] && ok "用户数据库目录仍存在：$(dirname "$USER_DB_FILE")" || true
  pause
}
