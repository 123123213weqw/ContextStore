# ContextStore 多轨网络 —— 快速上手与复现指南

> 上海开源大赛 · DaoCloud 智算云赛道 · 赛题《ContextStore 多轨网络设计与实现》
>
> 目标：让**单个客户端 Worker** 通过**多张 RDMA 网卡（轨）并行读取同一对象**，不改变对象与磁盘条带布局。
>
> - 设计文档（完整）：[docs/multirail-design-zh.md](multirail-design-zh.md)
> - 上游 PR（含逐文件改动与代码审核结论）：https://github.com/DaoCloud/ContextStore/pull/28

本指南在**一台没有任何 RoCE 硬件网卡的普通 Linux 服务器**上，用软 RDMA（rxe）完整复现双轨并行读取、负载均衡、数据校验与故障注入。

## 1. 环境要求

| 组件 | 要求 |
|---|---|
| 操作系统 | Linux（实测 Ubuntu 22.04，kernel 6.8；需支持 `rdma link add rxe`） |
| Rust | stable（`rustup`，大陆网络可用 `RsProxy` 镜像） |
| Redis | 本机可达（KVService 元数据依赖） |
| Python | 3.10+（仅复现 Python Worker 入口时需要） |
| root | 仅 `scripts/rxe-testbed-setup.sh` 需要（创建 veth/rxe 虚拟设备） |

## 2. 构建

```bash
git clone -b competition https://github.com/123123213weqw/ContextStore.git
cd ContextStore

# 服务端（需要 io_uring/rdma/metrics 特性）
make build          # 或: cargo build --release --features io-uring,rdma,metrics --manifest-path kv-service/server/Cargo.toml
# ↑ 若 make 默认未带特性，用上面的 cargo 命令显式构建

# 客户端 + 多轨基准工具 + FFI（Python 入口）
cargo build --release --features rdma --manifest-path kv-service/client-rs/Cargo.toml
cargo build --release --manifest-path kv-service/rdma-ffi/Cargo.toml
```

产物：`target/release/contextstore-server`、`target/release/cs-multirail-bench`、
`target/release/libcontextstore_rdma_ffi.so`。

## 3. 无硬件先跑通：单元测试

规划/校验/权重/白名单/拓扑/冷却全部硬件无关，21 个用例：

```bash
cargo test --features rdma --manifest-path kv-service/client-rs/Cargo.toml
```

## 4. 搭测试床（root，一键 up/down）

```bash
sudo ./scripts/rxe-testbed-setup.sh up
# 输出应包含: link rxe0 ... netdev veth0 / link rxe1 ... netdev veth1
# 用完一键还原（已验证 up→down→up 循环干净）:
# sudo ./scripts/rxe-testbed-setup.sh down
```

脚本只创建 1 对 veth + 2 个 rxe 设备 + 一条 /24 直连路由，不触碰物理网络；默认网段
192.168.250.0/24，冲突时 `sudo SUBNET=192.168.251 ...` 换段。

## 5. 启动服务端（双网卡监听 + 条带校验和）

`server-mr.toml`（最小可用，条带阈值 64MiB / 块 16MiB，RDMA 条带读取需 `tier_b`）：

```toml
[api]
listen = "127.0.0.1:50051"
max_connections = 1000

[storage]
devices = ["./data/nvme0", "./data/nvme1"]
data_subdir = "contextstore"
striping_threshold = 67108864   # 64 MiB，超过即条带化
striping_chunk_size = 16777216  # 16 MiB / 条带
verify_stripe_checksums = true  # 每条带 xxh3-64 校验

[memory_tier]
capacity_mb = 4096
slab_size_mb = 64

[io_executor]
kind = "tier_b"        # RDMA 流式读取依赖 io_uring 实现
thread_pool_size = 32
io_uring_depth = 256

[router]
strategy = "object_hash"

[metadata]
redis_url = "redis://127.0.0.1:6379/"
redis_key_prefix = "contextstore:mr:"

[gc]
enabled = true
interval_seconds = 300
grace_seconds = 600
max_tasks_per_run = 1000
task_lease_seconds = 300

[metrics]
enabled = false
listen = "127.0.0.1:9090"
```

启动（`CS_RDMA_DEVICES` 让服务端**同时在两张网卡上各开一个 RDMA listener**，这是原生能力，无需改服务端代码）：

```bash
mkdir -p data/nvme0 data/nvme1
CS_RDMA_ADVERTISE=192.168.250.1:50053 \
CS_RDMA_DEVICES="rxe0:192.168.250.1:50053:1,rxe1:192.168.250.2:50054:1" \
./target/release/contextstore-server --config server-mr.toml &
```

> 注：末位 `:1` 是该网卡的 GID index（软 RDMA 的 RoCE v2 GID 通常在 index 1），
> 用 `ibv_show_gids` 核对；真实 mlx5 网卡默认 index 3。

## 6. 双轨并行读取基准

```bash
./target/release/cs-multirail-bench \
  --coordinator http://127.0.0.1:50051 --namespace bench --object-key obj \
  --put-size-mb 512 --iters 5 --verify \
  --rails "rxe0:1:1,rxe1:1:1" \
  --pin "rxe0=192.168.250.1:50053,rxe1=192.168.250.2:50054" \
  --alternate-endpoints "192.168.250.1:50053,192.168.250.2:50054" \
  --task-max-stripes 4
```

- `--rails`：参与的轨（设备[:端口[:gid[:权重]]]]）；`--pin`：轨↔端点白名单（模拟
  rail-optimized 接线，软 RDMA 跨设备不通时必需）；`--task-max-stripes`：>0 时单轨拆多连接并发。
- 每轮结束打印 `RailSnapshot` 单行指标。实测期望：**两轨各 1280 MiB 精确均衡、零错误零超时、`verify` 全部通过**。

## 7. 硬件 e2e 三连测（双轨一致性 / 死端点故障注入 / 读期间重写的版本一致）

```bash
CS_MR_COORDINATOR=http://127.0.0.1:50051 \
CS_MR_RAILS="rxe0:1:1,rxe1:1:1" \
CS_MR_PIN="rxe0=192.168.250.1:50053,rxe1=192.168.250.2:50054" \
CS_MR_ALTERNATE_ENDPOINTS="192.168.250.1:50053,192.168.250.2:50054" \
CS_MR_TASK_MAX_STRIPES=4 \
cargo test --manifest-path kv-service/client-rs/Cargo.toml --features rdma \
  --test multirail_e2e -- --ignored --test-threads=1
```

3 个测试全部 PASS 即覆盖：双轨结果与单轨逐字节一致；死端点注入 → 类型化安全失败且**同一缓冲区**立即复用成功（无晚到写污染）；读期间对象重写 → `StaleDescriptor` 触发重新 lookup。

## 8. Python Worker 入口（ctypes → C ABI → 多轨核心）

```bash
pip install -e .   # 安装 contextstore 包
export CONTEXTSTORE_RDMA_LIB=$PWD/target/release/libcontextstore_rdma_ffi.so
python - <<'PY'
import ctypes
from contextstore.storage.multirail_client import MultiRailReader

rails = ["rxe0:1:1@192.168.250.1:50053", "rxe1:1:1@192.168.250.2:50054"]
reader = MultiRailReader(rails)
buf = ctypes.create_string_buffer(size)       # size = lookup 得到的对象大小
n = reader.read_into(buf, lookup_result)      # 双轨并行写入，返回字节数
for rail in reader.rail_stats():              # 每轨指标（吞吐/延迟/错误/在途）
    print(rail)
PY
```

轨绑定语法 `device[:port[:gid[:weight[:mtu]]]][@ep1[;ep2...]]`，`@` 后是端点白名单。实测：128MiB / 8 条带，两轨各 64MiB 精确均衡、内容校验通过。

## 9. 真实硬件网卡（可选）

有 RoCE 网卡时无需测试床，直接：

```bash
ibv_devices && ibv_show_gids    # 找设备名与 GID index
# 服务端按网卡各开 listener:
CS_RDMA_DEVICES="mlx5_0:192.168.10.1:50053:3,mlx5_1:192.168.11.1:50054:3" ...
# 客户端:
./target/release/cs-multirail-bench --rails "mlx5_0:1:3,mlx5_1:1:3" ...   # 同网段免 pin
```

## 10. 结果汇总（V100 实测）

| 验证项 | 结果 |
|---|---|
| 单元测试（硬件无关） | 21/21 通过 |
| e2e 双轨/故障注入/版本一致 | 3/3 通过 |
| 512MB × 5 轮双轨负载 | 两轨各 1280 MiB 精确均衡，0 错误 0 超时 |
| 系统级扩展（双进程各占一轨） | 1.81× 聚合吞吐提升 |
| Python Worker 端到端 | 均衡 + 校验 + 指标全部通过 |
| 上游回归（make e2e / pytest / clippy 双模式 / fmt） | 全部通过 |

软 RDMA 的内核 CPU 封包路径使单进程内收益受限（~0.3 GiB/s 天花板），负载均衡本身精确到字节；
真实网卡为硬件 DMA 卸载，不存在该瓶颈。分析详见设计文档 §3。

## 11. 兼容矩阵

| 维度 | 支持情况 | 说明 |
|---|---|---|
| 单轨 / 关闭多轨 | ✅ 行为等价旧路径 | 仅配一条 rail 或沿用原 `RdmaClient` 均可 |
| 旧客户端 ↔ 新服务端 | ✅ | 服务端多轨能力仅依赖既有 `CS_RDMA_DEVICES`，协议未变 |
| 新客户端 ↔ 旧服务端 | ✅ | stripe-subset GET（tag 12/15）为既有协议；placement 无校验和时跳过该校验 |
| Soft-RoCE (rxe) | ✅ 实测 | 本仓库默认验证环境；内核 rxe 跨设备路径有缺陷时用轨 pin + 端点交替规避 |
| 实体 RoCE 网卡 (mlx5 / irdma) | ✅ 设计支持 | `--rails "mlx5_0:1:3,mlx5_1:1:3"`；同网段免 pin，跨路由配 `hop_limit` |
| gRPC-only 构建（无 rdma feature） | ✅ 零依赖变化 | multirail 模块由 `rdma` feature 门控 |
| path MTU | ✅ 可配置 | 客户端/轨/服务端 `CS_RDMA_PATH_MTU`，两端一致，默认 1024 |
| 硬件 e2e / bench 门控 | ✅ | `CS_MR_*` 环境变量驱动，见 §7 |
| 上游回归 | ✅ | `make e2e`、clippy 双模式、`cargo fmt`、Python pytest 全绿 |

升级方式：客户端按需启用多轨（显式配置 rails 才激活），单轨部署无需任何配置变更。
