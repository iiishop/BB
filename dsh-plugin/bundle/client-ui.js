window.__ModuleLoader__.load({
  id: "@bb/dsh-bridge",
  factory(require) {
    const React = require("react"),
      h = React.createElement;
    const NS = "bb.bridge.settings";
    const copy = {
      en: {
        title: "BB Chat Bridge",
        description:
          "Connect your local BB client to an existing DSH session. Authentication stays in BB.",
        clientUrl: "BB client URL",
        urlHint: "Loopback HTTP only, for example http://127.0.0.1:9187.",
        targetSession: "Target session ID",
        sessionHint:
          "Use an existing DSH session. Unsettled work requires its original session.",
        peerAccount: "Peer account (optional)",
        peerHint:
          "Eight digits. Leave empty to follow authorized conversations.",
        enabled: "Enable bridge",
        enabledHint:
          "Save to stop or resume BB connections and automatic delivery.",
        pollMs: "Refresh interval (ms)",
        pollHint: "Whole number from 250 to 30000. Changes apply live.",
        save: "Save changes",
        saving: "Saving…",
        reload: "Reload saved values",
        saved: "Saved. Changes apply live; no host restart is required.",
        refused:
          "Save was refused. The configuration may have changed elsewhere. Reload saved values before trying again.",
        changed:
          "Configuration changed elsewhere. Your draft is preserved; reload to use the latest revision.",
        unavailable: "BB settings are not available in this profile.",
        loading: "Loading settings…",
        readonly: "This profile does not allow settings changes.",
        invalidUrl:
          "Enter a loopback HTTP URL with a valid port and no credentials, path or query.",
        invalidSession:
          "Use up to 200 letters, digits, hyphens or underscores.",
        invalidPeer: "Enter eight digits starting with 1–9, or leave empty.",
        invalidPoll: "Enter a whole number from 250 to 30000.",
        status: "Connection status",
        refresh: "Refresh status",
        disabled: "Disabled",
        blocked: "Binding stopped by a recovery or identity fence",
        connection_unavailable:
          "Client connection unavailable; automatic rebinding is paused",
        stopped: "Bridge stopped; manual recovery is required",
        connectionHelp:
          "Start the BB client and check its loopback URL and port. Save a corrected URL, or uncheck Enable bridge and save, then check it and save again. Existing uncertain work is retained.",
        blockedHelp:
          "Resolve the diagnostic before rebinding. Keep the original account/session and recovery records; do not delete uncertain work. After resolving it, disable and save, then enable and save.",
        stoppedHelp:
          "Check the diagnostic and restore the client/plugin prerequisites. Then disable and save, and enable and save. Preserve recovery records; do not resend uncertain operations.",
        bound: "Connected and bound",
        choose_session: "Choose a session",
        session_unavailable:
          "Target session is not running; open or resume it in DSH",
        login_required:
          "Log in using BB client or the registration/login MCP tools; then disable/save and enable/save to rebind",
        connecting: "Connecting / waiting for client",
        statusUnavailable: "Status unavailable",
        recovery: "Resume the original session before rebinding:",
        error: "Diagnostic code",
      },
      zh: {
        title: "BB 聊天桥接",
        description:
          "将本机 BB 客户端连接到已有 DSH 会话。认证始终由 BB 客户端持有。",
        clientUrl: "BB 客户端地址",
        urlHint: "仅允许本机 HTTP，例如 http://127.0.0.1:9187。",
        targetSession: "目标会话 ID",
        sessionHint: "填写已有 DSH 会话；未结算任务必须恢复原会话。",
        peerAccount: "对方账号（可选）",
        peerHint: "八位数字；留空则跟随已授权的会话。",
        enabled: "启用桥接",
        enabledHint: "保存后停止或恢复 BB 连接及自动投递。",
        pollMs: "刷新间隔（毫秒）",
        pollHint: "250–30000 的整数，保存后实时生效。",
        save: "保存更改",
        saving: "保存中…",
        reload: "重新读取已保存值",
        saved: "已保存，配置实时生效，无需重启宿主。",
        refused:
          "保存被拒绝，配置可能已被其他页面修改。请重新读取已保存值后再试。",
        changed: "配置已在其他页面更改。当前草稿已保留，请重新读取最新版本。",
        unavailable: "当前 profile 无可用 BB 配置。",
        loading: "正在读取配置…",
        readonly: "当前 profile 不允许修改设置。",
        invalidUrl:
          "请填写有效端口的本机 HTTP 地址，不得包含凭据、路径或查询参数。",
        invalidSession: "最多 200 个英文字母、数字、短横线或下划线。",
        invalidPeer: "请填写以 1–9 开头的八位数字，或留空。",
        invalidPoll: "请输入 250–30000 的整数。",
        status: "连接状态",
        refresh: "刷新状态",
        disabled: "已停用",
        blocked: "身份或恢复围栏已停止绑定",
        connection_unavailable: "客户端连接不可用；自动重绑已暂停",
        stopped: "桥接已停止，需要手动恢复",
        connectionHelp:
          "请启动 BB 客户端并检查本机地址和端口。修正地址后保存，或取消“启用桥接”并保存，再勾选并保存。既有不确定任务会保留。",
        blockedHelp:
          "请先解决诊断指出的限制，保留原账号、会话及恢复记录，不得删除不确定任务。解决后停用并保存，再启用并保存。",
        stoppedHelp:
          "请检查诊断并恢复客户端或插件所需条件，再停用并保存、启用并保存。保留恢复记录，不得重发结果不确定的操作。",
        bound: "已连接并绑定",
        choose_session: "请选择目标会话",
        session_unavailable: "目标会话尚未运行，请在 DSH 中打开或恢复",
        login_required:
          "请通过 BB 客户端或注册/登录 MCP 工具登录，再停用并保存、启用并保存以重新绑定",
        connecting: "正在连接或等待客户端",
        statusUnavailable: "暂时无法读取状态",
        recovery: "重新绑定前请恢复原会话：",
        error: "诊断代码",
      },
    };
    const fields = [
      "clientUrl",
      "targetSession",
      "peerAccount",
      "enabled",
      "pollMs",
    ];
    const styles = `
      .bb-settings{color:var(--dsw-alias-label-primary);max-width:680px;font-size:14px;line-height:1.5}
      .bb-settings p{margin:0 0 16px;color:var(--dsw-alias-label-secondary)}
      .bb-settings .bb-field{margin:18px 0}.bb-settings label{display:block;font-weight:600;margin-bottom:6px}
      .bb-settings input:not([type=checkbox]){box-sizing:border-box;width:100%;min-height:44px;padding:10px 12px;background:var(--dsw-alias-bg-layer-2);color:inherit;border:1px solid var(--dsw-alias-border-l2);border-radius:8px;font:inherit}
      .bb-settings small{display:block;margin-top:5px;color:var(--dsw-alias-label-secondary)}
      .bb-settings button{min-height:44px;padding:9px 16px;border:1px solid var(--dsw-alias-border-l2);border-radius:8px;background:var(--dsw-alias-bg-layer-2);color:inherit;font:inherit;cursor:pointer}
      .bb-settings button:disabled{opacity:.5;cursor:default}.bb-settings :focus-visible{outline:2px solid var(--dsw-alias-label-primary);outline-offset:3px}
      .bb-settings .bb-actions{display:flex;gap:12px;flex-wrap:wrap;margin-top:20px}.bb-settings .bb-notice{padding:12px;border:1px solid var(--dsw-alias-border-l2);border-radius:8px;margin:12px 0}
      .bb-settings .bb-toggle{display:flex;gap:12px;align-items:center;min-height:44px}.bb-settings input[type=checkbox]{width:20px;height:20px}
    `;
    function errors(draft, t) {
      const out = {};
      try {
        const u = new URL(draft.clientUrl);
        if (
          u.protocol !== "http:" ||
          u.hostname !== "127.0.0.1" ||
          u.username ||
          u.password ||
          u.pathname !== "/" ||
          u.search ||
          u.hash ||
          u.port === "0" ||
          !/^http:\/\/127\.0\.0\.1(?::[1-9]\d*)?\/?$/.test(draft.clientUrl)
        )
          throw Error();
      } catch {
        out.clientUrl = t("invalidUrl");
      }
      if (!/^[A-Za-z0-9_-]{0,200}$/.test(draft.targetSession))
        out.targetSession = t("invalidSession");
      if (!/^(?:[1-9][0-9]{7})?$/.test(draft.peerAccount))
        out.peerAccount = t("invalidPeer");
      const n = Number(draft.pollMs);
      if (!Number.isInteger(n) || n < 250 || n > 30000)
        out.pollMs = t("invalidPoll");
      return out;
    }
    function Editor({ bbForm: form, connection, t, view }) {
      const id = React.useId();
      const snapshot = React.useSyncExternalStore(
        form.subscribe.bind(form),
        form.getSnapshot.bind(form),
      );
      const [draft, setDraft] = React.useState(null),
        [revision, setRevision] = React.useState(),
        [dirty, setDirty] = React.useState(false),
        [saving, setSaving] = React.useState(false),
        [notice, setNotice] = React.useState(""),
        [health, setHealth] = React.useState(null);
      const reload = (clearNotice = true) => {
        const value = form.getSnapshot();
        if (!value.value) return;
        setDraft(
          Object.fromEntries(fields.map((key) => [key, value.value[key]])),
        );
        setRevision(value.revision);
        setDirty(false);
        if (clearNotice) setNotice("");
      };
      React.useEffect(() => {
        if (!dirty && !saving) reload(false);
      }, [snapshot.value, snapshot.revision]);
      React.useEffect(() => {
        if (view === "summary") return;
        const abort = new AbortController();
        const read = async () => {
          try {
            const response = await fetch(
              new URL("./api/bb-bridge/status", document.baseURI),
              {
                credentials: "same-origin",
                signal: abort.signal,
                cache: "no-store",
              },
            );
            const value = response.ok ? await response.json() : null;
            if (!abort.signal.aborted) setHealth(value);
          } catch {
            if (!abort.signal.aborted) setHealth(null);
          }
        };
        void read();
        const timer = setInterval(read, 2000);
        return () => {
          abort.abort();
          clearInterval(timer);
        };
      }, [connection, view]);
      if (view === "summary") return t("description");
      if (snapshot.status !== "ready" || !draft)
        return h(
          "p",
          null,
          t(snapshot.status === "loading" ? "loading" : "unavailable"),
        );
      const invalid = errors(draft, t),
        disabled = !snapshot.writable || saving;
      const edit = (key, value) => {
        setDraft({ ...draft, [key]: value });
        setDirty(true);
        setNotice("");
      };
      const save = async (event) => {
        event.preventDefault();
        if (disabled || Object.keys(invalid).length) return;
        setSaving(true);
        setNotice("");
        try {
          const accepted = await form.mutate(
            fields.map((key) => ({
              op: "set",
              path: [key],
              value: key === "pollMs" ? Number(draft[key]) : draft[key],
            })),
            revision,
          );
          if (accepted) {
            reload(false);
            setNotice("saved");
          } else setNotice("refused");
        } catch {
          setNotice("refused");
        } finally {
          setSaving(false);
        }
      };
      const field = (key, hint, type = "text") =>
        h(
          "div",
          { className: "bb-field", key },
          h("label", { htmlFor: `${id}-${key}` }, t(key)),
          h("input", {
            id: `${id}-${key}`,
            name: key,
            type,
            value: draft[key],
            disabled,
            "aria-invalid": !!invalid[key],
            "aria-describedby": `${id}-${key}-hint`,
            onChange: (e) => edit(key, e.target.value),
            ...(type === "number" ? { min: 250, max: 30000, step: 1 } : {}),
          }),
          h("small", { id: `${id}-${key}-hint` }, invalid[key] || t(hint)),
        );
      return h(
        "section",
        { className: "bb-settings", "aria-label": t("title") },
        h("style", null, styles),
        view === "page" ? null : h("h2", null, t("title")),
        h("p", null, t("description")),
        h(
          "div",
          { className: "bb-notice", role: "status" },
          h("strong", null, t("status")),
          ": ",
          t(health?.state || "statusUnavailable"),
          ["connection_unavailable", "blocked", "stopped"].includes(
            health?.state,
          )
            ? h(
                "small",
                null,
                t(
                  health.state === "connection_unavailable"
                    ? "connectionHelp"
                    : health.state === "blocked"
                      ? "blockedHelp"
                      : "stoppedHelp",
                ),
              )
            : null,
          health?.error
            ? h("small", null, `${t("error")}: ${health.error}`)
            : null,
          health?.required_sessions?.length
            ? h(
                "small",
                null,
                t("recovery"),
                " ",
                health.required_sessions.join(", "),
              )
            : null,
        ),
        !snapshot.writable ? h("p", { role: "alert" }, t("readonly")) : null,
        dirty && revision !== snapshot.revision
          ? h("p", { role: "alert" }, t("changed"))
          : null,
        h(
          "form",
          { onSubmit: save, noValidate: true },
          field("clientUrl", "urlHint"),
          field("targetSession", "sessionHint"),
          field("peerAccount", "peerHint"),
          field("pollMs", "pollHint", "number"),
          h(
            "div",
            { className: "bb-field" },
            h(
              "label",
              { className: "bb-toggle", htmlFor: `${id}-enabled` },
              h("input", {
                id: `${id}-enabled`,
                name: "enabled",
                type: "checkbox",
                checked: draft.enabled,
                disabled,
                onChange: (e) => edit("enabled", e.target.checked),
              }),
              t("enabled"),
            ),
            h("small", null, t("enabledHint")),
          ),
          h(
            "div",
            { className: "bb-actions" },
            h(
              "button",
              {
                type: "submit",
                disabled: disabled || !dirty || !!Object.keys(invalid).length,
              },
              t(saving ? "saving" : "save"),
            ),
            h(
              "button",
              { type: "button", disabled: saving, onClick: () => reload() },
              t("reload"),
            ),
          ),
          notice
            ? h(
                "p",
                {
                  className: "bb-notice",
                  role: notice === "saved" ? "status" : "alert",
                },
                t(notice),
              )
            : null,
        ),
      );
    }
    return {
      inject: ["slots", "locale", "configForms", "connection"],
      apply(ctx) {
        const t = ctx.locale.bind(NS),
          form = ctx.configForms.get("bb-bridge");
        ctx.effect(() => ctx.locale.register(NS, copy));
        const inject = () => ({ bbForm: form, connection: ctx.connection, t });
        ctx.effect(() =>
          ctx.configForms.whileServed(["bb-bridge"], () => {
            const disposers = [
              ctx.slots.inject("plugins.bundle.config", () =>
                ctx.slots.register(
                  {
                    name: "plugins.bundle.config",
                    key: "@bb/dsh-bridge",
                    order: 70,
                    label: () => t("title"),
                    locale: NS,
                    inject,
                  },
                  Editor,
                ),
              ),
              ctx.slots.inject("settings.section", () =>
                ctx.slots.register(
                  {
                    name: "settings.section",
                    id: "bb-bridge",
                    order: 70,
                    label: () => t("title"),
                    locale: NS,
                    inject,
                  },
                  Editor,
                ),
              ),
            ];
            return () => disposers.forEach((dispose) => dispose());
          }),
        );
      },
    };
  },
});
