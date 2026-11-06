---
title: 简单 logger 实现中的常见性能优化
slug: optimize-a-simple-logger
published: 2026-11-02
description: "从一个 logger 的实现出发，了解常见的底层内存优化。"
image: ""
tags: ["性能优化", "内存分配"]
category: "实用"
draft: false
lang: zh-CN
---

## 简述

在低层级高性能计算开发中，常常需要涉及到相当多方面的优化。遗憾的是，很多业务开发是无法接触到，或是无法掌控到这么底层的优化的。

然而，这些优化又非常有趣，而且对于理解底层图景非常有意义。因此，本文将以一个非常简单的 `logger` 实现作为例子，一步步展现常见的基础性能优化手段。

:::tip
性能优化包含很多方面，比如：

- 计算优化：算法、指令级优化（SIMD）、并行化等
- 内存优化：减少堆分配、数据布局（如优化伪共享）等
- IO 优化：批处理、零拷贝、缓存等
- 同步优化：无锁、分片、临界区缩小等

本次 `logger` 实现中的优化将主要围绕内存方向。
:::

## 从 `logger` 接口入手

与之前的所有文章思路类似，我们也同样自顶向下，从接口层开始探索我们需要实现的内容。

### 朴素 `logger` 的接口

考虑我们需要输出下述一段文本：

```text
[2026-11-02 14:05:09.114] [INFO] a message logged
```

那么显然，它对应的函数就类似：

```rust
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Level {
    Trace,
    Debug,
    Info,
    Warn,
    Error,
}

impl Level {
    pub const fn as_str(self) -> &'static str {
        match self {
            Level::Trace => "TRACE",
            Level::Debug => "DEBUG",
            Level::Info => "INFO",
            Level::Warn => "WARN",
            Level::Error => "ERROR",
        }
    }
}

pub struct Logger {
    min_level: Level,
}

impl Logger {
    pub fn new(min_level: Level) -> Self {
        Self { min_level }
    }

    pub fn log(&self, level: Level, timestamp_millis: u64, message: &str) {
        todo!("实现见下文")
    }
}
```

调用的是：

```rust
let logger = Logger::new(Level::Info);
let now: u64 = 1_793_628_309_114;
logger.log(Level::Info, now, "a message logged");
```

:::important
为了简单起见，我们先不加入带参格式化。具体原因留到最后再说。
:::

## 实现最简单 `log` 函数

确定了签名后，我们可以开始实现 `log` 函数的逻辑了。

不难想到，一次 `log` 函数的调用应该包含两步：1. 生成序列化后的字符串；2. 将序列化后字符串输出。

其代码实现类似：

```rust
const DATE_TIME_FORMAT: StaticFormatDescription = time::macros::format_description!(
    "[year]-[month]-[day] [hour]:[minute]:[second].[subsecond digits:3]"
);

impl Logger {
    pub fn log(&self, level: Level, timestamp_millis: u64, message: &str) {
        if self.min_level > level {
            return;
        }

        let formatted_time = Self::format_time(timestamp_millis);
        let formatted_line = Self::format_line(&formatted_time, level, message);

        self._mock_print(&formatted_line);
    }

    fn format_time(timestamp_millis: u64) -> String {
        let offset = UtcOffset::current_local_offset().unwrap_or(UtcOffset::UTC);
        let local =
            OffsetDateTime::from_unix_timestamp_nanos(i128::from(timestamp_millis) * 1_000_000)
                .expect("timestamp is in range")
                .to_offset(offset);

        local
            .format(DATE_TIME_FORMAT)
            .expect("date/time text fits the format")
    }

    fn format_line(formatted_time: &str, level: Level, message: &str) -> String {
        format!("[{}] [{}] {}\n", formatted_time, level.as_str(), message)
    }

    // 实际实现中，在 `print` 位置上被调用的是注入的 sink，
    // 而不是 Logger 自带的某个确定函数，
    // 这样才能实现输出到 console 或文件的可配置性
    fn _mock_print(&self, full_message: &str) {
        let _ = full_message;
    }
}
```

### 解读实现逻辑

上述代码看似比较复杂，实则我们可以只需要抓住一些重点来理解。

比如 `log` 函数的逻辑就是：

```rust
pub fn log(&self, level: Level, timestamp_millis: u64, message: &str) {
    // 1. 日志等级不满足，直接跳过
    // 2. 将时间从整数转换为字符串
    // 3. 将时间字符串、等级字符串、原始信息字符串整合为字符串
    // 4. 输出最终完整字符串
}
```

`format_time` 函数因为是非伪代码看似比较复杂，但是实际上也就一句话：

```rust
fn format_time(timestamp_millis: u64) -> String {
    // 从 u64 时间生成 String
    // （包含获取时区 offset、获取 local，然后格式化）
}
```

## 最简单 `logger` 的性能优化

那么这样一个极简的 `logger` 实现是否性能达到极限了呢？接下来我们将对其进行探究。

### 测量朴素实现的性能

为了方便比对，我们将使用一套 benchmark，同时对我们的实现（`baseline-simple`）与 `spdlog-rs` crate 进行性能测量。以 128 B 典型短负载测试结果如下：

|       类型        |     中位数     |    MAD     |    吞吐     |
| :---------------: | :------------: | :--------: | :---------: |
| `baseline-simple` | 272.6–274.3 ns | 1.5-2.3 ns | ~446 MiB/s  |
|    `spdlog-rs`    |  66.4–66.8 ns  | 0.4–0.7 ns | ~1.79 GiB/s |

可见，我们目前的实现，与高度优化的 `spdlog-rs` 差距非常大。不过，接下来，我们将开始进行优化，以逐渐地逼近乃至超越 `spdlog-rs` 的性能。

### 使用 profile 分析性能瓶颈

为了进行优化，除了靠惊人的注意力以及经验静态分析以外，通过 profile 等方法进行跑测也是非常重要的手段。

我们可以使用 macOS 上自带的 `sample` （或者 Linux 上的 `perf`）进行采样分析。在我的电脑上，关闭核心 `Logger` 函数内联，128B 短日志测试结果（部分）如下：

|     分类      | 时间占比 |
| :-----------: | :------: |
| `format_time` |  55.2%   |
| `format_line` |  40.9%   |
|     剩余      |   3.9%   |

可以发现，核心的开销就在于 `format_time` 和 `format_line` 函数上。因此，我们接下来的优化目标便是这两处核心瓶颈了。

## `format_time` 优化

我们首先优化时间占比最大的时间格式化的部分。

不考虑经验的话，我们可以进一步分析 `format_time` 内部的耗时。把上一版 `format_time` 临时替换成下面几个函数（仍然放在 `impl Logger` 里），就可以分别追踪各阶段的耗时：

```rust
impl Logger {
    #[inline(never)]
    fn format_time(timestamp_millis: u64) -> String {
        let offset = Self::current_offset();
        let local = Self::to_local(timestamp_millis, offset);
        Self::format_datetime(local)
    }

    #[inline(never)]
    fn current_offset() -> UtcOffset {
        UtcOffset::current_local_offset().unwrap_or(UtcOffset::UTC)
    }

    #[inline(never)]
    fn to_local(timestamp_millis: u64, offset: UtcOffset) -> OffsetDateTime {
        OffsetDateTime::from_unix_timestamp_nanos(i128::from(timestamp_millis) * 1_000_000)
            .expect("timestamp is in range")
            .to_offset(offset)
    }

    #[inline(never)]
    fn format_datetime(local: OffsetDateTime) -> String {
        local
            .format(DATE_TIME_FORMAT)
            .expect("date/time text fits the format")
    }
}
```

进而可以得到 `format_time` 内部的耗时分布：

|        阶段        |       函数        | 占比  |
| :----------------: | :---------------: | :---: |
|     取时区偏移     | `current_offset`  | 60.8% |
| 时间 → 23 B String | `format_datetime` | 34.6% |
|     转本地时间     |    `to_local`     | 4.5%  |

不难发现，本地 `offset` 获取与字符串化占了 `format_time` 的最大开销。那么我们该如何优化呢？看起来计算和转换的步骤已经最简了，还能怎么减少步数呢？

### 格式化前缀缓存

这个时候，既然我们无法优化单次调用的固有开销，那么工程上我们可以着眼多次调用的平均情况：想办法 **分类讨论**，拆出冷热路径，热路径尽可能降低开销，只让冷路径进行高开销计算。

那么我们该如何让 `format_time` 在热路径下跳过 `current_offset` 这些大开销计算呢？一个常见的方法是，同一秒内的时间戳不重复计算，而是优先使用缓存中的序列化结果。

不过，显然我们不可能缓存整个时间戳对应的完整结果（比如 `2026-11-02 14:05:09.114`），否则每次都会 cache miss。所以我们应该找一个在高频调用时，相对稳定的 **前缀部分**，通常选直到秒的部分（比如 `2026-11-02 14:05:09`）；而后续的毫秒部分则可以正常地转换并序列化，因为其完全不需要处理时区，也就不会有 `current_offset` 的巨大开销。

其具体实现思路是：

1. 每次尝试 format 时间戳时，先检查缓存中的 `second`。
2. 如果 `second` 与当前时间戳的 `second` 一致，则直接使用对应的 `prefix` 缓存。
3. 如果 `second` 与当前时间戳的 `second` 不一致，再重新进行时区获取，序列化前缀部分，更新缓存。
4. 最后将 `second` 对应的 `prefix` 与 `milli` 对应的 `postfix` 部分组合格式化到一起。

其思路类似：

```rust ins={1-16}
const PREFIX_FORMAT: StaticFormatDescription =
    time::macros::format_description!("[year]-[month]-[day] [hour]:[minute]:[second]");

pub struct FormattedPrefixCache {
    second: u64,
    prefix: String,
}

thread_local! {
    static FORMATTED_PREFIX_CACHE: RefCell<FormattedPrefixCache> = RefCell::new(
        FormattedPrefixCache {
            second: u64::MAX,
            prefix: String::new(),
        }
    );
}
```

然后把它放回 `impl Logger`，只替换 `format_time` 的函数体：

```rust del={3-5} ins={6-25}
impl Logger {
    fn format_time(timestamp_millis: u64) -> String {
        let offset = Self::current_offset();
        let local = Self::to_local(timestamp_millis, offset);
        Self::format_datetime(local)

        let format_prefix = |timestamp_millis: u64| {
            let offset = Self::current_offset();
            let local = Self::to_local(timestamp_millis, offset);
            local
                .format(PREFIX_FORMAT)
                .expect("date/time text fits the format")
        };

        FORMATTED_PREFIX_CACHE.with(|cache| {
            let mut cache = cache.borrow_mut();
            let second = timestamp_millis / 1_000;

            if cache.second != second {
                cache.second = second;
                cache.prefix = format_prefix(timestamp_millis);
            }

            format!("{}.{:03}", cache.prefix, timestamp_millis % 1_000)
        })
    }
}
```

这里用 `u64::MAX` 作为“尚未缓存”的哨兵，避免时间戳恰好落在 `second == 0` 时误命中默认值。

`format_time` 仍然是 `Logger` 的关联函数，所以 `log` 里的 `Self::format_time(...)` 不需要改。

从这一版开始，`format_datetime` 不再被调用；它只服务于前面的 profile 分析，最终实现里可以删掉。

:::tip
理论上来说，当然可以选择更短、有效期更长的前缀缓存，但是当日志的调用频率高到真的需要在意日志的亚微秒级开销时，通常都是一秒内有大量日志调用。此时缓存秒级前缀所带来的收益就已经足够，分钟级及以上的可行但是会多出一些计算和序列化拼接 `second` 的额外开销。
:::

### 格式化前缀缓存收益

优化之后，我们再重新进行 benchmark 和 profile。

benchmark 结果如下：

|           实现            |       中位数       |      MAD       |      吞吐      | 相对 baseline |
| :-----------------------: | :----------------: | :------------: | :------------: | :-----------: |
|     `baseline-simple`     |   272.6–274.3 ns   |   1.5–2.3 ns   |   ~446 MiB/s   |      1×       |
|        `spdlog-rs`        |    66.4–66.8 ns    |   0.4–0.7 ns   |  ~1.79 GiB/s   |     4.11x     |
| **`cache-prefix-simple`** | **148.3–149.3 ns** | **1.0–1.7 ns** | **~820 MiB/s** |   **1.84×**   |

`format_time` profile 结果如下：

|            阶段             |         函数          |    占比    |
| :-------------------------: | :-------------------: | :--------: |
|   命中：拼接 `prefix.mmm`   | `format!("{}.{:03}")` |   95.1%    |
|       缓存检查 + 借用       |  `format_time` 杂项   |    4.9%    |
| 未命中：计算前缀 + 更新缓存 |    `format_prefix`    | 摊销后 ≈0% |

可见，我们的优化效果是非常显著的，几乎让高频调用下的冷路径平均开销降低到 0。

那么我们是否就已经完成了优化呢？显然，和 `spdlog-rs` 的对比告诉我们并非如此。所以我们还需要继续优化。

### 静态分配格式化时间

上一节的 profile 已经告诉我们，接下来最大的开销来自于 `format!`。那么 `format!` 里的开销来自于哪里呢？

一个简单而不依赖经验的方法，依然是对 `format!` 做 profile。不过它是一个宏而非函数，我们可以用一个简单的非内联 wrapper 来检查它内部的调用：

```rust
#[inline(never)]
fn _format(prefix: &str, millis: u32) -> String {
    format!("{}.{:03}", prefix, millis)
}
```

它的 profile 结果是：

|        阶段        |                   函数/位置                    | 占比  |
| :----------------: | :--------------------------------------------: | :---: |
| 分配 / 扩容 / 释放 | `RawVec::reserve`、`realloc`、`malloc`、`free` | 63.0% |
|   core::fmt 写入   |       `fmt::write`、`String::write_str`        | 23.1% |
|      内存拷贝      |              `memmove` / `memcpy`              | 13.8% |

不难发现，`format!` 在运行时的开销主要来自于堆分配与堆回收，所以重点就在于如何消除堆分配。

消除堆分配（动态分配）通常的做法就是栈分配或静态分配。而要使用这两种分配方法，我们就必须在编译期确定要分配的内存大小（动态分配是堆分配才有的优势）。那么我们是否可以在编译期确定时间格式化所需要的内存大小上界呢？

我们仔细观察我们要输出的时间：

```text
2026-11-02 14:05:09.114
```

不难注意到，我们定义的格式是 **始终等长** 的。我们通过 0 作 padding，让整个格式化结果字符串长度是恒定的 23 B。所以我们可以让 `format_time` 总是使用一个固定大小的切片来格式化：

```rust ins={1-2,6,15-30,42} del={5,41}
const PREFIX_LEN: usize = 19;
const TIME_STR_LEN: usize = 23;

impl Logger {
    fn format_time(timestamp_millis: u64) -> String {
    fn format_time(buffer: &mut [u8], timestamp_millis: u64) {
        let format_prefix = |timestamp_millis: u64| {
            let offset = Self::current_offset();
            let local = Self::to_local(timestamp_millis, offset);
            local
                .format(PREFIX_FORMAT)
                .expect("date/time text fits the format")
        };

        let format_full = |buffer: &mut [u8], prefix: &str, timestamp_millis: u64| {
            debug_assert!(buffer.len() >= TIME_STR_LEN);
            debug_assert!(prefix.len() == PREFIX_LEN);

            // 先复制 19 B 前缀
            buffer[..PREFIX_LEN].copy_from_slice(prefix.as_bytes());

            // 再逐字节写入 ".mmm" 4 B
            let millis = (timestamp_millis % 1_000) as u32;
            buffer[PREFIX_LEN..TIME_STR_LEN].copy_from_slice(&[
                b'.',
                b'0' + (millis / 100) as u8,
                b'0' + ((millis / 10) % 10) as u8,
                b'0' + (millis % 10) as u8,
            ]);
        };

        FORMATTED_PREFIX_CACHE.with(|cache| {
            let mut cache = cache.borrow_mut();
            let second = timestamp_millis / 1_000;

            if cache.second != second {
                cache.second = second;
                cache.prefix = format_prefix(timestamp_millis);
            }

            format!("{}.{:03}", cache.prefix, timestamp_millis % 1_000)
            format_full(buffer, &cache.prefix, timestamp_millis);
        })
    }
}
```

这一版仍然保留 `FormattedPrefixCache` 里的 `prefix: String`：它只在每秒一次的冷路径上分配，热路径已经不再分配。但既然已经知道前缀固定是 19 B，这个 `String` 也可以继续消除。

#### 把前缀缓存也改成定长字节数组

`PREFIX_LEN` 已经在上一节定义，这里只需要把 `prefix` 的类型和初始化换掉，再改 `format_prefix` 的写法：

```rust del={3,11} ins={4,12}
pub struct FormattedPrefixCache {
    second: u64,
    prefix: String,
    prefix: [u8; PREFIX_LEN],
}

thread_local! {
    static FORMATTED_PREFIX_CACHE: RefCell<FormattedPrefixCache> = RefCell::new(
        FormattedPrefixCache {
            second: u64::MAX,
            prefix: String::new(),
            prefix: [0; PREFIX_LEN],
        }
    );
}
```

`format_prefix` 不再返回 `String`，而是直接写入 `cache.prefix` 这块 19 B 的字节数组：

```rust collapse={18-31} ins={10-16,40,44-48} del={3-9,39,43}
impl Logger {
    fn format_time(buffer: &mut [u8], timestamp_millis: u64) {
        let format_prefix = |timestamp_millis: u64| {
            let offset = Self::current_offset();
            let local = Self::to_local(timestamp_millis, offset);
            local
                .format(PREFIX_FORMAT)
                .expect("date/time text fits the format")
        };
        let format_prefix = |mut prefix_buffer: &mut [u8], timestamp_millis: u64| {
            let offset = Self::current_offset();
            let local = Self::to_local(timestamp_millis, offset);
            local
                .format_into(prefix_buffer, PREFIX_FORMAT)
                .expect("date/time text fits the prefix buffer");
        };

        let format_full = |buffer: &mut [u8], prefix: &str, timestamp_millis: u64| {
            debug_assert!(buffer.len() >= TIME_STR_LEN);
            debug_assert!(prefix.len() == PREFIX_LEN);

            buffer[..PREFIX_LEN].copy_from_slice(prefix.as_bytes());

            let millis = (timestamp_millis % 1_000) as u32;
            buffer[PREFIX_LEN..TIME_STR_LEN].copy_from_slice(&[
                b'.',
                b'0' + (millis / 100) as u8,
                b'0' + ((millis / 10) % 10) as u8,
                b'0' + (millis % 10) as u8,
            ]);
        };

        FORMATTED_PREFIX_CACHE.with(|cache| {
            let mut cache = cache.borrow_mut();
            let second = timestamp_millis / 1_000;

            if cache.second != second {
                cache.second = second;
                cache.prefix = format_prefix(timestamp_millis);
                format_prefix(&mut cache.prefix, timestamp_millis);
            }

            format_full(buffer, &cache.prefix, timestamp_millis);
            format_full(
                buffer,
                std::str::from_utf8(&cache.prefix).expect("prefix buffer is valid utf-8"),
                timestamp_millis,
            );
        });
    }
}
```

注意这里 `format_prefix` 的返回值从 `String` 变成了 `()`，所以缓存更新那一行不能再写 `cache.prefix = ...`，而是直接把 `&mut cache.prefix` 传进去原地写入。

### 静态分配格式化时间收益

不多说，直接跑测。

benchmark 结果如下：

|               实现               |       中位数       |      MAD       |      吞吐       | 相对 `baseline-simple` |
| :------------------------------: | :----------------: | :------------: | :-------------: | :--------------------: |
|        `baseline-simple`         |   272.6–274.3 ns   |   1.5–2.3 ns   |   ~446 MiB/s    |           1×           |
|           `spdlog-rs`            |    66.4–66.8 ns    |   0.4–0.7 ns   |   ~1.79 GiB/s   |         4.11x          |
|      `cache-prefix-simple`       |   148.3–149.3 ns   |   1.0–1.7 ns   |   ~820 MiB/s    |         1.84×          |
| **`static-alloc-prefix-simple`** | **114.2–115.2 ns** | **1.1–2.2 ns** | **~1.04 GiB/s** |       **2.38×**        |

`format_time` profile 结果如下：

|            阶段             |                 函数                  |    占比    |
| :-------------------------: | :-----------------------------------: | :--------: |
|  命中：写 `prefix` + .mmm   | `format_full`（内联在 `format_time`） |   68.3%    |
|       缓存检查 + 借用       |          `format_time` 杂项           |   31.7%    |
| 未命中：计算前缀 + 更新缓存 |            `format_prefix`            | 摊销后 ≈0% |

可见，整体的 `log` 时延相比于 `cache-prefix-simple` 版本又下降了 22.9%。而在 `format_time` 内部，杂项的开销（杂项绝对耗时几乎不变）从 4.9% 上升到 31.7% ，说明 `format_full` 为代表的格式化部分开销大幅度降低，约下降 90.6%。

我们也可以重新跑一下 `log` 整体的 profile，看一下现在的 E2E 耗时占比：

|         函数          | 占 `log` 耗时整体 |
| :-------------------: | :---------------: |
| `Logger::format_line` |      ~93.4%       |
|     `format_time`     |       1.4%        |
|      `log` 杂项       |       5.2%        |

通过这份数据，我们可以确定前文的优化是效果卓越的，成功将主要矛盾的 `format_time` 优化到了极低开销，相对耗时约降低 97.5%。

### 关于注入的 `buffer: &mut [u8]`

上文的优化中，我们修改了 `format_time` 的签名，让它接受了一个 `buffer`。那么这势必会修改 `log` 函数使用 `format_time` 的方式。

一个比较简单的办法是，临时构建一个 `buffer` 供 `format_time` 使用：

```rust del={7-8} ins={9-13}
impl Logger {
    pub fn log(&self, level: Level, timestamp_millis: u64, message: &str) {
        if self.min_level > level {
            return;
        }

        let formatted_time = Self::format_time(timestamp_millis);
        let formatted_line = Self::format_line(&formatted_time, level, message);
        let mut time_buffer = [0u8; TIME_STR_LEN];
        Self::format_time(&mut time_buffer, timestamp_millis);
        let formatted_time =
            std::str::from_utf8(&time_buffer).expect("formatted time is valid utf-8");
        let formatted_line = Self::format_line(&formatted_time, level, message);
        self._mock_print(&formatted_line);
    }
}
```

而又因为 `time_buffer` 是一个静态数组（且非常小，只有 23 B），所以它可以毫无压力地分配在栈上，几乎没有 overhead。我们无需担心为了传递 `buffer` 而引入额外的性能损耗。

:::tip
不过想要不每次都分配一段栈也是可以的。不过需要额外封装一个结构体，它存储这个 `time_buffer`，并且是 thread local 的。类似：

```rust
#[derive(Default)]
pub struct TimeFormatter {
    buffer: [u8; TIME_STR_LEN],
}

impl TimeFormatter {
    // 将 buffer 的生命周期与线程单例的 formatter 绑定
    pub fn format(&mut self, timestamp_millis: u64) -> &str {
        Logger::format_time(&mut self.buffer, timestamp_millis);
        std::str::from_utf8(&self.buffer).expect("formatted time is valid utf-8")
    }
}

thread_local! {
    static TIME_FORMATTER: RefCell<TimeFormatter> =
        RefCell::new(TimeFormatter::default());
}

pub fn log(&self, level: Level, timestamp_millis: u64, message: &str) {
    if self.min_level > level {
        return;
    }

    TIME_FORMATTER.with(|formatter| {
        let mut formatter = formatter.borrow_mut();
        let time_str = formatter.format(timestamp_millis);
        let formatted_line = Self::format_line(time_str, level, message);
        self._mock_print(&formatted_line);
    });
}
```

:::

## `format_line` 优化

在上一节，我们已经几乎优化完全了时间相关的格式化部分，现在我们需要开始准备优化耗时榜首的 `format_line` 函数了。

而 `format_line` 函数简直太简单了，我们甚至都不需要怎么看就可以凭借我们上面的经验知道瓶颈在于 `format!` 宏的使用：

```rust "format!" "String"
fn format_line(formatted_time: &str, level: Level, message: &str) -> String {
    format!("[{}] [{}] {}\n", formatted_time, level.as_str(), message)
}
```

根据上文的经验，我们第一想法自然就是直接使用栈分配或静态分配来解决这个格式化的动态分配开销。然而与之前格式化时间完全不同的点是：

所有日志的长度从库开发者视角来看，是不好完全确定内存上界的。一条日志可能有长有短，我们作为库开发者不能强迫用户有一个日志上限（尤其这个上限可能对栈来说过大）。

那么这是否意味着，我们只能举手放弃，宣告我们无法优化 `format_line` 当中的动态分配了呢？

`spdlog-rs` 的测试数据告诉我们，显然并非如此。

### 短日志内联分配

我们依然可以再次参考我们处理格式化前缀缓存时的分类讨论方法。不过不同的是，我们分类的是不同的日志长度：日志的一个良好性质是，相对短的日志占比大，相对长的日志占比小。

因此，我们如果可以优化短日志的性能，那么就可以让所有日志的平均开销显著降低。

也就是说，我们可以设置一个阈值，低于这些阈值的视为 “短日志”，它们因为有一个阈值作为上界，所以可以直接栈分配或者静态分配。而 “长日志” 则容许它们 fallback 到堆分配，因为这种较少的情况的低性能对整体的性能影响较小。

落实到具体设计上，我们可以实现一个 size-aware 的缓冲区 `AdaptiveBuffer`：它对外提供 `AsRef<str>` 读取和 `std::fmt::Write` 写入，内部在固定缓冲放不下时自动切换为堆缓冲。它需要两个变体：固定缓冲与堆缓冲。

我们先实现这两个变体（固定缓冲与堆缓冲）：

```rust
// 默认 128 B 的阈值
const BUFFER_THRESHOLD: usize = 1 << 7;

// 固定容量缓冲区
pub struct FixedBuffer {
    data: [u8; BUFFER_THRESHOLD],
    len: usize,
}

impl Default for FixedBuffer {
    fn default() -> Self {
        Self {
            data: [0; BUFFER_THRESHOLD],
            len: 0,
        }
    }
}

impl FixedBuffer {
    pub const fn capacity(&self) -> usize {
        BUFFER_THRESHOLD
    }

    pub fn len(&self) -> usize {
        self.len
    }

    pub fn is_empty(&self) -> bool {
        self.len == 0
    }

    // 一个快捷的清除函数
    pub fn clear(&mut self) {
        self.len = 0;
    }
}

impl AsRef<str> for FixedBuffer {
    fn as_ref(&self) -> &str {
        std::str::from_utf8(&self.data[..self.len]).expect("data is valid str")
    }
}

impl std::fmt::Write for FixedBuffer {
    fn write_str(&mut self, buf: &str) -> std::fmt::Result {
        // 注意，这里采用减法是为了防止加法溢出
        if buf.len() > self.capacity() - self.len {
            return Err(std::fmt::Error);
        }

        let buf = buf.as_bytes();

        self.data[self.len..self.len + buf.len()].copy_from_slice(buf);
        self.len += buf.len();

        Ok(())
    }
}

// 动态容量缓冲区
pub struct DynamicBuffer {
    data: String,
}

impl DynamicBuffer {
    pub fn with_capacity(cap: usize) -> Self {
        Self {
            data: String::with_capacity(cap),
        }
    }

    pub fn len(&self) -> usize {
        self.data.len()
    }

    pub fn is_empty(&self) -> bool {
        self.data.is_empty()
    }
}

impl AsRef<str> for DynamicBuffer {
    fn as_ref(&self) -> &str {
        &self.data
    }
}

impl std::fmt::Write for DynamicBuffer {
    fn write_str(&mut self, buf: &str) -> std::fmt::Result {
        self.data.push_str(buf);
        Ok(())
    }
}
```

`AdaptiveBuffer` 的完整实现如下：

```rust
enum Variant {
    Fixed(FixedBuffer),
    Dynamic(DynamicBuffer),
}

pub struct AdaptiveBuffer {
    data: Variant,
}

impl AdaptiveBuffer {
    pub fn clear(&mut self) {
        // 如果当前已经是 fixed 版本，可以走快路径快速清除
        if let Variant::Fixed(buf) = &mut self.data {
            buf.clear();
            return;
        }

        self.data = Variant::Fixed(FixedBuffer::default());
    }
}

impl Default for AdaptiveBuffer {
    fn default() -> Self {
        Self {
            data: Variant::Fixed(FixedBuffer::default()),
        }
    }
}

// 读取接口
impl AsRef<str> for AdaptiveBuffer {
    fn as_ref(&self) -> &str {
        match &self.data {
            Variant::Fixed(buf) => buf.as_ref(),
            Variant::Dynamic(buf) => buf.as_ref(),
        }
    }
}

// 写入接口，在固定缓冲放不下时自动切换为堆存储
impl std::fmt::Write for AdaptiveBuffer {
    fn write_str(&mut self, buf: &str) -> std::fmt::Result {
        match &mut self.data {
            Variant::Fixed(fixed) => {
                if fixed.write_str(buf).is_ok() {
                    return Ok(());
                }

                // 固定缓冲放不下：带着已有内容升级为堆缓冲
                let mut dynamic = DynamicBuffer::with_capacity(fixed.len() + buf.len());
                dynamic.write_str(fixed.as_ref())?;
                dynamic.write_str(buf)?;

                self.data = Variant::Dynamic(dynamic);

                Ok(())
            }
            Variant::Dynamic(dynamic) => dynamic.write_str(buf),
        }
    }
}
```

:::note
需要注意的是，我这里的 `AdaptiveBuffer` 的 `clear` 逻辑是，每次清除都必然切回到固定缓冲区，即使已经切换到了动态缓冲区。

这在短日志多、长日志极少的负载下是可以接受的。但是一旦长日志的数量没有那么少，大量的 `write_str` 都会导致开辟为动态缓冲区，则这种 `clear` 的逻辑会导致堆分配和堆回收的成本与相对开销显著上升。

那么就有两种解决方法，一种是提高 `BUFFER_THRESHOLD`，这就得根据用户程序的负载来确定了（可以将 `BUFFER_THRESHOLD` 设置为静态参数 `<const N: usize>`，以供业务层配置）；另外一种是让 `AdaptiveBuffer` 只会升级，不会降级，一旦升级为动态缓冲区则不会在 `clear` 时切换回固定缓冲区。
:::

最后，`format_line` 不再生成 `String`，而是直接写入 `AdaptiveBuffer`：

```rust del={1-3} ins={4-21}
fn format_line(formatted_time: &str, level: Level, message: &str) -> String {
    format!("[{}] [{}] {}\n", formatted_time, level.as_str(), message)
}
fn format_line(
    buffer: &mut AdaptiveBuffer,
    time_buffer: &[u8; TIME_STR_LEN],
    level: Level,
    message: &str,
) {
    let formatted_time =
        std::str::from_utf8(time_buffer).expect("formatted time is valid utf-8");

    writeln!(
        buffer,
        "[{}] [{}] {}",
        formatted_time,
        level.as_str(),
        message
    )
    .expect("adaptive buffer write cannot fail");
}
```

然后更新 `log` 函数：

```rust del={9-12} ins={14-26}
impl Logger {
    pub fn log(&self, level: Level, timestamp_millis: u64, message: &str) {
        if self.min_level > level {
            return;
        }

        let mut time_buffer = [0u8; TIME_STR_LEN];
        Self::format_time(&mut time_buffer, timestamp_millis);
        let formatted_time =
            std::str::from_utf8(&time_buffer).expect("formatted time is valid utf-8");
        let formatted_line = Self::format_line(&formatted_time, level, message);
        self._mock_print(&formatted_line);

        thread_local! {
            static ADAPTIVE_BUFFER: RefCell<AdaptiveBuffer> =
                RefCell::new(AdaptiveBuffer::default());
        }

        ADAPTIVE_BUFFER.with(|buffer| {
            let mut buffer = buffer.borrow_mut();
            buffer.clear(); // 懒清除

            Self::format_line(&mut buffer, &time_buffer, level, message);

            self._mock_print(buffer.as_ref());
        });
    }
}
```

这样，短日志的热路径上就完全没有堆分配了；只有超过 128 B 的长日志才会 fallback 到 `DynamicBuffer`。

### 短日志内联分配收益

接下来我们再进行一下短日志效果的测试。

benchmark 结果为：

|             实现             |      中位数      |      MAD       |      吞吐       | 相对 `baseline-simple` |
| :--------------------------: | :--------------: | :------------: | :-------------: | :--------------------: |
|      `baseline-simple`       |  272.6–274.3 ns  |   1.5–2.3 ns   |   ~446 MiB/s    |           1×           |
|         `spdlog-rs`          |   66.4–66.8 ns   |   0.4–0.7 ns   |   ~1.79 GiB/s   |         4.11×          |
|    `cache-prefix-simple`     |  148.3–149.3 ns  |   1.0–1.7 ns   |   ~820 MiB/s    |         1.84×          |
| `static-alloc-prefix-simple` |  114.2–115.2 ns  |   1.1–2.2 ns   |   ~1.04 GiB/s   |         2.38×          |
| **`adaptive-buffer-simple`** | **46.1–46.2 ns** | **0.3–0.4 ns** | **~2.58 GiB/s** |       **5.93×**        |

`format_line` 的 profile 如下：

|            阶段             |                  函数                   | 占比  |
| :-------------------------: | :-------------------------------------: | :---: |
|  128 B `buffer`（含拷贝）   | `AdaptiveBuffer::write_str` + `memmove` | 51.6% |
|      `core::fmt` 分派       |       `fmt::write` / `Formatter`        | 25.6% |
| 时间 `buffer` 的 UTF-8 校验 |               `from_utf8`               | 21.4% |
|            杂项             |                    —                    | 1.4%  |

以及整个 `log` 的 profile 如下：

|                       函数                       | 占 `log` 耗时整体 |
| :----------------------------------------------: | :---------------: |
|              `Logger::format_line`               |       69.2%       |
| `Logger::log` 自身（借用/`clear`/`as_ref` 校验） |       23.0%       |
|                  `format_time`                   |       4.2%        |
|                       杂项                       |       3.6%        |

相较于 `static-alloc-prefix-simple`，我们的时延降低了约 59.8%，且超过了 `spdlog-rs` 的实现，说明几乎解决了热路径下所有的分配瓶颈。

## 一些未提及的问题

### 时间获取的优化

在我们的实现中，`log` 函数是直接接受的外部注入的时间，这会对我们的论述造成两个问题。

第一个问题是，其实大部分的日志库是在自己的 `log` 函数里才获取时间戳的。所以 `spdlog-rs` 之所以比我们的性能稍低，一部分的原因就是它要自行付出获取时间的开销。

第二个问题是，既然 `logger` 要自己获取时间，那这部分开销也是要优化的。也就是说，时间获取的时机需要调整——最常见的就是放在 `level` 判断之后，这样只有 `level` 符合需求的日志才会触发获取时间戳的耗时操作。

### 带参格式化

上文中我们并没有做任何和带参数的格式化（比如 `"user_id: {}", user_id`）有关的处理，而这在日志库中其实属于必须要实现的功能，比如用于打印错误的上下文和关键信息。

之所以没有实现，主要是因为 Rust 当中要实现带参数的格式化，需要引入 `std::fmt::Arguments` 结构体。而引入它又需要介绍 `format_args!` 宏，和我们自定义的 `info!` 等宏来处理可变参数列表。这些内容相对较杂，也会使得优化的主线脉络不明，总是需要宕开一笔解释格式化的基础知识，所以最后权衡后我选择抛弃这一部分，只以 **simple** 的 `message: &str` 为核心例子。

要想支持带参格式化也非常简单，只需要修改 `log` 的参数 `message: &str` 为 `arguments: std::fmt::Arguments<'_>`，然后把 `format_line` 改成类似下面的效果：

```rust "write_fmt"
fn format_line(
    buffer: &mut AdaptiveBuffer,
    time_buffer: &[u8; TIME_STR_LEN],
    level: Level,
    arguments: fmt::Arguments<'_>,
) -> fmt::Result {
    let date = std::str::from_utf8(time_buffer).expect("formatted time is valid utf-8");

    write!(buffer, "[{}] [{}] ", date, level.as_str())?;
    buffer.write_fmt(arguments)?;
    buffer.write_str("\n")
}
```

对应地，`log` 的签名和调用点也要改：

```rust del={1} ins={2}
pub fn log(&self, level: Level, timestamp_millis: u64, message: &str)
pub fn log(&self, level: Level, timestamp_millis: u64, arguments: fmt::Arguments<'_>)
```

```rust del={1} ins={2-3}
Self::format_line(&mut buffer, &time_buffer, level, message);
Self::format_line(&mut buffer, &time_buffer, level, arguments)
    .expect("adaptive buffer write cannot fail");
```

## 完整实现

把上面所有增量按顺序合并、去重后，simple 版的完整实现如下，它是一个只有 300 行不到的超微型实现，可以直接作为 `logger.rs` 编译。为了聚焦优化主线，`_mock_print` 仍然作为 sink 的占位；且这段代码不包含最后“带参格式化”一节的 `fmt::Arguments` 扩展，只可输出固定字符串。

为了防止干扰阅读，下面按 `impl` 折叠。

```rust collapse={23-32,39-146,177-183,186-201,204-207,210-221,228-241,244-247,250-254,257-265,268-273,276-282,285-303}
use std::cell::RefCell;
use std::fmt::{self, Write as _};
use time::format_description::StaticFormatDescription;
use time::{OffsetDateTime, UtcOffset};

const PREFIX_FORMAT: StaticFormatDescription =
    time::macros::format_description!("[year]-[month]-[day] [hour]:[minute]:[second]");

const PREFIX_LEN: usize = 19;
const TIME_STR_LEN: usize = 23;
const BUFFER_THRESHOLD: usize = 1 << 7;

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Level {
    Trace,
    Debug,
    Info,
    Warn,
    Error,
}

impl Level {
    pub const fn as_str(self) -> &'static str {
        match self {
            Level::Trace => "TRACE",
            Level::Debug => "DEBUG",
            Level::Info => "INFO",
            Level::Warn => "WARN",
            Level::Error => "ERROR",
        }
    }
}

pub struct Logger {
    min_level: Level,
}

impl Logger {
    pub fn new(min_level: Level) -> Self {
        Self { min_level }
    }

    pub fn log(&self, level: Level, timestamp_millis: u64, message: &str) {
        if self.min_level > level {
            return;
        }

        let mut time_buffer = [0u8; TIME_STR_LEN];
        Self::format_time(&mut time_buffer, timestamp_millis);

        thread_local! {
            static ADAPTIVE_BUFFER: RefCell<AdaptiveBuffer> =
                RefCell::new(AdaptiveBuffer::default());
        }

        ADAPTIVE_BUFFER.with(|buffer| {
            // 防止嵌套调用 `log`，比如在 `_mock_print` 又调用日志
            let Ok(mut buffer) = buffer.try_borrow_mut() {
                return;
            }
            buffer.clear(); // 懒清除

            Self::format_line(&mut buffer, &time_buffer, level, message);

            self._mock_print(buffer.as_ref());
        });
    }

    fn format_line(
        buffer: &mut AdaptiveBuffer,
        time_buffer: &[u8; TIME_STR_LEN],
        level: Level,
        message: &str,
    ) {
        let formatted_time =
            std::str::from_utf8(time_buffer).expect("formatted time is valid utf-8");

        // 这个宏本质上也是使用的 `format_args!`，相对来说更 idiomatic
        writeln!(
            buffer,
            "[{}] [{}] {}",
            formatted_time,
            level.as_str(),
            message
        )
        .expect("adaptive buffer write cannot fail");
    }

    fn current_offset() -> UtcOffset {
        UtcOffset::current_local_offset().unwrap_or(UtcOffset::UTC)
    }

    fn to_local(timestamp_millis: u64, offset: UtcOffset) -> OffsetDateTime {
        OffsetDateTime::from_unix_timestamp_nanos(i128::from(timestamp_millis) * 1_000_000)
            .expect("timestamp is in range")
            .to_offset(offset)
    }

    fn format_time(buffer: &mut [u8], timestamp_millis: u64) {
        debug_assert!(buffer.len() >= TIME_STR_LEN);

        let format_prefix = |mut prefix_buffer: &mut [u8], timestamp_millis: u64| {
            let offset = Self::current_offset();
            let local = Self::to_local(timestamp_millis, offset);

            local
                .format_into(prefix_buffer, PREFIX_FORMAT)
                .expect("date/time text fits the prefix buffer");
        };

        let format_full = |buffer: &mut [u8], prefix: &str, timestamp_millis: u64| {
            debug_assert!(buffer.len() >= TIME_STR_LEN);
            debug_assert!(prefix.len() == PREFIX_LEN);

            buffer[..PREFIX_LEN].copy_from_slice(prefix.as_bytes());

            let millis = (timestamp_millis % 1_000) as u32;
            buffer[PREFIX_LEN..TIME_STR_LEN].copy_from_slice(&[
                b'.',
                b'0' + (millis / 100) as u8,
                b'0' + ((millis / 10) % 10) as u8,
                b'0' + (millis % 10) as u8,
            ]);
        };

        FORMATTED_PREFIX_CACHE.with(|cache| {
            let mut cache = cache.borrow_mut();
            let second = timestamp_millis / 1_000;

            if cache.second != second {
                cache.second = second;
                format_prefix(&mut cache.prefix, timestamp_millis);
            }

            format_full(
                buffer,
                std::str::from_utf8(&cache.prefix).expect("prefix buffer is valid utf-8"),
                timestamp_millis,
            );
        });
    }

    fn _mock_print(&self, full_message: &str) {
        let _ = full_message;
    }
}

struct FormattedPrefixCache {
    second: u64,
    prefix: [u8; PREFIX_LEN],
}

thread_local! {
    static FORMATTED_PREFIX_CACHE: RefCell<FormattedPrefixCache> = RefCell::new(
        FormattedPrefixCache {
            second: u64::MAX,
            prefix: [0; PREFIX_LEN],
        }
    );
}

pub struct AdaptiveBuffer {
    data: Variant,
}

enum Variant {
    Fixed(FixedBuffer),
    Dynamic(DynamicBuffer),
}

pub struct FixedBuffer {
    data: [u8; BUFFER_THRESHOLD],
    len: usize,
}

impl Default for FixedBuffer {
    fn default() -> Self {
        Self {
            data: [0; BUFFER_THRESHOLD],
            len: 0,
        }
    }
}

impl FixedBuffer {
    pub const fn capacity(&self) -> usize {
        BUFFER_THRESHOLD
    }

    pub fn len(&self) -> usize {
        self.len
    }

    pub fn is_empty(&self) -> bool {
        self.len == 0
    }

    pub fn clear(&mut self) {
        self.len = 0;
    }
}

impl AsRef<str> for FixedBuffer {
    fn as_ref(&self) -> &str {
        std::str::from_utf8(&self.data[..self.len]).expect("data is valid str")
    }
}

impl fmt::Write for FixedBuffer {
    fn write_str(&mut self, buf: &str) -> fmt::Result {
        if buf.len() > self.capacity() - self.len {
            return Err(fmt::Error);
        }

        let buf = buf.as_bytes();
        self.data[self.len..self.len + buf.len()].copy_from_slice(buf);
        self.len += buf.len();

        Ok(())
    }
}

pub struct DynamicBuffer {
    data: String,
}

impl DynamicBuffer {
    pub fn with_capacity(cap: usize) -> Self {
        Self {
            data: String::with_capacity(cap),
        }
    }

    pub fn len(&self) -> usize {
        self.data.len()
    }

    pub fn is_empty(&self) -> bool {
        self.data.is_empty()
    }
}

impl AsRef<str> for DynamicBuffer {
    fn as_ref(&self) -> &str {
        &self.data
    }
}

impl fmt::Write for DynamicBuffer {
    fn write_str(&mut self, buf: &str) -> fmt::Result {
        self.data.push_str(buf);
        Ok(())
    }
}

impl AdaptiveBuffer {
    pub fn clear(&mut self) {
        if let Variant::Fixed(buf) = &mut self.data {
            buf.clear();
            return;
        }

        self.data = Variant::Fixed(FixedBuffer::default());
    }
}

impl Default for AdaptiveBuffer {
    fn default() -> Self {
        Self {
            data: Variant::Fixed(FixedBuffer::default()),
        }
    }
}

impl AsRef<str> for AdaptiveBuffer {
    fn as_ref(&self) -> &str {
        match &self.data {
            Variant::Fixed(buf) => buf.as_ref(),
            Variant::Dynamic(buf) => buf.as_ref(),
        }
    }
}

impl fmt::Write for AdaptiveBuffer {
    fn write_str(&mut self, buf: &str) -> fmt::Result {
        match &mut self.data {
            Variant::Fixed(fixed) => {
                if fixed.write_str(buf).is_ok() {
                    return Ok(());
                }

                let mut dynamic = DynamicBuffer::with_capacity(fixed.len() + buf.len());
                dynamic.write_str(fixed.as_ref())?;
                dynamic.write_str(buf)?;

                self.data = Variant::Dynamic(dynamic);

                Ok(())
            }
            Variant::Dynamic(dynamic) => dynamic.write_str(buf),
        }
    }
}
```

:::note
注意，使用 `time` crate 时需要开启如下的 features：

```toml
[dependencies]
time = { version = "0.3", features = ["macros", "local-offset", "formatting"] }
```

:::

## 总结

经过了上文的三次递进优化后，我们终于得以迫近性能的极限。

可以发现，实现性能优化的核心就是不断地发掘、缩小问题的关键性质：时间字符串的前缀变化少、时间字符串的总长度一定、大部分日志都是短日志……在找到关键性质之后，我们就可以量身定做对应的特解，以求在平均意义上用热路径的优化摊平冷路径的重开销。

而落实到工程上，我们就是在预测与复用。我们预测到大部分日志的分配在 128B 之内，所以得以提前留下好可快速分配的栈/静态空间；我们意识到所有时间字符串都可以放在 23B 的空间内，所以我们复用同一块 23B 空间，连反复的分配也省略掉。

所谓性能优化，就是做到 99% 的好。

具体的源码与测试可以参考如下的 GitHub 仓库：

::github{repo="atomlubover/logger-tutorial"}
