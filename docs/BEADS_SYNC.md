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
| Beadazzle state | macOS application preferences | It does not travel with the repository | Stores UI preferences, setup intent, dismissals, and the local remote-change checkpoint |

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

## Beadazzle Setup Wizard

Choose **Set Up Beads** when a folder has no readable tracker, or open
**Project Settings > Overview > Beads Setup** to audit or change an existing
checkout. The same wizard supports these use cases:

- **Private / Local** keeps the tracker on the current Mac and preserves any
  existing remote rather than removing it implicitly.
- **Solo Synced** configures a remote for one person's machines and can opt in
  to Beads automatic push.
- **Team Shared** configures explicit synchronization and forces
  `dolt.auto-push` off for multi-writer safety.
- **Contributor Planning** follows `bd` contributor routing. A fresh setup
  requires a Git `upstream` remote so the wizard never invents a destination.
- **Advanced / Existing** audits the effective setup and preserves current
  choices unless a safe change is selected.

The wizard arrives at these profiles through conditional questions about
whether you maintain or contribute to the project, whether contributors should
join the project's shared task database or keep their planning separate,
whether you work alone or with a team, whether the team wants one shared task
database, and whether a personal database should sync through the project's
Git remote. Users do not need to understand the profile names or Dolt
terminology before answering.

A contributor who chooses the project's shared task database joins existing
Dolt history through bootstrap or a reviewed remote clone. Beadazzle will not
turn that choice into publication of a new empty tracker; if the Git remote is
known not to contain Dolt data, setup asks for the maintainer's Beads remote.

Before offering changes, Beadazzle runs `bd --readonly bootstrap --dry-run --json` and,
for an existing tracker, inspects its effective `bd context`, configuration
with provenance, Dolt remotes, hooks, and backup status. Opening the wizard may
also read `refs/dolt/data` from a compatible Git remote to distinguish a fresh
publish from an existing remote database. Routine background setup audits do
not perform that network probe. Bootstrap guidance is advisory: Beadazzle can
decode its JSON even when `bd` exits nonzero, and it cross-checks an embedded
database with a read-only query before proposing initialization or cloning.

The review step labels each change by scope and shows the exact `bd` command.
The displayed command and the executed command come from the same typed
argument list. Commands run with `--sandbox`, which prevents incidental automatic pushes;
remote publication and backup synchronization remain separate, explicit
reviewed steps. After changes, Beadazzle exports and reloads the snapshot from
the effective tracker directory.

For a fresh checkout, the wizard probes compatible Git-backed destinations
before deciding between joining and publishing. Existing Dolt data is joined
with `bd init --remote` (or the checkout's bootstrap plan). A verified empty
Git destination—or a non-Git destination explicitly chosen for publication—is
added only after local initialization, and it is not populated unless the
review includes the explicit push step.

The wizard deliberately does not:

- migrate embedded storage to server or shared-server mode;
- relocate existing contributor planning data;
- replace an existing Dolt remote or backup destination;
- choose between local and remote histories when both already exist; or
- stage, commit, pull, or push normal source-code Git branches.

Those states remain valid and are reported with guidance instead of being
silently rewritten. `bd config validate` and `bd config drift` can still be
useful diagnostics, but they are advisory rather than setup approval gates.

The selected use case is saved in macOS preferences for that checkout only. It
is not committed or shared. When a later audit finds an actionable difference,
Beadazzle shows a dismissible workspace notice and the finding in Project
Settings. Dismissal lasts until the set of findings changes.

## What Beadazzle Commands Do

| Action | Remote operation | Snapshot operation | Automatic? |
|---|---|---|---|
| Edit or create a bead | None from Beadazzle; Beads may auto-push if the project explicitly enables it | Exports and reloads after the mutation | Local reconciliation is automatic |
| Refresh / Command-R | None | Exports and reloads the readable snapshot | User initiated |
| Check for Remote Changes | Read-only `git ls-remote` for `refs/dolt/data` | None | Manual, or periodic when eligible |
| Pull | `bd dolt pull` | Exports and reloads afterward | User initiated |
| Push | `bd dolt push` | None | User initiated |
| Sync | Pull first, then push if pull succeeded | Exports and reloads after the remote commands | User initiated |
| Setup / Review Setup | Optional explicit remote publish or backup sync | Exports and reloads after setup | User initiated |

The toolbar Sync button is the normal team action. Its menu retains directional
commands for recovery and advanced workflows:

- Pull: Command-Option-Down Arrow
- Push: Command-Option-Up Arrow
- Refresh: Command-R

Sync deliberately has no default keyboard shortcut. Beadazzle serializes its
remote writes with other `bd` writes so a synchronization command cannot reorder
an in-progress edit. While remote work is running, the workspace status identifies
the current command and its elapsed time. Its close button requests a safe stop:
Beadazzle lets an active `bd dolt pull` or `bd dolt push` finish, skips later remote
steps, and reconciles any local changes that already completed. It does not terminate
a database write midway. Remote commands have a generous 30-minute last-resort safety
ceiling so an abandoned process cannot hold the serialized write queue forever.

For SSH remotes, Beadazzle asks OpenSSH to resolve the remote's effective host,
user, port, and `IdentityAgent`, then passes that socket to `bd`. This keeps host
aliases, included SSH configuration, `SSH_AUTH_SOCK` and `$VARIABLE` agent forms,
1Password, and other external agents working when macOS launches the app without
the terminal's `SSH_AUTH_SOCK` environment. The resolved OpenSSH agent setting is
cached in memory by host, user, and port for later remote checks.

Before a standalone Pull or Push, or before a combined Sync begins, Beadazzle runs
a read-only `git ls-remote` access check with that same environment. A successful
Pull is also proof that the same combined Sync can proceed to Push, so Beadazzle does
not repeat the preflight between those two steps. Authentication
and reachability failures therefore stop before Dolt begins an expensive fetch or
chunk conjoin, and the workspace shows the copyable Git diagnostic. A successful
empty response is valid for a new remote, and remote kinds Git cannot probe are
left to `bd` rather than blocked. This preflight cannot predict a conflicting
external command that starts later; Beadazzle serializes only the writes it owns.

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
- Failed remote-action cards remain visible until dismissed. Selecting one opens
  the captured command and output in a selectable view with a Copy action.

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
skipped gracefully. A configured remote without a local checkpoint is shown as
configured and prompts for one Sync before change checks become available. Once
a checkpoint exists, turning automatic checks off does not disable Check Now.

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

Beadazzle exposes whether bd-managed hooks are installed, partially installed,
or missing; the setup wizard can also install or remove them after showing the
command. `bd` still owns the generated hook contents and their interaction with
other hook managers. See the upstream
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

The setup wizard can add a missing Dolt remote, configure `dolt.auto-push`, and
register a backup after showing the exact command. It never replaces or removes
an existing remote or backup destination, and Team Shared always keeps
automatic push off. Directional Pull, Push, and Sync remain explicit workspace
actions.

For the complete Beads contract, see:

- [Sync Concepts](https://github.com/gastownhall/beads/blob/main/docs/core-concepts/sync-concepts.md)
- [Sync Setup Guide](https://github.com/gastownhall/beads/blob/main/docs/getting-started/sync-setup.md)
- [Git Integration](https://github.com/gastownhall/beads/blob/main/docs/reference/git-integration.md)
- [Configuration Reference](https://github.com/gastownhall/beads/blob/main/docs/reference/configuration.md)
