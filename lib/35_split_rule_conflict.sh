#!/usr/bin/env bash
# ============================================================
# 模块: 35_split_rule_conflict.sh
# 职责: WARP 分流与部分流量中转之间的规则归属互斥
# 依赖: 00_base.sh, 01_utils.sh, 40_relay.sh, 64_warp.sh
# ============================================================

split_rule_files_json_from_args() {
  if [ "$#" -eq 0 ]; then
    echo '[]'
    return 0
  fi
  printf '%s\n' "$@" | awk 'NF' | jq -R . | jq -s 'unique'
}

split_rule_relay_conflicts_json() {
  local files_json="$1"
  relay_meta_rules_json | jq -c --argjson files "$files_json" '
    [
      .[]?
      | (.file // "") as $file
      | select($file != "" and (($files | index($file)) != null))
    ] | unique_by(.file)
  '
}

split_rule_warp_conflicts_json() {
  local files_json="$1"
  warp_meta_rules_json | jq -c --argjson files "$files_json" '
    [
      .[]?
      | (.file // "") as $file
      | select($file != "" and (($files | index($file)) != null))
    ] | unique_by(.file)
  '
}

split_rule_has_warp_conflicts() {
  local files_json="$1" conflicts
  conflicts="$(split_rule_warp_conflicts_json "$files_json")" || return 1
  [ "$(echo "$conflicts" | jq 'length')" -gt 0 ]
}

split_rule_take_over_relay_to_warp() {
  local files_json="$1" conflicts count
  conflicts="$(split_rule_relay_conflicts_json "$files_json")" || return 1
  count="$(echo "$conflicts" | jq 'length')" || return 1
  [ "$count" -gt 0 ] || return 0

  warn "以下规则已在部分流量中转中使用："
  echo "$conflicts" | jq -r '
    .[]?
    | "  - \(.name // .file) -> 落地\(.landing_id // "未设置")：\(.file // "")"
  '
  ask_confirm_yn "是否改为 WARP 分流？(y/N): " || return 1
  relay_rule_remove_meta_by_files_json "$files_json"
}

split_rule_take_over_warp_to_relay() {
  local files_json="$1" landing_id="$2" conflicts count
  conflicts="$(split_rule_warp_conflicts_json "$files_json")" || return 1
  count="$(echo "$conflicts" | jq 'length')" || return 1
  [ "$count" -gt 0 ] || return 0

  warn "以下规则已在 WARP 分流中使用："
  echo "$conflicts" | jq -r '
    .[]?
    | "  - \(.name // .file)：\(.file // "")"
  '
  ask_confirm_yn "是否改为中转至落地${landing_id}？(y/N): " || return 1
  warp_rule_remove_meta_by_files_json "$files_json"
}
