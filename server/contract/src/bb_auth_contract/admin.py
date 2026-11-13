"""DEA-469 management wire types. No database, network or shell operations."""

from typing import Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, SecretStr, field_validator

PREFIX = "/admin/api"
COOKIE = "bb_admin_session"
SESSION_SECONDS = 8 * 60 * 60


class AdminModel(BaseModel):
    model_config = ConfigDict(extra="forbid", hide_input_in_errors=True)


class AdminLogin(AdminModel):
    username: str = Field(strict=True, min_length=1, max_length=64)
    password: SecretStr = Field(min_length=1, max_length=1024)


class PasswordChange(AdminModel):
    old_password: SecretStr = Field(min_length=1, max_length=1024)
    new_password: SecretStr = Field(min_length=12, max_length=1024)


class AdminSession(AdminModel):
    username: Literal["admin"] = "admin"
    must_change_password: bool
    csrf_token: str = Field(repr=False)
    expires_at: float


class DraftSave(AdminModel):
    expected_version: int = Field(strict=True, ge=0)
    domain: str = Field(strict=True, max_length=253)

    @field_validator("domain")
    @classmethod
    def domain_name(cls, value):
        # Dedicated ASCII subdomain only; no URLs, IP literals, ports or wildcards.
        import re

        value = value.lower()
        labels = value.split(".")
        if (
            len(labels) < 3
            or not re.fullmatch(r"[a-z]{2,63}", labels[-1])
            or any(
                not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", label)
                for label in labels
            )
        ):
            raise ValueError("A dedicated ASCII subdomain is required")
        return value


class ActiveConfig(AdminModel):
    domain: str
    verified_at: float
    instance_id: UUID
    tunnel_id: str


class PublicConfig(AdminModel):
    version: int = Field(ge=0)
    domain: str | None
    active: ActiveConfig | None


class ProbeStart(AdminModel):
    expected_version: int = Field(strict=True, ge=0)
    idempotency_key: UUID
    management_token: SecretStr | None = Field(default=None, max_length=4096)


Action = Literal[
    "install", "authorize", "create_and_connect", "verify", "reconcile", "local_admin"
]
Classification = Literal[
    "pending", "running", "passed", "failed", "unknown", "not_applicable"
]


class CheckResult(AdminModel):
    check: Literal[
        "installation", "service", "connection", "authorization", "route", "instance"
    ]
    classification: Classification
    issue_code: str | None
    message: str = Field(
        description="Allowlisted, sanitized user-facing detail; never raw subprocess/API output"
    )
    allowed_actions: list[Action]


class PlanCreate(AdminModel):
    expected_version: int = Field(strict=True, ge=0)
    probe_task_id: UUID
    action: Action


class ResourceIntent(AdminModel):
    kind: Literal["package", "service", "tunnel", "dns"]
    operation: Literal["create", "reuse"]
    name: str


class ActionPlan(AdminModel):
    plan_id: UUID
    config_version: int
    digest: str
    domain: str
    target_service: str = Field(
        description="Server-selected business listener only; never supplied by browser"
    )
    resources: list[ResourceIntent]
    public_scope: list[str]
    risks: list[str]
    requires_confirmation: Literal[True] = True
    expires_at: float


class PlanExecute(AdminModel):
    plan_id: UUID
    digest: str = Field(strict=True, min_length=64, max_length=64)
    expected_version: int = Field(strict=True, ge=0)
    idempotency_key: UUID
    confirmed: Literal[True]
    management_token: SecretStr | None = Field(default=None, max_length=4096)


class OwnedResource(AdminModel):
    kind: Literal["package", "service", "tunnel", "dns"]
    resource_id: str
    ownership: Literal["created_by_task", "reused", "unknown"]


class AdminTask(AdminModel):
    task_id: UUID
    seq: int = Field(ge=1)
    config_version: int
    kind: Literal["probe", "execute"]
    stage: Literal[
        "queued",
        "detecting",
        "awaiting_authorization",
        "awaiting_local_admin",
        "installing",
        "creating_tunnel",
        "creating_route",
        "connecting",
        "verifying",
        "reconciling",
        "finished",
    ]
    classification: Classification
    issue_code: str | None
    allowed_actions: list[Action]
    requires_confirmation: bool
    checks: list[CheckResult]
    resources: list[OwnedResource]
    message: str


class CurrentTask(AdminModel):
    task: AdminTask | None


class TaskAuthorization(AdminModel):
    management_token: SecretStr = Field(min_length=1, max_length=4096)
