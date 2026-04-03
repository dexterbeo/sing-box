#!/usr/bin/env bash
# ============================================================
# 模块: 62_user_menu.sh
# 职责: 用户管理交互菜单（纯 UI 层）
# 依赖: 00_base.sh, 01_utils.sh, 60_user_db.sh, 61_user_manager.sh
# ============================================================

user_package_invalid_return() {
  ui_echo "${Y}[WARN]${NC} 输入无效，未作修改，已返回上一级。"
}

show_user_status_table() {
  local db_json="$1"
  local sep=$'\t'
  local header widths_line row_line
  local -a rows=()
  local -a cols=()

  header="用户名${sep}状态${sep}上传流量${sep}下载流量${sep}已用总量${sep}套餐${sep}重置日${sep}到期时间"
  rows+=("$header")

  while IFS= read -r row_line; do
    [ -n "$row_line" ] && rows+=("$row_line")
  done < <(
    echo "$db_json" | jq -r '
      .users
      | to_entries
      | .[]
      | [
          .key,
          (if (.value.enabled == true) then "开启" else "关闭" end),
          ((.value.used_up_bytes // 0) | tostring),
          ((.value.used_down_bytes // 0) | tostring),
          (((.value.used_up_bytes // 0) + (.value.used_down_bytes // 0) + (.value.manual_added_bytes // 0)) | tostring),
          ((if (.value.quota_gb // 0) == 0 then "不限" else ((.value.quota_gb|tostring) + "GB") end)),
          (if (.value.reset_day // 0) == 0 then "不重置" elif (.value.reset_day // 0) == 32 then "月底" else ((.value.reset_day|tostring) + "号") end),
          (if (.value.expire_at // "0") == "0" then "永久" else (.value.expire_at // "0") end)
        ] | @tsv
    ' | while IFS=$'\t' read -r c1 c2 c3 c4 c5 c6 c7 c8; do
          printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$c1" \
            "$c2" \
            "$(format_bytes_human "$c3")" \
            "$(format_bytes_human "$c4")" \
            "$(format_bytes_human "$c5")" \
            "$c6" \
            "$c7" \
            "$c8"
      done
  )

  widths_line="$(table_compute_widths "$sep" "${rows[@]}")"

  IFS="$sep" read -r -a cols <<< "$header"
  local header_line divider_line divider_width
  header_line="$(table_print_row "$widths_line" "${cols[@]}")"
  divider_width="$(text_display_width "$header_line")"
  divider_line="$(printf '%*s' "$divider_width" '' | tr ' ' '-')"

  ui_echo "\033[1m${header_line}${NC}"
  ui_echo "${B}${divider_line}${NC}"

  for row_line in "${rows[@]:1}"; do
    IFS="$sep" read -r -a cols <<< "$row_line"
    table_print_row "$widths_line" "${cols[@]}"
  done

  ui_echo "${B}${divider_line}${NC}"
}

show_user_status_table_from_file() {
  local db_json
  sync_user_usage_counters || true
  db_json="$(user_db_load)"
  show_user_status_table "$db_json"
}

prompt_reset_day() {
  local outvar="$1" val
  while true; do
    ui_echo "0  不重置"
    ui_echo "1-29 指定日期"
    ui_echo "32 月底"
    read -r -p "请输入重置日: " val
    case "$val" in
      0|32) printf -v "$outvar" '%s' "$val"; return 0 ;;
      '') ui_echo "${Y}[WARN]${NC} 请输入 0、1-29 或 32。" ;;
      *)
        if [[ "$val" =~ ^[0-9]+$ ]] && [ "$val" -ge 1 ] && [ "$val" -le 29 ]; then
          printf -v "$outvar" '%s' "$val"
          return 0
        fi
        ui_echo "${Y}[WARN]${NC} 请输入 0、1-29 或 32。"
        ;;
    esac
  done
}

prompt_expire_date() {
  local outvar="$1" val
  read -r -p "请输入到期日期（格式：YYYY-MM-DD，输入 0 表示永久）: " val
  if [ "$val" = "0" ]; then
    printf -v "$outvar" '%s' '0'
    return 0
  fi
  if [[ "$val" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    printf -v "$outvar" '%s' "$val"
    return 0
  fi
  ui_echo "${Y}[WARN]${NC} 输入无效，未作修改，已返回上一级。"
  return 1
}

select_nodes_multi() {
  local json="$1" outvar="$2"
  local nodes=()
  # 节点按协议顺序排序
  mapfile -t nodes < <(list_all_node_keys "$json")
  if [ ${#nodes[@]} -eq 0 ]; then
    printf -v "$outvar" '%s' '[]'
    return 0
  fi
  ui_echo "请选择可用节点（多个用 + 连接，0 清除全部，回车跳过）："
  local i=1 node
  for node in "${nodes[@]}"; do
    ui_echo " [$i] $node"
    i=$((i+1))
  done
  local ans part selected=()
  read -r -p "请输入编号: " ans
  [ -z "${ans:-}" ] && { printf -v "$outvar" '%s' '__SKIP__'; return 0; }
  mapfile -t picks < <(parse_plus_selections "$ans")
  if [ ${#picks[@]} -eq 1 ] && [ "${picks[0]}" = "0" ]; then
    printf -v "$outvar" '%s' '[]'
    return 0
  fi
  for part in "${picks[@]}"; do
    if [[ "$part" =~ ^[0-9]+$ ]] && [ "$part" -ge 1 ] && [ "$part" -le "${#nodes[@]}" ]; then
      selected+=("${nodes[$((part-1))]}")
    fi
  done
  if [ ${#selected[@]} -gt 0 ]; then
    local picks_json
    picks_json="$(printf '%s\n' "${selected[@]}" | awk 'NF' | sort -u | jq -R . | jq -s '.')"
    printf -v "$outvar" '%s' "$picks_json"
  else
    printf -v "$outvar" '%s' '[]'
  fi
}

user_show_info() {
  local db_json="$1" username="$2"
  local used_up used_down manual_added total_used quota_bytes used_up_text used_down_text manual_text total_text quota_text
  sync_user_usage_counters || true
  db_json="$(user_db_load)"
  used_up="$(echo "$db_json" | jq -r --arg u "$username" '.users[$u].used_up_bytes // 0')"
  used_down="$(echo "$db_json" | jq -r --arg u "$username" '.users[$u].used_down_bytes // 0')"
  manual_added="$(echo "$db_json" | jq -r --arg u "$username" '.users[$u].manual_added_bytes // 0')"
  total_used="$(user_billable_bytes "$db_json" "$username")"
  quota_bytes="$(echo "$db_json" | jq -r --arg u "$username" '(.users[$u].quota_gb // 0) * 1073741824')"
  used_up_text="$(format_traffic_auto "$used_up")"
  used_down_text="$(format_traffic_auto "$used_down")"
  manual_text="$(format_traffic_auto "$manual_added")"
  total_text="$(format_traffic_auto "$total_used")"
  if [ "$quota_bytes" -eq 0 ]; then
    quota_text="不限"
  else
    quota_text="$(format_traffic_auto "$quota_bytes")"
  fi
  echo "$db_json" | jq -r     --arg u "$username"     --arg up "$used_up_text"     --arg down "$used_down_text"     --arg manual "$manual_text"     --arg total "$total_text"     --arg quota "$quota_text" '
    .users[$u] as $x
    | "用户名：" + $u + "\n"
      + "状态：" + (if $x.enabled then "开启" else "关闭" end) + "\n"
      + "上传流量：" + $up + "\n"
      + "下载流量：" + $down + "\n"
      + "手动补正流量：" + $manual + "\n"
      + "已用总量：" + $total + "\n"
      + "套餐总量：" + $quota + "\n"
      + "重置日：" + (if (($x.reset_day // 0) == 0) then "不重置" elif (($x.reset_day // 0) == 32) then "月底" else (($x.reset_day|tostring)+"号") end) + "\n"
      + "到期时间：" + (if (($x.expire_at // "0") == "0") then "永久" else $x.expire_at end) + "\n"
      + "节点策略：" + (if ($x.allow_all_nodes // false) then "全部节点" else "自定义节点" end)
  '
  echo "允许节点："
  if echo "$db_json" | jq -e --arg u "$username" '.users[$u].allow_all_nodes == true' >/dev/null 2>&1; then
    echo "  - 全部节点"
  else
    echo "$db_json" | jq -r --arg u "$username" '.users[$u].nodes[]? // empty' | sed 's/^/  - /'
  fi
}

user_add_menu() {
  local db_json json username quota reset_day expire_at ans nodes_json allow_all_json
  db_json="$(user_db_load)"
  json="$(config_load)"
  clear
  print_rect_title "新增用户"
  show_user_status_table "$db_json"
  read -r -p "请输入用户名: " username
  if ! is_valid_user_name "$username"; then
    warn "用户名仅允许字母、数字、点、下划线、短横线。"
    pause
    return 1
  fi
  [ "$username" = "admin" ] && { warn "admin 为系统默认用户，不能新增。"; pause; return 1; }
  if user_db_user_exists "$db_json" "$username"; then
    warn "用户已存在：$username"
    pause
    return 1
  fi
  ui_echo "${Y}折算成单向流量填入。示例：双向800G流量就填写400，单向500G流量就填写500${NC}"
  read -r -p "请输入流量限制（GB，输入 0 表示不限）: " quota
  [[ "$quota" =~ ^[0-9]+$ ]] || { warn "[WARN] 输入无效，未作修改，已返回上一级。"; pause; return 0; }
  prompt_reset_day reset_day
  if ! prompt_expire_date expire_at; then pause; return 0; fi

  # 节点权限设置（按协议顺序展示）
  allow_all_json='false'
  nodes_json='[]'
  ui_echo "${C}--- 节点权限 ---${NC}"
  select_nodes_multi "$json" nodes_json
  if [ "$nodes_json" = "__SKIP__" ]; then
    nodes_json='[]'
    ui_echo "已跳过节点权限设置，默认不分配节点。"
  fi

  db_json="$(echo "$db_json" | jq --arg u "$username" --argjson quota "$quota" --argjson reset "$reset_day" --arg expire "$expire_at" --argjson allow "$allow_all_json" --argjson nodes "$nodes_json" '
    .users[$u] = {
      enabled: true,
      quota_gb: $quota,
      used_up_bytes: 0,
      used_down_bytes: 0,
      manual_added_bytes: 0,
      last_live_up_bytes: 0,
      last_live_down_bytes: 0,
      last_reset_period: "",
      reset_day: $reset,
      expire_at: $expire,
      allow_all_nodes: $allow,
      nodes: $nodes
    }
  ')"
  user_manager_apply_changes "$db_json" "$json" || { pause; return 1; }
  pause
}

user_manage_permission_menu() {
  local db_json="$1" username="$2" json="$3"
  local cleaned_db_json
  cleaned_db_json="$(user_db_cleanup_missing_nodes "$db_json" "$json")" || cleaned_db_json="$db_json"
  if [ "$(echo "$cleaned_db_json" | jq -c . 2>/dev/null)" != "$(echo "$db_json" | jq -c . 2>/dev/null)" ]; then
    user_db_save "$cleaned_db_json"
  fi
  db_json="$cleaned_db_json"
  local current_nodes_json current_allow_all
  local nodes=() node i raw picks=() invalid=0 sel idx selected_json new_db

  clear >&2
  print_rect_title "节点权限" >&2
  show_user_status_table "$db_json" >&2
  current_allow_all="$(echo "$db_json" | jq -r --arg u "$username" '.users[$u].allow_all_nodes // false')"
  current_nodes_json="$(echo "$db_json" | jq -c --arg u "$username" '(.users[$u].nodes // [])')"

  if [ "$current_allow_all" = "true" ]; then
    ui_echo "当前权限类型：全部节点"
  else
    ui_echo "当前权限类型：自定义节点"
  fi
  ui_echo "当前已分配节点："
  if [ "$current_allow_all" = "true" ]; then
    ui_echo "- 全部节点"
  else
    while IFS= read -r node; do
      [ -n "$node" ] && ui_echo "- $node"
    done < <(echo "$current_nodes_json" | jq -r '.[]?')
    if ! echo "$current_nodes_json" | jq -e 'length > 0' >/dev/null 2>&1; then
      ui_echo "- （无）"
    fi
  fi
  ui_echo "${B}--------------------------------------------------------${NC}"

  # 节点列表按协议顺序排序（统一使用 sort_node_keys_by_protocol）
  mapfile -t nodes < <(list_all_node_keys "$json")
  ui_echo "可选节点："
  ui_echo "  0. 清除全部节点权限"
  ui_echo "  1. 全部节点"
  i=2
  for node in "${nodes[@]}"; do
    ui_echo "  ${i}. ${node}"
    i=$((i+1))
  done
  read -r -p "请输入编号（多个用 + 连接，回车返回）: " raw
  [ -z "${raw:-}" ] && return 1
  mapfile -t picks < <(parse_plus_selections "$raw")
  [ ${#picks[@]} -eq 0 ] && return 1

  # 选择 0 = 清除全部
  if [ ${#picks[@]} -eq 1 ] && [ "${picks[0]}" = "0" ]; then
    new_db="$(echo "$db_json" | jq --arg u "$username" '.users[$u].allow_all_nodes = false | .users[$u].nodes = []')"
    echo "$new_db"
    return 0
  fi

  for sel in "${picks[@]}"; do
    if ! [[ "$sel" =~ ^[0-9]+$ ]]; then invalid=1; break; fi
    if [ "$sel" -lt 1 ] || [ "$sel" -gt $(( ${#nodes[@]} + 1 )) ]; then invalid=1; break; fi
  done

  if [ $invalid -eq 1 ]; then
    ui_echo "${Y}[WARN]${NC} 输入编号无效，未做任何修改。"
    pause >&2
    return 1
  fi

  if printf '%s\n' "${picks[@]}" | grep -qx '1'; then
    new_db="$(echo "$db_json" | jq --arg u "$username" '.users[$u].allow_all_nodes = true | .users[$u].nodes = []')"
    echo "$new_db"
    return 0
  fi

  selected_json="$({
    for sel in "${picks[@]}"; do
      idx=$((sel-2))
      if [ $idx -ge 0 ] && [ $idx -lt ${#nodes[@]} ]; then
        echo "${nodes[$idx]}"
      fi
    done
  } | awk 'NF' | LC_ALL=C sort -u | jq -R . | jq -s '.')"

  new_db="$(echo "$db_json" | jq --arg u "$username" --argjson nodes "$selected_json" '.users[$u].allow_all_nodes = false | .users[$u].nodes = $nodes')"
  echo "$new_db"
}

user_manage_package_menu() {
  local db_json="$1" username="$2"
  local current_quota current_reset current_expire quota_in reset_in expire_in quota_val reset_val expire_val
  clear >&2
  print_rect_title "套餐设置" >&2
  show_user_status_table "$db_json" >&2

  current_quota="$(echo "$db_json" | jq -r --arg u "$username" '.users[$u].quota_gb // 0')"
  current_reset="$(echo "$db_json" | jq -r --arg u "$username" '.users[$u].reset_day // 0')"
  current_expire="$(echo "$db_json" | jq -r --arg u "$username" '.users[$u].expire_at // "0"')"

  ui_echo "当前流量限制：${current_quota} GB"
  ui_echo "${Y}折算成单向流量填入。示例：双向800G流量就填写400，单向500G流量就填写500${NC}"
  ui_echo "单位为 GB ，输入 0 表示不限"
  ui_echo "回车：保持当前值"
  read -r -p "请输入: " quota_in
  if [ -z "$quota_in" ]; then
    quota_val="$current_quota"
  elif [[ "$quota_in" =~ ^[0-9]+$ ]]; then
    quota_val="$quota_in"
  else
    user_package_invalid_return; pause >&2; return 1
  fi

  ui_echo "当前重置日期：$(reset_day_text "$current_reset")"
  ui_echo "0. 不重置"
  ui_echo "1-29. 指定日期"
  ui_echo "32. 月底"
  ui_echo "回车：保持当前值"
  read -r -p "请输入: " reset_in
  if [ -z "$reset_in" ]; then
    reset_val="$current_reset"
  elif [ "$reset_in" = "0" ] || [ "$reset_in" = "32" ]; then
    reset_val="$reset_in"
  elif [[ "$reset_in" =~ ^[0-9]+$ ]] && [ "$reset_in" -ge 1 ] && [ "$reset_in" -le 29 ]; then
    reset_val="$reset_in"
  else
    user_package_invalid_return; pause >&2; return 1
  fi

  ui_echo "当前到期时间：$(expire_text "$current_expire")"
  ui_echo "请输入到期日期（格式：YYYY-MM-DD，输入 0 表示永久）:"
  ui_echo "回车：保持当前值"
  read -r -p "请输入: " expire_in
  if [ -z "$expire_in" ]; then
    expire_val="$current_expire"
  elif [ "$expire_in" = "0" ]; then
    expire_val="0"
  elif [[ "$expire_in" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    expire_val="$expire_in"
  else
    user_package_invalid_return; pause >&2; return 1
  fi

  if [ "$quota_val" = "$current_quota" ] && [ "$reset_val" = "$current_reset" ] && [ "$expire_val" = "$current_expire" ]; then
    ui_echo "[INFO] 未检测到改动，按任意键返回。"
    pause >&2
    return 1
  fi

  echo "$db_json" | jq --arg u "$username" --argjson quota "$quota_val" --argjson reset "$reset_val" --arg exp "$expire_val" '
    (.users[$u].reset_day // 0) as $old_reset
    | .users[$u].quota_gb = $quota
    | .users[$u].reset_day = $reset
    | .users[$u].expire_at = $exp
    | if ($old_reset != $reset) then .users[$u].last_reset_period = "" else . end
  '
}

user_add_usage_menu() {
  local db_json="$1" username="$2" raw bytes
  clear >&2
  print_rect_title "手动添加流量" >&2
  show_user_status_table "$db_json" >&2
  ui_echo "此操作会增加该用户的手动补正流量，用于对齐总量。"
  read -r -p "请输入要增添的流量（精确到小数点后一位，需带单位 MB、GB）: " raw
  bytes="$(parse_traffic_to_bytes "$raw")" || {
    warn "[WARN] 输入无效，未作修改，已返回上一级。" >&2
    pause >&2
    return 1
  }
  echo "$db_json" | jq --arg u "$username" --argjson add "$bytes" '
    .users[$u].manual_added_bytes = ((.users[$u].manual_added_bytes // 0) + $add)
  '
}

user_reset_usage_menu() {
  local db_json="$1" username="$2"
  clear >&2
  print_rect_title "手动重置流量" >&2
  show_user_status_table "$db_json" >&2
  ui_echo "将清零该用户的上传流量、下载流量、手动补正流量以及统计基线。"
  ui_echo "此操作不会修改用户的启用状态、套餐设置、到期时间或重置日。"
  local ans
  read -r -p "输入 YES 确认重置该用户流量，其它任意输入取消: " ans
  if [ "$ans" != "YES" ]; then
    return 1
  fi
  echo "$db_json" | jq --arg u "$username" '
    .users[$u].used_up_bytes = 0
    | .users[$u].used_down_bytes = 0
    | .users[$u].last_live_up_bytes = 0
    | .users[$u].last_live_down_bytes = 0
  '
}

user_manage_single() {
  local username="$1"
  local db_json json act new_db
  while true; do
    user_db_cleanup_current_and_save || true
    db_json="$(user_db_load)"
    json="$(config_load)"
    clear
    print_rect_title "管理用户"
    show_user_status_table "$db_json"
    echo "当前用户：$username"
    if [ "$username" = "admin" ]; then
      echo "admin 为系统默认用户，不可删除，默认拥有全部节点权限。"
      echo "  1. 启用/停用"
      echo "  2. 套餐设置"
      echo "  3. 手动重置流量"
      echo "  4. 手动添加流量（对齐总量）"
      echo "  5. 查看用户信息"
      echo "  0. 返回"
      read -r -p "请选择操作: " act
      case "${act:-}" in
        1)
          if user_db_user_is_enabled "$db_json" "$username"; then
            new_db="$(echo "$db_json" | jq --arg u "$username" '.users[$u].enabled = false')"
          else
            new_db="$(echo "$db_json" | jq --arg u "$username" '.users[$u].enabled = true')"
          fi
          user_manager_apply_changes "$new_db" "$json" || true
          ;;
        2)
          new_db="$(user_manage_package_menu "$db_json" "$username")" || new_db=""
          if json_is_object "$new_db"; then
            user_manager_apply_changes "$new_db" "$json" || true
          fi
          ;;
        3)
          new_db="$(user_reset_usage_menu "$db_json" "$username")" || new_db=""
          if json_is_object "$new_db"; then
            user_manager_apply_changes "$new_db" "$json" || true
          fi
          ;;
        4)
          new_db="$(user_add_usage_menu "$db_json" "$username")" || new_db=""
          if json_is_object "$new_db"; then
            user_manager_apply_changes "$new_db" "$json" || true
          fi
          ;;
        5) clear; print_rect_title "用户信息"; user_show_info "$db_json" "$username"; echo ""; pause ;;
        0|q|Q|"") return 0 ;;
        *) warn "无效输入：$act"; sleep 1 ;;
      esac
      continue
    fi
    echo "  1. 启用/停用"
    echo "  2. 节点权限"
    echo "  3. 套餐设置"
    echo "  4. 手动重置流量"
    echo "  5. 手动添加流量（对齐总量）"
    echo "  6. 用户信息"
    echo "  0. 返回"
    read -r -p "请选择操作: " act
    case "${act:-}" in
      1)
        if user_db_user_is_enabled "$db_json" "$username"; then
          new_db="$(echo "$db_json" | jq --arg u "$username" '.users[$u].enabled = false')"
        else
          new_db="$(echo "$db_json" | jq --arg u "$username" '.users[$u].enabled = true')"
        fi
        user_manager_apply_changes "$new_db" "$json" || true
        ;;
      2)
        new_db="$(user_manage_permission_menu "$db_json" "$username" "$json")" || new_db=""
        if json_is_object "$new_db"; then
          user_manager_apply_changes "$new_db" "$json" || true
        fi
        ;;
      3)
        new_db="$(user_manage_package_menu "$db_json" "$username")" || new_db=""
        if json_is_object "$new_db"; then
          user_manager_apply_changes "$new_db" "$json" || true
        fi
        ;;
      4)
        new_db="$(user_reset_usage_menu "$db_json" "$username")" || new_db=""
        if json_is_object "$new_db"; then
          user_manager_apply_changes "$new_db" "$json" || true
        fi
        ;;
      5)
        new_db="$(user_add_usage_menu "$db_json" "$username")" || new_db=""
        if json_is_object "$new_db"; then
          user_manager_apply_changes "$new_db" "$json" || true
        fi
        ;;
      6)
        clear
        print_rect_title "用户信息"
        user_show_info "$db_json" "$username"
        echo ""
        pause
        ;;
      0|q|Q|"") return 0 ;;
      *) warn "无效输入：$act"; sleep 1 ;;
    esac
  done
}

user_select_and_manage_menu() {
  local db_json usernames=() ans idx username
  user_db_cleanup_current_and_save >/dev/null 2>&1 || true
  db_json="$(user_db_load)"
  clear
  print_rect_title "管理用户"
  show_user_status_table "$db_json"
  mapfile -t usernames < <(user_db_all_users "$db_json")
  local i=1
  for username in "${usernames[@]}"; do
    echo " [$i] $username"
    i=$((i+1))
  done
  read -r -p "请选择用户（回车返回）: " ans
  [ -z "${ans:-}" ] && return 0
  if ! [[ "$ans" =~ ^[0-9]+$ ]] || [ "$ans" -lt 1 ] || [ "$ans" -gt "${#usernames[@]}" ]; then
    warn "无效输入：$ans"
    pause
    return 1
  fi
  idx=$((ans-1))
  user_manage_single "${usernames[$idx]}"
}

user_delete_menu() {
  local db_json json usernames=() ans idx username new_db
  sync_user_usage_counters || true
  db_json="$(user_db_load)"
  json="$(config_load)"
  clear
  print_rect_title "删除用户"
  show_user_status_table "$db_json"
  mapfile -t usernames < <(echo "$db_json" | jq -r '.users | keys[] | select(. != "admin")')
  if [ ${#usernames[@]} -eq 0 ]; then
    warn "当前没有可删除的普通用户。"
    pause
    return 0
  fi
  local i=1
  for username in "${usernames[@]}"; do
    echo " [$i] $username"
    i=$((i+1))
  done
  read -r -p "请选择要删除的用户（回车返回）: " ans
  [ -z "${ans:-}" ] && return 0
  if ! [[ "$ans" =~ ^[0-9]+$ ]] || [ "$ans" -lt 1 ] || [ "$ans" -gt "${#usernames[@]}" ]; then
    warn "无效输入：$ans"
    pause
    return 1
  fi
  idx=$((ans-1))
  username="${usernames[$idx]}"
  ask_confirm_yes "输入 YES 确认彻底删除用户 ${username}，其它任意输入取消: " || { warn "已取消删除。"; pause; return 0; }
  new_db="$(echo "$db_json" | jq --arg u "$username" 'del(.users[$u])')" || return 1
  user_manager_apply_changes "$new_db" "$json" || true
  pause
}

user_manager_menu() {
  init_user_manager_if_needed || return 0
  sync_user_usage_counters >/dev/null 2>&1 || true
  user_db_cleanup_current_and_save >/dev/null 2>&1 || true
  while true; do
    local db_json
    db_json="$(user_db_load)"
    clear
    print_rect_title "用户管理"
    db_json="$(user_db_load)"
    show_user_status_table "$db_json"
    echo -e "  ${C}1.${NC} 新增用户"
    echo -e "  ${C}2.${NC} 管理用户"
    echo -e "  ${C}3.${NC} 删除用户"
    echo -e "  ${R}0.${NC} 返回主菜单"
    read -r -p "请选择操作: " act
    case "${act:-}" in
      1) user_add_menu || true ;;
      2) user_select_and_manage_menu || true ;;
      3) user_delete_menu || true ;;
      0|q|Q|"") return 0 ;;
      *) warn "无效输入：$act"; sleep 1 ;;
    esac
  done
}
