CREATE TABLE public_schema (version INTEGER PRIMARY KEY CHECK(version=1));
INSERT INTO public_schema VALUES(1);
CREATE TABLE public_config (id INTEGER PRIMARY KEY CHECK(id=1), instance_id TEXT NOT NULL, version INTEGER NOT NULL, domain TEXT, active TEXT);
CREATE TABLE public_tasks (id TEXT PRIMARY KEY, kind TEXT NOT NULL, version INTEGER NOT NULL, plan_id TEXT UNIQUE, terminal INTEGER NOT NULL, snapshot TEXT NOT NULL, context TEXT NOT NULL);
CREATE UNIQUE INDEX public_single_task ON public_tasks(terminal) WHERE terminal=0;
CREATE TABLE public_keys (key TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, task_id TEXT NOT NULL REFERENCES public_tasks(id));
CREATE TABLE public_events (task_id TEXT NOT NULL REFERENCES public_tasks(id), seq INTEGER NOT NULL, snapshot TEXT NOT NULL, PRIMARY KEY(task_id,seq));
CREATE TABLE public_plans (id TEXT PRIMARY KEY, version INTEGER NOT NULL, snapshot TEXT NOT NULL, context TEXT NOT NULL);
CREATE TABLE public_effects (task_id TEXT NOT NULL REFERENCES public_tasks(id), step TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN ('prepared','sent','done')), intent TEXT NOT NULL, outcome TEXT, PRIMARY KEY(task_id,step));
