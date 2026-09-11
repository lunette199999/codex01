# 给本地接入补丁的复核附件

复核结论见 [`../../docs/PATCH-REVIEW.md`](../../docs/PATCH-REVIEW.md)。
这里是那份复核里提到的、可以直接用的四样东西。

| 文件 | 用途 |
|---|---|
| `CoreVersionAssertion.swift` | 证明链接进去的核心确实是 1.1.0。编译期一条、运行期一条。丢进 app target 或测试二进制 |
| `apply-version-guard.patch` | 给 `scripts/apply.py` 加版本闸门,并打印实际复制进去的核心指纹 |
| `core-sha256.txt` | 1.1.0 十五个核心文件的 sha256,用来直接比对 |
| `reduce-motion.patch` | `setIdleEnabled(idle && !reduced)` 的最小改法,净 +19 行 |

## 为什么需要版本证明

三处修复全在核心里，`ChoreographyBridge.swift` 在 1.0.0 和 1.1.0 之间**逐字节相同**，
而且 1.1.0 的桥接对着 1.0.0 的核心**也能编译通过**。实测:

```
底层 pressedLips(0.85)+ 微张唇叠加层,说话开始的那一帧:
  核心 1.0.0   pressed 0.5780 -> 0.8500   单帧跳变 0.2720
  核心 1.1.0   pressed 0.5780 -> 0.5780   单帧跳变 0.0000
```

所以"桥接对得上"和"构建通过"都不是核心版本的证据。

## 怎么用

```sh
# 1. 比对核心
cd <choreo-copy> && shasum -a 256 Sources/ExpressionChoreography/*.swift
diff <(shasum -a 256 Sources/ExpressionChoreography/*.swift | awk '{print $1, substr($2, match($2,/[^\/]*$/))}' | sort) \
     <(grep -v '^#' core-sha256.txt | grep . | awk '{print $1, $2}' | sort)

# 2. 给 apply.py 加闸门
cd <补丁包目录> && patch -p1 < .../apply-version-guard.patch

# 3. 把断言编进去
cp CoreVersionAssertion.swift <choreo-copy>/Sources/ZhengZhipuDesktop/
#    在 ChoreoIT.main() 开头加一行,让每次验收报告自带核心指纹:
#    print("core fix step:", assertChoreographyCoreIsFixed())   // 1.1.0 上应为 0.0

# 4. reduce-motion
cd <choreo-copy> && patch -p1 < .../reduce-motion.patch
```

`reduce-motion.patch` 是打在**已经打过 `DesktopController.swift.patch` 的**文件上的；
已验证可干净应用。它依赖的模块行为(重新打开不补播、显式序列不受影响)在
Linux 上实测过,见 `docs/PATCH-REVIEW.md` 第二节;**AppKit 那段本身没有在 macOS 上编译过。**
