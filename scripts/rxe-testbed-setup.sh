#!/bin/bash
# ContextStore 多轨 RDMA 测试床（软 RDMA，无需硬件 RoCE 网卡）
#
# 足迹（全部为虚拟资源，up→down 循环已验证干净）：
#   - 1 对 veth 虚拟网卡（veth0/veth1）
#   - 2 个 rxe 软 RDMA 设备（rxe0/rxe1，分别挂在两张 veth 上）
#   - 1 个内核模块 rdma_rxe（down 后保留，如需彻底移除: sudo rmmod rdma_rxe）
#   - 1 条 /24 直连路由
# 不触碰任何物理网卡、其余路由表项、防火墙与既有服务。
#
# 网段默认 192.168.250.0/24 —— 使用前请核对与本机所有物理网卡 / docker 网桥无重叠
# （`ip -br addr` 与 `docker network ls` 后逐个查看），有冲突时用环境变量换段：
#   sudo SUBNET=192.168.251 ./scripts/rxe-testbed-setup.sh up
#
# 用法：
#   sudo ./scripts/rxe-testbed-setup.sh up      # 建测试床
#   sudo ./scripts/rxe-testbed-setup.sh down    # 一键删除全部虚拟设备与路由
set -e
SUBNET="${SUBNET:-192.168.250}"

up() {
  if ip route show | grep -q "^${SUBNET}\."; then
    echo "错误: ${SUBNET}.0/24 已存在路由，可能与现有网络重叠。请换段: sudo SUBNET=192.168.251 $0 up" >&2
    exit 1
  fi
  ip link add veth0 type veth peer name veth1 2>/dev/null || true
  ip addr add $SUBNET.1/24 dev veth0 2>/dev/null || true
  ip addr add $SUBNET.2/24 dev veth1 2>/dev/null || true
  ip link set veth0 up; ip link set veth1 up
  modprobe rdma_rxe
  rdma link add rxe0 type rxe netdev veth0 2>/dev/null || true
  rdma link add rxe1 type rxe netdev veth1 2>/dev/null || true
  rdma link show | grep rxe
}

down() {
  rdma link delete rxe0 2>/dev/null || true
  rdma link delete rxe1 2>/dev/null || true
  ip link del veth0 2>/dev/null || true
  echo "已清理: rxe0 rxe1 veth0 veth1 (内核模块 rdma_rxe 保留, 如需: sudo rmmod rdma_rxe)"
  ip route show | grep $SUBNET || echo "路由表已干净"
}

case "$1" in
  up) up ;;
  down) down ;;
  *) echo "usage: sudo $0 up|down" ;;
esac
