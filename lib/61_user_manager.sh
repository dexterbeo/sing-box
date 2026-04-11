#!/usr/bin/env bash
# ============================================================
# 模块: 61_user_manager.sh
# 职责: 用户管理业务逻辑（投影、同步、自动控制）
# 依赖: 00_base.sh, 10_config.sh, 20_protocol.sh, 30_route.sh,
#       50_v2ray_api.sh, 60_user_db.sh
# ============================================================

user_manager_apply_to_json() {
  local json="$1" db_json="$2"
  local work_json="$json"
  local inv_lines=() line idx entry_key proto port inbound
  work_json="$(config_normalize "$work_json")" || return 1
  mapfile -t inv_lines < <(protocol_entry_inventory_ext "$work_json")
  for line in "${inv_lines[@]}"; do
    IFS=$'\t' read -r idx entry_key proto port <<< "$line"
    inbound="$(find_inbound_by_entry_key "$work_json" "$entry_key")"
    [ -n "$inbound" ] || continue

    local relay_nodes=() relay_node
    mapfile -t relay_nodes < <(echo "$inbound" | jq -r '.users[]?.name // empty' | while IFS= read -r n; do
      [ -n "$n" ] || continue
      np="$(user_node_part "$n")"
      if [[ "$np" == *"-to-"* && "$np" != "$entry_key" ]]; then
        echo "$np"
      fi
    done | sort -u)

    local desired_names=("$entry_key")
    local username
    while IFS= read -r username; do
      [ -n "$username" ] || continue
      [ "$username" = "admin" ] && continue
      if user_db_user_allow_node "$db_json" "$username" "$entry_key"; then
        desired_names+=("$(node_user_name "$entry_key" "$username")")
      fi
    done < <(user_db_all_users "$db_json")

    for relay_node in "${relay_nodes[@]}"; do
      desired_names+=("$relay_node")
      while IFS= read -r username; do
        [ -n "$username" ] || continue
        [ "$username" = "admin" ] && continue
        if user_db_user_allow_node "$db_json" "$username" "$relay_node"; then
          desired_names+=("$(node_user_name "$relay_node" "$username")")
        fi
      done < <(user_db_all_users "$db_json")
    done

    local users_tmp
    users_tmp="$(mktemp)"
    local desired full_name existing_obj new_obj
    for desired in "${desired_names[@]}"; do
      existing_obj="$(find_user_obj_in_inbound "$inbound" "$desired")"
      if [ -n "$existing_obj" ]; then
        echo "$existing_obj" >> "$users_tmp"
      else
        new_obj="$(build_user_object_from_inbound "$inbound" "$desired")" || {
          rm -f "$users_tmp"
          return 1
        }
        echo "$new_obj" >> "$users_tmp"
      fi
    done
    local users_json='[]'
    if [ -s "$users_tmp" ]; then
      users_json="$(jq -s '.' "$users_tmp")"
    fi
    rm -f "$users_tmp" >/dev/null 2>&1 || true
    work_json="$(echo "$work_json" | jq --argjson idx "$idx" --argjson users "$users_json" '.inbounds[$idx].users = $users')" || return 1
  done

  work_json="$(route_rebuild "$work_json")" || return 1
  work_json="$(filter_disabled_auth_users "$work_json" "$db_json")" || return 1
  ensure_v2ray_api_on_json "$work_json" || return 1
}

filter_disabled_auth_users() {
  local json="$1" db_json="$2"
  local enabled_json
  enabled_json="$(echo "$db_json" | jq -c '[.users | to_entries[] | select(.value.enabled == true) | .key]')"
  echo "$json" | jq "${JQ_AUTH_USERS}"'
    def user_enabled($u):
      if ($u | contains("@")) then ($enabled | index(($u | split("@")[1]))) != null
      else ($enabled | index("admin")) != null
      end;

    .route.rules |= map(
      if (.auth_user? == null) then .
      else
        (auth_users_array | map(select(user_enabled(.)))) as $remain
        | if ($remain | length) == 0 then empty
          elif ($remain | length) == 1 then .auth_user = $remain[0]
          else .auth_user = $remain
          end
      end
    )
  ' --argjson enabled "$enabled_json"
}

user_manager_apply_changes() {
  local db_json="$1" base_json="${2:-}"
  [ -n "$base_json" ] || base_json="$(config_load)"

  db_json="$(user_db_cleanup_missing_nodes "$db_json" "$base_json")" || return 1
  user_db_save "$db_json"

  local applied_json
  applied_json="$(user_manager_apply_to_json "$base_json" "$db_json")" || {
    err "生成用户节点关系失败。"
    return 1
  }

  if config_apply "$applied_json"; then
    ok "用户变更已应用。"
    return 0
  fi
  return 1
}

user_manager_runtime_sync() {
  local db_json current_json desired_json current_norm desired_norm
  db_json="$(user_db_load)"
  if [ ! -s "$USER_DB_FILE" ]; then
    user_db_save "$db_json"
  fi

  ensure_grpcurl >/dev/null 2>&1 || true

  current_json="$(config_load)"
  desired_json="$(user_manager_apply_to_json "$current_json" "$db_json")" || {
    err "生成用户流量统计配置失败。"
    return 1
  }

  current_norm="$(echo "$current_json" | jq -S .)"
  desired_norm="$(echo "$desired_json" | jq -S .)"
  if [ "$current_norm" != "$desired_norm" ]; then
    if config_apply "$desired_json"; then
      ok "配置已同步。"
    else
      err "配置同步失败。"
      return 1
    fi
  fi

  sync_user_usage_counters || true
  return 0
}

# ---------- 自动控制（到期/超额/重置） ----------

user_today_date() {
  date +%F
}

user_current_period() {
  date +%Y-%m
}

apply_automatic_user_controls() {
  init_manager_env
  user_db_exists || return 0
  sync_user_usage_counters || true

  local db_json json today period today_day last_day result changed
  db_json="$(user_db_load)"
  json="$(config_load)"
  today="$(user_today_date)"
  period="$(user_current_period)"
  today_day=$((10#$(date +%d)))
  last_day=$(awk -v y="$(date +%Y)" -v m="$(date +%m)" 'BEGIN {
    split("31 28 31 30 31 30 31 31 30 31 30 31", d, " ")
    d[2] = (y%4==0 && (y%100!=0 || y%400==0)) ? 29 : 28
    print d[m+0]
  }')

  result="$(echo "$db_json" | jq --arg today "$today" --arg period "$period" --argjson today_day "$today_day" --argjson last_day "$last_day" '
    .users |= with_entries(
      .value as $v
      | ($v.expire_at // "0") as $expire
      | ($v.reset_day // 0) as $reset_day
      | ($v.last_reset_period // "") as $last_reset
      | ($v.enabled // false) as $enabled
      | ($v.quota_gb // 0) as $quota
      | (($v.used_up_bytes // 0) + ($v.used_down_bytes // 0) + ($v.manual_added_bytes // 0)) as $billable

      # 1. 到期检查
      | if ($expire != "0" and ($today >= $expire)) then
          .value.enabled = false
        else
          # 2. 重置检查
          (
            if ($reset_day == 32) then $last_day
            elif ($reset_day >= 1 and $reset_day <= 29) then
              (if ($reset_day > $last_day) then $last_day else $reset_day end)
            else 0 end
          ) as $effective_reset_day
          | if ($effective_reset_day > 0 and $today_day == $effective_reset_day and $last_reset != $period) then
              .value.used_up_bytes = 0
              | .value.used_down_bytes = 0
              | .value.last_live_up_bytes = 0
              | .value.last_live_down_bytes = 0
              | .value.last_reset_period = $period
              | .value.enabled = true
            else . end
          # 3. 超额检查（重置后 billable 已清零，不会误判）
          | if ($quota > 0 and .value.enabled == true) then
              ((.value.used_up_bytes // 0) + (.value.used_down_bytes // 0) + (.value.manual_added_bytes // 0)) as $current_billable
              | if ($current_billable >= ($quota * 1073741824)) then
                  .value.enabled = false
                else . end
            else . end
        end
    )
  ')" || return 1

  changed="$(jq -n --argjson old "$db_json" --argjson new "$result" 'if ($old == $new) then "0" else "1" end' | tr -d '"')"

  if [ "$changed" = "1" ]; then
    user_manager_apply_changes "$result" "$json" >/dev/null 2>&1 || return 1
  fi
  return 0
}

user_watch_run() {
  # cron 场景下用 flock 排他锁，避免与交互式操作并发修改文件
  local lock_fd
  exec {lock_fd}>/var/lock/singbox-manager.lock || return 0
  flock -n "$lock_fd" || return 0
  init_user_manager_if_needed >/dev/null 2>&1 || { exec {lock_fd}>&-; return 0; }
  apply_automatic_user_controls >/dev/null 2>&1 || true
  exec {lock_fd}>&-
}

init_user_manager_if_needed() {
  init_manager_env
  if [ ! -e "$USER_DB_FILE" ] && [ -e "/etc/sing-box/user-manager.json" ]; then
    mkdir -p "$(dirname "$USER_DB_FILE")"
    mv -f /etc/sing-box/user-manager.json "$USER_DB_FILE" 2>/dev/null || cp -f /etc/sing-box/user-manager.json "$USER_DB_FILE"
  fi
  if ! user_db_exists; then
    user_db_save "$(user_db_min_template)"
    ok "已初始化用户数据库，默认启用 admin 用户。"
  fi
  user_db_cleanup_current_and_save || true
  user_manager_runtime_sync || true
  return 0
}
