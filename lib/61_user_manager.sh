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

  say "更新用户数据库..."
  user_db_save "$db_json"
  ok "用户数据库已保存。"

  say "重新生成用户节点关系..."
  db_json="$(user_db_load)"
  db_json="$(user_db_cleanup_missing_nodes "$db_json" "$base_json")" || return 1
  user_db_save "$db_json"
  local applied_json
  applied_json="$(user_manager_apply_to_json "$base_json" "$db_json")" || {
    err "生成用户节点关系失败。"
    return 1
  }
  ok "用户节点关系已更新。"

  say "重建路由规则..."
  ok "路由规则已重建。"

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
    say "初始化用户数据库..."
    user_db_save "$db_json"
    ok "用户数据库已初始化。"
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
    say "检测到用户流量统计配置需要更新..."
    if config_apply "$desired_json"; then
      ok "用户流量统计配置已更新。"
    else
      err "用户流量统计配置更新失败。"
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

  local db_json json changed=0 today period today_day
  db_json="$(user_db_load)"
  json="$(config_load)"
  today="$(user_today_date)"
  period="$(user_current_period)"
  today_day=$((10#$(date +%d)))

  local username expire_at reset_day last_reset enabled quota billable hit_reset last_day effective_reset_day
  while IFS= read -r username; do
    [ -n "$username" ] || continue

    expire_at="$(echo "$db_json" | jq -r --arg u "$username" '.users[$u].expire_at // "0"')"
    reset_day="$(echo "$db_json" | jq -r --arg u "$username" '.users[$u].reset_day // 0')"
    last_reset="$(echo "$db_json" | jq -r --arg u "$username" '.users[$u].last_reset_period // ""')"
    enabled="$(echo "$db_json" | jq -r --arg u "$username" '.users[$u].enabled // false')"

    if [ "$expire_at" != "0" ] && [[ "$today" > "$expire_at" || "$today" == "$expire_at" ]]; then
      if [ "$enabled" = "true" ]; then
        db_json="$(echo "$db_json" | jq --arg u "$username" '.users[$u].enabled = false')"
        changed=1
      fi
      continue
    fi

    hit_reset=0
    if [[ "$reset_day" =~ ^[0-9]+$ ]]; then
      last_day=$((10#$(date -d "$(date +%Y-%m-01) +1 month -1 day" +%d)))
      if [ "$reset_day" -eq 32 ]; then
        effective_reset_day="$last_day"
      elif [ "$reset_day" -ge 1 ] && [ "$reset_day" -le 29 ]; then
        if [ "$reset_day" -gt "$last_day" ]; then
          effective_reset_day="$last_day"
        else
          effective_reset_day="$reset_day"
        fi
      else
        effective_reset_day=0
      fi
      [ "$effective_reset_day" -gt 0 ] && [ "$today_day" -eq "$effective_reset_day" ] && hit_reset=1
    fi
    if [ "$hit_reset" -eq 1 ] && [ "$last_reset" != "$period" ]; then
      db_json="$(echo "$db_json" | jq --arg u "$username" --arg p "$period" '
        .users[$u].used_up_bytes = 0
        | .users[$u].used_down_bytes = 0
        | .users[$u].last_live_up_bytes = 0
        | .users[$u].last_live_down_bytes = 0
        | .users[$u].last_reset_period = $p
        | .users[$u].enabled = true
      ')"
      changed=1
    fi

    quota="$(echo "$db_json" | jq -r --arg u "$username" '.users[$u].quota_gb // 0')"
    if [[ "$quota" =~ ^[0-9]+$ ]] && [ "$quota" -gt 0 ]; then
      billable="$(user_billable_bytes "$db_json" "$username")"
      if [ "$billable" -ge $((quota * 1073741824)) ]; then
        enabled="$(echo "$db_json" | jq -r --arg u "$username" '.users[$u].enabled // false')"
        if [ "$enabled" = "true" ]; then
          db_json="$(echo "$db_json" | jq --arg u "$username" '.users[$u].enabled = false')"
          changed=1
        fi
      fi
    fi
  done < <(user_db_all_users "$db_json")

  if [ "$changed" -eq 1 ]; then
    user_manager_apply_changes "$db_json" "$json" >/dev/null 2>&1 || return 1
  fi
  return 0
}

user_watch_run() {
  init_user_manager_if_needed >/dev/null 2>&1 || return 0
  apply_automatic_user_controls >/dev/null 2>&1 || true
}

init_user_manager_if_needed() {
  init_manager_env
  if [ ! -e "$USER_DB_FILE" ] && [ -e "/etc/sing-box/user-manager.json" ]; then
    mkdir -p "$(dirname "$USER_DB_FILE")"
    mv -f /etc/sing-box/user-manager.json "$USER_DB_FILE" 2>/dev/null || cp -f /etc/sing-box/user-manager.json "$USER_DB_FILE"
  fi
  if ! user_db_exists; then
    say "首次进入用户管理，已默认启用 admin 用户。"
    user_db_save "$(user_db_min_template)"
    ok "默认用户 admin 已启用。"
  fi
  user_db_cleanup_current_and_save || true
  user_manager_runtime_sync || true
  return 0
}
