"""APK 包体与原生库成分门禁；stdlib only，不安装任何产品依赖。

DEA-471 给客户端加了 fvp（Linux/Windows 桌面内嵌播放），它把 FFmpeg 系原生库
一并打进 Android 包，实测 +13MB。Android 走官方 video_player，这些 so 没有
任何调用路径，已在 client/android/app/build.gradle.kts 里排除。

本脚本守两件事，两件都能在构建产物上直接查：

1. 排除清单里的 so 不许回来（回来说明排除规则被人删了或改名了）；
2. 包体不许明显回退（挡的是整包重新塞进三个架构或又拖进一个新 FFmpeg）。

它守不了"装到手机上能不能跑" —— 那需要设备，CI 里没有。

用法：python3 scripts/ci/apk_budget.py <apk>
"""

import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

# 与 client/android/app/build.gradle.kts 的 excludes 保持一致。
EXCLUDED_SO = ("libffmpeg.so", "libmdk.so", "libass.so", "libfvp.so")

# 单架构 release 包当前 19.6 MiB。这是防回退的上限，不是体积目标；正常功能
# 增长撞到它时应该重新量一次再调，而不是顺手调大。
MAX_MIB = 23

# fvp 的 Dart 侧一旦被 client/lib 使用，排除 native 库就会在运行期崩。
FVP_DART_IMPORT = "package:fvp/"


def check_bundle(apk: Path) -> list[str]:
    problems: list[str] = []
    if not apk.is_file():
        return [f"找不到构建产物: {apk}"]

    size_mib = apk.stat().st_size / 1024 / 1024
    if size_mib > MAX_MIB:
        problems.append(
            f"APK {size_mib:.1f} MiB 超过上限 {MAX_MIB} MiB"
            f"（排查是否又把 {', '.join(EXCLUDED_SO)} 打进来了）"
        )

    with zipfile.ZipFile(apk) as bundle:
        names = bundle.namelist()
    for name in names:
        for banned in EXCLUDED_SO:
            if name == banned or name.endswith("/" + banned):
                problems.append(f"排除清单里的原生库回到了包里: {name}")
    return problems


def check_sources(root: Path) -> list[str]:
    problems: list[str] = []
    lib = root / "client" / "lib"
    if not lib.is_dir():
        return [f"找不到客户端源码目录: {lib}"]
    for path in sorted(lib.rglob("*.dart")):
        text = path.read_text(encoding="utf-8", errors="ignore")
        if FVP_DART_IMPORT in text:
            relative = path.relative_to(root)
            problems.append(
                f"{relative} 开始使用 {FVP_DART_IMPORT}；"
                "Android 排除 fvp 原生库后会崩，请先确认平台分支"
            )
    return problems


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("用法: python3 scripts/ci/apk_budget.py <apk>", file=sys.stderr)
        return 2
    problems = check_bundle(Path(argv[1])) + check_sources(ROOT)
    for problem in problems:
        print(f"::error::{problem}")
    if problems:
        return 1
    print("APK 包体与原生库成分符合预期")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
