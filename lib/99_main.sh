#!/usr/bin/env bash
# ============================================================
# 模块: 99_main.sh
# 职责: 主菜单 + CLI 入口路由
# 依赖: 所有其它模块
# ============================================================

main_menu() {
  ensure_local_script_entrypoint_once
  while true; do
    clear
    print_rect_title "Sing-box Elite 管理系统  V${SCRIPT_VERSION}"
    echo -e "  ${C}1.${NC} 安装/更新 sing-box"
    echo -e "  ${C}2.${NC} 清空/重置 config.json"
    echo -e "  ${C}3.${NC} 查看配置"
    echo -e "  ${C}4.${NC} 协议管理"
    echo -e "  ${C}5.${NC} 中转管理"
    echo -e "  ${C}6.${NC} 导出节点配置"
    echo -e "  ${C}7.${NC} 用户管理"
    echo -e "  ${C}8.${NC} warp分流"
    echo -e "  ${C}9.${NC} 系统工具"
    echo -e "  ${C}10.${NC} 卸载 sing-box"
    echo -e "  ${R}0.${NC} 退出系统"
    echo -e "${B}--------------------------------------------------------${NC}"
    read -r -p "请选择操作指令: " opt
    case "${opt:-}" in
      1) install_or_update_singbox ;;
      2) clear_config_json ;;
      3) view_config_formatted ;;
      4) protocol_manager || true ;;
      5) manage_relay_nodes || true ;;
      6) export_configs || true ;;
      7) user_manager_menu || true ;;
      8) warp_manager_menu || true ;;
      9) system_tools_menu || true ;;
      10) uninstall_singbox_keep_config ;;
      0|q|Q) exit 0 ;;
      *) warn "无效输入：$opt"; sleep 1 ;;
    esac
  done
}

# ====================================================
# CLI 入口路由
# ====================================================
if [[ "${1:-}" == "--user-watch" ]]; then
  user_watch_run
  exit 0
fi

if [[ "${1:-}" == "--maintain-logs" ]]; then
  maintain_logs
  exit 0
fi

if [[ "${1:-}" == "--tg-agent-sync" ]]; then
  tg_agent_sync
  exit 0
fi

main_menu
