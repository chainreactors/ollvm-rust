# LLVM 多版本兼容适配指南 (17–22)

> 本文档记录了 LLVM 17 到 22 之间的 C++ API 断裂性变更，以及本项目中的适配方法。
> 适用于开发 out-of-tree LLVM pass plugin 的场景。

## 快速概览

| 变更 | 移除版本 | 影响范围 | 适配方法 |
|------|---------|---------|---------|
| `cl::ZeroOrMore` | 19 | 命令行选项 | 删除，使用默认行为 |
| `Module` 间接包含移除 | 19 | 多数 pass 文件 | 显式 `#include "llvm/IR/Module.h"` |
| `ICmpInst(BB&, ...)` 构造函数 | 19 | 指令创建 | 分离创建与插入 |
| `DemoteRegToStack` 签名 | 19 | 寄存器降级 | `Instruction*` → `iterator` |
| `ConstantExpr::getSub/getAdd/getNeg` | 20 | 常量折叠 | 改用运行时 `BinaryOperator` |
| `ConstantExpr::getBitCast` (ptr→ptr) | 20 | 指针类型转换 | opaque ptr 下直接使用原值 |
| `FunctionType::getPointerTo()` | 20 | 函数指针类型 | 使用 `PointerType::getUnqual()` |
| `Attribute::NoCapture` | 21 | 函数属性 | `Attribute::getWithCaptureInfo()` |

## 版本检测方法

```cpp
#include "llvm/Config/llvm-config.h"

#if LLVM_VERSION_MAJOR >= 20
  // LLVM 20+ 代码路径
#else
  // LLVM 17-19 代码路径
#endif
```

---

## LLVM 19 变更

### 1. `cl::ZeroOrMore` 移除

`cl::ZeroOrMore` 和 `cl::OneOrMore` 在 LLVM 19 中被移除。对于 `cl::opt`，这些本来就是默认行为。

```cpp
// ❌ LLVM 19+ 编译失败
static cl::opt<bool> Flag("flag", cl::init(false), cl::ZeroOrMore);

// ✅ 所有版本通用 — 直接删除 occurrence 参数
static cl::opt<bool> Flag("flag", cl::init(false));
```

### 2. `llvm::Module` 不再被间接包含

LLVM 19 清理了头文件依赖，`Module` 类型不再通过 `Constants.h`、`IRBuilder.h` 等头文件间接引入。任何使用 `Module` 的文件都需要显式包含。

```cpp
// ✅ 在所有使用 Module 的 .cpp 文件中添加
#include "llvm/IR/Module.h"
```

**受影响的典型操作**：`F.getParent()`（返回 `Module*`）、遍历 `Module` 的函数、`M.getDataLayout()` 等。

### 3. `ICmpInst` 构造函数变更

以 `BasicBlock&` 作为第一个参数（插入位置）的构造函数被移除。

```cpp
// ❌ LLVM 19+ 编译失败
Comp = new ICmpInst(*NewLeaf, ICmpInst::ICMP_EQ, Val, RHS, "name");

// ✅ 所有版本通用 — 分离创建与插入
Comp = new ICmpInst(ICmpInst::ICMP_EQ, Val, RHS, "name");
Comp->insertInto(NewLeaf, NewLeaf->end());
```

> 同类变更也影响其他指令类（如 `FCmpInst`）。通用做法：不依赖构造函数做插入，统一使用 `insertInto()` 或 `IRBuilder`。

### 4. `DemoteRegToStack` / `DemotePHIToStack` 签名变更

`AllocaPoint` 参数从 `Instruction*` 变为 `std::optional<BasicBlock::iterator>`。

```cpp
#include "llvm/Config/llvm-config.h"

// DemoteRegToStack(Inst, VolatileLoads, AllocaPoint)
#if LLVM_VERSION_MAJOR >= 19
DemoteRegToStack(Inst, false, AllocaPoint->getIterator());
#else
DemoteRegToStack(Inst, false, AllocaPoint);
#endif

// DemotePHIToStack(PHI, AllocaPoint)
#if LLVM_VERSION_MAJOR >= 19
DemotePHIToStack(PHI, AllocaPoint->getIterator());
#else
DemotePHIToStack(PHI, AllocaPoint);
#endif
```

---

## LLVM 20 变更

### 5. `ConstantExpr` 算术/转换操作移除

LLVM 20 大幅缩减了 `ConstantExpr` 支持的操作类型。以下操作被移除：

- `ConstantExpr::getSub(A, B)`
- `ConstantExpr::getAdd(A, B)`
- `ConstantExpr::getNeg(A)` （等价于 `getSub(Zero, A)`）
- `ConstantExpr::getBitCast(V, Ty)` （指针到指针的转换）

**注意**：`ConstantExpr::getGetElementPtr()` 仍然保留（GEP 是最后移除的常量表达式之一）。

#### 5a. 算术常量表达式 → 运行时指令

当结果用于运行时指令的操作数时，直接用 `BinaryOperator` 替代：

```cpp
#if LLVM_VERSION_MAJOR >= 20
// 运行时计算 -numCase
Value *NegVal = BinaryOperator::CreateNeg(numCase, "", InsertBB);
Value *Result = BinaryOperator::Create(Instruction::Sub, MySecret, NegVal, "", InsertBB);
#else
// 编译期常量折叠
Constant *NegVal = ConstantExpr::getSub(Zero, numCase);
Value *Result = BinaryOperator::Create(Instruction::Sub, MySecret, NegVal, "", InsertBB);
#endif
```

同理处理 `getNeg` 和 `getAdd`：

```cpp
#if LLVM_VERSION_MAJOR >= 20
Value *NegLo = BinaryOperator::CreateNeg(Leaf.Low, "", BB);
Value *Sum   = BinaryOperator::CreateAdd(NegLo, Leaf.High, "", BB);
#else
Constant *NegLo = ConstantExpr::getNeg(Leaf.Low);
Constant *Sum   = ConstantExpr::getAdd(NegLo, Leaf.High);
#endif
```

#### 5b. 指针 BitCast 移除

LLVM 17+ 强制使用 opaque pointer（`ptr`），所有指针类型相同，ptr→ptr 的 bitcast 是无操作。

```cpp
// ❌ LLVM 20+ 编译失败
Constant *CE = ConstantExpr::getBitCast(Callee, PointerType::getUnqual(Ctx));

// ✅ LLVM 17+ opaque pointer 下直接使用原值
#if LLVM_VERSION_MAJOR >= 20
Constant *CE = Callee;  // 已经是 ptr 类型
#else
Constant *CE = ConstantExpr::getBitCast(Callee, PointerType::getUnqual(Ctx));
#endif
```

> `IRBuilder::CreateBitCast(ptr, ptr)` 在所有版本中仍然有效（自动检测同类型并返回原值），无需特殊处理。

### 6. `FunctionType::getPointerTo()` 移除

opaque pointer 下此方法无意义（所有函数指针类型都是 `ptr`）。

```cpp
// ❌ LLVM 20+
Value *FnPtr = IRB.CreateBitCast(Addr, FTy->getPointerTo());

// ✅ opaque pointer 下无需转换
#if LLVM_VERSION_MAJOR >= 20
Value *FnPtr = Addr;
#else
Value *FnPtr = IRB.CreateBitCast(Addr, FTy->getPointerTo());
#endif
```

---

## LLVM 21 变更

### 7. `Attribute::NoCapture` → `captures(none)`

LLVM 21 将 `nocapture` 属性重构为更精细的 `captures` 属性。

```cpp
#include "llvm/Config/llvm-config.h"
#if LLVM_VERSION_MAJOR >= 21
#include "llvm/Support/ModRef.h"
#endif

#if LLVM_VERSION_MAJOR >= 21
Arg->addAttr(Attribute::getWithCaptureInfo(Ctx, CaptureInfo::none()));
#else
Arg->addAttr(Attribute::NoCapture);
#endif
```

> `Attribute::ReadOnly` 在 LLVM 21 中仍然有效，无需修改。

---

## 跨平台注意事项

### Windows vs Linux 构建差异

| 项目 | Windows | Linux |
|------|---------|-------|
| 产物格式 | `LLVMObfuscationx.dll` | `libLLVMObfuscationx.so` |
| 符号导出 | `obfuscation.def` | `LLVMObfuscationx.map` (version script) |
| 关键导出符号 | `llvmGetPassPluginInfo` | `llvmGetPassPluginInfo` |
| 编译选项 | — | `-fPIC` (POSITION_INDEPENDENT_CODE) |
| 随机数源 | `std::mt19937` + `<random>` | `/dev/urandom` + `<fstream>` |

### CMakeLists.txt 跨平台写法

```cmake
# 条件包含 .def 文件（仅 Windows）
if(WIN32)
    list(APPEND SOURCES obfuscation.def)
endif()

# 条件依赖（预编译 LLVM 中不存在这些 target）
if(TARGET intrinsics_gen)
    add_dependencies(MyPlugin intrinsics_gen)
endif()

# Linux 符号导出与 PIC
if(NOT WIN32)
    target_link_options(MyPlugin PRIVATE
        "LINKER:--version-script=${CMAKE_CURRENT_SOURCE_DIR}/MyPlugin.map")
    set_target_properties(MyPlugin PROPERTIES POSITION_INDEPENDENT_CODE ON)
endif()
```

### Linux Linker Version Script 模板

```
{
  global:
    llvmGetPassPluginInfo;
  local:
    *;
};
```

---

## 版本与 Rust Nightly 对应关系

| Rust Nightly 版本 | 内嵌 LLVM 版本 |
|-------------------|---------------|
| 1.76–1.81 | LLVM 18 |
| 1.82–1.84 | LLVM 19 |
| 1.85–1.89 | LLVM 20 |
| 1.90+ | LLVM 21+ |

> **重要**：pass plugin 的 .so/.dll 必须与加载它的 LLVM 版本完全一致。使用 `rustc +nightly --version --verbose` 查看 Rust 内嵌的 LLVM 版本，然后用对应版本的 `llvm-XX-dev` 编译 pass。

查看 Rust 使用的 LLVM 版本：

```bash
rustc +nightly --version --verbose 2>&1 | grep LLVM
# LLVM version: 20.1.5
# → 使用 llvm-20-dev 编译 pass
```

---

## 适配新 LLVM 版本的检查清单

当需要支持新的 LLVM 版本时，按以下步骤排查：

1. **编译测试**：直接编译，收集所有错误
2. **头文件缺失**：检查是否有间接包含被移除（通常报 `incomplete type`）
3. **ConstantExpr**：检查是否有新的 ConstantExpr 操作被移除（报 `no member named 'getXxx'`）
4. **指令构造函数**：检查是否有插入点构造函数被移除（报 `no matching function for call`）
5. **属性变更**：检查 `Attribute::` 枚举是否有重命名/移除
6. **函数签名变更**：注意参数类型从原始指针到 iterator/optional 的迁移趋势

**LLVM API 迁移趋势总结**：
- 逐步移除所有 `ConstantExpr` 子类，推动常量折叠到运行时
- 指令创建与插入分离，废弃"构造时插入"的模式
- 函数参数从原始指针迁移到 iterator / optional 包装
- opaque pointer 统一后，清理所有指针类型相关的旧 API
- 属性系统持续重构，简单布尔属性可能变为参数化属性
