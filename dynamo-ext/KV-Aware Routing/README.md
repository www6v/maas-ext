
# KV-Aware Routing 实现详解

## 目录

1. [概述](#概述)
   - [核心目标](#核心目标)
   - [与其他策略的对比](#与其他策略的对比)
2. [核心架构](#核心架构)
   - [整体架构](#整体架构)
   - [KV Router 内部架构](#kv-router-内部架构)
   - [部署模式对比](#部署模式对比)
   - [Kubernetes 部署拓扑](#kubernetes-部署拓扑)
   - [多数据中心部署](#多数据中心部署)
3. [关键组件](#关键组件)
   - [KV Cache Index (KV 缓存索引)](#1-kv-cache-index-kv-缓存索引)
     - [KV Cache Index 架构](#kv-cache-index-架构)
     - [PositionalIndexer 架构](#positionalindexer-架构)
     - [多层存储匹配流程](#多层存储匹配流程)
   - [Active Load Tracker (活跃负载跟踪器)](#2-active-load-tracker-活跃负载跟踪器)
     - [负载跟踪数据流](#负载跟踪数据流)
   - [Worker Selector (Worker 选择器)](#3-worker-selector-worker-选择器)
   - [Local Scheduler (本地调度器)](#4-local-scheduler-本地调度器)
     - [Worker 状态转换](#worker-状态转换)
4. [工作流程](#工作流程)
   - [数据流架构](#数据流架构)
   - [请求处理完整流程](#请求处理完整流程)
   - [请求生命周期](#请求生命周期)
   - [请求数据流](#请求数据流)
   - [请求接收和预处理](#1-请求接收和预处理)
   - [重叠度计算](#2-重叠度计算)
   - [Worker 过滤](#3-worker-过滤)
   - [成本计算](#4-成本计算)
     - [Worker 选择决策流程](#worker-选择决策流程)
   - [Worker 选择](#5-worker-选择)
   - [负载更新](#6-负载更新)
     - [KV Cache 事件处理流程](#kv-cache-事件处理流程)
     - [KV Cache 事件数据流](#kv-cache-事件数据流)
5. [成本计算模型](#成本计算模型)
   - [成本计算详细流程](#成本计算详细流程)
   - [核心公式](#核心公式)
   - [各项详解](#各项详解)
   - [成本示例](#成本示例)
   - [缓存命中率影响](#缓存命中率影响)
6. [数据结构和索引](#数据结构和索引)
   - [索引器性能对比](#索引器性能对比)
   - [Block Hash 标识符](#block-hash-标识符)
   - [索引器选择指南](#索引器选择指南)
   - [性能指标](#性能指标)
7. [配置和调优](#配置和调优)
   - [配置优先级](#配置优先级)
   - [启用 KV-Aware Routing](#启用-kv-aware-routing)
     - [路由模式配置](#路由模式配置)
   - [关键配置参数](#关键配置参数)
   - [调优建议](#调优建议)
   - [Worker 配置一致性](#worker-配置一致性)
   - [监控和调试](#监控和调试)
8. [总结](#总结)

---

## 概述

KV-Aware Routing 是 Dynamo 的核心路由机制,通过结合 **可复用的 KV Cache 状态** 和 **预测的活跃负载**,选择能够以最低预测成本处理请求的 worker。

### 核心目标

- **减少重复计算**: 优先选择已缓存请求前缀的 worker,避免重复计算 prompt 的 attention 状态
- **负载均衡**: 避免仅基于缓存亲和性导致热点 worker 过载
- **最优化成本**: 综合考虑 prefill 计算成本、decode 成本和活跃请求成本

### 与其他策略的对比

| 路由策略 | 考虑因素 | 适用场景 |
|---------|---------|---------|
| Round-Robin | 无 | 简单轮询,不考虑状态 |
| Random | 无 | 随机选择 |
| Least-Loaded | 活跃连接数 | 基于负载的简单路由 |
| **KV-Aware** | **KV Cache 重叠 + 活跃负载** | **LLM 推理优化** |

---

## 核心架构

```
┌─────────────────────────────────────────────────────────────┐
│                      Client Request                         │
└──────────────────────┬──────────────────────────────────────┘
                       │
                       ▼
        ┌──────────────────────────────┐
        │  Dynamo Frontend / EPP       │
        │  (Request Path Host)         │
        └──────────┬───────────────────┘
                   │
                   ├─► Tokenize & Normalize
                   │
                   ▼
        ┌──────────────────────────────┐
        │      KV Router               │
        │  ┌────────────────────────┐  │
        │  │  KV Cache Index        │◄─┼── Worker KV Events
        │  │  (Prefix Overlap)      │  │   (Cache State)
        │  └────────────────────────┘  │
        │                              │
        │  ┌────────────────────────┐  │
        │  │  Active Load Tracker   │◄─┼── Worker Load Updates
        │  │  (Projected Load)      │  │   (Active Requests)
        │  └────────────────────────┘  │
        │                              │
        │  ┌────────────────────────┐  │
        │  │  Worker Selector       │  │
        │  │  (Cost Calculation)    │  │
        │  └────────────────────────┘  │
        └──────────┬───────────────────┘
                   │
                   ▼
        ┌──────────────────────────────┐
        │     Selected Worker          │
        │  (Lowest Cost Candidate)     │
        └──────────────────────────────┘
```

---


### 整体架构

```mermaid
graph TB
    subgraph "Client Layer"
        Client[Client Request]
    end
    
    subgraph "Request Path Host"
        FE[Dynamo Frontend<br/>OpenAI API]
        EPP[Endpoint Picker Plugin<br/>K8s Gateway API]
    end
    
    subgraph "KV Router Core"
        Tokenizer[Tokenizer &<br/>Normalizer]
        
        subgraph "Index Layer"
            KVI[KV Cache Index]
            DeviceIdx[(Device Index<br/>GPU)]
            HostIdx[(Host Index<br/>CPU)]
            DiskIdx[(Disk Index)]
        end
        
        subgraph "Load Tracking"
            ALT[Active Load Tracker]
            PrefillTrack[Prefill Tracker]
            DecodeTrack[Decode Tracker]
            RequestTrack[Request Tracker]
        end
        
        subgraph "Selection Layer"
            Filter[Worker Filter]
            Scorer[Cost Scorer]
            Selector[Worker Selector]
        end
        
        subgraph "Queue Management"
            Queue[Scheduler Queue]
            Policy[Scheduling Policy]
        end
    end
    
    subgraph "Worker Pool"
        W1[Worker 0<br/>GPU + KV Cache]
        W2[Worker 1<br/>GPU + KV Cache]
        W3[Worker 2<br/>GPU + KV Cache]
        W4[Worker N<br/>GPU + KV Cache]
    end
    
    Client --> FE
    Client --> EPP
    FE --> Tokenizer
    EPP --> Tokenizer
    
    Tokenizer --> KVI
    KVI --> DeviceIdx
    KVI --> HostIdx
    KVI --> DiskIdx
    
    Tokenizer --> ALT
    ALT --> PrefillTrack
    ALT --> DecodeTrack
    ALT --> RequestTrack
    
    DeviceIdx --> Filter
    HostIdx --> Filter
    DiskIdx --> Filter
    PrefillTrack --> Filter
    DecodeTrack --> Filter
    RequestTrack --> Filter
    
    Filter --> Scorer
    Scorer --> Selector
    Selector --> Queue
    Queue --> Policy
    
    Policy -->|Select| W1
    Policy -->|Select| W2
    Policy -->|Select| W3
    Policy -->|Select| W4
    
    W1 -->|KV Events| KVI
    W2 -->|KV Events| KVI
    W3 -->|KV Events| KVI
    W4 -->|KV Events| KVI
    
    W1 -->|Load Updates| ALT
    W2 -->|Load Updates| ALT
    W3 -->|Load Updates| ALT
    W4 -->|Load Updates| ALT
```


### KV Router 内部架构

```mermaid
graph LR
    subgraph "Input Processing"
        Req[Scheduling Request]
        Tokenize[Tokenize]
        Hash[Compute Block Hashes]
    end
    
    subgraph "Overlap Calculation"
        QueryIdx[Query Index]
        DeviceMatch[Device Match]
        HostMatch[Host Match]
        DiskMatch[Disk Match]
        Combine[Combine Overlaps]
    end
    
    subgraph "Load Projection"
        GetLoads[Get Worker Loads]
        ProjPrefill[Project Prefill]
        ProjDecode[Project Decode]
        ProjRequests[Project Requests]
    end
    
    subgraph "Cost Computation"
        ComputePrefill[Compute Prefill Cost]
        ComputeDecode[Compute Decode Cost]
        ComputeRequest[Compute Request Cost]
        SumCost[Sum Total Cost]
    end
    
    subgraph "Selection"
        FilterWorkers[Filter Workers]
        ScoreWorkers[Score Workers]
        PickWorker[Pick Worker]
    end
    
    Req --> Tokenize --> Hash
    Hash --> QueryIdx
    QueryIdx --> DeviceMatch
    QueryIdx --> HostMatch
    QueryIdx --> DiskMatch
    DeviceMatch --> Combine
    HostMatch --> Combine
    DiskMatch --> Combine
    
    Hash --> GetLoads
    GetLoads --> ProjPrefill
    GetLoads --> ProjDecode
    GetLoads --> ProjRequests
    
    Combine --> ComputePrefill
    ProjPrefill --> ComputePrefill
    ProjDecode --> ComputeDecode
    ProjRequests --> ComputeRequest
    
    ComputePrefill --> SumCost
    ComputeDecode --> SumCost
    ComputeRequest --> SumCost
    
    SumCost --> FilterWorkers
    FilterWorkers --> ScoreWorkers
    ScoreWorkers --> PickWorker
```


### 部署模式对比

```mermaid
graph TB
    subgraph "Aggregated Deployment"
        Client1[Client]
        Frontend1[Frontend + Router]
        Worker1[Worker 0<br/>Prefill + Decode]
        Worker2[Worker 1<br/>Prefill + Decode]
        Worker3[Worker 2<br/>Prefill + Decode]
        
        Client1 --> Frontend1
        Frontend1 -->|Route| Worker1
        Frontend1 -->|Route| Worker2
        Frontend1 -->|Route| Worker3
    end
    
    subgraph "Disaggregated Deployment"
        Client2[Client]
        Frontend2[Frontend + Router]
        
        subgraph "Prefill Pool"
            P1[Prefill Worker 0]
            P2[Prefill Worker 1]
        end
        
        subgraph "Decode Pool"
            D1[Decode Worker 0]
            D2[Decode Worker 1]
        end
        
        Client2 --> Frontend2
        Frontend2 -->|Select Prefill| P1
        Frontend2 -->|Select Prefill| P2
        Frontend2 -->|Select Decode| D1
        Frontend2 -->|Select Decode| D2
        
        P1 -.->|KV Transfer| D1
        P2 -.->|KV Transfer| D2
    end
```


### Kubernetes 部署拓扑

```mermaid
graph TB
    subgraph "Kubernetes Cluster"
        subgraph "Ingress Layer"
            LB[Load Balancer]
            Gateway[Gateway API]
        end
        
        subgraph "Routing Layer"
            EPP[Endpoint Picker<br/>Plugin]
        end
        
        subgraph "Worker Pool"
            subgraph "Namespace: llm-serving"
                W1[Worker Pod 0<br/>GPU + KV Cache]
                W2[Worker Pod 1<br/>GPU + KV Cache]
                W3[Worker Pod 2<br/>GPU + KV Cache]
            end
        end
        
        subgraph "Shared Storage"
            NFS[NFS / Shared Cache]
        end
    end
    
    LB --> Gateway
    Gateway --> EPP
    EPP -->|KV-Aware Selection| W1
    EPP -->|KV-Aware Selection| W2
    EPP -->|KV-Aware Selection| W3
    
    W1 -.->|Shared KV| NFS
    W2 -.->|Shared KV| NFS
    W3 -.->|Shared KV| NFS
```


### 多数据中心部署

```mermaid
graph TB
    subgraph "Data Center 1"
        DC1_Client[Client]
        DC1_Router[Router + Indexer]
        DC1_W1[Worker 0]
        DC1_W2[Worker 1]
        
        DC1_Client --> DC1_Router
        DC1_Router --> DC1_W1
        DC1_Router --> DC1_W2
    end
    
    subgraph "Data Center 2"
        DC2_Router[Router + Indexer]
        DC2_W1[Worker 2]
        DC2_W2[Worker 3]
        
        DC2_Router --> DC2_W1
        DC2_Router --> DC2_W2
    end
    
    subgraph "Shared KV Store"
        SharedKV[(Distributed KV Cache)]
    end
    
    DC1_Router <-->|Sync Index| DC2_Router
    DC1_W1 <-->|KV Transfer| SharedKV
    DC2_W1 <-->|KV Transfer| SharedKV
```

## 关键组件

### 1. KV Cache Index (KV 缓存索引)

**位置**: `lib/kv-router/src/indexer/`

**核心职责**:
- 跟踪每个 worker 缓存的 KV blocks
- 计算请求与 worker 缓存的前缀重叠度
- 支持多层存储 (Device, Host-Pinned, Disk, External)

**主要实现**:

#### RadixTree (单线程压缩树)
```rust
RadixTree
├── root: SharedRadixBlock (Rc<RefCell<RadixBlock>>)
└── lookup: HashMap<Worker, HashMap<SeqHash, SharedRadixBlock>>

RadixBlock
├── state.edge: Vec<(LocalBlockHash, SeqHash)>
├── state.edge_index: HashMap<SeqHash, Position>
├── state.worker_cutoffs: HashMap<Worker, Position>
├── children: HashMap<LocalBlockHash, SharedRadixBlock>
├── parent: Weak<RefCell<RadixBlock>>
└── internal: bool
```

**操作**:
- `store_blocks(worker, parent_hash, blocks)`: 添加 worker 的缓存块
- `remove_blocks(worker, block_hashes)`: 移除 worker 的缓存块
- `find_matches(local_hashes, early_exit)`: 查找具有匹配前缀的 worker

**复杂度**:
- 存储/删除: O(N)
- 查找匹配: O(D × W),D = 深度,W = worker 数量

#### ConcurrentRadixTreeCompressed (并发压缩树)
```
                   ┌──────────────────────────────┐
find_matches() ──→ │ Arc<ConcurrentRadixTree>     │ ◄── 读取并发
                   │                              │
 KV events ──→ flume[0] ──→ thread 0 (W0, W3) ──→ │
           ──→ flume[1] ──→ thread 1 (W1, W4) ──→ │ ◄── 写入串行化
           ──→ flume[2] ──→ thread 2 (W2, W5) ──→ │   (sticky routing)
                   └──────────────────────────────┘
```

**特点**:
- 线程安全的压缩边(trie)节点
- ThreadPoolIndexer 包装,实现 per-worker sticky routing
- 读取并发,写入通过 flume channel 串行化

#### PositionalIndexer (嵌套 Map)
```rust
PositionalIndexer
├── index: DashMap<(Position, LocalHash), SeqEntry>
├── worker_blocks: DashMap<Worker, RwLock<HashMap<SeqHash, (Position, LocalHash)>>>
└── jump_size: usize

SeqEntry (enum)
├── Single(SeqHash, HashSet<Worker>)  // 常见:一个 seq_hash
└── Multi(HashMap<SeqHash, HashSet<Worker>>)  // 罕见:多个前缀
```

**优化**:
- **Jump Optimization**: 跳过 jump_size 位置(如 32),O(1) 随机访问
- **Lazy Hash Optimization**: 大多数 (position, local_hash) 只有一个 seq_hash,跳过计算

**复杂度**:
- 查找匹配: O(D/J),J = jump_size


### KV Cache Index 架构

```mermaid
graph TB
    subgraph "ThreadPoolIndexer"
        subgraph "Read Path - Concurrent"
            Query["find_matches query"]
            Traverse["Traverse Tree"]
            Score["Compute Scores"]
        end
        
        subgraph "Write Path - Serialized per Worker"
            Event0["Worker 0 Events"]
            Event1["Worker 1 Events"]
            Event2["Worker 2 Events"]
            
            Queue0["flume channel 0"]
            Queue1["flume channel 1"]
            Queue2["flume channel 2"]
            
            Thread0["OS Thread 0"]
            Thread1["OS Thread 1"]
            Thread2["OS Thread 2"]
        end
        
        Tree["Arc ConcurrentRadixTreeCompressed"]
        
        Event0 --> Queue0 --> Thread0
        Event1 --> Queue1 --> Thread1
        Event2 --> Queue2 --> Thread2
        
        Thread0 -->|write| Tree
        Thread1 -->|write| Tree
        Thread2 -->|write| Tree
        
        Query --> Traverse --> Tree
        Tree --> Score
    end
    
    subgraph "Tree Structure"
        Root["root node"]
        N1["node: local=0xA, workers: W0,W1"]
        N2["node: local=0xB, workers: W2"]
        N3["node: local=0xC, workers: W0,W1"]
        N4["node: local=0xD, workers: W0"]
        
        Root --> N1
        Root --> N2
        N1 --> N3
        N3 --> N4
    end
    
    Tree -.->|contains| Root
```


### PositionalIndexer 架构

```mermaid
graph TB
    subgraph "PositionalIndexer - NestedMap"
        subgraph "Main Index - DashMap"
            Entry0["pos=0, local=0xA → Single seq=0x1111, W0,W1"]
            Entry1["pos=0, local=0xB → Single seq=0x2222, W2"]
            Entry2["pos=1, local=0xC → Single seq=0x3333, W0,W1"]
            Entry3["pos=2, local=0xD → Multi: seq=0x4444→W0, seq=0x5555→W1"]
        end
        
        subgraph "Reverse Lookup - DashMap"
            W0Blocks["W0: 0x1111→pos=0, 0x3333→pos=1, 0x4444→pos=2"]
            W1Blocks["W1: 0x1111→pos=0, 0x3333→pos=1, 0x5555→pos=2"]
            W2Blocks["W2: 0x2222→pos=0"]
        end
    end
    
    subgraph "Jump Optimization Example"
        Query["Query: b0, b1, b2, ..., b63, b64, ..., b127"]
        Jump1["Check pos=0"]
        Jump2["Jump to pos=64"]
        Jump3["Jump to pos=128"]
        Scan["Scan back if workers drop"]
        
        Query --> Jump1 --> Jump2 --> Jump3
        Jump2 -.->|"workers dropped?"| Scan
    end
```


### 多层存储匹配流程

```mermaid
flowchart TD
    Start([find_matches]) --> InputBlockHashes[Input: Local Block Hashes]
    InputBlockHashes --> InitCandidates[Initialize Candidates<br/>All Workers]
    
    InitCandidates --> CheckDevice{Query Device<br/>Index?}
    CheckDevice -->|Yes| QueryDevice[Query Device Index]
    CheckDevice -->|No| CheckHost
    
    QueryDevice --> TraverseDevice[Traverse Device Tree]
    TraverseDevice --> MatchDevice[Match Device Blocks]
    MatchDevice --> RecordDevice[Record Device Overlap<br/>per Worker]
    
    RecordDevice --> CheckHost{Query Host<br/>Index?}
    CheckHost -->|Yes| QueryHost[Query Host Index]
    CheckHost -->|No| CheckDisk
    
    QueryHost --> MatchHost[Match Host Blocks]
    MatchHost --> RecordHost[Record Host Overlap<br/>per Worker]
    
    RecordHost --> CheckDisk{Query Disk<br/>Index?}
    CheckDisk -->|Yes| QueryDisk[Query Disk Index]
    CheckDisk -->|No| Combine
    
    QueryDisk --> MatchDisk[Match Disk Blocks]
    MatchDisk --> RecordDisk[Record Disk Overlap<br/>per Worker]
    
    RecordDisk --> Combine[Combine Results]
    
    Combine --> ForEachWorker[For Each Worker]
    ForEachWorker --> CalcEffective[Calculate Effective Overlap]
    
    CalcEffective --> DeviceWeight[Device × 1.0]
    CalcEffective --> HostWeight[Host × host_weight]
    CalcEffective --> DiskWeight[Disk × disk_weight]
    
    DeviceWeight --> SumEffective[Sum Effective Overlap]
    HostWeight --> SumEffective
    DiskWeight --> SumEffective
    
    SumEffective --> CalcTokens[Calculate Cached Tokens<br/>overlap × block_size]
    
    CalcTokens --> NextWorker{More Workers?}
    NextWorker -->|Yes| ForEachWorker
    NextWorker -->|No| ReturnResults
    
    ReturnResults[Return Results] --> Output[Output:<br/>effective_overlap_blocks<br/>cached_tokens per worker]
    Output --> Done([Complete])
```

### 2. Active Load Tracker (活跃负载跟踪器)

**位置**: `lib/kv-router/src/sequences/`

**核心职责**:
- 跟踪每个 worker 的活跃 prefill tokens
- 跟踪每个 worker 的活跃 decode blocks
- 跟踪每个 worker 的活跃请求数
- 预测新请求的负载影响

**数据结构**:
```rust
WorkerLoadProjection {
    active_prefill_tokens: usize,
    active_decode_blocks: usize,
    active_requests: usize,
}
```

**负载建模**:

#### Prefill Load Modeling
- **默认**: 有效 prefill 负载(未缓存的 prompt tokens)保持全值,直到第一个输出 token
- **AIS 模式** (`--router-prefill-load-model ais`): 使用 AISimulate 预测 prefill 持续时间,基于时间衰减

#### Decode Load Modeling
- 跟踪活跃 KV blocks 和活跃请求数
- 可选启用 `--router-track-output-blocks`: 随生成进度添加占位输出 blocks
- 可选启用 `--router-decode-active-request-weight`: 为每个活跃请求添加 block 等效成本


### 负载跟踪数据流

```mermaid
sequenceDiagram
    participant W as Worker
    participant P as Publisher
    participant T as Load Tracker
    participant R as Router
    
    W->>P: Request Started
    P->>T: add_request(worker_id, prefill_tokens)
    T->>T: Update active_prefill_tokens
    T->>T: Update active_requests
    
    W->>P: Prefill Complete
    P->>T: complete_prefill(worker_id)
    T->>T: Decrease active_prefill_tokens
    T->>T: Increase active_decode_blocks
    
    loop Every Decode Step
        W->>P: Decode Progress
        P->>T: update_decode(worker_id, blocks)
        T->>T: Update active_decode_blocks
    end
    
    W->>P: Request Completed
    P->>T: release_request(worker_id)
    T->>T: Decrease active_decode_blocks
    T->>T: Decrease active_requests
    
    R->>T: get_projections()
    T->>R: worker_loads map
```

### 3. Worker Selector (Worker 选择器)

**位置**: `lib/kv-router/src/scheduling/selector/`

**核心职责**:
- 实现成本计算逻辑
- 过滤不合格的 worker
- 选择成本最低的 worker

**主要 trait**:
```rust
pub trait WorkerSelector<C: WorkerConfigLike> {
    fn required_worker_inputs(&self) -> WorkerInputs;
    
    fn select_worker(
        &self,
        input: WorkerSelectionInput<'_, C>,
    ) -> Result<WorkerSelectionResult, KvSchedulerError>;
}
```

**输入**:
```rust
WorkerSelectionInput<'a, C> {
    workers: &'a HashMap<WorkerId, C>,
    request: &'a SchedulingRequest,
    eligibility: RoutingEligibility<'a>,
    block_size: u32,
}
```

### 4. Local Scheduler (本地调度器)

**位置**: `lib/kv-router/src/scheduling/local.rs`

**核心职责**:
- 协调 KV Cache Index、Active Load Tracker 和 Worker Selector
- 管理请求队列和调度策略
- 处理 worker 配置更新和拓扑变化

**主要结构**:
```rust
pub struct LocalScheduler<P, C, Sel, RF> {
    slots: Arc<ActiveSequencesMultiWorker<P>>,
    queue: Arc<SchedulerQueue<P, C, Sel, RF>>,
    queue_updates: watch::Sender<()>,
    worker_configs: watch::Receiver<HashMap<WorkerId, C>>,
    // ...
}
```

---


### Worker 状态转换

```mermaid
stateDiagram-v2
    [*] --> Idle: Worker Started
    Idle --> Receiving: Request Arrived
    Receiving --> LoadingCache: Load KV Cache
    LoadingCache --> Processing: Cache Ready
    Processing --> Prefilling: Start Prefill
    Prefilling --> Decoding: Prefill Complete
    Decoding --> Generating: Generate Tokens
    Generating --> Completing: EOS or Max Length
    Completing --> EmittingEvents: Emit KV Events
    EmittingEvents --> ReleasingLoad: Release Load
    ReleasingLoad --> Idle: Ready for Next
    
    Prefilling --> UpdatingLoad: Update Prefill Load
    Decoding --> UpdatingDecodeLoad: Update Decode Load
    Generating --> UpdatingOutputLoad: Update Output Blocks
    
    note right of LoadingCache
        Check for cached
        prefix blocks
    end note
    
    note right of EmittingEvents
        Notify router of
        KV cache changes
    end note
```

## 工作流程


### 数据流架构

```mermaid
sequenceDiagram
    participant C as Client
    participant F as Frontend
    participant T as Tokenizer
    participant I as KV Indexer
    participant L as Load Tracker
    participant S as Selector
    participant W as Worker
    
    C->>F: Request
    F->>T: Tokenize & Normalize
    T->>I: find_matches(block_hashes)
    I-->>T: overlap_scores per worker
    
    T->>L: get_worker_loads()
    L-->>T: load_projections per worker
    
    T->>S: select_worker(overlap, loads)
    
    loop For each eligible worker
        S->>S: compute_cost(worker)
        S->>S: adjusted_prefill = max(0, active + incoming - overlap)
        S->>S: decode_cost = active_decode + incoming
        S->>S: total_cost = prefill + decode + request_cost
    end
    
    S->>S: pick lowest cost worker
    S-->>F: selected_worker
    
    F->>W: Route request
    W->>I: KV lifecycle events
    W->>L: Load updates
    W-->>C: Response
```


### 请求处理完整流程

```mermaid
flowchart TD
    Start(["Client Request"]) --> Tokenize["Tokenize & Normalize"]
    Tokenize --> Hash["Compute Block Hashes"]
    
    Hash --> QueryIndex{"Query KV Index"}
    QueryIndex --> DeviceOverlap["Get Device Overlap"]
    QueryIndex --> HostOverlap["Get Host Overlap"]
    QueryIndex --> DiskOverlap["Get Disk Overlap"]
    
    DeviceOverlap --> CombineOverlap["Combine Overlaps with Weights"]
    HostOverlap --> CombineOverlap
    DiskOverlap --> CombineOverlap
    
    CombineOverlap --> QueryLoads{"Query Load Tracker"}
    QueryLoads --> GetPrefill["Get Active Prefill"]
    QueryLoads --> GetDecode["Get Active Decode"]
    QueryLoads --> GetRequests["Get Active Requests"]
    
    GetPrefill --> FilterWorkers{"Filter Workers"}
    GetDecode --> FilterWorkers
    GetRequests --> FilterWorkers
    
    FilterWorkers -->|"Eligible Workers"| ComputeCost["Compute Cost per Worker"]
    FilterWorkers -->|Ineligible| Skip["Skip Worker"]
    
    ComputeCost --> CalcPrefill["adjusted_prefill = max 0, active + incoming - overlap"]
    ComputeCost --> CalcDecode["potential_decode = active + incoming"]
    ComputeCost --> CalcRequest["request_cost = weight × active_requests"]
    
    CalcPrefill --> SumCost["total_cost = prefill + decode + request"]
    CalcDecode --> SumCost
    CalcRequest --> SumCost
    
    SumCost --> CheckTrace{"Trace Enabled?"}
    CheckTrace -->|Yes| RecordTrace["Record per-worker costs"]
    CheckTrace -->|No| SelectWorker
    
    RecordTrace --> SelectWorker{"Select Worker"}
    SelectWorker -->|"Temperature > 0"| Softmax["Softmax Sampling"]
    SelectWorker -->|"Temperature = 0"| Greedy["Greedy Selection"]
    
    Softmax --> UpdateLoads["Update Load Tracker"]
    Greedy --> UpdateLoads
    
    UpdateLoads --> SubscribeEvents["Subscribe to KV Events"]
    SubscribeEvents --> RouteRequest["Route Request to Worker"]
    RouteRequest --> WorkerProcess["Worker Processes Request"]
    
    WorkerProcess --> EmitEvents["Emit KV Lifecycle Events"]
    WorkerProcess --> UpdateLoadState["Update Load State"]
    WorkerProcess --> GenerateResponse["Generate Response"]
    
    EmitEvents --> UpdateIndex["Update KV Index"]
    UpdateLoadState --> UpdateTracker["Update Load Tracker"]
    
    GenerateResponse --> Response(["Response to Client"])
```


### 请求生命周期

```mermaid
stateDiagram-v2
    [*] --> Received: Client Request
    Received --> Tokenizing: Tokenize & Normalize
    Tokenizing --> Indexing: Query KV Index
    Indexing --> LoadTracking: Query Load Tracker
    LoadTracking --> Filtering: Filter Workers
    Filtering --> Scoring: Score Eligible Workers
    Scoring --> Selection: Select Worker
    Selection --> Routing: Route Request
    Routing --> Processing: Worker Processes
    Processing --> EmittingEvents: Emit KV Events
    EmittingEvents --> UpdatingIndex: Update KV Index
    UpdatingIndex --> UpdatingLoad: Update Load Tracker
    UpdatingLoad --> GeneratingResponse: Generate Response
    GeneratingResponse --> [*]: Response to Client
    
    note right of Indexing
        Find prefix matches
        across Device, Host,
        and Disk tiers
    end note
    
    note right of Scoring
        Compute cost based on
        cache overlap and
        active load
    end note
    
    note right of EmittingEvents
        Store/Remove/Clear
        KV cache lifecycle
        events
    end note
```


### 请求数据流

```mermaid
graph LR
    A[Client Request] -->|HTTP/gRPC| B[Frontend]
    B -->|Tokenize| C[Token Sequence]
    C -->|Hash Blocks| D[Block Hashes]
    
    D -->|Query| E[KV Indexer]
    E -->|Overlap Scores| F[Router]
    
    D -->|Load Query| G[Load Tracker]
    G -->|Load Projections| F
    
    F -->|Cost Calculation| H[Worker Selector]
    H -->|Selected Worker| I[Route Request]
    
    I -->|Forward| J[Worker]
    J -->|Process| K[Response]
    K -->|HTTP/gRPC| A
    
    J -->|KV Events| E
    J -->|Load Updates| G
    
    style E fill:#4ecdc4
    style G fill:#45b7d1
    style H fill:#96ceb4
```


### 1. 请求接收和预处理

```rust
// 1. Tokenize and normalize
let token_seq = tokenize_and_normalize(request.prompt);
let block_hashes = compute_block_hashes(&token_seq, block_size);

// 2. Query KV Cache Index for overlap
let overlap_scores = kv_indexer.find_matches(&block_hashes);
let tier_overlap_blocks = compute_tier_overlap(&overlap_scores);

// 3. Query Active Load Tracker
let worker_loads = active_load_tracker.get_projections();
```

### 2. 重叠度计算

**位置**: `lib/kv-router/src/scheduling/overlap.rs`

```rust
// 计算多层存储的有效重叠
effective_overlap_blocks = device_overlap_blocks
    + host_pinned_overlap_blocks * host_cache_hit_weight
    + disk_overlap_blocks * disk_cache_hit_weight;

// 转换为缓存 tokens
cached_tokens = effective_overlap_blocks * block_size;
```

**多层存储权重**:
- Device (GPU): 1.0
- Host-Pinned (CPU): `config.host_cache_hit_weight` (默认 0.5)
- Disk/External: `config.disk_cache_hit_weight` (默认 0.3)


### 3. Worker 过滤

**位置**: `lib/kv-router/src/scheduling/filter.rs`

**过滤条件**:
- Request allow-lists (允许的 worker 列表)
- Exact pins (精确绑定)
- DP-rank bounds (数据并行 rank 边界)
- Required taints (必需的 taints)
- Busy-threshold overload state (忙碌阈值过载状态)

### 4. 成本计算

**位置**: `lib/kv-router/src/scheduling/selector/policy.rs`

详见下一节 [成本计算模型](#成本计算模型)。


### Worker 选择决策流程

```mermaid
flowchart TD
    Start(["Start Selection"]) --> GetWorkers["Get All Workers"]
    GetWorkers --> ApplyFilters["Apply Filters"]
    
    ApplyFilters --> Filter1{"Allow-list Check"}
    Filter1 -->|Pass| Filter2{"Exact Pin Check"}
    Filter1 -->|Fail| Exclude1["Exclude Worker"]
    
    Filter2 -->|Pass| Filter3{"DP Rank Bounds"}
    Filter2 -->|Fail| Exclude2["Exclude Worker"]
    
    Filter3 -->|Pass| Filter4{"Required Taints"}
    Filter3 -->|Fail| Exclude3["Exclude Worker"]
    
    Filter4 -->|Pass| Filter5{"Busy Threshold"}
    Filter4 -->|Fail| Exclude4["Exclude Worker"]
    
    Filter5 -->|Pass| Eligible["Eligible Worker"]
    Filter5 -->|Fail| Exclude5["Exclude Worker"]
    
    Eligible --> ComputeOverlap["Compute Overlap Score"]
    ComputeOverlap --> DeviceHits["Device Hits × 1.0"]
    ComputeOverlap --> HostHits["Host Hits × Weight"]
    ComputeOverlap --> DiskHits["Disk Hits × Weight"]
    
    DeviceHits --> SumOverlap["Sum Effective Overlap"]
    HostHits --> SumOverlap
    DiskHits --> SumOverlap
    
    SumOverlap --> ComputeCosts["Compute Costs"]
    
    ComputeCosts --> PrefillCost["Prefill Cost = max 0, active + new - overlap"]
    ComputeCosts --> DecodeCost["Decode Cost = active_decode + new_decode"]
    ComputeCosts --> RequestCost["Request Cost = weight × active_requests"]
    
    PrefillCost --> TotalCost["Total Cost = prefill + decode + request"]
    DecodeCost --> TotalCost
    RequestCost --> TotalCost
    
    TotalCost --> CheckAffinity{"Affinity Target?"}
    CheckAffinity -->|Yes| PreferAffinity["Prefer Affinity Worker"]
    CheckAffinity -->|No| CheckTemperature
    
    PreferAffinity --> CheckTemperature{"Temperature > 0?"}
    CheckTemperature -->|Yes| SoftmaxSelect["Softmax Sampling"]
    CheckTemperature -->|No| MinCost["Select Min Cost"]
    
    SoftmaxSelect --> ReturnWorker(["Return Selected Worker"])
    MinCost --> ReturnWorker
```

### 5. Worker 选择

```rust
// 1. 计算所有合格 worker 的成本
let candidates: Vec<CandidateData> = eligible_workers
    .iter()
    .map(|worker| compute_candidate_data(worker, request))
    .collect();

// 2. 应用 worker selection policy
let scored_candidates = policy.score_candidates(&candidates);

// 3. 选择成本最低的 worker
let selected_worker = if router_temperature > 0 {
    // Softmax sampling with temperature
    softmax_sample(&scored_candidates, router_temperature)
} else {
    // Greedy selection
    scored_candidates.iter().min_by_key(|c| c.cost).worker
};
```

### 6. 负载更新

```rust
// 1. 更新 Active Load Tracker
active_load_tracker.add_request(
    selected_worker,
    request_id,
    prompt_tokens,
    expected_output_tokens,
);

// 2. 订阅 worker 的 KV lifecycle events
kv_indexer.subscribe_worker_events(selected_worker);

// 3. 当请求完成时释放负载
active_load_tracker.release_request(selected_worker, request_id);
```

---


### KV Cache 事件处理流程

```mermaid
flowchart TD
    Start([Worker KV Event]) --> EventType{Event Type?}
    
    EventType -->|Store| HandleStore[Handle Store Event]
    EventType -->|Remove| HandleRemove[Handle Remove Event]
    EventType -->|Clear| HandleClear[Handle Clear Event]
    
    HandleStore --> ExtractBlocks[Extract Block Hashes]
    ExtractBlocks --> FindParent[Find Parent Node]
    FindParent --> TraverseTree[Traverse/Create Tree Path]
    
    TraverseTree --> ForEachBlock[For Each Block]
    ForEachBlock --> CreateNode{Node Exists?}
    CreateNode -->|No| CreateNew[Create New Node]
    CreateNode -->|Yes| UpdateNode[Update Node]
    
    CreateNew --> AddWorker[Add Worker to Node]
    UpdateNode --> AddWorker
    AddWorker --> UpdateLookup[Update Lookup Table]
    UpdateLookup --> NextBlock{More Blocks?}
    NextBlock -->|Yes| ForEachBlock
    NextBlock -->|No| DoneStore([Store Complete])
    
    HandleRemove --> LookupBlocks[Lookup Block Positions]
    LookupBlocks --> ForEachHash[For Each Hash]
    ForEachHash --> FindNode[Find Node]
    FindNode --> RemoveWorker[Remove Worker from Node]
    
    RemoveWorker --> CheckOwnership{Node Still<br/>Has Owners?}
    CheckOwnership -->|Yes| NextHash{More Hashes?}
    CheckOwnership -->|No| DetachNode[Detach Node]
    
    DetachNode --> CleanupChildren[Cleanup Children]
    CleanupChildren --> UpdateLookup2[Update Lookup]
    UpdateLookup2 --> NextHash
    
    NextHash -->|Yes| ForEachHash
    NextHash -->|No| DoneRemove([Remove Complete])
    
    HandleClear --> GetWorkerBlocks[Get All Worker Blocks]
    GetWorkerBlocks --> RemoveAll[Remove All Blocks]
    RemoveAll --> CleanupLookup[Cleanup Lookup]
    CleanupLookup --> DoneClear([Clear Complete])
```


### KV Cache 事件数据流

```mermaid
graph TB
    subgraph "Worker Side"
        Engine[Inference Engine]
        Publisher[Event Publisher]
    end
    
    subgraph "Transport Layer"
        NATS[NATS / Redis / ZMQ]
    end
    
    subgraph "Router Side"
        Subscriber[Event Subscriber]
        Dispatcher[Event Dispatcher]
        
        subgraph "Indexer Threads"
            Thread0[Thread 0<br/>Worker 0, 3]
            Thread1[Thread 1<br/>Worker 1, 4]
            Thread2[Thread 2<br/>Worker 2, 5]
        end
        
        Index[KV Index]
    end
    
    Engine -->|KV Created/Removed| Publisher
    Publisher -->|Publish| NATS
    NATS -->|Subscribe| Subscriber
    Subscriber --> Dispatcher
    
    Dispatcher -->|Sticky Route| Thread0
    Dispatcher -->|Sticky Route| Thread1
    Dispatcher -->|Sticky Route| Thread2
    
    Thread0 -->|Update| Index
    Thread1 -->|Update| Index
    Thread2 -->|Update| Index
    
    style NATS fill:#ffe66d
    style Index fill:#4ecdc4
```

## 成本计算模型


### 成本计算详细流程

```mermaid
flowchart TD
    Start(["Compute Worker Cost"]) --> GetInputs["Get Input Parameters"]
    
    GetInputs --> ActivePrefill["active_prefill_tokens"]
    GetInputs --> IncomingPrompt["incoming_prompt_tokens"]
    GetInputs --> DeviceOverlap["device_overlap_blocks"]
    GetInputs --> HostOverlap["host_overlap_blocks"]
    GetInputs --> DiskOverlap["disk_overlap_blocks"]
    GetInputs --> ActiveDecode["active_decode_blocks"]
    GetInputs --> IncomingDecode["incoming_decode_blocks"]
    GetInputs --> ActiveRequests["active_requests"]
    
    DeviceOverlap --> CalcOverlapCredit["Calculate Overlap Credit"]
    HostOverlap --> CalcOverlapCredit
    DiskOverlap --> CalcOverlapCredit
    
    CalcOverlapCredit --> DeviceCredit["device_overlap × 1.0"]
    CalcOverlapCredit --> HostCredit["host_overlap × host_weight"]
    CalcOverlapCredit --> DiskCredit["disk_overlap × disk_weight"]
    
    DeviceCredit --> SumCredit["overlap_credit = device + host + disk"]
    HostCredit --> SumCredit
    DiskCredit --> SumCredit
    
    SumCredit --> CheckDecay{"Credit Decay Enabled?"}
    CheckDecay -->|Yes| ApplyDecay["Apply Decay Factor"]
    CheckDecay -->|No| CalcPrefill
    
    ApplyDecay --> CalcDecay["decay = max 0, 1 - excess/threshold"]
    CalcDecay --> AdjustDeviceCredit["device_credit × decay"]
    AdjustDeviceCredit --> CalcPrefill
    
    CalcPrefill["Calculate Prefill Cost"] --> ConvertToBlocks["Convert to Blocks: tokens / block_size"]
    ConvertToBlocks --> RawPrefill["raw_prefill = active + incoming"]
    RawPrefill --> AdjustedPrefill["adjusted_prefill = max 0, raw - credit"]
    AdjustedPrefill --> ScalePrefill["prefill_cost = scale × adjusted_prefill"]
    
    ScalePrefill --> CalcDecode["Calculate Decode Cost"]
    CalcDecode --> PotentialDecode["potential_decode = active + incoming"]
    PotentialDecode --> CheckOutputTrack{"Track Output Blocks?"}
    
    CheckOutputTrack -->|Yes| AddOutput["Add Output Blocks with Progress Weight"]
    CheckOutputTrack -->|No| DecodeCost["decode_cost = potential_decode"]
    
    AddOutput --> DecodeCost
    
    DecodeCost --> CalcRequest["Calculate Request Cost"]
    CalcRequest --> RequestCost["request_cost = weight × active_requests"]
    
    RequestCost --> SumTotal["Total Cost = prefill + decode + request"]
    SumTotal --> ReturnCost(["Return Cost"])
```

### 核心公式

```
raw_prefill_blocks = active_prefill_blocks + incoming_prompt_blocks
adjusted_prefill_blocks = max(0, raw_prefill_blocks - overlap_credit_blocks)
potential_decode_blocks = active_decode_blocks + incoming_active_blocks
active_request_blocks = decode_active_request_weight * active_requests

cost = prefill_load_scale * adjusted_prefill_blocks 
     + potential_decode_blocks 
     + active_request_blocks
```

### 各项详解

#### 1. Prefill Cost (Prefill 成本)

```
adjusted_prefill_blocks = max(0, 
    active_prefill_tokens / block_size 
    + incoming_prompt_tokens / block_size 
    - overlap_credit_blocks
)
```

**组成部分**:
- `active_prefill_blocks`: worker 当前正在处理的 prefill tokens(以 block 为单位)
- `incoming_prompt_blocks`: 新请求的 prompt tokens(以 block 为单位)
- `overlap_credit_blocks`: 缓存重叠信用(减少的成本)

**Overlap Credit 计算**:
```
overlap_credit_blocks = device_overlap_blocks
    + host_pinned_overlap_blocks * host_cache_hit_weight
    + disk_overlap_blocks * disk_cache_hit_weight
    + shared_cache_overlap_blocks * shared_cache_weight
```

**Device Overlap Decay**:
```
if overlap_score_credit_decay > 0:
    decay_factor = max(0, 1 - excess_prefill_load / decay_threshold)
    device_overlap_credit *= decay_factor
```

#### 2. Decode Cost (Decode 成本)

```
potential_decode_blocks = active_decode_blocks + incoming_active_blocks
```

**组成部分**:
- `active_decode_blocks`: worker 当前活跃的 decode KV blocks
- `incoming_active_blocks`: 新请求预计使用的 decode blocks

**可选增强**:
- `--router-track-output-blocks`: 跟踪输出 blocks,随生成进度增加
- Expected OSL (Output Sequence Length): 基于预期输出长度的分数权重

#### 3. Active Request Cost (活跃请求成本)

```
active_request_blocks = decode_active_request_weight * active_requests
```

**说明**:
- `decode_active_request_weight`: 默认为 0(可选)
- 启用后,每个活跃请求添加 block 等效成本
- 适用于 decode 延迟对 batch size 敏感的场景

### 成本示例

**场景 1: Worker A (缓存热)**
```
active_prefill_blocks = 10
incoming_prompt_blocks = 20
device_overlap_blocks = 15 (75% 缓存命中)
host_cache_hit_weight = 0.5
overlap_credit_blocks = 15 * 1.0 = 15

adjusted_prefill_blocks = max(0, 10 + 20 - 15) = 15
active_decode_blocks = 5
incoming_active_blocks = 2
potential_decode_blocks = 5 + 2 = 7
active_requests = 3
decode_active_request_weight = 0 (默认)

cost = 1.0 * 15 + 7 + 0 = 22
```

**场景 2: Worker B (缓存冷)**
```
active_prefill_blocks = 5
incoming_prompt_blocks = 20
device_overlap_blocks = 0 (无缓存命中)
overlap_credit_blocks = 0

adjusted_prefill_blocks = max(0, 5 + 20 - 0) = 25
active_decode_blocks = 3
incoming_active_blocks = 2
potential_decode_blocks = 3 + 2 = 5
active_requests = 2

cost = 1.0 * 25 + 5 + 0 = 30
```

**结果**: 选择 Worker A (成本 22 < 30),即使它的活跃负载更高,因为缓存命中显著降低了 prefill 成本。

---


### 缓存命中率影响

```mermaid
graph TD
    subgraph "Low Cache Hit Rate"
        L1[Worker A: 0% Hit]
        L2[Prefill Cost: High]
        L3[Total Cost: High]
        L1 --> L2 --> L3
    end
    
    subgraph "Medium Cache Hit Rate"
        M1[Worker B: 50% Hit]
        M2[Prefill Cost: Medium]
        M3[Total Cost: Medium]
        M1 --> M2 --> M3
    end
    
    subgraph "High Cache Hit Rate"
        H1[Worker C: 90% Hit]
        H2[Prefill Cost: Low]
        H3[Total Cost: Low]
        H1 --> H2 --> H3
    end
    
    L3 -.->|Compare| Decision{Select Worker}
    M3 -.->|Compare| Decision
    H3 -.->|Compare| Decision
    
    Decision -->|Lowest Cost| H1
    
    style H3 fill:#4ecdc4
    style M3 fill:#ffe66d
    style L3 fill:#ff6b6b
```

## 数据结构和索引


### 索引器性能对比

```mermaid
graph LR
    subgraph "RadixTree Performance"
        RT_Store[store_blocks: O N]
        RT_Remove[remove_blocks: O N]
        RT_Find[find_matches: O D×W]
    end
    
    subgraph "PositionalIndexer Performance"
        PI_Store[store_blocks: O N]
        PI_Remove[remove_blocks: O N]
        PI_Find[find_matches: O D/J]
    end
    
    subgraph "ConcurrentRadixTreeCompressed"
        CRTC_Store[Concurrent Writes<br/>per Worker Thread]
        CRTC_Remove[Concurrent Removes<br/>per Worker Thread]
        CRTC_Find[Concurrent Reads<br/>Inline]
    end
    
    RT_Store -.->|Single Threaded| RT_Find
    PI_Store -.->|Jump Optimization| PI_Find
    CRTC_Store -.->|High Throughput| CRTC_Find
    
    style RT_Find fill:#ff6b6b
    style PI_Find fill:#4ecdc4
    style CRTC_Find fill:#45b7d1
```

### Block Hash 标识符

#### 1. LocalBlockHash (u64)
```
Block at position 5: tokens [101, 102, 103, ...]
LocalBlockHash = hash(tokens) = 0xABCD1234
```
**用途**: 标识单个 block 的内容,独立于上下文

#### 2. ExternalSequenceBlockHash (u64)
```
Sequence A: [block0, block1, block2]
block2 in A: seq_hash = hash(hash(hash(block0) || block1) || block2) = 0x1111
```
**用途**: 唯一标识 block 在特定序列历史中的位置

**计算**: `seq_hash[i] = hash(seq_hash[i-1] || local_hash[i])`

#### 3. WorkerWithDpRank
```rust
WorkerWithDpRank {
    worker_id: WorkerId,
    dp_rank: DpRank,
}
```
**用途**: 标识哪个 worker(及其数据并行 rank)缓存了该 block

### 索引器选择指南

```
Start
  │
  ├─ Single worker or worker-side local index?
  │      └─ RadixTree (非并发)
  │
  ├─ < ~1000 workers, no sharding needed?
  │      └─ ThreadPoolIndexer<ConcurrentRadixTreeCompressed>
  │
  └─ ≥ ~1000 workers or need one-shard lookups?
         │
         ├─ Need approximate pruning?
         │      └─ ThreadPoolIndexer<CRTC>
         │
         └─ Need routing-correct sharding?
                └─ BranchShardedIndexer<CRTC>
```

### 性能指标

**吞吐量**:
- 组合吞吐量: **> 10 million events + requests per second**
- p99 延迟: **< 10 microseconds**

**内存开销**:
- RadixTree: 较高 (Rc/Arc overhead per node)
- PositionalIndexer: 较低 (flat entries)
- ConcurrentRadixTreeCompressed: 中等 (Arc nodes + compressed edges)

---

## 配置和调优


### 配置优先级

```mermaid
graph TB
    subgraph "Configuration Hierarchy"
        Default[Default Values<br/>Lowest Priority]
        Frontend[Frontend Config<br/>--router-mode kv]
        WorkerSet[Worker Set Config<br/>Model Deployment Card]
        Request[Request Override<br/>router_config_override]
    end
    
    Default -->|Override| Frontend
    Frontend -->|Override| WorkerSet
    WorkerSet -->|Override| Request
    
    Request --> Final[Final Configuration<br/>Highest Priority]
    
    style Default fill:#e0e0e0
    style Frontend fill:#b0b0b0
    style WorkerSet fill:#808080
    style Request fill:#4ecdc4
    style Final fill:#96ceb4
```

### 启用 KV-Aware Routing

```bash
# 基本启用
python -m dynamo.frontend --router-mode kv

# 禁用 KV events (仅基于负载)
python -m dynamo.frontend --router-mode kv --no-router-kv-events
```


### 路由模式配置

```mermaid
graph TD
    RouterMode{--router-mode}
    
    RouterMode -->|kv| KV[KV-Aware Routing]
    RouterMode -->|round-robin| RR[Round Robin]
    RouterMode -->|random| Random[Random]
    RouterMode -->|power-of-two| POT[Power of Two]
    RouterMode -->|least-loaded| LL[Least Loaded]
    RouterMode -->|device-aware-weighted| DAW[Device Aware Weighted]
    RouterMode -->|direct| Direct[Direct Routing]
    
    KV --> KVConfig[Requires:<br/>KV Events<br/>Load Tracking]
    KV --> KVFeatures[Features:<br/>Cache Locality<br/>Load Balance]
    
    RR --> RRConfig[Simple:<br/>No State]
    RR --> RRFeatures[Use Case:<br/>Baseline Testing]
    
    LL --> LLConfig[Requires:<br/>Load Tracking]
    LL --> LLFeatures[Use Case:<br/>General Load Balance]
    
    style KV fill:#4ecdc4
    style KVConfig fill:#ffe66d
    style KVFeatures fill:#96ceb4
```

### 关键配置参数

#### 路由模式
```bash
--router-mode kv                    # KV-aware routing
--router-mode round-robin           # 轮询
--router-mode random                # 随机
--router-mode power-of-two          # 两次选择
--router-mode least-loaded          # 最少负载
--router-mode device-aware-weighted # 设备感知加权
```

#### Prefill Load Model
```bash
--router-prefill-load-model default  # 静态计数直到第一个输出 token
--router-prefill-load-model ais      # AISimulate 时间衰减模型
```

#### Decode Load Tracking
```bash
--router-track-output-blocks              # 跟踪输出 blocks
--router-decode-active-request-weight 0.5 # 每个活跃请求的 block 等效成本
```

#### Cache Hit Weights
```bash
--host-cache-hit-weight 0.5    # Host-pinned 缓存权重
--disk-cache-hit-weight 0.3    # Disk 缓存权重
--shared-cache-weight 0.8      # Shared cache 权重
```

#### Router Temperature
```bash
--router-temperature 0.0  # Greedy selection (默认)
--router-temperature 0.5  # Softmax sampling with temperature
```

### 调优建议

#### 场景 1: 高缓存命中率
```bash
# 增加缓存重叠的权重
--host-cache-hit-weight 0.7
--disk-cache-hit-weight 0.5
--overlap-score-credit-decay 0.0  # 禁用衰减
```

#### 场景 2: 负载均衡优先
```bash
# 减少缓存影响,增加负载影响
--host-cache-hit-weight 0.3
--disk-cache-hit-weight 0.2
--router-decode-active-request-weight 1.0
--prefill-load-scale 1.5
```

#### 场景 3: 大规模集群 (>1000 workers)
```bash
# 使用分支分片索引器
--indexer-type branch-sharded
--branch-shard-count 16
```

#### 场景 4: 低延迟优先
```bash
# 禁用高级负载建模
--router-prefill-load-model default
--no-router-track-output-blocks
--router-temperature 0.0
```

### Worker 配置一致性

**Worker Set 定义**:
- 相同 namespace, component, endpoint, model, worker type
- 第一个有效的 model deployment card 保留配置
- 不同 MDC checksum 的 replica 不接收流量

**配置替换规则**:
- Worker set 配置**替换**(而非合并)Frontend 配置
- 省略的设置使用默认值,而非继承 Frontend 值

### 监控和调试

#### 启用 Selection Trace
```bash
--selection-trace-enabled
--selection-trace-output /tmp/routing-trace.json
```

#### Prometheus Metrics
```
# KV Indexer 指标
kv_indexer_find_matches_duration_seconds
kv_indexer_store_blocks_duration_seconds
kv_indexer_remove_blocks_duration_seconds

# Router 指标
router_selection_cost_total
router_selection_cache_overlap_blocks
router_selection_active_load_blocks

# Worker 指标
worker_active_prefill_tokens
worker_active_decode_blocks
worker_active_requests
```

---


## 总结

KV-Aware Routing 通过以下机制实现高效的 LLM 推理路由:

1. **多层 KV Cache 索引**: 跟踪 Device、Host-Pinned、Disk 和 External 存储的缓存状态
2. **活跃负载建模**: 实时跟踪和预测 prefill、decode 和活跃请求负载
3. **综合成本计算**: 结合缓存重叠和活跃负载,选择成本最低的 worker
4. **灵活的配置**: 支持多种路由模式、负载模型和调优参数
5. **高性能实现**: 使用并发数据结构和优化算法,实现 >10M ops/sec 和 <10μs p99 延迟

通过合理使用 KV-Aware Routing,可以显著减少重复计算,提高系统吞吐量,同时保持负载均衡。
