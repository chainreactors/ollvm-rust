# Architecture

> 本文档面向 AI agent 和开发者，描述 ollvm-rust 项目的整体架构、代码组织和工作流程。

## 项目定位

ollvm-rust 是一个 **out-of-tree LLVM obfuscation pass plugin**，以动态库形式（`.so`/`.dll`）加载到 LLVM 工具链中，在编译期对 LLVM IR 进行代码混淆变换。核心目标是让 Rust 项目在不修改 LLVM/rustc 源码的前提下获得二进制混淆能力。

## 目录结构

```
ollvm-rust/
├── ollvm-pass/                    # LLVM pass 插件源码（C++）
│   ├── CMakeLists.txt             # 顶层 cmake 配置
│   └── obfuscation/               # 混淆 pass 实现
│       ├── CMakeLists.txt          # 构建目标定义
│       ├── ObfuscationPassManager.cpp  # 插件入口，注册所有 pass
│       ├── ObfuscationOptions.cpp  # 命令行选项解析
│       ├── IndirectBranch.cpp      # 间接跳转混淆 (irobf-indbr)
│       ├── IndirectCall.cpp        # 间接调用混淆 (irobf-icall)
│       ├── IndirectGlobalVariable.cpp  # 间接全局变量混淆 (irobf-indgv)
│       ├── Flattening.cpp          # 控制流平坦化 (irobf-cff)
│       ├── StringEncryption.cpp    # 字符串加密 (irobf-cse)
│       ├── LegacyLowerSwitch.cpp   # switch 语句降级（平坦化前置）
│       ├── CryptoUtils.cpp         # 加密工具（随机数、密钥生成）
│       ├── Utils.cpp               # 通用工具函数
│       ├── LLVMObfuscationx.map    # Linux 符号导出脚本
│       └── obfuscation.def         # Windows 符号导出定义
├── docker/
│   └── ollvm-rustc-linker.sh       # Docker 用 linker wrapper 脚本
├── scripts/
│   └── setup-linux.sh              # Linux 自动化环境搭建 + 编译脚本
├── test-project/                   # 测试用 Rust 项目
│   ├── Cargo.toml
│   └── src/main.rs
├── Dockerfile                      # 全量镜像（LLVM 17-21 + 5 Rust nightly）
├── Dockerfile.test                 # 轻量测试镜像（单 LLVM 版本）
├── test-docker.sh                  # Docker 多目标自动化测试脚本
├── LLVM_COMPAT.md                  # LLVM 17-21 API 兼容性指南
└── README.md                       # 用户文档
```

## 核心组件

### 1. OLLVM Pass 插件 (`ollvm-pass/`)

C++ 编写的 LLVM pass plugin，编译为动态库。通过 LLVM 的 `PassPluginLibraryInfo` 接口注册。

**入口点**：`ObfuscationPassManager.cpp` 中的 `llvmGetPassPluginInfo()` 函数，这是 LLVM pass plugin 的标准入口。它注册了一个 module pass pipeline parsing callback，解析 `irobf(...)` 语法并组合多个 function pass。

**Pass 管线架构**：

```
irobf(irobf-indbr, irobf-icall, irobf-indgv, irobf-cff, irobf-cse)
  │
  ├── ModulePass: ObfuscationPassManager
  │     遍历 Module 中的所有 Function，依次执行：
  │
  │     ├── Flattening (irobf-cff)
  │     │     控制流平坦化。将函数的控制流图转换为 switch-based 分发器。
  │     │     前置依赖：LegacyLowerSwitch（将 switch 降级为 if-else 链）
  │     │
  │     ├── IndirectBranch (irobf-indbr)
  │     │     将直接跳转替换为间接跳转，跳转目标存储在加密的全局表中。
  │     │     运行时通过密钥解密恢复真实跳转地址。
  │     │
  │     ├── IndirectCall (irobf-icall)
  │     │     将直接函数调用替换为间接调用。函数地址存储在全局表中并加密。
  │     │     运行时解密获取真实函数指针。
  │     │
  │     ├── IndirectGlobalVariable (irobf-indgv)
  │     │     将全局变量的直接引用替换为间接引用。
  │     │     通过加密的指针表间接访问全局变量。
  │     │
  │     └── StringEncryption (irobf-cse)
  │           加密 C 风格字符串常量。注：在 Rust 中不生效。
  │
  └── 辅助模块
        ├── CryptoUtils: 随机数生成和加密原语
        ├── Utils: IR 操作辅助函数
        └── ObfuscationOptions: 命令行参数定义
```

**LLVM 版本兼容**：通过 `LLVM_VERSION_MAJOR` 预处理宏进行条件编译，支持 LLVM 17-21。详见 `LLVM_COMPAT.md`。

**构建系统**：CMake，需要 `LT_LLVM_INSTALL_DIR` 指向 LLVM 安装目录。产物为 `libLLVMObfuscationx.so`（Linux）或 `LLVMObfuscationx.dll`（Windows）。

### 2. Linker Wrapper (`docker/ollvm-rustc-linker.sh`)

Rust 的 `-Zllvm-plugins` 对所有 crate 生效，无法只混淆特定 crate。linker wrapper 解决了这个问题。

**工作原理**：

```
cargo build --release
    │
    ├── rustc 编译每个 crate → .o 文件（bitcode，因为 -Clinker-plugin-lto）
    │
    └── rustc 调用 linker（被替换为 ollvm-rustc-linker）
          │
          ├── 1. 自动检测 LLVM 版本（从 rustc --version --verbose）
          ├── 2. 选择对应的 pass plugin（libLLVMObfuscationx-{VER}.so）
          ├── 3. 遍历 linker 参数中的 .o 文件
          │     只处理文件名匹配 OLLVM_CRATE 的 .o 文件
          ├── 4. 用 opt-{VER} 对匹配的 .o 运行混淆 pass
          │     opt -load-pass-plugin=<plugin> --passes=<passes> file.o -o file.o
          ├── 5. 检测目标类型（MSVC vs GNU/ELF）
          │     通过检查参数中的 /libpath:、/out: 等 MSVC 特征
          └── 6. 委托给真实 linker
                ├── MSVC → lld-link-{VER}
                └── GNU/ELF → clang-{VER} -fuse-ld=lld-{VER}
```

**关键设计决策**：
- **只混淆指定 crate**：通过 `OLLVM_CRATE` 环境变量过滤，避免对 `windows` 等巨型依赖施加混淆导致 OOM
- **自动版本匹配**：从 `rustc --version --verbose` 提取 LLVM 版本，自动选择对应的 plugin 和 opt 二进制
- **透明代理**：对 cargo/rustc 完全透明，只需设置 `RUSTFLAGS="-Clinker=ollvm-rustc-linker"`

### 3. Docker 构建系统

#### 全量镜像 (`Dockerfile`)

两阶段构建：

```
Stage 1 (builder): ubuntu:22.04
  ├── 安装 llvm-{17..21}-dev
  ├── 编译 5 个版本的 .so 插件
  └── 输出: /out/libLLVMObfuscationx-{17..21}.so

Stage 2 (runtime): ubuntu:22.04
  ├── LLVM 工具: opt/clang/lld × 5 版本
  ├── 交叉编译: gcc-mingw-w64-{x86-64,i686}
  ├── Rust: 5 个 nightly toolchain + cross targets
  ├── MSVC 交叉编译: xwin (Windows SDK headers/libs)
  ├── linker wrapper: ollvm-rustc-linker
  └── protobuf-compiler (prost-build 依赖)
```

#### 测试镜像 (`Dockerfile.test`)

单 LLVM 版本，用于快速验证。结构与全量镜像相同但只包含一个版本，构建更快。

### 4. 自动化脚本

- **`scripts/setup-linux.sh`**：自动检测系统环境，安装依赖，编译 pass plugin。支持 Ubuntu 20.04/22.04/24.04。
- **`test-docker.sh`**：Docker 内多目标自动化测试。测试 Linux、Windows GNU、Windows MSVC 编译 + baseline 对比。

## 数据流

### 场景 A：Docker + Linker Wrapper（推荐，大型项目）

```
用户项目 (Cargo.toml)
    │
    │  RUSTFLAGS="-Clinker-plugin-lto -Clinker=ollvm-rustc-linker"
    │  OLLVM_CRATE=my_crate
    ▼
cargo build --release --target x86_64-pc-windows-gnu
    │
    ├── rustc 编译 dep1.rs → dep1.o (bitcode, 不混淆)
    ├── rustc 编译 dep2.rs → dep2.o (bitcode, 不混淆)
    ├── rustc 编译 my_crate.rs → my_crate.o (bitcode)
    │
    └── rustc 调用 ollvm-rustc-linker（代替 cc）
          │
          ├── 跳过 dep1.o, dep2.o（文件名不匹配 OLLVM_CRATE）
          ├── opt 处理 my_crate.o → my_crate.o (混淆后的 bitcode)
          └── clang -fuse-ld=lld → 最终二进制
```

### 场景 B：-Zllvm-plugins（简单项目）

```
cargo +nightly rustc --release -- -Zllvm-plugins=<plugin> -Cpasses="irobf(...)"
    │
    └── rustc 对每个 crate 执行：
          ├── 前端编译 → LLVM IR
          ├── LLVM pass pipeline (包含 irobf pass) → 混淆后的 IR
          └── 后端代码生成 → 目标代码
```

> 场景 B 对所有 crate 生效，大型依赖可能 OOM。

## 支持矩阵

| 目标平台 | Docker | 本地编译 |
|---------|:------:|:-------:|
| `x86_64-unknown-linux-gnu` | ✅ | ✅ |
| `x86_64-pc-windows-gnu` | ✅ | — |
| `x86_64-pc-windows-msvc` | ✅ (xwin) | ✅ (VS) |
| `i686-pc-windows-gnu` | ✅ | — |
| `i686-pc-windows-msvc` | ✅ (xwin) | ✅ (VS) |

| LLVM 版本 | Rust Nightly | rustc |
|-----------|-------------|-------|
| 17 | `nightly-2023-09-18` | 1.74 |
| 18 | `nightly-2024-03-15` | 1.78 |
| 19 | `nightly-2024-09-15` | 1.83 |
| 20 | `nightly-2025-03-15` | 1.87 |
| 21 | `nightly-2025-08-15` | 1.91 |

## 已知限制

- **字符串加密 (`-irobf-cse`)** 在 Rust 中不生效，因为 Rust 的字符串常量布局与 C 不同
- **`-Zllvm-plugins` 全局生效**：无法对单个 crate 启用，依赖中的巨型 crate（如 `windows 0.58`）可能导致 OOM。使用 Docker linker wrapper 方案可规避
- **LLVM 版本必须精确匹配**：pass plugin 的编译 LLVM 版本必须与 rustc 内嵌的 LLVM 版本一致，否则会 crash
- **nightly 工具链要求**：`-Zllvm-plugins` 是 unstable feature，仅 nightly 可用
