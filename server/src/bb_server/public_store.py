"""Single transactional owner of configuration, tasks, confirmations and event order."""

import hashlib
import json
from pathlib import Path
from uuid import uuid4

from bb_auth_contract import ContractError
from bb_auth_contract.admin import ActionPlan, AdminTask, PublicConfig

from bb_server.storage import connection


def encode(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def fingerprint(value):
    return hashlib.sha256(encode(value).encode()).hexdigest()


def conflict(code="configuration_conflict"):
    return ContractError(409, code, "配置或任务状态已变化，请刷新后重试")


class PublicStore:
    def __init__(self, path: Path, clock):
        self.path, self.clock = path, clock

    def migrate(self):
        with connection(self.path, write=True) as db:
            if db.execute(
                "SELECT 1 FROM sqlite_schema WHERE name='public_schema'"
            ).fetchone():
                if (
                    db.execute("SELECT version FROM public_schema").fetchall()[0][0]
                    != 1
                ):
                    raise RuntimeError("Unsupported public management schema")
                return
            sql = (Path(__file__).parent / "migrations/public_001.sql").read_text(
                encoding="utf-8"
            )
            for statement in sql.split(";"):
                if statement.strip():
                    db.execute(statement)
            db.execute(
                "INSERT INTO public_config VALUES(1, ?, 0, NULL, NULL)", (str(uuid4()),)
            )

    @staticmethod
    def _config(db):
        return db.execute("SELECT * FROM public_config WHERE id=1").fetchone()

    def identity(self):
        with connection(self.path) as db:
            return self._config(db)["instance_id"]

    def config(self):
        with connection(self.path) as db:
            row = self._config(db)
            return PublicConfig(
                version=row["version"],
                domain=row["domain"],
                active=json.loads(row["active"]) if row["active"] else None,
            )

    @staticmethod
    def _task(db, task_id):
        row = db.execute(
            "SELECT * FROM public_tasks WHERE id=?", (str(task_id),)
        ).fetchone()
        if not row:
            raise ContractError(404, "task_not_found", "任务不存在")
        return row

    @staticmethod
    def _unresolved(db, task_id):
        return db.execute(
            "SELECT step FROM public_effects WHERE task_id=? AND state='sent' ORDER BY rowid LIMIT 1",
            (str(task_id),),
        ).fetchone()

    @staticmethod
    def _emit(db, row, **changes):
        snapshot = json.loads(row["snapshot"])
        snapshot.update(changes)
        # A parser/programming error is not evidence that an external write failed.
        # Every terminal writer shares this transaction boundary and target lock.
        if snapshot["stage"] == "finished":
            unresolved = PublicStore._unresolved(db, row["id"])
            if unresolved:
                local = unresolved["step"] in ("package", "service")
                snapshot.update(
                    stage="awaiting_local_admin" if local else "awaiting_authorization",
                    classification="unknown",
                    issue_code="effect_result_unknown",
                    allowed_actions=["local_admin" if local else "authorize"],
                    requires_confirmation=False,
                    message="已发送操作的结果尚未核实；保留原任务和资源，请核对后恢复，禁止重新创建",
                )
        snapshot["seq"] += 1
        snapshot = AdminTask.model_validate(snapshot).model_dump(mode="json")
        value = encode(snapshot)
        db.execute(
            "UPDATE public_tasks SET snapshot=?, terminal=? WHERE id=?",
            (value, int(snapshot["stage"] == "finished"), row["id"]),
        )
        db.execute(
            "INSERT INTO public_events VALUES(?,?,?)",
            (row["id"], snapshot["seq"], value),
        )
        return AdminTask.model_validate(snapshot)

    def save(self, body, *, auth=None):
        with connection(self.path, write=True) as db:
            if auth:
                auth(db)
            config = self._config(db)
            if config["version"] != body.expected_version:
                raise conflict()
            active = db.execute(
                "SELECT * FROM public_tasks WHERE terminal=0"
            ).fetchone()
            if active and active["kind"] == "execute":
                raise conflict("task_busy")
            if active:
                self._emit(
                    db,
                    active,
                    stage="finished",
                    classification="failed",
                    issue_code="draft_superseded",
                    allowed_actions=[],
                    message="域名草稿已变化，请重新探测",
                )
            db.execute(
                "UPDATE public_config SET version=version+1, domain=? WHERE id=1",
                (body.domain,),
            )
            # Historical plans remain immutable; version comparison invalidates them.
        return self.config()

    def get(self, task_id):
        with connection(self.path) as db:
            return AdminTask.model_validate_json(self._task(db, task_id)["snapshot"])

    def current(self):
        with connection(self.path) as db:
            row = db.execute(
                "SELECT snapshot FROM public_tasks ORDER BY rowid DESC LIMIT 1"
            ).fetchone()
            return AdminTask.model_validate_json(row[0]) if row else None

    def context(self, task_id):
        with connection(self.path) as db:
            return json.loads(self._task(db, task_id)["context"])

    def pending(self):
        with connection(self.path) as db:
            return [
                row[0]
                for row in db.execute("SELECT id FROM public_tasks WHERE terminal=0")
            ]

    def publish(self, task_id, *, context=None, **changes):
        with connection(self.path, write=True) as db:
            row = self._task(db, task_id)
            if row["terminal"]:
                return AdminTask.model_validate_json(row["snapshot"])
            if context is not None:
                db.execute(
                    "UPDATE public_tasks SET context=? WHERE id=?",
                    (encode(context), str(task_id)),
                )
            return self._emit(db, row, **changes)

    def admit(self, *, kind, version, key, plan=None, auth=None):
        request_hash = fingerprint(
            {
                "kind": kind,
                "version": version,
                "plan": plan.model_dump(
                    mode="json", exclude={"management_token", "idempotency_key"}
                )
                if plan
                else None,
            }
        )
        with connection(self.path, write=True) as db:
            if auth:
                auth(db)
            previous = db.execute(
                "SELECT * FROM public_keys WHERE key=?", (str(key),)
            ).fetchone()
            if previous:
                if previous["fingerprint"] != request_hash:
                    raise conflict("idempotency_conflict")
                return AdminTask.model_validate_json(
                    self._task(db, previous["task_id"])["snapshot"]
                )
            config = self._config(db)
            context = {"domain": config["domain"], "instance_id": config["instance_id"]}
            plan_id = str(plan.plan_id) if plan else None
            if plan:
                stored = db.execute(
                    "SELECT * FROM public_plans WHERE id=?", (plan_id,)
                ).fetchone()
                if not stored:
                    raise conflict("plan_invalid")
                detail = json.loads(stored["snapshot"])
                if detail["digest"] != plan.digest or stored["version"] != version:
                    raise conflict("plan_invalid")
                existing = db.execute(
                    "SELECT * FROM public_tasks WHERE plan_id=?", (plan_id,)
                ).fetchone()
                if existing:
                    db.execute(
                        "INSERT INTO public_keys VALUES(?,?,?)",
                        (str(key), request_hash, existing["id"]),
                    )
                    return AdminTask.model_validate_json(existing["snapshot"])
                if detail["expires_at"] <= self.clock():
                    raise conflict("plan_expired")
                context.update(json.loads(stored["context"]))
                context["plan"] = detail
            if version != config["version"] or not config["domain"]:
                raise conflict(
                    "draft_required"
                    if not config["domain"]
                    else "configuration_conflict"
                )
            if db.execute("SELECT 1 FROM public_tasks WHERE terminal=0").fetchone():
                raise conflict("task_busy")
            task_id = str(uuid4())
            snapshot = AdminTask(
                task_id=task_id,
                seq=1,
                config_version=version,
                kind=kind,
                stage="queued",
                classification="pending",
                issue_code=None,
                allowed_actions=[],
                requires_confirmation=False,
                checks=[],
                resources=[],
                message="任务已接收",
            )
            value = snapshot.model_dump_json()
            db.execute(
                "INSERT INTO public_tasks VALUES(?,?,?,?,0,?,?)",
                (task_id, kind, version, plan_id, value, encode(context)),
            )
            db.execute(
                "INSERT INTO public_keys VALUES(?,?,?)",
                (str(key), request_hash, task_id),
            )
            db.execute("INSERT INTO public_events VALUES(?,1,?)", (task_id, value))
            return snapshot

    def plan(self, body, *, target, auth=None):
        with connection(self.path, write=True) as db:
            if auth:
                auth(db)
            config = self._config(db)
            row = self._task(db, body.probe_task_id)
            task = json.loads(row["snapshot"])
            if (
                row["kind"] != "probe"
                or not row["terminal"]
                or row["version"] != body.expected_version
                or config["version"] != body.expected_version
                or body.action not in task["allowed_actions"]
            ):
                raise conflict("probe_stale")
            if body.action not in ("install", "create_and_connect", "verify"):
                raise conflict("action_not_confirmable")
            context = json.loads(row["context"])
            context.update(action=body.action, target=target)
            context["probe_task_id"] = str(body.probe_task_id)
            resources = (
                [{"kind": "package", "operation": "create", "name": "cloudflared"}]
                if body.action == "install"
                else []
            )
            if body.action == "create_and_connect":
                resources = [
                    {
                        "kind": kind,
                        "operation": "reuse"
                        if context.get("owned_tunnel") and kind != "service"
                        else "create",
                        "name": name,
                    }
                    for kind, name in (
                        ("tunnel", "BB dedicated tunnel"),
                        ("dns", config["domain"]),
                        ("service", "BB cloudflared service"),
                    )
                ]
            value = {
                "plan_id": str(uuid4()),
                "config_version": config["version"],
                "domain": config["domain"],
                "target_service": target,
                "resources": resources,
                "public_scope": [
                    "BB business API only; management and Dart local control excluded"
                ],
                "risks": [
                    "Publishes business API to the Internet",
                    "Creates only the listed resources; OS elevation and cloud permission are separate",
                ]
                if body.action != "install"
                else [
                    "Installs cloudflared from the platform's official channel; requires local OS approval"
                ],
                "requires_confirmation": True,
                "expires_at": self.clock() + 600,
            }
            value["digest"] = fingerprint(value)
            plan = ActionPlan.model_validate(value)
            db.execute(
                "INSERT INTO public_plans VALUES(?,?,?,?)",
                (
                    str(plan.plan_id),
                    config["version"],
                    plan.model_dump_json(),
                    encode(context),
                ),
            )
            return plan

    def authorize(self, task_id, *, auth=None):
        with connection(self.path, write=True) as db:
            if auth:
                auth(db)
            row = self._task(db, task_id)
            task = json.loads(row["snapshot"])
            if (
                row["terminal"]
                or task["stage"] != "awaiting_authorization"
                or row["version"] != self._config(db)["version"]
            ):
                raise conflict("authorization_not_needed")
            return self._emit(
                db,
                row,
                stage="reconciling",
                classification="pending",
                allowed_actions=[],
                issue_code=None,
                message="已接收授权，核对原任务后继续",
            )

    def events(self, task_id, after):
        with connection(self.path) as db:
            task = json.loads(self._task(db, task_id)["snapshot"])
            if after > task["seq"]:
                raise conflict("event_cursor_future")
            return [
                (row[0], row[1])
                for row in db.execute(
                    "SELECT seq,snapshot FROM public_events WHERE task_id=? AND seq>? ORDER BY seq",
                    (str(task_id), after),
                )
            ]

    def effect(self, task_id, step, intent):
        with connection(self.path, write=True) as db:
            task = self._task(db, task_id)
            if task["terminal"]:
                raise conflict("task_finished")
            db.execute(
                "INSERT INTO public_effects VALUES(?,?,'prepared',?,NULL) ON CONFLICT DO NOTHING",
                (str(task_id), step, encode(intent)),
            )
            row = db.execute(
                "SELECT * FROM public_effects WHERE task_id=? AND step=?",
                (str(task_id), step),
            ).fetchone()
            if row["intent"] != encode(intent):
                raise conflict("effect_intent_changed")
            return {
                **dict(row),
                "intent": json.loads(row["intent"]),
                "outcome": json.loads(row["outcome"]) if row["outcome"] else None,
            }

    def mark_effect(self, task_id, step, state, outcome=None):
        with connection(self.path, write=True) as db:
            row = self._task(db, task_id)
            if row["terminal"]:
                raise conflict("task_finished")
            db.execute(
                "UPDATE public_effects SET state=?, outcome=? WHERE task_id=? AND step=?",
                (state, encode(outcome) if outcome else None, str(task_id), step),
            )

    def activate(self, task_id, tunnel_id):
        with connection(self.path, write=True) as db:
            row = self._task(db, task_id)
            config = self._config(db)
            if row["terminal"] or config["version"] != row["version"]:
                raise conflict()
            if self._unresolved(db, task_id):
                raise conflict("effect_unresolved")
            active = {
                "domain": config["domain"],
                "instance_id": config["instance_id"],
                "verified_at": self.clock(),
                "tunnel_id": tunnel_id,
            }
            db.execute(
                "UPDATE public_config SET active=? WHERE id=1", (encode(active),)
            )
            return self._emit(
                db,
                row,
                stage="finished",
                classification="passed",
                issue_code=None,
                allowed_actions=[],
                message="公网挑战与当前实例匹配，配置已生效",
            )

    def owned_tunnels(self):
        with connection(self.path) as db:
            return {
                json.loads(row["outcome"])["id"]: row["task_id"]
                for row in db.execute(
                    "SELECT task_id,outcome FROM public_effects WHERE step='tunnel' AND state='done' AND outcome IS NOT NULL"
                )
            }
