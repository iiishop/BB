"""Fixed platform operations; credentials use private files/stdin, never argv."""

import base64
import csv
import hashlib
import json
import os
import platform
import re
import secrets
import subprocess
from pathlib import Path
from uuid import UUID

from bb_auth_contract.admin import CheckResult

from bb_server.public_cloud import PublicFailure


def check(name, classification, code=None, actions=(), message=""):
    return CheckResult(
        check=name,
        classification=classification,
        issue_code=code,
        allowed_actions=list(actions),
        message=message,
    )


def platform_kind():
    if platform.machine().lower() not in ("x86_64", "amd64"):
        return "unsupported"
    if os.name == "nt":
        return "windows"
    try:
        if (
            platform.system() == "Linux"
            and "ID=arch" in Path("/etc/os-release").read_text().splitlines()
        ):
            return "arch"
    except OSError:
        pass
    return "unsupported"


class SecretFiles:
    def __init__(self, directory):
        self.directory = Path(directory)

    def prepare(self):
        if self.directory.is_symlink():
            raise PublicFailure("private_directory_invalid", "私密状态目录不安全")
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        if os.name == "posix":
            stat = self.directory.stat()
            if stat.st_uid != os.getuid() or stat.st_mode & 0o077:
                raise PublicFailure(
                    "private_directory_invalid",
                    "私密状态目录须由当前用户拥有且权限为 0700",
                )
        else:
            # Current user's SID, not a translated display name; no credential discovery.
            try:
                result = subprocess.run(
                    ["whoami.exe", "/user", "/fo", "csv", "/nh"],
                    capture_output=True,
                    text=True,
                    errors="replace",
                    timeout=15,
                    check=True,
                )
                rows = list(csv.reader(result.stdout.splitlines()))
                if len(rows) != 1 or len(rows[0]) != 2:
                    raise ValueError()
                sid = rows[0][1]
                if not re.fullmatch(r"S-1-\d+(?:-\d+)+", sid):
                    raise ValueError()
                subprocess.run(
                    [
                        "icacls.exe",
                        str(self.directory),
                        "/inheritance:r",
                        "/grant:r",
                        f"*{sid}:(OI)(CI)F",
                        "*S-1-5-18:(OI)(CI)F",
                        "*S-1-5-32-544:(OI)(CI)F",
                    ],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=15,
                    check=True,
                )
                # grant:r does not remove unrelated explicit ACEs on an existing
                # directory. Fail before writing a secret if any remain.
                directory = "'" + str(self.directory).replace("'", "''") + "'"
                subprocess.run(
                    [
                        "powershell.exe",
                        "-NoProfile",
                        "-NonInteractive",
                        "-Command",
                        "$ErrorActionPreference='Stop'; $p=" + directory + "; "
                        "if((Get-Item -LiteralPath $p).Attributes -band [IO.FileAttributes]::ReparsePoint){exit 1}; "
                        "$acl=Get-Acl -LiteralPath $p; "
                        "$bad=@($acl.Access | Where-Object {$_.AccessControlType -eq 'Allow' -and "
                        "$_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value "
                        "-notin @('" + sid + "','S-1-5-18','S-1-5-32-544')}); "
                        "if($bad.Count){exit 1}",
                    ],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=15,
                    check=True,
                )
            except (OSError, ValueError, csv.Error, subprocess.SubprocessError):
                raise PublicFailure(
                    "private_acl_unavailable", "无法设置当前用户的私密状态 ACL"
                ) from None

    def path(self, task_id, suffix):
        if suffix not in ("secret", "request"):
            raise ValueError()
        return self.directory / (str(UUID(str(task_id))) + "." + suffix)

    def secret(self, task_id, *, create=False):
        self.prepare()
        path = self.path(task_id, "secret")
        if create:
            try:
                fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            except FileExistsError:
                pass
            else:
                with os.fdopen(fd, "w", encoding="ascii") as file:
                    file.write(base64.b64encode(secrets.token_bytes(32)).decode())
                    file.flush()
                    os.fsync(file.fileno())
        if (
            path.is_symlink()
            or not path.exists()
            or (os.name == "posix" and path.stat().st_mode & 0o077)
        ):
            raise PublicFailure(
                "runtime_secret_missing",
                "本任务的运行密钥不可用；停止自动接管或重复创建",
            )
        return path.read_text(encoding="ascii")

    def request(self, payload):
        self.prepare()
        path = self.path(payload["task_id"], "request")
        value = json.dumps(payload).encode()
        try:
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError:
            if path.is_symlink() or path.read_bytes() != value:
                raise PublicFailure(
                    "helper_request_conflict", "本机操作请求已变化，停止执行"
                )
        else:
            with os.fdopen(fd, "wb") as file:
                file.write(value)
                file.flush()
                os.fsync(file.fileno())
        return path


class PlatformAdapter:
    def __init__(self, secrets_dir, *, kind=None, runner=subprocess.run):
        self.kind = kind or platform_kind()
        self.files = SecretFiles(secrets_dir)
        self.runner = runner

    def binary(self):
        if self.kind == "arch":
            return Path("/usr/bin/cloudflared")
        if self.kind == "windows":
            return (
                Path(os.environ.get("ProgramFiles", r"C:\Program Files"))
                / "BB"
                / "cloudflared.exe"
            )
        return None

    def inspect(self, instance):
        binary = self.binary()
        if self.kind == "unsupported":
            return [
                check(
                    "installation",
                    "not_applicable",
                    "platform_unsupported",
                    ("local_admin",),
                    "该平台不支持自动安装，请使用官方手动步骤",
                ),
                check(
                    "service", "unknown", "service_unknown", message="未检查系统服务"
                ),
            ]
        if not binary.is_file():
            return [
                check(
                    "installation",
                    "failed",
                    "cloudflared_missing",
                    ("install",),
                    "未安装 cloudflared",
                ),
                check("service", "not_applicable", message="安装后再检查服务"),
            ]
        try:
            result = self.runner(
                [str(binary), "--version"], capture_output=True, timeout=5, check=False
            )
            if result.returncode:
                return [
                    check(
                        "installation",
                        "failed",
                        "cloudflared_not_executable",
                        ("local_admin",),
                        "cloudflared 无法运行",
                    ),
                    check("service", "unknown", message="未检查服务"),
                ]
            if self.kind == "arch":
                result = self.runner(
                    [
                        "/usr/bin/systemctl",
                        "show",
                        f"bb-cloudflared-{UUID(str(instance))}.service",
                        "--property=LoadState",
                        "--property=ActiveState",
                    ],
                    capture_output=True,
                    text=True,
                    timeout=5,
                    check=False,
                )
                fields = dict(
                    line.split("=", 1)
                    for line in result.stdout.splitlines()
                    if "=" in line
                )
                state = fields.get("ActiveState")
                exists = fields.get("LoadState") not in (None, "not-found")
                if exists:
                    from bb_server.helpers.arch import unit

                    unit_file = (
                        Path("/etc/systemd/system")
                        / f"bb-cloudflared-{UUID(str(instance))}.service"
                    )
                    if (
                        unit_file.is_symlink()
                        or not unit_file.is_file()
                        or unit_file.stat().st_uid != 0
                        or unit_file.read_bytes() != unit(str(instance))
                    ):
                        state = "conflict"
            else:
                inspect_script = (
                    "$ErrorActionPreference='Stop'; $s=Get-Service -Name Cloudflared -ErrorAction SilentlyContinue; if(-not $s){'Missing';exit 0}; "
                    "$root=Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'BB-Public'; "
                    "$owner=Join-Path $root 'owner.txt'; if(-not (Test-Path -LiteralPath $owner) -or [IO.File]::ReadAllText($owner) -cne '__INSTANCE__'){'Conflict';exit 0}; "
                    "$s=Get-CimInstance Win32_Service -Filter \"Name='Cloudflared'\"; $exe=Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'BB\\cloudflared.exe'; "
                    "$token=Join-Path $root '__INSTANCE__\\token'; $expected='\"'+$exe+'\" tunnel --no-autoupdate run --token-file \"'+$token+'\"'; "
                    "if($s.PathName -cne $expected -or $s.StartName -ne 'NT AUTHORITY\\LocalService'){'Conflict'}else{$s.State}"
                ).replace("__INSTANCE__", str(UUID(str(instance))))
                result = self.runner(
                    [
                        "powershell.exe",
                        "-NoProfile",
                        "-NonInteractive",
                        "-Command",
                        inspect_script,
                    ],
                    capture_output=True,
                    text=True,
                    timeout=5,
                    check=False,
                )
                state = (
                    "active"
                    if result.stdout.strip() == "Running"
                    else "conflict"
                    if result.stdout.strip() == "Conflict"
                    else "inactive"
                )
                exists = result.stdout.strip() != "Missing"
            if result.returncode or not state:
                status = check(
                    "service",
                    "unknown",
                    "service_unreadable",
                    ("local_admin",),
                    "无权读取或无法连接系统服务管理器",
                )
            elif state == "conflict":
                status = check(
                    "service",
                    "failed",
                    "service_conflict",
                    ("local_admin",),
                    "已有服务归属或启动参数不匹配，禁止接管或重注册",
                )
            elif not exists:
                status = check(
                    "service", "failed", "service_missing", message="本应用服务尚未注册"
                )
            elif state != "active":
                status = check(
                    "service",
                    "failed",
                    "service_stopped",
                    message="服务未运行；不能据此判断 Tunnel 路由",
                )
            else:
                status = check(
                    "service",
                    "passed",
                    message="服务运行中；仍需核对 Tunnel 连接与实例挑战",
                )
            return [
                check("installation", "passed", message="cloudflared 可执行"),
                status,
            ]
        except (OSError, subprocess.SubprocessError):
            return [
                check(
                    "installation",
                    "unknown",
                    "local_probe_unreadable",
                    ("local_admin",),
                    "本机只读探测未能完成",
                ),
                check("service", "unknown", message="服务状态未知"),
            ]

    def apply(self, action, task_id, instance, token=None):
        if self.kind not in ("arch", "windows"):
            raise PublicFailure(
                "platform_unsupported", "该平台不支持自动处理", waiting="local_admin"
            )
        payload = {
            "action": action,
            "task_id": str(task_id),
            "instance_id": str(instance),
        }
        if token is not None:
            payload["token"] = token
        request = self.files.request(payload)
        source = (
            Path(__file__).parent
            / "helpers"
            / ("arch.py" if self.kind == "arch" else "windows.ps1")
        )
        helper = (
            Path("/usr/local/libexec/bb-public-helper")
            if self.kind == "arch"
            else self.binary().parent / "bb-public-helper.ps1"
        )
        if (
            not helper.is_file()
            or helper.is_symlink()
            or hashlib.sha256(helper.read_bytes()).digest()
            != hashlib.sha256(source.read_bytes()).digest()
        ):
            raise PublicFailure(
                "local_helper_required",
                "请本机管理员安装随 BB 提供的固定操作助手；任务已保留，未执行系统修改",
                waiting="local_admin",
            )
        try:
            if self.kind == "arch":
                if any(
                    path.stat().st_uid != 0 or path.stat().st_mode & 0o022
                    for path in (helper, *helper.parents)
                ):
                    raise PublicFailure(
                        "local_helper_untrusted",
                        "本机助手路径必须由 root 拥有且普通用户不可写",
                        waiting="local_admin",
                    )
                if not (os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY")):
                    raise PublicFailure(
                        "local_desktop_required",
                        "后台无交互桌面，请本机管理员按文档执行已保存请求",
                        waiting="local_admin",
                    )
                command = ["/usr/bin/pkexec", "/usr/bin/python3", "-I", str(helper)]
                result = self.runner(
                    command,
                    input=request.read_bytes(),
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=210,
                    check=False,
                )
            else:
                # Paths are local startup configuration, never frontend fields. Single-quote escaping
                # keeps even a quote in the user's directory from becoming PowerShell code.
                def literal(path):
                    return "'" + str(path).replace("'", "''") + "'"

                safety = (
                    "$ErrorActionPreference='Stop'; $p=" + literal(helper) + "; "
                    "foreach($item in @($p,(Split-Path $p),(Split-Path (Split-Path $p)))){"
                    "if((Get-Item -LiteralPath $item).Attributes -band [IO.FileAttributes]::ReparsePoint){exit 1}; $acl=Get-Acl -LiteralPath $item; "
                    "$bad=@($acl.Access | Where-Object {$_.AccessControlType -eq 'Allow' -and ($_.FileSystemRights -band 0xD0116) -and $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -notin @('S-1-5-18','S-1-5-32-544','S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')}); if($bad.Count){exit 1}}"
                )
                safe = self.runner(
                    [
                        "powershell.exe",
                        "-NoProfile",
                        "-NonInteractive",
                        "-Command",
                        safety,
                    ],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=10,
                    check=False,
                )
                if safe.returncode:
                    raise PublicFailure(
                        "local_helper_untrusted",
                        "本机助手 ACL 不满足要求",
                        waiting="local_admin",
                    )
                if (
                    not os.environ.get("SESSIONNAME", "")
                    .lower()
                    .startswith(("console", "rdp"))
                ):
                    raise PublicFailure(
                        "local_desktop_required",
                        "后台无交互桌面，请本机管理员执行已保存请求",
                        waiting="local_admin",
                    )
                arguments = (
                    '-NoProfile -ExecutionPolicy Bypass -File "'
                    + str(helper)
                    + '" -RequestFile "'
                    + str(request)
                    + '"'
                )
                script = (
                    "$p=Start-Process -FilePath powershell.exe -Verb RunAs -Wait -PassThru -ArgumentList "
                    + literal(arguments)
                    + "; exit $p.ExitCode"
                )
                result = self.runner(
                    [
                        "powershell.exe",
                        "-NoProfile",
                        "-NonInteractive",
                        "-Command",
                        script,
                    ],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=210,
                    check=False,
                )
            if result.returncode:
                raise PublicFailure(
                    "local_operation_not_confirmed",
                    "系统授权被取消、操作失败或结果未知；先核对本机状态后恢复",
                    waiting="local_admin",
                )
            request.unlink(missing_ok=True)
        except (OSError, subprocess.SubprocessError):
            raise PublicFailure(
                "local_operation_unknown",
                "本机操作结果未知，请核对保存的请求和服务状态",
                waiting="local_admin",
            ) from None
