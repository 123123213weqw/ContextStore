# ContextStore 多轨网络设计与实现 —— 赛题交付说明

> DaoCloud 赛题：ContextStore 多轨网络设计与实现
> 代码基线：github.com/DaoCloud/ContextStore @ d29903d (add generation garbage collection #27)
> 上游 PR：https://github.com/DaoCloud/ContextStore/pull/28 （分支 `multirail-read`，5 个提交，+3730/-16）
> 交付物：`kv-service/client-rs` 内新增 multi-rail 读路径 + 工具 + 测试，对现有接口完全向后兼容。

## 1. 总体设计

```
                单个客户端 Worker
  ┌─────────────────────────────────────────────┐
  │ MultiRailClient                              │
  │  ├─ Rail[0]: rxe0/irdma0/mlx5_0 (PD/CQ/QP)  │
  │  ├─ Rail[1]: rxe1/irdma1/mlx5_1 (PD/CQ/QP)  │
  │  │    每轨独立: verbs ctx, PD, CQ, MR, 健康态, 指标 │
  │  ├─ RailSelectPolicy (LeastLoaded/亲和/RR/白名单) │
  │  └─ RailLimits (连接数/队列深度/在途字节背压)     │
  └───────┬─────────────────┬───────────────────┘
      TCP 控制面 + RDMA WRITE 数据面 (每 (轨,端点) 一条连接)
          ▼                 ▼
   存储节点 listener A   存储节点 listener B
   (服务端 CS_RDMA_DEVICES 原生支持多网卡监听, 无需改动)
```

**轨（Rail）= 客户端本地一张 RDMA 网卡/端口 + 它独占的资源切片**（verbs context、PD、CQ、QP、缓存 MR、健康状态、统计）。
**连接 = (轨, 远端端点) 二元组**，每条连接一个专属 worker 线程，串行处理请求，保持原 TCP 控制面"一连接一在途请求"的协议不变量。

核心思路：**完全复用现有数据面**。GET 本来就是服务端发起 RDMA WRITE 推到客户端注册缓冲区、条带按 `stripe_index * chunk_size` 落位——多轨只需：同一缓冲区在每张卡上各注册一次（rkey 只在本设备有效）、条带按轨分组、每轨一条连接并行发 stripe-subset GET。不改变对象与磁盘条带布局。

## 2. 六项能力覆盖

### 2.1 多路径发现与管理
- `RailConfig::parse("dev[:port[:gid[:weight]]]")` + `rdma::list_device_names()` 设备枚举 + `rdma::query_gid_raw()` GID 探测（含 RoCE v2 IPv4 提取用于亲和）。
- Rail↔Endpoint 映射：默认任意可达；`RailConfig.endpoints` 白名单支持显式 pin（rail-optimized 拓扑/交叉接线测试床）；`EndpointAffinity` 策略自动按 GID 子网 /24 匹配。
- 每轨管理连接池（`HashMap<(rail, endpoint), ConnEntry>`）、QP/CQ/MR 生命周期、健康位 + 冷却窗口（失败轨默认冷却 10s，过后自动重新纳入规划 = 路径恢复）。

### 2.2 条带分配与并行读取
- `validate_placement` → `build_plan` → `plan_waves` 三级规划：
  - 校验：条带缺失/重复/越界/长度与布局不符在**发 IO 前**即报类型化错误；
  - 分配：按端点分组后，`LeastLoaded` 用交叉相乘比较 `assigned/weight`（无整除舍入）+ 平局偏向高权重轨；权重默认 1:1；
  - 汇聚：各轨条带写入目标缓冲区的天然不相交区域（服务端定位语义），无客户端重组。
- 单元测试断言：2 轨 8 条带精确 4/4 均分、1:4 权重精确 16:64 字节比、条带集合恰好覆盖 0..N 无重无漏。

### 2.3 数据完整与版本一致
- 每个任务的请求都携带完整 Descriptor（handle/generation/ETag/layout_version），服务端元数据不匹配即拒（`found=false`），客户端映射为 `MultiRailError::StaleDescriptor` 提示重新 lookup——**多轨数据必属同一对象版本**。
- 完整性四重校验：① 规划期条带覆盖检查；② 每任务实际字节数 == 布局推导字节数（`ByteCountMismatch`）；③ 服务端 `num_chunks` == 请求条带数（`ChunkCountMismatch`，识别缺失/重复）；④ placement 带校验和时逐条带 xxh3-64 小写十六进制比对（与服务端 `twox-hash` 编码一致，`ChecksumMismatch`）。

### 2.4 传输与内存安全（晚到写防护）
- 控制面 `io_timeout`/`connect_timeout`（新增于 `RdmaClientConfig`，默认 None 保持旧行为）：断连/死端点表现为即时 io 错误而非无限挂起。
- **失败返回前完成静默（quiesce）**：`Stop` 排在在途命令之后 → join worker 线程 → worker 退出时 `RdmaClient` drop 顺序为 BYE → `ibv_destroy_qp` → MR 反注册（MR 内的 `Arc<RdmaResources>` 保证 PD/ctx 活到最后一刻）。QP 销毁后残余重传打到已释放 QPN/失效 rkey，被传输层丢弃，**不可能 DMA 进已释放/复用的内存**。
- 安全 API（`read_object_into(&mut [u8])`）每次读后同步驱逐该缓冲区的缓存 MR（ack 确认），杜绝注册残留钉住已释放页；`read_object_into_raw` 提供 sticky 注册快速路径（池化缓冲区复用，契约写入文档）。
- e2e 验证：故障注入后**同一缓冲区**立即复用做成功读 + 全量字节校验通过——证明无晚到写污染。

### 2.5 资源与背压
`RailLimits`：`max_connections_per_rail`（单轨队列深度，默认 8）、`max_connections_total`（默认 32）、`max_inflight_bytes_per_rail/total`（默认 8/32 GiB）、`io_timeout`、`rail_cooldown`。规划按 wave 分波保证连接上限；派发线程在字节预算不足时带期限等待（1ms 粒度），在途字节按轨原子计数、应答后释放。

### 2.6 拓扑感知与性能分析
- `RailTopology`：sysfs 读取每轨 `numa_node` + PCIe BDF，纳入 `RailSnapshot` 输出。
- 策略三层：`LeastLoaded`（默认，最大扇出）、`EndpointAffinity`（GID 子网匹配优先 + 白名单 pin，模拟 rail-optimized）、`WeightedRoundRobin`。
- 量化结果见 §4。

### 2.7 兼容与可观测
- 单轨配置 = 行为等价旧路径；`RdmaClient` 公共 API 仅增不改（新增 builder 均有默认值）；上游 `rdma_bench`/`rdma-ffi` 构建不受影响；gRPC-only 构建（无 rdma feature）零依赖变化。
- `RailSnapshot`：每轨健康/冷却、ok/err/timeout 请求数、读字节、连接创建/静默数、在途请求与字节，`Display` 单行表格化，bench 每轮打印。

## 2.8 Python Worker 入口（rdma-ffi C ABI + ctypes）

赛题中的"客户端 Worker"是 Python 侧 KVConnector，经 ctypes 加载 `libcontextstore_rdma_ffi.so` 使用多轨：

- **C ABI**（`kv-service/rdma-ffi/src/multirail.rs`，前缀 `cs_mr_`）：`cs_mr_new(rail_specs, n, io_timeout_ms)` / `cs_mr_read(reader, CsMrDescriptor*, CsMrChunk*, n, buf, len, sticky, err_buf)` / `cs_mr_rail_stats` / `cs_mr_free`。描述符与 placement 块用 C 结构体镜像 gRPC 字段，由 Python 从 `LookupObject` 结果填充。
- **Python 绑定**（`src/contextstore/storage/multirail_client.py`）：`MultiRailReader(rails).read_into(buffer, lookup, sticky=...)`，`rail_stats()` 返回每轨指标快照；失败抛 `MultiRailError`（携带 Rust 侧类型化错误文本）。
- **显式取消**：Rust 核心 `CancelToken`（克隆共享标志；在 wave 边界、背压等待、应答收集点检查；取消路径同样先排空在途应答再 quiesce，不违反内存安全契约）——`read_object_into_cancelled(..., &token)`。FFI 层为同步调用未导出取消（Python 侧可按需加异步包装）。
- 轨绑定语法：`device[:port[:gid[:weight[:mtu]]]][@ep[;ep...]]`，`@` 后缀为端点白名单（rail-optimized pin）。

实测（V100 测试床）：Python 端到端 128MiB/8 条带双轨读取，**两轨各 64MiB 精确均衡、内容校验通过、每轨指标输出正常**。

## 3. 测试与验证（V100 实测）

环境：Ubuntu 22.04 / kernel 6.8 / 64C / 251G，veth 对 (192.168.250.1↔.2，已核对与主机全部物理网卡/16 个 docker 网桥零重叠) + 双 rxe 软 RDMA 设备模拟双轨；服务端 `CS_RDMA_DEVICES=rxe0:192.168.250.1:50053:1,rxe1:192.168.250.2:50054:1` 双监听 + `CS_RDMA_ADVERTISE` + tier_b(io_uring) + 条带阈值 64MB/块 16MB + 条带校验和开启。

**测试床安全隔离**（`scripts/rxe-testbed-setup.sh up\|down`，root 执行）：全部足迹 = 1 对 veth 虚拟网卡 + 2 个 rxe 设备 + rdma_rxe 内核模块 + 一条 /24 私网直连路由；不触碰任何物理网卡、路由表其它条目、防火墙与既有服务；`down` 一键删除并已验证 up→down→up 循环干净。曾尝试完整 netns 隔离（`ip netns`），但该内核的 rxe 在 netns 内传输层故障（上游原生 PUT 亦报 `WR_FLUSH_ERR`，属内核软 RDMA 的 UDP 隧道实现缺陷），故退而采用无冲突私网段方案；真实硬件部署不涉及此问题。

| 验证项 | 结果 |
|---|---|
| 单元测试（规划/校验/权重/白名单/拓扑/冷却，硬件无关） | **21/21 通过** |
| clippy `-D warnings`（client，default 与 rdma 双模式） | **0 错误**（上游基线 45） |
| e2e 双轨读：128MB 条带对象，双轨内容逐字节一致、两轨均承载流量、单轨结果一致 | **通过** |
| e2e 故障注入：死端点 → 类型化安全失败；同缓冲区复用恢复读校验通过 | **通过** |
| e2e 版本一致：读期间对象重写 → `StaleDescriptor` | **通过** |
| bench：512MB/32 条带 × 5 轮，双轨各 1280MiB 精确均衡，零错误零超时 | **通过** |
| e2e 复验：无冲突网段 + 单轨多连接拆分（CS_MR_TASK_MAX_STRIPES=4） | **通过** |
| Python Worker 端到端（ctypes→cs_mr_*→双轨，均衡+校验+指标） | **通过** |
| Python 集成回归 `pytest tests/`（上游用例，5 用例） | **5/5 通过** |
| 硬件无关上游回归 `make e2e` | 通过 |

**软 RDMA 上的扩展性量化**（256MB/16 条带，sticky 注册）：

| 配置 | 聚合吞吐 |
|---|---|
| 单轨 × 1 连接 | 0.28 GiB/s |
| 双轨 × 每轨 1 连接（负载精确对半） | 0.30 GiB/s（1.08x） |
| 双轨 × 每轨 8 连接（单轨并发） | 0.28–0.31 GiB/s（最高 1.29x） |
| **两个独立进程各占一轨（同一服务端）** | **0.41 GiB/s（1.81x）** |

结论：多轨的系统级扩展成立（1.81x），单进程内收益被软 RDMA 的内核 CPU 处理路径吃掉——rxe 的封包/CRC/内存拷贝全在 CPU 完成，~0.3 GiB/s 即为该路径天花板；负载均衡本身精确到字节（1280/1280MiB），瓶颈已从"轨调度"明确转移到"软 RDMA 内核实现"（这正是赛题要求的瓶颈转移分析）。真实网卡（硬件 DMA 卸载）不存在该瓶颈：本机 X722 双口 irdma 已就绪，接线后用相同命令即可复测真实加速比（命令见 §5，`--rails "irdma0:1:<gid>,irdma1:1:<gid>"`）。

另：RC path MTU 已全链路可配置（客户端 `RdmaClientConfig::with_path_mtu`、轨 spec 第 5 字段、服务端 `CS_RDMA_PATH_MTU`；两端需一致，默认 1024 兼容 1500 网络环境）——实测 rxe 回环在 >1024 时传输层故障（内核软 RDMA 限制），4096 供真实巨帧网卡使用。

## 3.1 跨机双节点验证的网络可行性结论（V100↔L40 实测）

为验证"多存储节点 + 多轨"的完整形态，实测了两台位于不同网段的实验室服务器（下称 V100 与 L40）之间的全部可用路径：

| 路径 | 结果 |
|---|---|
| 直连跨网段（ping/TCP/UDP 双向） | **全部被过滤**（校园网 VLAN 隔离；V100 侧另有 docker 网桥 172.19.0.0/16 遮蔽对端网段） |
| EasyConnect SOCKS 中继（docker 化 VPN） | 仅 TCP 可中继（控制面可用），**无法承载 RoCE 的 UDP 数据面** |
| Tailscale | L40 节点失联，不通 |

**第二条路（V100↔另一台同校服务器，同样实测到头）**：两机 Tailscale 直连（0.7ms UDP 可达）看似有戏，逐层排除：
1. rxe 直接挂 tailscale0（TUN）→ 失败：**TUN 是三层点对点设备、无 MAC/邻居，rxe 的以太帧无从发出**（QP 握手成功为假象，首个 WRITE 永无完成事件）；
2. **VXLAN over Tailscale**（`vx0` 虚拟二层，172.20.0.1/.2，ICMP/TCP 均通，双侧 rxe 挂 vx0，gid 正确）→ 仍失败：发送方抓包显示 **rxe 仅发出 1 个 95 字节包后永久静默**，RC 数据分片无法经 UDP 隧道传输——内核 rxe 与 UDP 封装隧道的深层交互缺陷（MTU 512/1024 均试过，可排除分段问题）。
3. 双节点集群本身工作正常：对象成功跨两机条带化（128MB/8 条带，两节点 gRPC 协作），卡在数据面传输。

**总结论：跨机 RoCE 在该网络环境下不可行**——四条路径（直连 VLAN、EasyConnect SOCKS、Tailscale TUN、VXLAN-over-Tailscale）全部实测排除，最后一条卡在内核 rxe×隧道的交互层。多 endpoint 逻辑已由单测覆盖、单节点双网卡场景已实测；真机跨节点验证需同一二层网络（同交换机）的网卡对。为此预备的能力保留在代码中：QP GRH `hop_limit` 可配置（客户端/轨/服务端 `CS_RDMA_HOP_LIMIT`，默认 1 兼容同网段）、bench `--endpoint-map`（TCP 控制面可达性间接映射，不影响带内 GID 交换的数据面）、双节点集群配置模板（`server-2n-*.toml` 流程已验证可复用）。

## 4. 顺带发现并处理的上游问题

1. `tier_a` IO 执行器未实现 `read_aligned_into_ptr_batch`，默认实现返回单条错误 → RDMA 条带流式读取静默返回 `found=true, bytes=0`（本测试以 tier_b 规避；上游应补实现或让默认返回空 vec 并由 serve 层报错）。
2. `client-rs/src/rdma.rs` 上游单测 `build_put_request` 缺参数（`--features rdma` 下编译失败，上游从不带 feature 跑测试故未暴露）——已修复。
3. 新版 clippy 对 tonic 生成代码的 `result_large_err` 误伤（上游 server 76 个 / client 45 个）——client 已 crate 级 allow 修至 0；server 的其余 lint 为上游既有，与赛题无关，未动。

## 5. 复现命令

```bash
# 测试床（需 root；down 一键还原）
sudo scripts/rxe-testbed-setup.sh up    # veth 192.168.250.1/.2 + rxe0/rxe1
# ... 测试 ...
sudo scripts/rxe-testbed-setup.sh down  # 删除全部虚拟设备与路由

# 服务端（tier_b + 校验和 + 双监听）
CS_RDMA_ADVERTISE=192.168.250.1:50053 \
CS_RDMA_DEVICES="rxe0:192.168.250.1:50053:1,rxe1:192.168.250.2:50054:1" \
./target/release/contextstore-server --config <config(tier_b,striping≥64MB)> &

# 双轨基准（真实硬件：--rails "irdma0:1:<gid>,irdma1:1:<gid>"，去掉 pin/alternat 或按接线调整）
./target/release/cs-multirail-bench \
  --coordinator http://127.0.0.1:50051 --namespace bench --object-key obj \
  --put-size-mb 512 --iters 5 --verify \
  --rails "rxe0:1:1,rxe1:1:1" \
  --pin "rxe0=192.168.250.1:50053,rxe1=192.168.250.2:50054" \
  --alternate-endpoints "192.168.250.1:50053,192.168.250.2:50054" \
  --task-max-stripes 4   # >0 时每轨多连接并发

# e2e 三连测
CS_MR_COORDINATOR=http://127.0.0.1:50051 CS_MR_RAILS="rxe0:1:1,rxe1:1:1" \
CS_MR_PIN="rxe0=192.168.250.1:50053,rxe1=192.168.250.2:50054" \
CS_MR_ALTERNATE_ENDPOINTS="192.168.250.1:50053,192.168.250.2:50054" \
cargo test --manifest-path kv-service/client-rs/Cargo.toml --features rdma \
  --test multirail_e2e -- --ignored --test-threads=1
```

## 6. 改动清单

| 文件 | 改动 |
|---|---|
| `kv-service/client-rs/src/multirail.rs` | **新增**：MultiRailClient/RailConfig/RailLimits/RailSelectPolicy/规划/校验/单轨多连接拆分/指标 + 21 单测（约 2000 行） |
| `kv-service/client-rs/src/rdma.rs` | 增量扩展：io/connect 超时、设备枚举、GID 查询、GET num_chunks、MR 同步驱逐；修复上游单测编译 |
| `kv-service/client-rs/src/bin/multirail_bench.rs` | **新增**：多轨基准工具（seed/verify/pin/交替端点/基线加速比） |
| `kv-service/client-rs/tests/multirail_e2e.rs` | **新增**：硬件门控三连测 |
| `kv-service/client-rs/src/lib.rs` / `Cargo.toml` | 挂载模块、twox-hash 依赖（rdma feature 门控）、生成代码 lint allow |
| `kv-service/server/src/lib.rs` | 生成代码 lint allow（工具链版本适配） |
| `kv-service/server/src/rdma/{qp,server}.rs` | QP path MTU 可配置（CS_RDMA_PATH_MTU，默认 1024 不变） |
| `kv-service/client-rs/src/bin/rdma_bench.rs` | 1 行：新版 clippy 除法 lint 适配 |
| `kv-service/rdma-ffi/src/multirail.rs` + `Cargo.toml` | **新增**：多轨 C ABI（cs_mr_*），rdma-ffi 依赖 client-rs(rdma) |
| `src/contextstore/storage/multirail_client.py` | **新增**：Python ctypes 绑定（MultiRailReader/RailStats/MultiRailError） |

## 3.2 性能与开销扫描（对象大小 × 并发度 × CPU 开销，V100 实测）

同一 Soft-RoCE 测试床、同一存储布局与校验配置，双轨 pin + 交替端点 + sticky 注册 + 逐字节校验，
每格 3 轮取均值（`cs-multirail-bench --iters 3 --verify`，单轨对照由工具自动输出）：

| 对象 | 每轨连接 | 双轨吞吐 | 单轨对照 | 加速比 | 两轨读量(3轮) | bench CPU | server CPU | 系统 %sys |
|---|---|---|---|---|---|---|---|---|
| 128MiB | 1 | 0.197 GiB/s | 0.151 | **1.31×** | 192/192 MiB | 52%¹ | 45%¹ | 1.1% |
| 128MiB | 4 | 0.252 | 0.230 | 1.10× | 192/192 | 58% | 33% | 3.5% |
| 128MiB | 8 | 0.261 | 0.290 | 0.90× | 192/192 | 65% | 28% | 2.8% |
| 256MiB | 1 | 0.242 | 0.172 | **1.40×** | 384/384 | 40% | 54% | 1.3% |
| 256MiB | 4 | 0.261 | 0.235 | 1.11× | 384/384 | 43% | 41% | 4.6% |
| 256MiB | 8 | 0.271 | 0.285 | 0.95× | 384/384 | 49% | 34% | 6.0% |
| 512MiB | 1 | 0.193 | 0.177 | 1.09× | 768/768 | 27% | 57% | 1.0% |
| 512MiB | 4 | 0.281 | 0.226 | **1.24×** | 768/768 | 32% | 48% | 5.0% |
| 512MiB | 8 | 0.260 | 0.289 | 0.90× | 768/768 | 34% | 44% | 8.0% |

¹ 单进程占单核百分比（64 核整机）；系统级 %soft < 0.2%，整机 idle ≥ 70%。

结论：
- **字节级均衡在全部 9 个组合下精确保持**（192/192、384/384、768/768 MiB），0 错误 0 超时，逐字节校验全过；
- 双轨收益在**低并发时最明显**（1.31–1.40×）；并发提高后单/双轨同趋 ~0.26–0.29 GiB/s 天花板——
  rxe 单流内核封包/CRC/拷贝路径的限制，调度器不是瓶颈（瓶颈转移结论与 §3 一致）；
- **CPU 与内存开销有界**：两端进程各 ≤ 1 核，系统 %sys ≤ 8%，sticky 注册内存固定记账 1024MiB/进程，
  在途字节归零（每轮 RailSnapshot inflight=(req:0,B:0)）；软 RDMA 环境整机 CPU 远未饱和，
  瓶颈在内核单流处理而非 CPU 总量——真实网卡为硬件卸载，预期随轨数近线性聚合。
