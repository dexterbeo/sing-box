#!/usr/bin/env bash
# ============================================================
# 模块: 80_installer.sh
# 职责: sing-box 安装/更新/卸载、systemd 服务、cron、系统工具
# 依赖: 00_base.sh, 01_utils.sh, 10_config.sh, 50_v2ray_api.sh
# ============================================================

# ---------- 依赖安装 ----------

ensure_deps_for_installer() {
  require_root
  [ "$PKG_MANAGER" = "unknown" ] && { err "未找到受支持的包管理器（apt-get 或 apk）。"; exit 1; }
  say "检查并安装必要依赖..."
  install_pkg curl
  install_pkg jq
  install_pkg openssl
  install_pkg tar
  case "$PKG_MANAGER" in
    apt) install_pkg ca-certificates; install_pkg gnupg; install_pkg gzip ;;
    apk) install_pkg ca-certificates; install_pkg gcompat ;;
  esac
}

version_ge() {
  # version_ge A B → true if A >= B（使用 sort -V）
  [ "$(printf '%s\n%s' "$1" "$2" | sort -V | head -n1)" = "$2" ]
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
  echo -e " 当前版本 : ${inst:-未安装}"
  echo -e " 最新版本 : ${cand:-无}"
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
    # 管道/process substitution 执行场景：从自身文件描述符读取内容写入目标
    # 这样无论从哪个分支执行，s 快捷命令始终与当前运行版本一致
    if [ ! -s "$SB_TARGET_SCRIPT" ] || [ "$target_ver" != "$current_ver" ]; then
      local fd_path
      fd_path="$(readlink -f "$current" 2>/dev/null || true)"
      if [ -n "$fd_path" ] && [ -r "$fd_path" ]; then
        cp -f "$fd_path" "$SB_TARGET_SCRIPT" >/dev/null 2>&1 || true
      else
        # fd 不可读时（极少数系统）回退到网络下载
        curl -Ls "$REMOTE_SCRIPT_URL" -o "$SB_TARGET_SCRIPT" >/dev/null 2>&1 || true
      fi
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
    # 管道执行场景：优先从自身 fd 读取，确保版本一致
    local fd_path
    fd_path="$(readlink -f "$current" 2>/dev/null || true)"
    if [ -n "$fd_path" ] && [ -r "$fd_path" ]; then
      cp -f "$fd_path" "$SB_TARGET_SCRIPT" || {
        warn "快捷命令 s 安装失败：无法写入 $SB_TARGET_SCRIPT"
        return 1
      }
    else
      curl -Ls "$REMOTE_SCRIPT_URL" -o "$SB_TARGET_SCRIPT" || {
        warn "快捷命令 s 安装失败：无法下载脚本到 $SB_TARGET_SCRIPT"
        return 1
      }
    fi
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

_cron_job_installed() {
  local mark="$1"
  has_cmd crontab || return 1
  crontab -l 2>/dev/null | grep -Fq "$mark"
}

_crond_daemon_active() {
  case "$INIT_SYSTEM" in
    systemd)
      systemctl is-active --quiet crond 2>/dev/null || systemctl is-active --quiet cron 2>/dev/null
      ;;
    openrc)
      rc-service crond status >/dev/null 2>&1 || rc-service cron status >/dev/null 2>&1
      ;;
    *) return 1 ;;
  esac
}

_ensure_crond_running() {
  # Alpine 环境需要主动装 + 启 crond；apt 环境通常随包自启
  if [ "$PKG_MANAGER" = "apk" ]; then
    install_pkg cronie 2>/dev/null || install_pkg dcron 2>/dev/null || true
    case "$INIT_SYSTEM" in
      openrc)
        if ! _crond_daemon_active; then
          rc-service crond start >/dev/null 2>&1 || rc-service cron start >/dev/null 2>&1 || true
          rc-update add crond default >/dev/null 2>&1 || rc-update add cron default >/dev/null 2>&1 || true
        fi
        ;;
      systemd)
        _crond_daemon_active || { systemctl start crond >/dev/null 2>&1 || systemctl start cron >/dev/null 2>&1 || true; }
        ;;
    esac
  fi
  # 严格验证：所有环境最后都必须 daemon 已运行
  _crond_daemon_active
}

cron_job_status_line() {
  local label="$1" mark="$2"
  local installed daemon_state
  if _cron_job_installed "$mark"; then
    installed="${G}已安装${NC}"
  else
    installed="${R}未安装${NC}"
  fi
  if _crond_daemon_active; then
    daemon_state="${G}运行中${NC}"
  else
    daemon_state="${R}未运行${NC}"
  fi
  printf '  %b%s%b : %b  daemon %b\n' "$W" "$label" "$NC" "$installed" "$daemon_state"
}

_install_cron_job() {
  local mark="$1" schedule="$2" cmd="$3"
  has_cmd crontab || { err "未找到 crontab 命令，请先安装 cron。"; return 1; }
  _ensure_crond_running || { err "crond 服务未运行，无法安装定时任务。"; return 1; }
  local tmp
  tmp="$(mktemp)"
  crontab -l 2>/dev/null | grep -v "$mark" > "$tmp" || true
  echo "${schedule} ${cmd} >/dev/null 2>&1" >> "$tmp"
  crontab "$tmp" || { rm -f "$tmp"; err "crontab 写入失败。"; return 1; }
  rm -f "$tmp"
  _cron_job_installed "$mark" || { err "crontab 写入后验证失败：未找到 mark $mark"; return 1; }
  return 0
}

_remove_cron_job() {
  local mark="$1"
  has_cmd crontab || return 0
  local tmp
  tmp="$(mktemp)"
  crontab -l 2>/dev/null | grep -v "$mark" > "$tmp" || true
  if [ -s "$tmp" ]; then
    crontab "$tmp"
  else
    crontab -r 2>/dev/null || true
  fi
  rm -f "$tmp"
}

install_log_maintain_cron() { _install_cron_job "$LOG_MAINTAIN_CRON_MARK" "$LOG_MAINTAIN_CRON_SCHEDULE" "bash ${SB_TARGET_SCRIPT} --maintain-logs"; }
remove_log_maintain_cron()  { _remove_cron_job "$LOG_MAINTAIN_CRON_MARK"; }
install_user_watch_cron()   { _install_cron_job "$USER_WATCH_CRON_MARK" "$USER_WATCH_CRON_SCHEDULE" "bash ${SB_TARGET_SCRIPT} --user-watch"; }
remove_user_watch_cron()    { _remove_cron_job "$USER_WATCH_CRON_MARK"; }

# ---------- 服务管理（systemd / OpenRC） ----------

remove_all_singbox_service_units() {
  say "清理 sing-box service（包含官方残留）..."
  case "$INIT_SYSTEM" in
    systemd)
      systemctl stop sing-box >/dev/null 2>&1 || true
      systemctl disable sing-box >/dev/null 2>&1 || true
      rm -f /etc/systemd/system/sing-box.service \
            /usr/lib/systemd/system/sing-box.service \
            /lib/systemd/system/sing-box.service >/dev/null 2>&1 || true
      systemctl daemon-reload >/dev/null 2>&1 || true
      ;;
    openrc)
      rc-service sing-box stop >/dev/null 2>&1 || true
      rc-update del sing-box default >/dev/null 2>&1 || true
      rm -f /etc/init.d/sing-box >/dev/null 2>&1 || true
      ;;
  esac
  ok "sing-box service 已清理。"
}

write_managed_singbox_service() {
  mkdir -p /var/lib/sing-box /etc/sing-box
  case "$INIT_SYSTEM" in
    systemd)
      mkdir -p /etc/systemd/system
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
      ;;
    openrc)
      cat > /etc/init.d/sing-box <<EOF
#!/sbin/openrc-run
description="sing-box service"
command="${SINGBOX_BIN}"
command_args="-D /var/lib/sing-box -c ${CONFIG_FILE} run"
command_background=true
pidfile="/run/sing-box.pid"
depend() {
  need net
  after firewall
}
EOF
      chmod +x /etc/init.d/sing-box
      ;;
  esac
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
  case "$INIT_SYSTEM" in
    systemd)
      [ -f /etc/systemd/system/sing-box.service ] || return 1
      grep -Fq "ExecStart=${SINGBOX_BIN} -D /var/lib/sing-box -c /etc/sing-box/config.json run" /etc/systemd/system/sing-box.service 2>/dev/null || return 1
      ;;
    openrc)
      [ -f /etc/init.d/sing-box ] || return 1
      grep -Fq "${SINGBOX_BIN}" /etc/init.d/sing-box 2>/dev/null || return 1
      ;;
    *) return 1 ;;
  esac
  [ -f /usr/local/bin/s ] && grep -Fq 'exec bash /root/sing-box.sh "$@"' /usr/local/bin/s 2>/dev/null || return 1
  return 0
}

prepare_script_runtime() {
  migrate_legacy_user_db_if_needed
  write_managed_singbox_service
  ensure_command_compat_links
  mkdir -p /var/log/sing-box >/dev/null 2>&1 || true
  [ "$INIT_SYSTEM" = "systemd" ] && systemctl daemon-reload >/dev/null 2>&1 || true
}

# ---------- 安装/更新 sing-box ----------

install_or_update_singbox() {
  clear
  print_rect_title "sing-box 安装/更新"

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
    if [ -n "${inst:-}" ] && version_ge "$inst" "$latest_ver"; then
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

  say "下载 sing-box ${latest_ver}..."
  if ! curl -fL --connect-timeout 20 --retry 3 "$download_url" -o "$tmp_dir/$file"; then
    rm -rf "$tmp_dir"
    err "下载失败。"
    pause
    return 1
  fi

  say "校验安装包..."
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
    if [ "$PKG_MANAGER" = "apk" ]; then
      warn "Alpine 环境提示：若报 'cannot execute' 错误，请手动执行：apk add gcompat"
    fi
    pause
    return 1
  fi

  say "准备流量统计依赖..."
  ensure_grpcurl_logged || true
  ensure_v2ray_api_proto_files || true

  prepare_script_runtime
  config_ensure_exists
  config_force_access_log_settings || true
  enable_now_singbox_safe || true
  ensure_sb_shortcut || true
  install_user_watch_cron || {
    err "用户流量统计定时任务安装失败，请修复 cron 后重新运行安装。"
    pause
    return 1
  }
  install_log_maintain_cron || {
    err "日志维护定时任务安装失败，请修复 cron 后重新运行安装。"
    pause
    return 1
  }
  show_versions
  ok "安装完成，已配置服务（${INIT_SYSTEM}）、定时任务、快捷命令 s。"
  pause
}

# ---------- 时间同步 ----------

sync_system_time_chrony() {
  require_root
  clear
  echo -e "${R}--- 一键同步系统时间 ---${NC}"
  if ! has_cmd chronyc; then
    warn "未检测到 chrony，开始安装..."
    install_pkg chrony || { err "chrony 安装失败。"; pause; return 1; }
  fi
  # 停用系统自带 timesyncd（仅 systemd 有此服务）
  if [ "$INIT_SYSTEM" = "systemd" ]; then
    systemctl stop systemd-timesyncd >/dev/null 2>&1 || true
    systemctl disable systemd-timesyncd >/dev/null 2>&1 || true
  fi
  local chrony_running=0
  case "$INIT_SYSTEM" in
    systemd) [ "$(systemctl is-active chrony 2>/dev/null)" = "active" ] && chrony_running=1 ;;
    openrc)  rc-service chrony status >/dev/null 2>&1 && chrony_running=1 ;;
  esac
  if chronyc tracking >/dev/null 2>&1 && [ "$chrony_running" = "1" ]; then
    ok "chrony 已正常运行。"
  else
    warn "开始修复 chrony 服务状态..."
    case "$INIT_SYSTEM" in
      systemd)
        systemctl stop chrony >/dev/null 2>&1 || true
        pkill -9 chronyd >/dev/null 2>&1 || true
        rm -f /run/chrony/chronyd.pid >/dev/null 2>&1 || true
        systemctl reset-failed chrony >/dev/null 2>&1 || true
        systemctl start chrony >/dev/null 2>&1 || true
        ;;
      openrc)
        rc-service chrony stop >/dev/null 2>&1 || true
        pkill -9 chronyd >/dev/null 2>&1 || true
        rm -f /run/chrony/chronyd.pid >/dev/null 2>&1 || true
        rc-service chrony start >/dev/null 2>&1 || true
        ;;
    esac
    sleep 2
  fi
  case "$INIT_SYSTEM" in
    systemd) systemctl enable chrony >/dev/null 2>&1 || true ;;
    openrc)  rc-update add chrony default >/dev/null 2>&1 || true ;;
  esac
  chronyc -a makestep >/dev/null 2>&1 || true
  ok "时间同步完成。"
  case "$INIT_SYSTEM" in
    systemd) systemctl status chrony --no-pager -l || true ;;
    openrc)  rc-service chrony status || true ;;
  esac
  pause
}

# ---------- 卸载 ----------

uninstall_singbox_keep_config() {
  require_root
  clear
  echo -e "${R}--- 卸载 sing-box（保留 /etc/sing-box/ 配置）---${NC}"
  echo -e "${Y}注意：该操作将卸载接管层、官方安装残留、cron 与运行文件，但保留配置、用户数据、日志文件。${NC}"
  ask_confirm_yes || { warn "已取消卸载。"; pause; return 0; }

  sync_user_usage_counters || true
  remove_user_watch_cron || true
  remove_log_maintain_cron || true
  remove_all_singbox_service_units
  # 清理官方包可能创建的系统用户/组
  if has_cmd deluser; then
    deluser --system sing-box >/dev/null 2>&1 || true
  else
    userdel sing-box >/dev/null 2>&1 || true
  fi
  if has_cmd delgroup; then
    delgroup --system sing-box >/dev/null 2>&1 || true
  else
    groupdel sing-box >/dev/null 2>&1 || true
  fi
  rm -f "$SINGBOX_BIN" /usr/bin/sing-box "$SINGBOX_VERSION_STAMP" "$GRPCURL_BIN" >/dev/null 2>&1 || true
  if pkg_installed sing-box || pkg_installed sing-box-beta; then
    case "$PKG_MANAGER" in
      apt)
        pkg_installed sing-box && apt-get remove -y sing-box || true
        pkg_installed sing-box-beta && apt-get remove -y sing-box-beta || true
        pkg_installed sing-box && apt-get purge -y sing-box || true
        pkg_installed sing-box-beta && apt-get purge -y sing-box-beta || true
        ;;
      apk)
        pkg_installed sing-box && apk del sing-box >/dev/null 2>&1 || true
        pkg_installed sing-box-beta && apk del sing-box-beta >/dev/null 2>&1 || true
        ;;
    esac
    ok "已清理脚本运行层并卸载官方包残留（如存在）。"
  else
    ok "已清理脚本运行层（如存在）。"
  fi
  [ -d /etc/sing-box ] && ok "配置目录仍存在：/etc/sing-box" || warn "未找到 /etc/sing-box"
  [ -d "$(dirname "$USER_DB_FILE")" ] && ok "用户数据库目录仍存在：$(dirname "$USER_DB_FILE")" || true
  pause
}
