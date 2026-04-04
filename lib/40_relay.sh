#!/usr/bin/env bash
# ============================================================
# 模块: 40_relay.sh
# 职责: 中转节点列表、添加、删除、菜单
# 依赖: 00_base.sh, 10_config.sh, 20_protocol.sh, 30_route.sh
# ============================================================

# ---------- 中转节点列表（纯数据查询） ----------

relay_list_table() {
  local json="$1"
  echo "$json" | jq -r "${JQ_SHARED}"'
    . as $root
    | [
        .inbounds[]?
        | select((detect_protocol) != "")
        | .tag as $entry
        | (.users // [])[]?
        | (.name // empty) as $name
        | (node_part($name)) as $node
        | select($name != "" and $node != $entry and ($node | contains("-to-")))
        | [
            $root.route.rules[]?
            | select((auth_users_array | index($name)) != null)
            | .outbound // empty
            | select(. != "" and . != "direct")
          ] as $outs
        | [
            (["out-" + $node] + (if ($node | contains("-to-")) then ["out-to-" + (($node | capture(".*-to-(?<land>.+)$").land)), "to-" + (($node | capture(".*-to-(?<land>.+)$").land))] else [] end))[] as $cand
            | $root.outbounds[]?
            | .tag // empty
            | select(. == $cand)
          ] as $fallback_outs
        | [$entry, $name, (if ($outs | length) > 0 then $outs[0] elif ($fallback_outs | length) > 0 then $fallback_outs[0] else "" end)]
      ]
    | unique
    | .[]
    | @tsv
  ' || return 1
}

# ---------- UI: 显示中转节点行 ----------

show_managed_relay_lines() {
  local json="$1"
  local found=0
  local seen=""
  local relay_node
  while IFS=$'\t' read -r entry relay_user out_tag; do
    [ -z "${relay_user:-}" ] && continue
    relay_node="$(user_node_part "$relay_user")"
    [ -n "$relay_node" ] || continue
    if printf '%s\n' "$seen" | grep -Fxq "$relay_node"; then
      continue
    fi
    seen="${seen}${relay_node}"$'\n'
    found=1
    echo -e "  - ${G}${relay_node}${NC}"
  done < <(relay_list_table "$json")
  [ $found -eq 1 ]
}

# ---------- 中转节点菜单 ----------

relay_add() {
  init_manager_env
  local json lines=() entry_key choice land ip relay_port pw normalized_pw relay_user out_tag inbound
  json="$(config_load)"

  mapfile -t lines < <(protocol_entry_inventory "$json" | sort_tsv_by_protocol 1 | head -100)
  if [ ${#lines[@]} -eq 0 ]; then
    err "当前没有任何主入站，请先在核心模块管理里安装协议。"
    pause
    return 1
  fi

  clear
  echo -e "${C}--- 添加/覆盖中转节点 ---${NC}"
  echo -e "${C}请选择主入站：${NC}"
  local i=1 tag port
  for line in "${lines[@]}"; do
    IFS=$'\t' read -r tag proto port <<< "$line"
    echo -e "  [$i] ${G}${tag}${NC}"
    i=$((i+1))
  done
  echo ""
  echo -e "${C}当前已配置中转节点：${NC}"
  if ! show_managed_relay_lines "$json"; then
    echo -e "  ${Y}当前没有中转节点。${NC}"
  fi
  read -r -p "请选择编号（回车返回上一级）: " choice
  if [ -z "${choice:-}" ]; then
    return 0
  fi
  if ! [[ "${choice:-}" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#lines[@]}" ]; then
    warn "无效选择，已返回上一级。"
    pause
    return 0
  fi
  IFS=$'\t' read -r entry_key _ _ <<< "${lines[$((choice-1))]}"
  inbound="$(find_inbound_by_entry_key "$json" "$entry_key")"

  read -r -p "落地标识 (如 sg01): " land
  [ -z "${land:-}" ] && { warn "已取消，返回上一级。"; pause; return 0; }
  read -r -p "落地 IP 地址: " ip
  [ -z "${ip:-}" ] && { warn "已取消，返回上一级。"; pause; return 0; }
  read -r -p "落地端口（默认: 8080）: " relay_port
  relay_port="${relay_port:-8080}"
  if ! [[ "$relay_port" =~ ^[0-9]+$ ]] || [ "$relay_port" -lt 1 ] || [ "$relay_port" -gt 65535 ]; then
    warn "落地端口无效，已返回上一级。"
    pause
    return 0
  fi
  read -r -p "落地 SS 2022 密钥（回车随机生成）: " pw
  normalized_pw="$(ss2022_normalize_password_pair "$pw")"

  relay_user="$(relay_user_name "$entry_key" "$land")"
  out_tag="$(relay_outbound_tag "$entry_key" "$land")"

  local new_user new_out updated_json
  new_user="$(build_user_object_from_inbound "$inbound" "$relay_user")" || {
    err "不支持的主入站类型，无法生成中转用户。"
    pause
    return 1
  }

  new_out="$(jq -n --arg tag "$out_tag" --arg ip "$ip" --arg pw "$normalized_pw" --argjson p "$relay_port" '{type:"shadowsocks",tag:$tag,server:$ip,server_port:$p,method:"2022-blake3-aes-128-gcm",password:$pw}')"

  updated_json="$(echo "$json" | jq "${JQ_AUTH_USERS}"'
    .inbounds |= map(
      if .tag == $ek then
        .users = (((.users // []) | map(select((.name // "") != $ru))) + [$nu])
      else
        if .users? then .users |= map(select((.name // "") != $ru)) else . end
      end
    )
    | .outbounds = (
        ((.outbounds // []) | map(
          if (.tag // "") == $ot then $no else . end
        ))
        | if any(.[]?; (.tag // "") == $ot) then . else . + [$no] end
      )
    | .route.rules = (
        ((.route.rules // [])
          | map(select(((auth_users_array | index($ru)) == null) and ((.outbound // "") != $ot)))
        )
        + [{auth_user:[$ru], outbound:$ot}]
      )
  ' --arg ek "$entry_key" --arg ru "$relay_user" --arg ot "$out_tag" --argjson nu "$new_user" --argjson no "$new_out")"
  updated_json="$(route_rebuild "$updated_json")" || {
    err "重建路由失败，已中止，未写入配置。"
    pause
    return 1
  }
  if user_db_exists; then
    local db_json
    db_json="$(user_db_load)"
    db_json="$(user_db_on_node_added "$db_json" "$relay_user")"
    if user_manager_apply_changes "$db_json" "$updated_json"; then
      ok "中转节点已添加/覆盖：$relay_user"
    else
      warn "中转节点添加失败，已返回上一级。"
    fi
  else
    if config_apply "$updated_json"; then
      ok "中转节点已添加/覆盖：$relay_user"
    else
      warn "中转节点添加失败，已返回上一级。"
    fi
  fi
  pause
  return 0
}

relay_delete() {
  init_manager_env
  local json lines=() node_lines=() choice picks=() updated_json line entry relay_user out_tag part idx
  local node_key users_json
  json="$(config_load)"
  mapfile -t lines < <(relay_list_table "$json")
  if [ ${#lines[@]} -eq 0 ]; then
    warn "当前没有中转节点。"
    pause
    return 0
  fi

  mapfile -t node_lines < <(
    printf '%s\n' "${lines[@]}" | awk -F '\t' '
      function node_part(s) { sub(/@.*/, "", s); return s }
      {
        node=node_part($2)
        if (!(node in seen)) {
          seen[node]=1
          print $1 "\t" node "\t" $3
        }
      }' | sort_tsv_by_protocol 2
  )

  clear
  echo -e "${R}--- 删除中转节点 ---${NC}"
  local i=1
  for line in "${node_lines[@]}"; do
    IFS=$'\t' read -r entry relay_user out_tag <<< "$line"
    echo -e " [$i] ${relay_user}"
    i=$((i+1))
  done
  read -r -p "请输入要删除的编号（支持 1+2+3，回车返回）: " choice
  [ -z "${choice:-}" ] && return 0
  mapfile -t picks < <(parse_plus_selections "$choice")
  [ ${#picks[@]} -eq 0 ] && { warn "未选择任何条目。"; pause; return 1; }

  updated_json="$json"
  for part in "${picks[@]}"; do
    if ! [[ "$part" =~ ^[0-9]+$ ]] || [ "$part" -lt 1 ] || [ "$part" -gt "${#node_lines[@]}" ]; then
      err "编号超出范围：$part"
      pause
      return 1
    fi
    idx=$((part-1))
    IFS=$'\t' read -r entry node_key out_tag <<< "${node_lines[$idx]}"
    users_json="$({
      printf '%s\n' "${lines[@]}" | awk -F '\t' -v n="$node_key" '
        function node_part(s) { sub(/@.*/, "", s); return s }
        node_part($2)==n { print $2 }'
    } | awk 'NF' | sort -u | jq -R . | jq -s '.')"
    updated_json="$(remove_relays_by_user_names "$updated_json" "$users_json")" || {
      err "删除中转失败，已中止，未写入配置。"
      pause
      return 1
    }
  done

  if user_db_exists; then
    local db_json
    db_json="$(user_db_load)"
    db_json="$(user_db_cleanup_missing_nodes "$db_json" "$updated_json")"
    if ! user_manager_apply_changes "$db_json" "$updated_json"; then
      warn "删除中转失败，已返回上一级。"
    fi
  else
    if ! config_apply "$updated_json"; then
      warn "删除中转失败，已返回上一级。"
    fi
  fi
  pause
  return 0
}

manage_relay_nodes() {
  init_manager_env
  while true; do
    clear
    local json
    json="$(config_load)"
    print_rect_title "中转节点管理"
    local _relay_tmp
    _relay_tmp="$(mktemp)"
    if relay_list_table "$json" >"$_relay_tmp" && [ -s "$_relay_tmp" ]; then
      awk -F '\t' 'NF >= 2 {print $2}' "$_relay_tmp" | while IFS= read -r relay_user; do
        [ -n "$relay_user" ] || continue
        relay_node="$(user_node_part "$relay_user")"
        [ -n "$relay_node" ] || continue
        echo "$relay_node"
      done | sort -u | sort_node_keys_by_protocol | while IFS= read -r relay_node; do
        echo -e "  - ${G}${relay_node}${NC}"
      done
    else
      echo -e "  ${Y}当前没有中转节点。${NC}"
    fi
    rm -f "$_relay_tmp" >/dev/null 2>&1 || true
    echo -e "${B}----------------------------------------${NC}"
    echo -e "  ${C}1.${NC} 添加/覆盖中转"
    echo -e "  ${C}2.${NC} 删除中转"
    echo -e "  ${R}0.${NC} 返回主菜单"
    read -r -p "请选择操作: " act
    case "${act:-}" in
      1) relay_add || true ;;
      2) relay_delete || true ;;
      0|q|Q|"") return 0 ;;
      *) warn "无效输入：$act"; sleep 1 ;;
    esac
  done
}
