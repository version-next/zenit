# zenit perf baselines

Phase 0 录入的 perf 基线。每个 phase 完成时跑一次并 diff，作为 CI gate。

## 跑

```sh
zig build bench                                  # 全部，输出表格到 stdout
zig build bench -- reactive                      # 过滤名字包含 reactive 的
zig build bench -- json=src/bench/baselines/<phase>.json   # 输出 JSON
```

## CI gate

`scripts/check_bench_regression.sh <baseline.json> <current.json>` 比较两份
JSON，`min_ns` 退步 > 阈值时先复测，复测仍超标则退出非 0 阻止 merge。
只有新旧结果都低于默认 200ns 噪声地板时才不阻塞；从纳秒级跃迁到
微秒级仍会按真实回归判红。

## 注册新 case

`src/bench/main.zig` 的 `cases` 数组里追加 `BenchCase`。setup/teardown 可选。
body 用 `ctx.blackbox(value)` 防 LLVM dead-code-eliminate。

## Phase 0 基线（首录）

- `reactive_1k_signal_fanout` ~363µs/iter — 1k effect 全订阅同一 signal，set 一次的总开销
- `resource_pool_alloc_release_cycle` ~6 ns/iter — alloc + release，每 64 次推一次 endFrame
- `slotmap_alloc_free_cycle` ~3.5 ns/iter — SlotMap alloc + free 即刻复用

后续 phase 加：
- Phase 1 (reactive 重写)：diamond glitch 0、1k fanout 目标 < 100µs
- Phase 2 (property tree + layout)：10k 节点零脏帧 CPU < 0.5ms
- Phase 3 (拆 Node + paint chunks)：单 signal 改色 → paint < 100µs
- Phase 4 (layer tree)：ScrollArea 60fps 帧时间 < 3ms、transform 动画 paint 重录次数 = 0
- Phase 5 (display IR + 文本 shaping)：draw call < 400、shaping cache 命中率 > 95%
