#!/bin/bash

# ==============================================================================
# VPS 精简初始化脚本 (Hostname, Swap, SSH, Fail2ban)
# ==============================================================================
set -euo pipefail

# --- 全局变量 ---
LOG_FILE=""
GREEN='\033[0;32m' RED='\033[0;31m' YELLOW='\033[1;33m'
BLUE='\033[0;34m' CYAN='\033[0;36m' NC='\033[0m'

# 配置变量
CONF_HOSTNAME=""
CONF_SWAP_SIZE=""
CONF_SSH_PORT=""
CONF_SSH_PWD=""
CONF_FAIL2BAN="false"

spinner_pid=0
VERIFICATION_PASSED=0
VERIFICATION_FAILED=0
VERIFICATION_WARNINGS=0

# ==============================================================================
# --- 辅助工具函数 ---
# ==============================================================================

log() { echo -e "$1"; }

handle_error() {
    local exit_code=$? line_number=$1
    command -v tput >/dev/null 2>&1 && tput cnorm 2>/dev/null || true
    echo -e "\n${RED}[ERROR] 脚本在第 ${line_number} 行失败 (退出码: ${exit_code})${NC}"
    [[ -n "$LOG_FILE" ]] && echo "[ERROR] Failed at line ${line_number}" >> "$LOG_FILE"
    [[ $spinner_pid -ne 0 ]] && kill "$spinner_pid" 2>/dev/null
    exit "$exit_code"
}

start_spinner() {
    if ! command -v tput >/dev/null 2>&1 || [[ ! -t 1 ]]; then echo -e "${CYAN}${1:-}${NC}"; return; fi
    echo -n -e "${CYAN}${1:-}${NC}"
    ( while :; do for c in '/' '-' '\' '|'; do echo -ne "\b$c"; sleep 0.1; done; done ) &
    spinner_pid=$!
    tput civis 2>/dev/null || true
}

stop_spinner() {
    if [[ $spinner_pid -ne 0 ]]; then kill "$spinner_pid" 2>/dev/null; wait "$spinner_pid" 2>/dev/null || true; spinner_pid=0; fi
    if command -v tput >/dev/null 2>&1 && [[ -t 1 ]]; then tput cnorm 2>/dev/null || true; echo -e "\b${GREEN}✔${NC}"; else echo -e "${GREEN}✔${NC}"; fi
}

check_disk_space() {
    local required_mb="$1" available_mb
    available_mb=$(df -BM / | awk 'NR==2 {gsub(/M/,"",$4); print $4}' || echo 0)
    if [[ "$available_mb" -lt "$required_mb" ]]; then
        log "${RED}[ERROR] 磁盘空间不足: 需要${required_mb}MB，可用${available_mb}MB${NC}"
        return 1
    fi
}

verify_privileges() {
    if [[ $EUID -ne 0 ]]; then log "${RED}[ERROR] 请使用 root 权限运行此脚本${NC}"; exit 1; fi
}

# ==============================================================================
# --- 1. 交互式输入收集 ---
# ==============================================================================
collect_user_input() {
    log "${CYAN}=== 请根据提示输入配置信息 ===${NC}"
    
    # 1. 主机名配置
    echo
    read -p "1. 是否修改主机名 (Hostname)? [y/N] " -r
    if [[ "$REPLY" =~ ^[Yy]$ ]]; then
        read -p "   请输入新的主机名: " CONF_HOSTNAME
    fi

    # 2. Swap 配置
    echo
    read -p "2. 是否配置虚拟内存 (Swap)? [y/N] " -r
    if [[ "$REPLY" =~ ^[Yy]$ ]]; then
        read -p "   请输入Swap大小(MB) (例如 1024, 2048): " CONF_SWAP_SIZE
        if [[ ! "$CONF_SWAP_SIZE" =~ ^[0-9]+$ ]]; then
            log "${YELLOW}   输入格式错误，跳过Swap配置${NC}"
            CONF_SWAP_SIZE=""
        fi
    fi

    # 3. SSH 配置
    echo
    read -p "3. 是否修改 SSH 端口或密码? [y/N] " -r
    if [[ "$REPLY" =~ ^[Yy]$ ]]; then
        read -p "   请输入新 SSH 端口 (留空不修改): " CONF_SSH_PORT
        read -s -p "   请输入新 root 密码 (留空不修改): " CONF_SSH_PWD
        echo
    fi

    # 4. Fail2ban 配置
    echo
    read -p "4. 是否安装并启用 Fail2ban 防爆破? [y/N] " -r
    if [[ "$REPLY" =~ ^[Yy]$ ]]; then
        CONF_FAIL2BAN="true"
    fi
}

# ==============================================================================
# --- 功能执行函数 ---
# ==============================================================================

# 1. 配置主机名
do_hostname() {
    [[ -z "$CONF_HOSTNAME" ]] && return
    log "\n${YELLOW}>>> 配置主机名...${NC}"
    
    local current_hostname=$(hostname)
    if [[ "$CONF_HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]]; then
        hostnamectl set-hostname "$CONF_HOSTNAME" >> "$LOG_FILE" 2>&1
        # 修改 hosts
        if grep -q "^127\.0\.1\.1" /etc/hosts; then
            sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t${CONF_HOSTNAME}/" /etc/hosts
        else
            echo -e "127.0.1.1\t${CONF_HOSTNAME}" >> /etc/hosts
        fi
        log "${GREEN}✅ 主机名已修改为: ${CONF_HOSTNAME}${NC}"
    else
        log "${RED}[ERROR] 主机名格式错误，跳过${NC}"
    fi
}

# 2. 配置 Swap
do_swap() {
    [[ -z "$CONF_SWAP_SIZE" ]] && return
    log "\n${YELLOW}>>> 配置 Swap...${NC}"
    
    check_disk_space $((CONF_SWAP_SIZE + 100)) || return 1
    
    local swap_file="/swapfile"
    # 如果已存在，先清理
    if [[ -f "$swap_file" ]]; then
        swapoff "$swap_file" 2>/dev/null || true
        rm -f "$swap_file"
    fi
    
    log "${BLUE}正在创建 ${CONF_SWAP_SIZE}MB Swap文件...${NC}"
    if command -v fallocate &>/dev/null; then
        fallocate -l "${CONF_SWAP_SIZE}M" "$swap_file" >> "$LOG_FILE" 2>&1
    else
        dd if=/dev/zero of="$swap_file" bs=1M count="$CONF_SWAP_SIZE" status=none >> "$LOG_FILE" 2>&1
    fi
    
    chmod 600 "$swap_file"
    mkswap "$swap_file" >> "$LOG_FILE" 2>&1
    swapon "$swap_file" >> "$LOG_FILE" 2>&1
    
    # 写入 fstab
    if ! grep -q "$swap_file" /etc/fstab; then
        echo "$swap_file none swap sw 0 0" >> /etc/fstab
    fi
    log "${GREEN}✅ Swap 配置完成${NC}"
}

# 3. 配置 SSH
do_ssh() {
    if [[ -z "$CONF_SSH_PORT" ]] && [[ -z "$CONF_SSH_PWD" ]]; then return; fi
    log "\n${YELLOW}>>> 配置 SSH...${NC}"

    # 确保安装了 openssh-server
    if ! dpkg -l openssh-server >/dev/null 2>&1; then
        apt-get update -qq >> "$LOG_FILE" 2>&1
        apt-get install -y openssh-server >> "$LOG_FILE" 2>&1
    fi

    # 修改密码
    if [[ -n "$CONF_SSH_PWD" ]]; then
        echo "root:${CONF_SSH_PWD}" | chpasswd >> "$LOG_FILE" 2>&1
        log "${GREEN}✅ root 密码已更新${NC}"
    fi

    # 修改端口
    if [[ -n "$CONF_SSH_PORT" ]]; then
        if [[ "$CONF_SSH_PORT" =~ ^[0-9]+$ && "$CONF_SSH_PORT" -gt 0 && "$CONF_SSH_PORT" -lt 65536 ]]; then
            cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%s)"
            sed -i '/^[#\s]*Port\s\+/d' /etc/ssh/sshd_config
            echo "Port ${CONF_SSH_PORT}" >> /etc/ssh/sshd_config
            
            if sshd -t; then
                systemctl restart sshd >> "$LOG_FILE" 2>&1
                log "${GREEN}✅ SSH 端口已修改为: ${CONF_SSH_PORT}${NC}"
                log "${YELLOW}⚠️  请务必记住新端口，下次连接需要使用！${NC}"
            else
                log "${RED}[ERROR] SSH 配置测试失败，已还原${NC}"
                mv "/etc/ssh/sshd_config.bak.$(date +%s)" /etc/ssh/sshd_config
                systemctl restart sshd
            fi
        else
            log "${RED}[ERROR] 端口号无效，跳过端口修改${NC}"
        fi
    fi
}

# 4. 配置 Fail2ban
do_fail2ban() {
    [[ "$CONF_FAIL2BAN" != "true" ]] && return
    log "\n${YELLOW}>>> 配置 Fail2ban...${NC}"

    start_spinner "安装 Fail2ban... "
    apt-get update -qq >> "$LOG_FILE" 2>&1
    apt-get install -y fail2ban >> "$LOG_FILE" 2>&1
    stop_spinner

    # 确定要保护的端口 (包括默认22和新修改的端口)
    local protect_ports="22"
    [[ -n "$CONF_SSH_PORT" ]] && protect_ports="${protect_ports},${CONF_SSH_PORT}"

    cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime = -1
findtime = 300
maxretry = 3
backend = systemd
ignoreip = 127.0.0.1/8

[sshd]
enabled = true
port = ${protect_ports}
maxretry = 3
EOF

    systemctl enable fail2ban >> "$LOG_FILE" 2>&1
    systemctl restart fail2ban >> "$LOG_FILE" 2>&1
    
    if systemctl is-active --quiet fail2ban; then
        log "${GREEN}✅ Fail2ban 已运行，保护端口: ${protect_ports}${NC}"
    else
        log "${RED}[ERROR] Fail2ban 启动失败${NC}"
    fi
}

# ==============================================================================
# --- 验证函数 ---
# ==============================================================================
record_verification() {
    local component="$1" status="$2" message="$3"
    case "$status" in
        "PASS") log "    ${GREEN}✓${NC} ${component}: ${message}"; ((VERIFICATION_PASSED++)) ;;
        "FAIL") log "    ${RED}✗${NC} ${component}: ${message}"; ((VERIFICATION_FAILED++)) ;;
    esac
}

run_verification() {
    log "\n${YELLOW}=============== 最终配置验证 ===============${NC}"
    
    # 验证 Hostname
    if [[ -n "$CONF_HOSTNAME" ]]; then
        if [[ "$(hostname)" == "$CONF_HOSTNAME" ]]; then
            record_verification "主机名" "PASS" "已生效 ($(hostname))"
        else
            record_verification "主机名" "FAIL" "未生效 (当前: $(hostname))"
        fi
    fi

    # 验证 Swap
    if [[ -n "$CONF_SWAP_SIZE" ]]; then
        local current_swap=$(awk '/SwapTotal/ {print int($2/1024 + 0.5)}' /proc/meminfo)
        if [[ $current_swap -ge $CONF_SWAP_SIZE ]]; then
            record_verification "Swap" "PASS" "已启用 (总量: ${current_swap}MB)"
        else
            record_verification "Swap" "FAIL" "容量不符 (当前: ${current_swap}MB)"
        fi
    fi

    # 验证 SSH
    if [[ -n "$CONF_SSH_PORT" ]]; then
        local active_port=$(grep -oP '^\s*Port\s+\K\d+' /etc/ssh/sshd_config | tail -n1)
        if [[ "$active_port" == "$CONF_SSH_PORT" ]]; then
            record_verification "SSH端口" "PASS" "配置已更新为 $active_port"
        else
            record_verification "SSH端口" "FAIL" "配置不符 (文件配置: $active_port)"
        fi
    fi

    # 验证 Fail2ban
    if [[ "$CONF_FAIL2BAN" == "true" ]]; then
        if systemctl is-active --quiet fail2ban; then
            record_verification "Fail2ban" "PASS" "服务运行正常"
        else
            record_verification "Fail2ban" "FAIL" "服务未运行"
        fi
    fi
    
    echo
    if [[ $VERIFICATION_PASSED -gt 0 || $VERIFICATION_FAILED -gt 0 ]]; then
        log "${BLUE}验证汇总: ${GREEN}成功 ${VERIFICATION_PASSED}${NC}, ${RED}失败 ${VERIFICATION_FAILED}${NC}"
    else
        log "${BLUE}未进行任何修改，无验证项。${NC}"
    fi
}

# ==============================================================================
# --- 主程序 ---
# ==============================================================================
main() {
    trap 'handle_error ${LINENO}' ERR
    verify_privileges
    
    LOG_FILE="/var/log/vps-mini-init.log"
    echo "VPS Mini Init Log - $(date)" > "$LOG_FILE"

    # 1. 收集信息
    collect_user_input

    # 2. 确认执行
    log "\n${CYAN}即将执行以下操作:${NC}"
    [[ -n "$CONF_HOSTNAME" ]]  && log "  - 修改主机名: $CONF_HOSTNAME"
    [[ -n "$CONF_SWAP_SIZE" ]] && log "  - 设置 Swap: ${CONF_SWAP_SIZE}MB"
    [[ -n "$CONF_SSH_PORT" ]]  && log "  - 修改 SSH 端口: $CONF_SSH_PORT"
    [[ -n "$CONF_SSH_PWD" ]]   && log "  - 修改 root 密码: (已隐藏)"
    [[ "$CONF_FAIL2BAN" == "true" ]] && log "  - 启用 Fail2ban"
    
    if [[ -z "$CONF_HOSTNAME" && -z "$CONF_SWAP_SIZE" && -z "$CONF_SSH_PORT" && -z "$CONF_SSH_PWD" && "$CONF_FAIL2BAN" != "true" ]]; then
        log "\n${YELLOW}您未选择任何操作，脚本退出。${NC}"
        exit 0
    fi

    echo
    read -p "确认执行以上配置? [y/N] " -r
    [[ ! "$REPLY" =~ ^[Yy]$ ]] && { log "已取消"; exit 0; }

    # 3. 开始执行
    log "\n${BLUE}>>> 开始执行配置...${NC}"
    do_hostname
    do_swap
    do_ssh
    do_fail2ban

    # 4. 验证与收尾
    run_verification
    
    log "\n${GREEN}🎉 配置脚本执行完毕!${NC}"
    log "日志文件: $LOG_FILE"
    if [[ -n "$CONF_SSH_PORT" ]]; then
        log "${RED}⚠️  注意：SSH端口已修改，请确保防火墙(如安全组)放行端口 ${CONF_SSH_PORT}，并使用新端口连接！${NC}"
    fi
}

main "$@"
