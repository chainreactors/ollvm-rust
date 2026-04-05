# ollvm-pass

Out-of-tree llvm obfuscation pass，可在编译时对二进制进行混淆，通过 rustc/opt 动态加载使用，无需重新编译 llvm 和 rustc，支持以下混淆方式：

- 间接跳转,并加密跳转目标(-irobf-indbr)
- 间接函数调用,并加密目标函数地址(-irobf-icall)
- 间接全局变量引用,并加密变量地址(-irobf-indgv)
- 字符串(c string)加密功能(-irobf-cse) （rust 中不生效，已知问题）
- 过程相关控制流平坦混淆(-irobf-cff)
- 全部 (-irobf-indbr -irobf-icall -irobf-indgv -irobf-cse -irobf-cff)

混淆插件提取自 [Arkari](https://github.com/KomiMoe/Arkari) 项目。

> 支持 Windows (MSVC) 和 Linux (GNU) 平台编译

![effect.png](assets/effect.png)

## rust 动态加载

动态加载 llvm pass 插件需切换到 nightly 通道（[Allow loading of LLVM plugins [when dynamically built rust]](https://github.com/rust-lang/rust/pull/82734)）：

```bash
rustup toolchain install nightly
```

生成一个示例项目，通过 `-Zllvm-plugins` 参数加载 pass 插件，并通过 `-Cpasses` 参数指定混淆开关：

```bash
cargo new helloworld --bin
cd helloworld
# Windows
cargo +nightly rustc --target x86_64-pc-windows-msvc --release -- -Zllvm-plugins="/path/to/LLVMObfuscationx.dll" -Cpasses="irobf(irobf-indbr,irobf-icall,irobf-indgv,irobf-cff,irobf-cse)"
# Linux
cargo +nightly rustc --target x86_64-unknown-linux-gnu --release -- -Zllvm-plugins="/path/to/LLVMObfuscationx.so" -Cpasses="irobf(irobf-indbr,irobf-icall,irobf-indgv,irobf-cff,irobf-cse)"
```

## opt 动态加载

```bash
# 使用 clang 编译源代码并生成 IR
clang -emit-llvm -c input.c -o input.bc

# 使用 opt 工具加载和运行自定义 Pass
# Windows: LLVMObfuscationx.dll / Linux: LLVMObfuscationx.so
opt -load-pass-plugin="/path/to/LLVMObfuscationx.so" --passes="irobf(irobf-indbr,irobf-icall,irobf-indgv,irobf-cff,irobf-cse)" input.bc -o output.bc

# 将 IR 文件编译为目标文件
llc -filetype=obj output.bc -o output.o

# 链接目标文件生成可执行文件
clang output.o -o output
```

## Linux GNU 编译方法

### 环境及依赖安装

```bash
# Ubuntu/Debian
apt-get update && apt-get install -y \
    build-essential \
    cmake \
    ninja-build \
    git \
    llvm-18-dev

# 或者使用自行编译的 LLVM 18+
```

所需软件列表（用于 Docker 镜像构建）：
- `build-essential` (gcc, g++, make)
- `cmake` (>= 3.20)
- `ninja-build`
- `git`
- `llvm-18-dev` (LLVM 18 开发库和头文件)

### 编译

```bash
git clone --branch ollvm-pass https://github.com/chainreactors/ollvm-rust.git
cd ollvm-rust
cmake -G "Ninja" -S ./ollvm-pass -B ./build \
    -DCMAKE_CXX_STANDARD=17 \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=ON \
    -DLT_LLVM_INSTALL_DIR=/usr/lib/llvm-18
cmake --build ./build -j$(nproc)
```

> `LT_LLVM_INSTALL_DIR` 需指定为自己的 LLVM 安装路径，apt 安装的 LLVM 18 通常在 `/usr/lib/llvm-18`

编译产物为 `build/obfuscation/LLVMObfuscationx.so`

## x86 msvc pass 编译方法 (Windows)

### 环境

- Windows 11 (10.0.22631.3737)
- Visual Studio 2022 (17.10.3)
  - 使用 C++ 的桌面开发
- LLVM 18.1.5

### 编译

需在 `x64 Native Tools Command Prompt for VS 2022` 环境中执行，从开始菜单或者执行 `cmd.exe /k "C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\Tools\VsDevCmd.bat" -startdir=none -arch=x64 -host_arch=x64` 进入：

```bash
git clone --branch ollvm-pass https://github.com/chainreactors/ollvm-rust.git
cd ollvm-rust
cmake -G "Ninja" -S .\ollvm-pass -B .\build -DCMAKE_CXX_STANDARD=17 -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON -DLT_LLVM_INSTALL_DIR=D:\dev\rust_ollvm\llvm-build\llvm_x64
cmake --build .\build\ -j12 # change 12 to yourself nproc
```

> `LT_LLVM_INSTALL_DIR` 需指定为自己的 LLVM 安装路径

## 参考

- [Allow loading of LLVM plugins [when dynamically built rust]](https://github.com/rust-lang/rust/pull/82734)
- [Installing from Source](https://github.com/rust-lang/rust/blob/master/INSTALL.md)
- [rustc dev guide](https://rustc-dev-guide.rust-lang.org/building/how-to-build-and-run.html)
- [Windows rust使用LLVM pass](https://bbs.kanxue.com/thread-274453.htm)
- [Orust Mimikatz Bypass Kaspersky](https://b1n.io/posts/orust-mimikatz-bypass-kaspersky/)
- [Building LLVM with CMake](https://llvm.org/docs/CMake.html#developing-llvm-passes-out-of-source)
- [llvm-tutor](https://github.com/banach-space/llvm-tutor)
- [String encryption failed](https://github.com/joaovarelas/Obfuscator-LLVM-16.0/issues/8)

## 感谢

- [Arkari](https://github.com/KomiMoe/Arkari)
