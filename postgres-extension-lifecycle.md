# Postgres Extension Lifecycle

## Problem

Upgrades to first-party Postgres extensions (`pg_clickhouse`, `pg_stat_ch`) currently require either an AMI rebuild followed by fleet-wide `incr_recycle`, or a manual `init_script` edit followed by per-server recycle. Neither supports HA-safe ordering or per-cluster pinning, and the manual path is not auditable.

This document proposes moving first-party extension upgrades onto a control-plane reconciliation loop. AMI and Postgres-major changes continue to use `incr_recycle`. Cross-major Postgres upgrades and OS changes remain out of scope. Third-party extensions are also out of scope and are discussed separately under [Third-party extensions](#third-party-extensions).

## Data model

State lives in three places:

- Per-resource desired state — `postgres_resource.desired_extensions`, operator-set.
- Per-resource extension config — `postgres_resource.extension_config`, driver-managed.
- Per-server observed state — `postgres_server_extension` (table), driver-managed.

Read-replicas (`parent_id` set, `restore_target IS NULL`) inherit by walking `parent_id` to root; their own columns are forced to `{}` by CHECK. Inheritance is single-level — read-replicas cannot themselves have read-replicas. PITR / fork resources (`parent_id` set, `restore_target IS NOT NULL`) are operationally independent roots and own their own state, snapshotted from the parent at creation.

Resource-level schema:

```
ALTER TABLE postgres_resource
  ADD COLUMN desired_extensions jsonb NOT NULL DEFAULT '{}',
  ADD COLUMN extension_config   jsonb NOT NULL DEFAULT '{}',
  ADD CONSTRAINT desired_extensions_root_only
    CHECK (parent_id IS NULL OR restore_target IS NOT NULL OR desired_extensions = '{}'::jsonb),
  ADD CONSTRAINT extension_config_root_only
    CHECK (parent_id IS NULL OR restore_target IS NOT NULL OR extension_config   = '{}'::jsonb);
```

### Transitions

Both transitions below share one invariant: when a resource moves from `(parent_id set, restore_target NULL)` to having `restore_target` non-NULL, it must own its own extension state — snapshot `parent.desired_extensions` and `parent.extension_config` in the same transaction. Without the copy, the restored/promoted resource's `desired_extensions = '{}'` causes the convergence loop to stop managing extensions that are already installed on disk, and `100-extension.conf` renders empty even though the `pg_extension` catalog references the libraries.

- **PITR / fork creation** (`routes/project/location/postgres.rb` `r.post "restore"`). `PostgresResourceNexus.assemble` derives the snapshot internally from `parent_id`, matching the existing pattern that derives `superuser_password`, `timeline_id`, `timeline_access`, and `target_version`.
- **Read-replica promotion** (`routes/project/location/postgres.rb` `r.post "promote"`). The route sets `restore_target = Time.now` on the existing resource (no `parent_id` clear in this codebase); extend the same `update` to copy `desired_extensions` and `extension_config` from `parent`.

### Desired — `postgres_resource.desired_extensions` (jsonb)

```
{ "pg_clickhouse": "1.42.1", "pg_stat_ch": "v0.2.0" }
```

Operator-set via API/CLI on root resources only; `effective_desired_extensions` walks `parent_id` to read the inherited value. An update bumps `incr_converge_extensions` on the resource in the same transaction (see [Driver](#driver)). An absent key means the extension is not desired. Versions are exact strings.

### Extension config — `postgres_resource.extension_config` (jsonb)

Keyed by extension name; values are `config_entries` hashes:

```
{ "pg_stat_ch": { "shared_preload_libraries": "pg_stat_ch" } }
```

Written by the primary's `process_extensions` on transition to `sync_pending`. Standby and read-replica `process_extensions` do not write. Stores real GUC entries plus `!`-prefixed metadata keys: `!needs_restart` (whether postgres restart is required) and `!version` (the version the primary was at when this config was written, so the cluster barrier can reject stale entries from a previous version). Rhizome's `100-extension.conf` render filters out any key starting with `!`. Restart-only extensions (script returns `needs_restart=true` with empty `config_entries`) still get an entry written here with `extension_config[name] = {"!needs_restart": true, "!version": v}` — the marker carries no GUCs to render but routes the row through the cluster barrier so all restart-required extensions coalesce into one restart per server.

Rendered to `100-extension.conf` by `rhizome/postgres/bin/configure`. The render reads flavor default, `user_config`, and `extension_config`; for list-valued GUCs like `shared_preload_libraries` it unions across sources. Entries are filtered to those where the local `postgres_server_extension` row has `installed_version IS NOT NULL`, so the conf never references libraries not on disk on this server — new servers without rows, in-flight installs, or unrelated `incr_configure` fires mid-upgrade.

Non-list GUC contributions from `extension_config` are written one-line-per-entry to `100-extension.conf`. Extensions contributing such GUCs must namespace them under their own extension name (PG convention: `extension_name.guc_name`, e.g., `pg_clickhouse.some_setting`). Collisions on non-namespaced keys produce duplicate lines in the rendered file — Postgres applies last-wins semantics with undefined iteration order; behavior is undefined.

### Observed — `postgres_server_extension` (table)

```
CREATE TABLE postgres_server_extension (
  postgres_server_id UUID NOT NULL REFERENCES postgres_server(id) ON DELETE CASCADE,
  name               TEXT NOT NULL,
  installed_version  TEXT,
  state              TEXT NOT NULL DEFAULT 'pending',
  last_transition_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_error         TEXT,
  PRIMARY KEY (postgres_server_id, name)
);
```

`state ∈ {pending, installing, sync_pending, restart_pending, ready, failed}`. `sync_pending` = installed locally, waiting for the cluster barrier to propagate config + state across the cluster. `restart_pending` = config rendered cluster-wide, waiting for postgres restart + post-restart script to run. `last_transition_at` is updated on every state change. `last_error` is set when transitioning to `failed`. `ON DELETE CASCADE` removes observed state when a server is recycled; replacement servers create rows lazily on the first wait-tick.

## Script contract

The driver dispatches every install through a single generic mechanism. The install logic itself lives in scripts in S3, owned by the operator. Adding an in-house extension is a new script in S3 — no Ubicloud code change.

### Configuration

Ubicloud reads one environment variable: `POSTGRES_EXTENSION_SCRIPT_BASE_URL` (e.g., `s3://my-pgext-bucket/scripts`). The driver derives the script URL as `{base}/{ext_name}/{pg_major}/install.sh`. Postgres VMs fetch via `aws s3 cp`; their IAM instance profile (already attached for walg backups) grants `s3:GetObject` on the configured prefix. AWS-only — non-AWS providers would need a different fetch path.

### Inputs (driver → script, env vars)

| Variable | Source |
|---|---|
| `INSTALL_PHASE` | `install` (first call) or `post_restart` (second call, after postgres restarts) |
| `INSTALL_NAME` | extension name (key in `desired_extensions`) |
| `INSTALL_VERSION` | requested version (value in `desired_extensions`) |
| `INSTALL_PG_MAJOR` | `postgres_server.version` (parsed major) |
| `INSTALL_RESOURCE_ID` | `postgres_resource.id` (UBID) |
| `INSTALL_SERVER_ID` | `postgres_server.id` |
| `INSTALL_SERVER_ROLE` | `primary` / `standby` / `read_replica` |
| `INSTALL_SERVER_FLAVOR` | `postgres_resource.flavor` |
| `INSTALL_RESOURCE_TAGS` | `postgres_resource.tags` as JSON; array of `{key, value}` objects |
| `INSTALL_SCRIPT_BASE_URL` | `POSTGRES_EXTENSION_SCRIPT_BASE_URL` |
| `INSTALL_RESULT_FILE` | driver-assigned per-extension path the script writes its outcome to (e.g., `/tmp/extension-result-{name}.json`) |

### Phases

- `install` — first call. Stages the `.so`, registers the extension, reports `config_entries` and `needs_restart`. **Output is canonical, not delta**: even on idempotent re-runs (extension already installed at desired version), the script returns the same `config_entries` and `needs_restart` that would apply on a fresh install. This lets the driver recover state without depending on stable result-file persistence. If `needs_restart=false`, the script also runs anything that needs the new code live (e.g., `ALTER EXTENSION UPDATE`) here; no restart will follow.
- `post_restart` — second call, fired only when the previous install reported `needs_restart=true`, after `:restart` has completed and the new postmaster is up. Verifies the new code loaded (PG can start with a broken `.so` in `shared_preload_libraries` and silently log-skip it) and runs any post-restart SQL setup like `CREATE EXTENSION` or deferred migrations.

### Outputs (script → driver, result file)

```
{
  "status": "ok" | "failed",
  "config_entries": { "shared_preload_libraries": "pg_stat_ch" },
  "needs_restart": true,
  "error": "..."
}
```

- `status` — required. `"ok"` or `"failed"`.
- `config_entries` — optional. When `status = "ok"` AND (`config_entries` is non-empty OR `needs_restart=true`), the row transitions to `sync_pending`. On the primary, the driver writes `config_entries` into `extension_config[name]`, merging in `"!needs_restart"` and `"!version"` as sibling metadata keys (the `!` prefix is the driver's storage convention — PG GUC identifiers cannot start with `!`, so it's collision-free, and rhizome's `100-extension.conf` render filters out any `!`-prefixed key) — even when `config_entries` is empty, so restart-only extensions go through the cluster barrier alongside config+restart ones, coalescing into a single restart per server. When `config_entries` is empty AND `needs_restart=false`, the row transitions to `ready` directly with no barrier or restart.
- `needs_restart` — optional, install-phase only, defaults `false`. `true` if loading the new code requires a postmaster restart (`shared_preload_libraries` and other POSTMASTER-only GUCs). The script writes it as a top-level result key; the driver stores it as `!needs_restart` inside `extension_config[name]` so the cluster barrier can route the row's next state.
- `error` — required when `status = "failed"`; ignored otherwise. Driver writes to `last_error`.

### Call patterns

Walker decides the row's next state at the `installing → ???` transition from the first install call's result file. No rerun-at-restart_pending — the decision is encoded in the row state going forward.

- `needs_restart=false`, empty `config_entries`: one call total. Row goes `installing → ready` directly. No barrier, no restart.
- `needs_restart=false`, non-empty `config_entries`: one call total. Row goes `installing → sync_pending → ready` — the cluster barrier renders `100-extension.conf` everywhere then promotes the row.
- `needs_restart=true` (with or without `config_entries`): two calls (install + `post_restart`). Row goes `installing → sync_pending → restart_pending → ready`. The cluster barrier ensures `100-extension.conf` is rendered cluster-wide AND coalesces every restart-required extension into a single restart per server. The resource bumps `:restart` between the two calls when the restart gate clears; the walker gates the `post_restart` d_run on `restart_unblocked?` AND `!restart_set?` so the script never runs before postgres has actually restarted.

## Cross-server ordering

Three gates enforce HA correctness.

### Primary does not install until peers have the files

Resource-level: `converge_extensions` fans out `:process_extensions` only to non-primary cluster_servers. The primary's `:process_extensions` is held back until `watch_extension_apply` observes that every non-primary cluster_server has `installed_version == desired.version` for some desired extension; only then does the resource bump the primary. Without this gate, the primary's `ALTER EXTENSION UPDATE` can emit WAL referencing symbols whose library is not yet on disk on a downstream consumer. The check lives on the resource strand rather than the primary's walker so peer-readiness is evaluated once per cluster poll instead of on every primary walker pass.

### Primary does not restart until standbys have restarted

Resource-level. All restarts are resource-driven; no walker fires `:restart` on itself. Two predicates:

- `representative_install_unblocked?(name, version)` — releases the rep's `:process_extensions` bump for install once all `cluster_servers` peers have the files (state at `sync_pending` / `restart_pending` / `ready`).
- `restart_unblocked?(server_id, name, version)` — releases `:restart` bumps for any cluster_server at `restart_pending`:
  - **Rep**: waits for HA-`servers` peers at `ready` (RR servers excluded — they're operationally independent).
  - **Standby / RR**: waits for the rep's row to be at `restart_pending` or `ready` (i.e., rep has finished installing).

Rep waits because briefly losing the parent's primary while standbys are still mid-restart removes the failover endpoint. Standbys (and RRs) wait because restarting with new code loaded while the rep is still on old code would leave the cluster briefly in a "new code, old catalog" split state.

### Config apply requires matching `installed_version` across all servers

The version scope on the apply predicate (see [Driver](#driver)) prevents in-flight rows from an older version being counted toward the gate, which would otherwise trigger the apply before every server has the new files.

### Read replicas

Read-replicas are separate `postgres_resource` rows linked by `parent_id` (`model/postgres/postgres_resource.rb:17`). The parent's resource prog fans out to `read_replicas.flat_map(&:servers)` on convergence; the resource-level primary-install gate in `watch_extension_apply` consults the same set.

Read-replicas' own resource strands stay dormant for extension work — `converge_extensions` no-ops on them. The parent's resource strand bumps `:process_extensions` and `:configure` on read-replica servers directly (cross-resource bump on a per-server semaphore). Each read-replica server then runs its standard per-server walker and fires its own `incr_restart` locally — RR resources are assumed single-server (no HA standbys of their own), so the restart gate doesn't apply.

## State machine

The primary's `pending → installing` is gated at the resource level, not the per-server walker (see [Cross-server ordering](#primary-does-not-install-until-peers-have-the-files)); the per-server walker just acts on whatever it's been bumped to.

| From → To | Owner | Trigger |
|---|---|---|
| (none) → pending | per-server | desired key exists, no observed row |
| pending → installing | per-server | semaphore bumped (resource holds the primary's bump until peers have the files) |
| installing → sync_pending | per-server | `status = "ok"` AND (non-empty `config_entries` OR `needs_restart=true`); on the primary, driver writes `config_entries` + `!needs_restart` to `extension_config[name]` |
| installing → ready | per-server | `status = "ok"`, empty `config_entries`, `needs_restart=false` |
| installing → failed | per-server | `status = "failed"`, or no result file produced |
| sync_pending → restart_pending | resource-level | `extension_config[name]["!needs_restart"] = true`; `trigger_extension_configure` promotes per-extension matching rows |
| sync_pending → ready | resource-level | `extension_config[name]["!needs_restart"] = false`; `trigger_extension_configure` promotes per-extension matching rows |
| sync_pending → installing | per-server | primary's row at `sync_pending` with `extension_config[name]` nil (edge case: new primary inherited the row from a standby that had reached sync_pending before any primary wrote `extension_config`); walker re-fires install to write it. Standby rows do not self-recover — they wait for primary to write |
| restart_pending → ready | per-server | walker gate `restart_unblocked? && !restart_set?` is open AND post-restart `INSTALL_PHASE=post_restart` rerun returned `status = "ok"` |

The transitions out of `sync_pending` to `restart_pending` / `ready` are the cluster-scope step, owned by `trigger_extension_configure`: it bumps `:configure` on every cluster_server (renders `100-extension.conf` from `extension_config`, with `!`-prefixed keys filtered out) and promotes the matching rows. The promotion is per-extension and doesn't require all `cluster_servers` to be aligned at `sync_pending`; standbys that reach the state ahead of the primary wait for `extension_config[name]` to be populated. Rows going `installing → ready` directly (no `config_entries` and no restart needed) skip the cluster step.

`installed_version` is written when transitioning out of `installing` into a success state (`sync_pending` or `ready`). It stays unchanged on `failed`, and is already at `desired.version` by the time any further transition fires.

```
(no row)
   |
   v
pending
   |  (resource bumps this server's :process_extensions; primary held until peers have the files)
   v
installing --> {sync_pending, ready, failed}
                       |
                       v  (resource label: any cluster_server at sync_pending + extension_config[name] populated)
                {restart_pending, ready}  (split by !needs_restart in extension_config)
                       |
                       v  (resource bumps :restart when gate clears; walker gates post_restart d_run on restart_unblocked? && !restart_set?)
                {ready, failed}
```

## Driver

### Resource-level (`prog/postgres/postgres_resource_nexus.rb`)

`:converge_extensions` is a per-resource semaphore on root resources. It is bumped on (a) any change to `desired_extensions` (in the API handler's transaction), (b) operator retry actions (admin button / API endpoint that does nothing more than increment the semaphore), and (c) by `Prog::RolloutSemaphore` for paced fleet operations (see [Rollout](#rollout)). The resource's `wait` label also self-discovers convergence work via `hop_converge_extensions unless read_replica? || fully_converged? || has_failed_extension_row?` — every wait tick re-evaluates so newly-created resources and newly-added servers trigger convergence without explicit upstream bumps. Self-discovery skips when failed rows are present so the resource doesn't auto-retry into a failure loop; the explicit `:converge_extensions` semaphore handler still triggers retry from `wait` regardless.

`cluster_servers` denotes `servers + read_replicas.flat_map(&:servers)` — the full set the resource label coordinates across.

Labels:

- `converge_extensions` — entry. No-ops (hops to `wait`) if the resource is a read-replica. Otherwise: destroys any `failed` rows on `cluster_servers` (so this entry serves as the retry mechanism), then fans out by bumping `:process_extensions` on every *non-primary* `cluster_server` (HA standbys + read-replica servers); the primary's bump is deferred to `watch_extension_apply`. Hops to `watch_extension_apply`.
- `watch_extension_apply` — polls while apply work is in flight. Each pass: consumes any new `:converge_extensions` bump (re-fans-out); pages once via `["watch_extension_apply", resource.id]` if any row has been non-terminal for >10 minutes; bumps `:process_extensions` on cluster_servers that need it (`cluster_server_ids_needing_bump`) and `:restart` on those whose restart gate is clear (`cluster_server_ids_needing_restart`); hops to `trigger_extension_configure` if `should_trigger_extension_configure?`; hops back to `wait` once `fully_converged?` OR no row is in a non-terminal state (all are at `ready` / `failed`) — the second clause settles the resource back to `wait` when failures park convergence; otherwise naps 5s.
- `trigger_extension_configure` — fires when any cluster_server has a `sync_pending` row whose extension has `extension_config[name]["!version"]` matching the currently desired version. Bumps `:configure` on every `cluster_server` and promotes the matching rows (per-extension) to `restart_pending` (if `extension_config[name]["!needs_restart"] = true`) or `ready` (if `false`), in one transaction. Hops back to `watch_extension_apply`. The `!version` check rejects stale extension_config left over from a prior version — after a `desired_extensions` version bump (which resets `ready`/`failed` rows back to `pending` via DB trigger), a standby installing the new version reaches `sync_pending` before the primary, but the barrier only fires once the primary's install writes new `extension_config[name]` carrying `!version: <new>`. The cluster step doesn't require all servers aligned at `sync_pending` — standbys that reach it ahead of the primary wait for the primary's atomic row+`extension_config` write before being promoted.

`should_trigger_extension_configure?` — true if any `cluster_server` has a `sync_pending` row for some desired extension AND `extension_config[name]` is populated for that extension.

### Per-server (`prog/postgres/postgres_server_nexus.rb`)

`:process_extensions` on `postgres_server` is the wake mechanism, bumped by the resource prog's fan-out (and by the server's own provisioning prog on first start / recycle completion).

Additions to the existing prog:

- `needs_extension_converge?` — predicate consulted from the provisioning hop `wait_extensions_converged` (not from steady-state `wait`), and by `ConvergePostgresResource` to gate standby creation against the representative server. True when at least one desired key (from `effective_desired_extensions`) has no matching `ready` row at `installed_version == desired.version`.
- `process_extensions` — walks all actionable rows for this server in one pass:
  - `pending` row → starts `d_run` with `INSTALL_PHASE=install`, transitions to `installing`. (The primary only sees a `pending` row once the resource has bumped it, after peers have the files.)
  - `installing` row, `d_check Running` → leaves in place.
  - `installing` row, `d_check Failed` → `failed` with `last_error` from the systemd unit.
  - `installing` row, `d_check Succeeded` → reads result file. `status = "failed"` → `failed` (`last_error = error`). `"ok"` with (non-empty `config_entries` OR `needs_restart=true`) → `sync_pending`; on the primary, writes `config_entries` + `!needs_restart` to `extension_config[name]` *atomically* in the same `DB.transaction` as the row update (standby/RR servers transition state but do not write). `"ok"` with empty `config_entries` AND `needs_restart=false` → `ready` directly. Missing or malformed result → `failed` with marker.
  - `sync_pending` row on the **primary** with `extension_config[row.name]` nil — edge-case recovery: re-fires `d_run` with `INSTALL_PHASE=install` and resets row to `installing`. This happens when a standby reached `sync_pending` before any primary wrote `extension_config`, then was promoted (old primary died). Walker on the new primary re-installs; the script's canonical-state contract guarantees the same `config_entries` come back, and the atomic primary write fixes `extension_config`.
  - `restart_pending` row → gated on `resource.restart_unblocked?(server_id, name, version) && !postgres_server.restart_set?`. The first predicate ensures the resource has decided this server is allowed to restart (rep waits for HA standbys at `ready`; standby/RR waits for rep installed). The second ensures the daemonized restart has completed — the wait label's `when_restart_set?` arm runs ahead of `when_process_extensions_set?` and naps until restart finishes, so by the time the walker re-enters with `restart_set?=false`, postgres has actually restarted. Both true → queues `d_run` with `INSTALL_PHASE=post_restart`; on `d_check Succeeded` transitions to `ready`, failure → `failed`. The walker is purely reactive — never self-fires `:restart`.

After walking, walker hops to `wait_extensions_converged` if `postgres_server.initial_provisioning_set?`, else to `wait`. This keeps the provisioning chain progressing through `wait_extensions_converged → wait_catch_up / wait_recovery_completion / wait` during initial server setup, while steady-state convergence routes through the standard `wait` label.

## Failure handling

- A row with `state='failed'` is terminal until the next `:converge_extensions` bump. The resource's `watch_extension_apply` settles back to `wait` once nothing is in flight, even with failed rows still present. The `wait` label skips its self-discovery (`hop_converge_extensions unless ... || has_failed_extension_row?`) so the resource doesn't auto-retry into a failure loop. The retry path is an **explicit** `:converge_extensions` bump (operator action via admin/API, or a `desired_extensions` change in the API handler's transaction): `converge_extensions` on entry destroys all failed rows on `cluster_servers`, and the walker re-creates them as `pending`. No automatic retry, and operators never reach into row state directly.
- Failure detail is surfaced via `postgres_server_extension.last_error`, populated from the script's result file (or, if no result was produced, a marker error from the driver). The strand's exception store carries the backtrace for driver-side failures.
- Stall detection. `watch_extension_apply` scans each pass for any row in a non-terminal state (`pending` / `installing` / `sync_pending` / `restart_pending`) older than 10 minutes. If any are found, pages once for the resource via `Prog::PageNexus.assemble(summary, ["watch_extension_apply", postgres_resource.id], postgres_resource.ubid)` — operator looks at the resource to find the stuck row. No per-row pages, no automatic state change (auto-failing a stalled row can leave primary and standbys desynced, which needs manual remediation). Tag dedups, so repeated scans don't multi-page.
- Label deadline. `converge_extensions` registers `register_deadline("wait", 60 * 60)` on entry — if the convergence cycle doesn't return to `wait` within 60 minutes, a standard `["Deadline", strand.id, prog, "wait"]` page fires. Deadline is well above the stall threshold so the per-row stall page surfaces first; deadline is the backstop if a stall doesn't clear or convergence is stuck for some other reason.
- Trust: scripts come from an S3 bucket the operator controls. The VM's IAM role grants `s3:GetObject` on the configured prefix. CI is the only writer.

## Wait on provisioning

**Primaries and PITR reps skip `wait_extensions_converged` during initial provisioning.** The root primary skips because it has no replication concern (no peers consume its WAL) and gating it would deadlock the resource strand. The PITR representative skips for a different reason: during recovery it is in `timeline_access="fetch"` mode, replaying WAL from the parent's bucket, and we don't want extension convergence running with `INSTALL_SERVER_ROLE=standby` mid-recovery (the install step would be done with the wrong role and never re-run with role=primary after `switch_to_new_timeline` flips it). The configure label's `when_initial_provisioning_set?` arm routes PITR reps to `wait_recovery_completion` directly; once recovery completes, `switch_to_new_timeline` decrements `:initial_provisioning` and hops back through `configure`, which now lands at `wait`. The resource strand's normal root-convergence path (self-discovery via `fully_converged?` is false) bumps the now-primary rep's `:process_extensions` and install runs with `INSTALL_SERVER_ROLE=primary` from the start. First-party AMI-baked extensions tolerate the recovery-without-extensions window because the `.so` files are present in the image; third-party extensions that need their library on disk before WAL replay are out of scope per the trust model.

For HA standbys, RR servers, and other non-primaries, `wait_extensions_converged` is inserted before `wait_catch_up` / `wait_recovery_completion` in the provisioning chain (in the `configure` label's `when_initial_provisioning_set?` branch). The label handles cluster-scope events the server's strand can't know to do on its own (`when_configure_set?` → `hop_configure` to re-render `100-extension.conf` when the cluster barrier bumps `:configure`; `when_restart_set?` → `drive_restart` to perform the actual postgres restart for SPL changes when the resource bumps `:restart`), and then **self-drives the walker** via local state: `hop_process_extensions if needs_extension_converge?`. The walker, during initial provisioning, naps 5s before hopping back to `wait_extensions_converged` if convergence is still incomplete — short enough to track d_run progress quickly, long enough to avoid CPU spin. Once `needs_extension_converge?` returns false, the label hops based on server state: `wait_recovery_completion` (PITR rep mid-recovery), `wait_catch_up` (standby/RR), or `wait` (primary, though primary should rarely reach this label). The label has no `:process_extensions` handler — initial-provisioning servers don't depend on the resource strand to fire their own walker. The `:process_extensions` semaphore stays alive for steady-state `wait` (the resource still wakes the server from outside when a `:configure`/`:restart` cycle requires the walker after the fact); during initial provisioning the walker runs purely off the server's own state.

**Sequencing**: `ConvergePostgresResource` naps if `representative_server.needs_extension_converge?` is true before calling `provision_new_standby`. Standbys are only created after the primary has finished converging all desired extensions, so a new standby joining never has to coordinate with an in-flight primary install — `extension_config` is already populated for the primary's extensions by the time the standby installs them.

## Rollout

### Implementation

Single stage. The migration backfills `desired_extensions` on root resources from the AMI baseline; observed rows populate lazily.

1. Schema: add `postgres_resource.desired_extensions` and `postgres_resource.extension_config` with the root-only CHECK constraints; create `postgres_server_extension`; declare `:converge_extensions` on `postgres_resource` and `:process_extensions` on `postgres_server`. Add an `AFTER UPDATE OF desired_extensions` trigger on `postgres_resource` that resets `ready`/`failed` `postgres_server_extension` rows back to `pending` (clearing `last_transition_at`, `last_error`) when the row's `installed_version` no longer matches the new desired version. `installed_version` is preserved during reset — it's "what's on disk," and the renderer in `postgres_server.configure_hash` uses non-null `installed_version` to decide whether to include the extension's stored config in the rendered hash; nulling it would drop the running library's config while the library is still loaded. The trigger cascades to the updated resource's `servers` and to read-replicas' `servers` (children with `parent_id = NEW.id AND restore_target IS NULL`); PITR forks and promoted RRs have `restore_target IS NOT NULL` and are independent roots, so the cascade excludes them. Stale `extension_config[name]` is left in place — the cluster barrier's `!version` check blocks promotion using outdated metadata, and the entry gets overwritten when the primary re-installs at the new version.
2. Extract `flavor_default_preload_libraries` from the inline strings at `postgres_server.rb:79, 83-93` into a method on `postgres_server`.
3. Extend `rhizome/postgres/bin/configure` to render `100-extension.conf` from `extension_config`, with union-merge for list-valued GUCs.
4. Add the `POSTGRES_EXTENSION_SCRIPT_BASE_URL` setting; wire it through the per-server convergence dispatch.
5. Resource-level label additions: `converge_extensions` (fan-out, with read-replica no-op), `watch_extension_apply`, and `trigger_extension_configure`.
6. Per-server label additions: `process_extensions` (with the primary's cross-resource write to `extension_config`) and the `wait_extensions_converged` provisioning hop.
7. Operator ships scripts to its S3 bucket per the [Script contract](#script-contract).
8. Staging validation across first-install, single-node, HA standby, HA primary, and parent-with-read-replica topologies. Canary, then full rollout.

### Fleet operations

Per-resource changes (one customer, one version bump) happen via the API: update `desired_extensions` and bump `:converge_extensions` on the resource in the same transaction.

Fleet-wide changes (e.g., rolling a new default version across the customer base) use the existing rollout primitive:

1. Update `desired_extensions` on every applicable root `postgres_resource` without bumping the semaphore synchronously.
2. `Prog::RolloutSemaphore.assemble(semaphore: :converge_extensions, ids: root_resource_ids, gap: 60)`. Paced bump across the resource set, pausable, observable from the admin UI.

## Out of scope

### Uninstall

Removing a key from `desired_extensions` leaves the corresponding rows at `ready` and the extension on disk. Wiring uninstall in later: extend `needs_extension_converge?` to catch observed rows without a matching desired key, and introduce a `ready → uninstalling → (none)` transition with a corresponding script path.

### Downgrade

Writing a lower version to `desired_extensions` is not a supported recovery path. The mechanism (same install flow with an older version) only works when the older `.deb` is still fetchable AND ships a downgrade migration AND the data on disk is forward-compatible with the older code. PITR is the recovery path.

## Third-party extensions

The design above assumes scripts come from a trusted, operator-controlled S3 bucket. Supporting third-party extensions (customer-installable, marketplace-style) extends the script model with additional trust controls:

- Signed artifacts and content-addressed pinning for third-party scripts.
- A per-cluster catalog of available extensions and versions, exposed via API/CLI.
- Governance: allowlists, version compatibility matrices, vendor SLA expectations, vulnerability response.
- A different threat model for third-party code running on a customer's Postgres VM.

The data model and most of the driver survive that transition — the desired/observed split is correct regardless. The script contract and trust model are where the work concentrates. This is a separate effort to scope if and when third-party extension support becomes a real requirement.
