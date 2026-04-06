# ollvm-pass

Out-of-tree LLVM obfuscation pass plugin，编译时对二进制进行代码混淆。通过 rustc/opt 动态加载，无需重新编译 LLVM 或 Rust。

混淆插件提取自 [Arkari](https://github.com/KomiMoe/Arkari) 项目。

## 混淆功能

| 开关 | 说明 |
|------|------|
| `-irobf-indbr` | 间接跳转，加密跳转目标 |
| `-irobf-icall` | 间接函数调用，加密目标函数地址 |
| `-irobf-indgv` | 间接全局变量引用，加密变量地址 |
| `-irobf-cff` | 过程相关控制流平坦混淆 |
| `-irobf-cse` | 字符串 (C string) 加密（Rust 中不生效，已知问题） |

> 支持 LLVM 17–21，Windows (MSVC/GNU) 和 Linux (GNU) 平台

![effect.png](assets/effect.png)

## 快速开始

### 方式一：Docker（推荐）

Docker 镜像内置 OLLVM 插件、LLVM 工具链和 Rust nightly，开箱即用。

#### 构建镜像

```bash
# 全量镜像（LLVM 17-21 + 5 个 Rust nightly + MSVC 交叉编译）
docker build -t ollvm-rust .

# 轻量测试镜像（仅 LLVM 18 + Rust 1.78）
docker build -f Dockerfile.test -t ollvm-rust-test .
```

#### 编译 Rust 项目（Linux 目标）

```bash
docker run --rm -v "$(pwd):/src" ollvm-rust bash -c '
  OLLVM_CRATE=my_crate \
  OLLVM_PASSES="irobf(irobf-indbr,irobf-icall,irobf-indgv)" \
  RUSTFLAGS="-Clinker-plugin-lto -Clinker=ollvm-rustc-linker" \
  cargo build --release'
```

#### 编译 Rust 项目（Windows GNU 目标）

```bash
docker run --rm -v "$(pwd):/src" ollvm-rust bash -c '
  OLLVM_CRATE=my_crate \
  OLLVM_PASSES="irobf(irobf-indbr,irobf-icall,irobf-indgv)" \
  RUSTFLAGS="-Clinker-plugin-lto -Clinker=ollvm-rustc-linker \
    -Clink-arg=--target=x86_64-w64-windows-gnu" \
  cargo build --release --target x86_64-pc-windows-gnu'
```

#### 编译 Rust 项目（Windows MSVC 目标）

```bash
docker run --rm -v "$(pwd):/src" ollvm-rust bash -c '
  OLLVM_CRATE=my_crate \
  OLLVM_PASSES="irobf(irobf-indbr,irobf-icall,irobf-indgv)" \
  RUSTFLAGS="-Clinker-plugin-lto -Clinker=ollvm-rustc-linker \
    -Clink-arg=/libpath:/opt/xwin/crt/lib/x86_64 \
    -Clink-arg=/libpath:/opt/xwin/sdk/lib/um/x86_64 \
    -Clink-arg=/libpath:/opt/xwin/sdk/lib/ucrt/x86_64" \
  cargo build --release --target x86_64-pc-windows-msvc'
```

#### 32 位目标

将上面的 `x86_64` 替换为 `i686`，例如：

```bash
# Windows GNU 32-bit
docker run --rm -v "$(pwd):/src" ollvm-rust bash -c '
  OLLVM_CRATE=my_crate \
  RUSTFLAGS="-Clinker-plugin-lto -Clinker=ollvm-rustc-linker \
    -Clink-arg=--target=i686-w64-windows-gnu" \
  cargo build --release --target i686-pc-windows-gnu'
```

#### 切换 LLVM/Rust 版本

全量镜像内置 5 个 Rust nightly，linker wrapper 会自动匹配 LLVM 版本：

```bash
docker run --rm -v "$(pwd):/src" ollvm-rust bash -c '
  rustup default nightly-2024-09-15 &&
  OLLVM_CRATE=my_crate \
  RUSTFLAGS="-Clinker-plugin-lto -Clinker=ollvm-rustc-linker" \
  cargo build --release'
```

| Rust Nightly | LLVM | rustc 版本 |
|-------------|------|-----------|
| `nightly-2023-09-18` | 17 | 1.74 |
| `nightly-2024-03-15` | 18 | 1.78 |
| `nightly-2024-09-15` | 19 | 1.83 |
| `nightly-2025-03-15` | 20 | 1.87 (默认) |
| `nightly-2025-08-15` | 21 | 1.91 |

#### Docker 环境变量

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `OLLVM_CRATE` | 要混淆的 crate 名称（**必填**） | — |
| `OLLVM_PASSES` | 混淆 pass 管线 | `irobf(irobf-indbr)` |
| `OLLVM_VERBOSE` | 调试输出（`1` 开启） | `0` |

#### 大型项目编译注意事项

对于依赖了 `windows` 等巨型 crate 的项目，`-Clinker-plugin-lto` 会让所有 crate 生成 bitcode，峰值内存较高。建议：

```bash
docker run --rm --memory=8g --memory-swap=-1 \
  -v "$(pwd):/src" ollvm-rust bash -c '
  OLLVM_CRATE=my_crate \
  CARGO_PROFILE_RELEASE_LTO=off \
  CARGO_PROFILE_RELEASE_CODEGEN_UNITS=16 \
  RUSTFLAGS="-Clinker-plugin-lto -Clinker=ollvm-rustc-linker \
    -Clink-arg=--target=x86_64-w64-windows-gnu -Clink-arg=-fuse-ld=lld-18" \
  cargo build -p my_crate --release --target x86_64-pc-windows-gnu'
```

- `--memory=8g --memory-swap=-1`：增大容器内存限制
- `CARGO_PROFILE_RELEASE_LTO=off`：关闭 LTO，减少编译时内存和时间
- `CARGO_PROFILE_RELEASE_CODEGEN_UNITS=16`：允许并行代码生成

> 注意：linker wrapper 只对 `OLLVM_CRATE` 指定的 crate 施加混淆，依赖 crate 不受影响。

### 方式二：Rust 直接加载

需要 nightly 工具链（[Allow loading of LLVM plugins](https://github.com/rust-lang/rust/pull/82734)）：

```bash
rustup toolchain install nightly
```

通过 `-Zllvm-plugins` 加载插件，`-Cpasses` 指定混淆开关：

```bash
# Windows
cargo +nightly rustc --target x86_64-pc-windows-msvc --release -- \
  -Zllvm-plugins="/path/to/LLVMObfuscationx.dll" \
  -Cpasses="irobf(irobf-indbr,irobf-icall,irobf-indgv)"

# Linux
cargo +nightly rustc --target x86_64-unknown-linux-gnu --release -- \
  -Zllvm-plugins="/path/to/libLLVMObfuscationx.so" \
  -Cpasses="irobf(irobf-indbr,irobf-icall,irobf-indgv)"
```

> ⚠️ `-Zllvm-plugins` 对所有 crate 生效。依赖中有巨型 crate（如 `windows`）时可能导致内存不足，建议使用 Docker + linker wrapper 方式。

### 方式三：opt 命令行

```bash
# 生成 IR
clang -emit-llvm -c input.c -o input.bc

# 加载插件运行混淆
opt -load-pass-plugin="/path/to/libLLVMObfuscationx.so" \
  --passes="irobf(irobf-indbr,irobf-icall,irobf-indgv)" \
  input.bc -o output.bc

# 编译链接
llc -filetype=obj output.bc -o output.o
clang output.o -o output
```

## 从源码编译

### Linux

```bash
# 安装依赖
apt-get update && apt-get install -y \
    build-essential cmake ninja-build llvm-18-dev libzstd-dev zlib1g-dev

# 编译
git clone --branch ollvm-pass https://github.com/chainreactors/ollvm-rust.git
cd ollvm-rust
cmake -G Ninja -S ./ollvm-pass -B ./build \
    -DCMAKE_CXX_STANDARD=17 \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=ON \
    -DLT_LLVM_INSTALL_DIR=/usr/lib/llvm-18
cmake --build ./build -j$(nproc)
```

产物：`build/obfuscation/libLLVMObfuscationx.so`

也可用自动化脚本：

```bash
./scripts/setup-linux.sh       # 自动检测 rustc nightly 的 LLVM 版本
./scripts/setup-linux.sh 20    # 指定 LLVM 20
```

### Windows (MSVC)

环境要求：
- Visual Studio 2022（使用 C++ 的桌面开发）
- LLVM 18+（预编译或自行编译）

在 `x64 Native Tools Command Prompt for VS 2022` 中执行：

```bash
git clone --branch ollvm-pass https://github.com/chainreactors/ollvm-rust.git
cd ollvm-rust
cmake -G Ninja -S .\ollvm-pass -B .\build \
    -DCMAKE_CXX_STANDARD=17 \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=ON \
    -DLT_LLVM_INSTALL_DIR=D:\path\to\llvm
cmake --build .\build -j12
```

产物：`build\obfuscation\LLVMObfuscationx.dll`

> `LT_LLVM_INSTALL_DIR` 需指向 LLVM 安装路径。插件的 LLVM 版本必须与 rustc 内嵌的 LLVM 版本一致。

## 参考

- [Allow loading of LLVM plugins [when dynamically built rust]](https://github.com/rust-lang/rust/pull/82734)
- [Windows rust使用LLVM pass](https://bbs.kanxue.com/thread-274453.htm)
- [Orust Mimikatz Bypass Kaspersky](https://b1n.io/posts/orust-mimikatz-bypass-kaspersky/)
- [Building LLVM with CMake](https://llvm.org/docs/CMake.html#developing-llvm-passes-out-of-source)
- [llvm-tutor](https://github.com/banach-space/llvm-tutor)
- [LLVM 多版本兼容适配指南](LLVM_COMPAT.md)

## 感谢

- [Arkari](https://github.com/KomiMoe/Arkari)
