# Beads Collaboration and Synchronization

Beadazzle presents Beads data, but Beads owns the database, configuration,
history, and synchronization rules. This guide explains how those layers fit
together when multiple people work from separate clones of the same repository.

## The Four Pieces

| Layer | Source of truth | How it moves between machines | What Beadazzle does |
|---|---|---|---|
| Project source code | Normal Git commits and branches such as `refs/heads/main` | `git pull`, `git push`, and the team's normal Git workflow | Nothing; source-code Git remains separate |
| Beads issue data | The local Dolt database and its Dolt history | `bd dolt pull` and `bd dolt push` | Runs these through Pull, Push, and Sync |
| Readable issue snapshot | A JSONL export such as `.beads/issues.jsonl` | It is not the canonical sync channel | Runs `bd export`, validates the result, and reloads it for the UI |
| Beadazzle state | macOS application preferences | It does not travel with the repository | Stores UI preferences and the local remote-change checkpoint |

A Git-hosted project can use the same remote URL for source code and Beads,
but the data remains separate. Source branches use normal Git refs. Dolt stores
Beads history under `refs/dolt/data`. A normal `git clone` does not bootstrap
that Dolt history by itself.

## What Git Tracks

A current `bd init` normally creates and tracks files such as:

- `.beads/config.yaml`, including shared settings such as `sync.remote`;
- `.beads/metadata.json`, which identifies the backend and database;
- `.beads/.gitignore`; and
- any hook or agent-instruction files the team deliberately shares.

The generated `.beads/.gitignore` keeps the live database and machine-specific
runtime state out of source-control Git. In particular, never add
`.beads/embeddeddolt/` or `.beads/dolt/` to Git or Git LFS. Lock files, sockets,
push state, backup data, and similar runtime files are also local.

The JSONL snapshot is an export, not the database. Teams may deliberately track
it for viewers or interchange, but current Beads defaults do not require that.
Use these commands to see the truth for a particular checkout:

```bash
bd context --json
git ls-files .beads
git status --short --ignored .beads
git check-ignore -v .beads/embeddeddolt .beads/dolt .beads/issues.jsonl
```

Do not infer the effective tracker directory from the presence of a local
`.beads` folder. Redirected projects and worktrees can resolve elsewhere;
`bd context --json` is authoritative, and Beadazzle follows it.

## Initial Team Setup

On the authoritative machine:

```bash
bd context --json
bd dolt remote list
bd config get sync.remote
bd dolt push
```

`bd init` normally creates a Dolt remote from the repository's Git `origin`.
If an older project has no Dolt remote, configure one from the authoritative
database and push it before another person bootstraps. Follow the upstream
[Sync Setup Guide](https://github.com/gastownhall/beads/blob/main/docs/getting-started/sync-setup.md)
for the recovery procedure rather than moving database directories manually.

On another person's fresh clone:

```bash
git clone git@github.com:org/project.git
cd project
bd bootstrap
bd context --json
bd dolt remote list
bd list
```

`bd bootstrap` discovers `refs/dolt/data`, clones the Dolt database, and wires
the remote for later pulls and pushes. If the remote does not yet advertise
`refs/dolt/data`, the first machine has not published the Beads database.

For a team with more than one writer, keep `dolt.auto-push` off and synchronize
explicitly. Current Beads documentation warns that concurrent automatic pushes
to Git-protocol Dolt remotes can race and strand or corrupt remote history.
Inspect the effective value and its source with:

```bash
bd config show --json
```

The normal handoff is: pull before starting work, then Sync before switching
machines or handing the tracker to someone else.

## What Beadazzle Commands Do

| Action | Remote operation | Snapshot operation | Automatic? |
|---|---|---|---|
| Edit or create a bead | None from Beadazzle; Beads may auto-push if the project explicitly enables it | Exports and reloads after the mutation | Local reconciliation is automatic |
| Refresh / Command-R | None | Exports and reloads the readable snapshot | User initiated |
| Check for Remote Changes | Read-only `git ls-remote` for `refs/dolt/data` | None | Manual, or periodic when eligible |
| Pull | `bd dolt pull` | Exports and reloads afterward | User initiated |
| Push | `bd dolt push` | None | User initiated |
| Sync | Pull first, then push if pull succeeded | Exports and reloads after the remote commands | User initiated |

The toolbar Sync button is the normal team action. Its menu retains directional
commands for recovery and advanced workflows:

- Pull: Command-Option-Down Arrow
- Push: Command-Option-Up Arrow
- Refresh: Command-R

Sync deliberately has no default keyboard shortcut. Beadazzle serializes its
remote writes with other `bd` writes so a synchronization command cannot reorder
an in-progress edit.

### Reconciliation and partial failures

`bd dolt pull` performs the Dolt merge. Beadazzle does not implement a second
issue-level merge algorithm. After the remote work, it asks `bd` for a fresh
JSONL export and reloads that authoritative result into its in-memory index.

- If Pull fails, Sync does not Push. Beadazzle still exports and reloads the
  local database in case the failed command changed any durable state.
- If Push fails after a successful Pull, the pulled database changes are still
  exported and reloaded locally.
- If the remote operation succeeds but export or reload fails, the remote may
  already be updated while the visible issue list remains stale. Beadazzle says
  so explicitly and offers a local refresh retry rather than silently repeating
  the remote write.
- In-progress edits are allowed to settle before the final snapshot reload; if
  they changed the database after the first export, Beadazzle exports again.

If Dolt reports a real merge conflict, use Beads diagnostics such as
`bd doctor --fix`. Do not edit Dolt internals or run raw `dolt` commands against
a database managed by a running Beads server.

## Lightweight Remote-Change Checks

The check is an indicator, not synchronization. It compares the Git-backed
remote's `refs/dolt/data` generation with a checkpoint recorded locally by
Beadazzle after a successful Beadazzle Pull, Push, or Sync.

Automatic checks run approximately every five minutes only when all of these
conditions hold:

- Beadazzle has an active workspace window;
- automatic checks are enabled in Application Settings > General;
- the project uses embedded Dolt;
- the selected sync remote has a compatible Git URL; and
- a successful remote action has established a checkpoint.

The probe does not pull, fetch database objects, modify the project, or update
the visible issue list. It only reports whether the remote ref differs. A Sync
is still required to receive and reconcile the remote data.

The checkpoint is machine-local Beadazzle state. It is keyed by the effective
tracker identity and remote URL, so it is not committed or shared. Changing the
selected remote invalidates the old comparison. Projects with no remote show
Not Configured; unsupported remote types and server/shared-server projects are
skipped gracefully. Turning automatic checks off does not disable Check Now.

## Contributor Mode

Contributor mode is Beads routing, not a second Beadazzle sync engine.
`bd init --contributor` can keep planning data in a separate repository and
leave the upstream source checkout without `.beads`. Beadazzle asks
`bd context --json` for that effective tracker and routes all creates, edits,
gates, and remote commands back through `bd`.

The role alone does not force a remote operation. If the routed tracker has no
Dolt remote, Beadazzle disables Pull, Push, and Sync and skips automatic remote
checks. If it has a compatible embedded remote and a local checkpoint, the same
remote-change behavior applies to that routed tracker.

## Git Integration and Hooks

The Git Integration status in Project Settings refers to Beads' optional Git
hooks. It does not mean the Dolt remote is synchronized.

Current hooks can refresh a JSONL export before a Git commit when
`export.auto` is enabled, preserve chained hook-manager behavior, and add agent
identity metadata. With `sync.remote` configured, hooks do not replace
`bd dolt pull` or `bd dolt push`. Core Beads CRUD and Dolt synchronization work
without hooks.

Inspect or install hooks through Beads:

```bash
bd hooks list
bd hooks install
```

Beadazzle exposes the status and install action, but `bd` owns the generated
hook contents and their interaction with other hook managers. See the upstream
[Git Integration reference](https://github.com/gastownhall/beads/blob/main/docs/reference/git-integration.md).

## Configuration Ownership

Beads has two relevant configuration stores:

- tool/startup settings in `config.yaml`, with machine-local overrides and
  environment variables; and
- project settings in the Dolt database, which travel when Dolt history is
  pushed and pulled.

`sync.*`, `dolt.*`, `export.*`, `git.*`, and `routing.*` are startup namespaces
stored in YAML. Use `bd config show` to inspect effective values and provenance;
do not guess which file won precedence. Secrets belong in environment variables
or another machine-local source, not tracked project configuration.

Beadazzle currently reports relevant settings and health but does not create,
edit, or remove Dolt remotes or change Beads' auto-push policy.

For the complete Beads contract, see:

- [Sync Concepts](https://github.com/gastownhall/beads/blob/main/docs/core-concepts/sync-concepts.md)
- [Sync Setup Guide](https://github.com/gastownhall/beads/blob/main/docs/getting-started/sync-setup.md)
- [Git Integration](https://github.com/gastownhall/beads/blob/main/docs/reference/git-integration.md)
- [Configuration Reference](https://github.com/gastownhall/beads/blob/main/docs/reference/configuration.md)
