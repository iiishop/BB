"""One owned executor, durable effects, and explicit reconciliation after uncertainty."""

import os
import sqlite3
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from uuid import UUID

from bb_auth_contract import ContractError

from bb_server.public_challenge import InstanceVerifier
from bb_server.public_cloud import Cloudflare, PublicFailure, identifier, unknown
from bb_server.public_platform import PlatformAdapter, check
from bb_server.public_store import PublicStore


class PublicRuntime:
    def __init__(
        self,
        path,
        *,
        business_port,
        challenge_directory,
        clock=time.time,
        adapter=None,
        cloud_factory=Cloudflare,
        verifier=None,
    ):
        if not 1 <= business_port <= 65535:
            raise ValueError("Invalid business port")
        self.store = PublicStore(Path(path), clock)
        self.target = f"http://127.0.0.1:{business_port}"
        self.adapter = adapter or PlatformAdapter(str(path) + ".private")
        self.verifier = verifier or InstanceVerifier(challenge_directory, business_port)
        self.cloud_factory = cloud_factory
        self.credentials = {}
        self.mutex = threading.RLock()
        self.wake = threading.Event()
        self.stop = threading.Event()
        self.executor = None
        self.lock_file = None

    def start(self):
        # The OS releases this lock on a crash; no expiring lease may overlap an old worker.
        fd = os.open(
            str(self.store.path) + ".worker-lock", os.O_CREAT | os.O_RDWR, 0o600
        )
        self.lock_file = os.fdopen(fd, "a+b")
        try:
            if os.name == "nt":
                import msvcrt

                if self.lock_file.seek(0, 2) == 0:
                    self.lock_file.write(b"0")
                    self.lock_file.flush()
                self.lock_file.seek(0)
                msvcrt.locking(fd, msvcrt.LK_NBLCK, 1)
            else:
                import fcntl

                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            self.lock_file.close()
            self.lock_file = None
            raise RuntimeError(
                "Another management executor owns this database"
            ) from None
        self.executor = ThreadPoolExecutor(
            max_workers=1, thread_name_prefix="bb-public"
        )
        self.executor.submit(self._loop)
        self.wake.set()

    def close(self):
        self.stop.set()
        self.wake.set()
        if self.executor:
            self.executor.shutdown(wait=True)
        self.credentials.clear()
        if self.lock_file:
            self.lock_file.close()

    def credential(self, task_id, token=None):
        with self.mutex:
            now = time.monotonic()
            self.credentials = {
                key: value for key, value in self.credentials.items() if value[1] > now
            }
            if token:
                self.credentials[str(task_id)] = (token, now + 900)
            return self.credentials.get(str(task_id), (None, 0))[0]

    def admit(self, body, kind, *, auth=None):
        task = self.store.admit(
            kind=kind,
            version=body.expected_version,
            key=body.idempotency_key,
            plan=body if kind == "execute" else None,
            auth=auth,
        )
        if body.management_token:
            self.credential(task.task_id, body.management_token.get_secret_value())
        self.wake.set()
        return task

    def authorize(self, task_id, body, *, auth=None):
        with self.mutex:
            context = self.store.context(task_id)
            if context.get("target", self.target) != self.target:
                raise ContractError(
                    409,
                    "task_invalidated",
                    "业务目标已改变，原任务不能使用补交凭据恢复",
                )
            result = self.store.authorize(task_id, auth=auth)
            self.credential(task_id, body.management_token.get_secret_value())
        self.wake.set()
        return result

    def _loop(self):
        while not self.stop.is_set():
            self.wake.wait(2)
            self.wake.clear()
            if self.stop.is_set():
                return
            try:
                for task_id in self.store.pending():
                    task = self.store.get(task_id)
                    if task.stage == "awaiting_authorization" and not self.credential(
                        task_id
                    ):
                        continue
                    self.run_one(task_id)
            except (sqlite3.Error, OSError):
                # Retain the durable task/effect boundary; retry storage on the next tick.
                continue

    def run_one(self, task_id):
        task = self.store.get(task_id)
        if task.stage == "finished":
            return
        try:
            context = self.store.context(task_id)
            token = self.credential(task_id) or self.credential(
                context.get("probe_task_id")
            )
            cloud = self.cloud_factory(token) if token else None
            if task.kind == "probe":
                self._probe(task_id, context, cloud)
            else:
                self._execute(task_id, context, cloud)
        except PublicFailure as error:
            stage = "awaiting_" + error.waiting if error.waiting else "finished"
            actions = (
                ["authorize"]
                if error.waiting == "authorization"
                else ["local_admin"]
                if error.waiting
                else []
            )
            current = self.store.get(task_id)
            if (current.stage, current.issue_code) != (stage, error.code):
                self.store.publish(
                    task_id,
                    stage=stage,
                    classification="unknown" if error.waiting else "failed",
                    issue_code=error.code,
                    allowed_actions=actions,
                    message=error.message,
                )
            # An invalid/expired key must not cause a 2-second authorization retry loop.
            if error.waiting == "authorization":
                with self.mutex:
                    self.credentials.pop(str(task_id), None)
                    self.credentials.pop(context.get("probe_task_id"), None)
        except (ContractError, OSError, ValueError, KeyError, TypeError):
            self.store.publish(
                task_id,
                stage="finished",
                classification="failed",
                issue_code="operation_rejected",
                allowed_actions=[],
                message="操作未完成，保留已知资源；请核对配置和私密状态目录",
            )
        except sqlite3.Error:
            raise
        except (RuntimeError, AttributeError, IndexError):
            self.store.publish(
                task_id,
                stage="finished",
                classification="failed",
                issue_code="worker_failed",
                allowed_actions=[],
                message="执行器异常中止；已记录的资源与意图保留，未自动重复副作用",
            )

    @staticmethod
    def require_cloud(cloud):
        if cloud is None:
            raise PublicFailure(
                "cloud_authorization_required",
                "请提交专用 Cloudflare API Token；只授予所属区域 Zone Read/DNS Edit 及账户 Tunnel Edit",
                waiting="authorization",
            )

    def _inventory(self, context, cloud):
        self.require_cloud(cloud)
        inventory = cloud.inspect(context["domain"])
        owned = self.store.owned_tunnels()
        chosen = None
        for record in inventory["records"]:
            matches = [
                t
                for t in inventory["tunnels"]
                if record.get("type") == "CNAME"
                and record.get("content", "").rstrip(".")
                == f"{t.get('id')}.cfargotunnel.com"
                and record.get("proxied") is True
            ]
            if len(matches) != 1 or matches[0]["id"] not in owned:
                raise PublicFailure(
                    "route_conflict",
                    "域名已有非本应用管理或不匹配的记录，停止；不会覆盖或接管",
                )
            tunnel = matches[0]
            if (
                tunnel.get("remote_config") is False
                or tunnel.get("config_src") == "local"
            ):
                raise PublicFailure(
                    "local_managed_tunnel",
                    "该 Tunnel 为本地管理模式；运行可能正常，禁止自动改写本地配置",
                )
            secret = self.adapter.files.secret(owned[tunnel["id"]])
            token = cloud.token(inventory["account_id"], tunnel["id"])
            if not cloud.owns_token(token, secret, tunnel["id"]):
                raise PublicFailure(
                    "tunnel_ownership_unknown",
                    "现有 Tunnel 不能证明由本应用创建，停止接管",
                )
            desired = cloud.ingress(context["domain"], self.target)
            if (
                cloud.config(inventory["account_id"], tunnel["id"]).get("ingress")
                != desired["ingress"]
            ):
                raise PublicFailure(
                    "tunnel_route_conflict",
                    "现有 Tunnel 路由或业务目标不匹配，停止覆盖",
                )
            chosen = tunnel["id"]
        if len(inventory["records"]) > 1:
            raise PublicFailure("route_conflict", "域名存在多条记录，停止自动处理")
        return inventory, chosen

    def _probe(self, task_id, context, cloud):
        self.store.publish(
            task_id,
            stage="detecting",
            classification="running",
            issue_code=None,
            allowed_actions=[],
            message="正在检查本机与公网配置",
        )
        local = self.adapter.inspect(context["instance_id"])
        initial = [
            *local,
            *[
                check(name, "unknown", message="尚未核实")
                for name in ("authorization", "connection", "route", "instance")
            ],
        ]
        self.store.publish(task_id, checks=[x.model_dump() for x in initial])
        install = local[0]
        if install.classification != "passed":
            self.store.publish(
                task_id,
                stage="finished",
                classification=install.classification,
                issue_code=install.issue_code,
                allowed_actions=install.allowed_actions,
                requires_confirmation="install" in install.allowed_actions,
                message=install.message,
            )
            return
        if (
            local[1].classification == "unknown"
            or local[1].issue_code == "service_conflict"
        ):
            self.store.publish(
                task_id,
                stage="finished",
                classification=local[1].classification,
                issue_code=local[1].issue_code,
                allowed_actions=["local_admin"],
                message=local[1].message,
            )
            return
        if cloud is None:
            remaining = [
                check(
                    name,
                    "unknown",
                    "cloud_authorization_required",
                    ("authorize",),
                    "未授权，不能核实",
                )
                for name in ("authorization", "connection", "route", "instance")
            ]
            self.store.publish(
                task_id, checks=[x.model_dump() for x in [*local, *remaining]]
            )
            self.require_cloud(cloud)
        inventory, owned = self._inventory(context, cloud)
        context.update({key: inventory[key] for key in ("zone_id", "account_id")})
        context["owned_tunnel"] = owned
        active = self.store.config().active
        if (
            active
            and active.domain != context["domain"]
            and local[1].classification == "passed"
        ):
            raise PublicFailure(
                "existing_service_conflict",
                "已有服务绑定其他已生效域名；不会覆盖或迁移现有服务",
            )
        tunnel = next(
            (item for item in inventory["tunnels"] if item["id"] == owned), None
        )
        connected = bool(
            tunnel
            and tunnel.get("status") in ("healthy", "degraded")
            and tunnel.get("connections")
        )
        results = [
            *local,
            check(
                "authorization",
                "passed",
                message="可读取授权区域与 Tunnel；写权限在确认执行时仍会由 Cloudflare 检查",
            ),
            check(
                "connection",
                "passed" if connected else "failed",
                "tunnel_not_connected" if not connected else None,
                message="已检测到实际连接" if connected else "未检测到当前 Tunnel 连接",
            ),
            check(
                "route",
                "passed" if owned else "not_applicable",
                message="已核对本应用路由" if owned else "域名无冲突记录",
            ),
        ]
        verified = False
        if owned:
            try:
                self.verifier.verify(context["domain"])
                verified = True
            except PublicFailure:
                pass
        results.append(
            check(
                "instance",
                "passed" if verified else "failed",
                "instance_not_verified" if not verified else None,
                message="随机挑战匹配当前实例" if verified else "当前实例尚未验证",
            )
        )
        action = "verify" if verified else "create_and_connect"
        self.store.publish(
            task_id,
            context=context,
            checks=[x.model_dump() for x in results],
            stage="finished",
            classification="passed" if verified else "failed",
            issue_code=None if verified else "configuration_required",
            allowed_actions=[action],
            requires_confirmation=True,
            message="可复用当前配置，请确认验证生效"
            if verified
            else "检查完成，可创建并连接专用 Tunnel",
        )

    def _resource(self, task_id, kind, resource_id, ownership):
        task = self.store.get(task_id)
        resources = [x.model_dump() for x in task.resources]
        if not any(
            x["kind"] == kind and x["resource_id"] == resource_id for x in resources
        ):
            resources.append(
                {"kind": kind, "resource_id": resource_id, "ownership": ownership}
            )
            self.store.publish(task_id, resources=resources)

    def _local(self, task_id, context, action, token=None):
        step = "package" if action == "install" else "service"
        intent = {"action": action, "instance_id": context["instance_id"]}
        effect = self.store.effect(task_id, step, intent)
        local = self.adapter.inspect(context["instance_id"])
        ready = (
            local[0].classification == "passed"
            if action == "install"
            else local[1].classification == "passed"
        )
        reused = ready and effect["state"] == "prepared"
        if not ready:
            if effect["state"] != "prepared":
                raise PublicFailure(
                    "local_result_unknown",
                    "本机操作尚未确认；请管理员核对保存的请求，服务就绪后原任务自动恢复",
                    waiting="local_admin",
                )
            self.store.mark_effect(task_id, step, "sent")
            self.adapter.apply(action, task_id, context["instance_id"], token)
            local = self.adapter.inspect(context["instance_id"])
            ready = (
                local[0].classification == "passed"
                if action == "install"
                else local[1].classification == "passed"
            )
            if not ready:
                raise PublicFailure(
                    "local_result_unknown",
                    "本机助手返回后状态仍未知，等待本机管理员核对",
                    waiting="local_admin",
                )
        self.store.mark_effect(
            task_id,
            step,
            "done",
            {"id": context["instance_id"] if action != "install" else "cloudflared"},
        )
        self._resource(
            task_id,
            step,
            "cloudflared" if action == "install" else context["instance_id"],
            "reused" if reused else "created_by_task",
        )

    def _execute(self, task_id, context, cloud):
        if context["target"] != self.target:
            raise PublicFailure(
                "target_changed", "业务监听目标已改变，请重新探测和确认"
            )
        if context["action"] == "install":
            self._local(task_id, context, "install")
            self.store.publish(
                task_id,
                stage="finished",
                classification="passed",
                issue_code=None,
                allowed_actions=[],
                message="cloudflared 安装已核实，请重新探测",
            )
            return
        self.require_cloud(cloud)
        local = self.adapter.inspect(context["instance_id"])
        if (
            local[0].classification != "passed"
            or local[1].classification == "unknown"
            or local[1].issue_code == "service_conflict"
        ):
            raise PublicFailure(
                "plan_prerequisites_changed",
                "本机前提已变化，请核对安装及服务归属后重新探测、计划和确认",
            )
        # Re-read scope and conflicts before any write, including resumed tasks.
        inventory, owned = self._inventory(context, cloud)
        if owned != context.get("owned_tunnel") and not (
            owned and self.store.owned_tunnels().get(owned) == str(task_id)
        ):
            raise PublicFailure(
                "plan_prerequisites_changed",
                "现有资源已变化，原计划不再适用；未执行新的副作用",
            )
        if any(inventory[key] != context[key] for key in ("zone_id", "account_id")):
            raise PublicFailure(
                "cloud_scope_changed", "区域或账户已变化，原确认计划不再适用"
            )
        account, zone = context["account_id"], context["zone_id"]
        if owned:
            tunnel = owned
            ownership = (
                "created_by_task"
                if self.store.owned_tunnels().get(tunnel) == str(task_id)
                else "reused"
            )
            self._resource(task_id, "tunnel", tunnel, ownership)
        elif context["action"] == "verify":
            raise PublicFailure("route_changed", "已验证路由发生变化，停止执行原计划")
        else:
            name = "bb-" + str(task_id)
            effect = self.store.effect(
                task_id, "tunnel", {"name": name, "account": account}
            )
            secret = self.adapter.files.secret(
                task_id, create=effect["state"] == "prepared"
            )
            matches = [
                item
                for item in cloud.tunnels(account, name)
                if item.get("name") == name
            ]
            if not matches:
                if effect["state"] != "prepared":
                    raise unknown("tunnel_create_unknown")
                self.store.publish(
                    task_id,
                    stage="creating_tunnel",
                    classification="running",
                    message="正在创建专用 Tunnel",
                )
                self.store.mark_effect(task_id, "tunnel", "sent")
                tunnel = cloud.create_tunnel(account, name, secret)
            elif len(matches) == 1:
                tunnel = str(UUID(matches[0]["id"]))
            else:
                raise PublicFailure(
                    "tunnel_name_conflict", "存在多个同名 Tunnel，停止处理"
                )
            runtime_token = cloud.token(account, tunnel)
            if not cloud.owns_token(runtime_token, secret, tunnel):
                raise PublicFailure(
                    "tunnel_ownership_unknown", "Tunnel 密钥不匹配本任务意图，禁止接管"
                )
            self.store.mark_effect(task_id, "tunnel", "done", {"id": tunnel})
            self._resource(task_id, "tunnel", tunnel, "created_by_task")
            desired = cloud.ingress(context["domain"], self.target)
            effect = self.store.effect(
                task_id, "ingress", {"tunnel": tunnel, "config": desired}
            )
            current = cloud.config(account, tunnel)
            if current.get("ingress") != desired["ingress"]:
                if effect["state"] != "prepared":
                    raise unknown("ingress_update_unknown")
                if current.get("ingress") not in (
                    None,
                    [],
                    [{"service": "http_status:404"}],
                ):
                    raise PublicFailure(
                        "tunnel_route_conflict", "Tunnel 已有其他路由，停止覆盖"
                    )
                self.store.mark_effect(task_id, "ingress", "sent")
                cloud.configure(account, tunnel, context["domain"], self.target)
                if cloud.config(account, tunnel).get("ingress") != desired["ingress"]:
                    raise unknown("ingress_update_unknown")
            self.store.mark_effect(task_id, "ingress", "done", {"id": tunnel})
        marker = "bb-task:" + str(task_id)
        effect = self.store.effect(
            task_id,
            "dns",
            {"domain": context["domain"], "tunnel": tunnel, "zone": zone},
        )
        records = cloud.records(zone, context["domain"])
        if not records:
            if effect["state"] != "prepared":
                raise unknown("dns_create_unknown")
            self.store.publish(
                task_id,
                stage="creating_route",
                classification="running",
                message="正在创建专用 DNS 路由",
            )
            self.store.mark_effect(task_id, "dns", "sent")
            cloud.create_record(zone, context["domain"], tunnel, marker)
            records = cloud.records(zone, context["domain"])
        if (
            len(records) != 1
            or records[0].get("type") != "CNAME"
            or records[0].get("content", "").rstrip(".") != f"{tunnel}.cfargotunnel.com"
            or records[0].get("proxied") is not True
        ):
            raise PublicFailure(
                "route_conflict", "DNS 路由冲突或结果未知，保留本任务已创建资源"
            )
        ownership = (
            "created_by_task" if records[0].get("comment") == marker else "reused"
        )
        record_id = identifier(records[0]["id"])
        self.store.mark_effect(task_id, "dns", "done", {"id": record_id})
        self._resource(task_id, "dns", record_id, ownership)
        if context["action"] != "verify":
            self.store.publish(
                task_id,
                stage="connecting",
                classification="running",
                message="连接本机专用服务",
            )
            self._local(task_id, context, "connect", cloud.token(account, tunnel))
        self.store.publish(
            task_id,
            stage="verifying",
            classification="running",
            message="正在核对公网与本机的短期随机挑战",
        )
        self.verifier.verify(context["domain"])
        self.store.activate(task_id, tunnel)
