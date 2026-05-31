# CLAUDE.md

## Setup

Read [`README.md`](README.md) first and complete the setup steps described there (Ruby version, `bundle install`, credentials in `TEMPEST_IDENTIFIER` / `TEMPEST_APP_PASSWORD`, etc.) before starting any work.

## Workflow

Before starting any work in this repository:

1. Fetch and pull the latest `main` from `origin` so your starting point is up to date.
2. Create a worktree for the change and do all editing inside it. Do not commit directly on `main`.

Use [`git wt`](https://github.com/k1LoW/git-wt) for worktree management. Examples:

```sh
git fetch origin
git switch main
git pull --ff-only origin main
git wt add feature/short-name
```

Run tests and the development loop inside the worktree, not on `main`.

### Merging a worktree branch into `main`

When asked to merge a worktree branch into `main`, only fast-forward merges are allowed. The history must stay linear.

1. Update local `main` first:

   ```sh
   git fetch origin
   git switch main
   git pull --ff-only origin main
   ```

2. Verify that the branch is fast-forward-mergeable (i.e. `main` is an ancestor of the branch):

   ```sh
   git merge-base --is-ancestor main <branch>
   ```

   Exit code `0` means a fast-forward is possible.

3. If the check fails, the branch is behind `main`. Rebase it before merging:

   ```sh
   git switch <branch>
   git rebase main
   ```

   Then repeat step 2.

4. Merge with `--ff-only` so a non-fast-forward attempt fails loudly instead of creating a merge commit:

   ```sh
   git switch main
   git merge --ff-only <branch>
   ```

If `--ff-only` refuses, stop and report it. Do not fall back to a regular merge commit without confirmation.


## Running tests

The project uses Minitest, wired through Rake. From the repository root (inside the worktree):

```sh
bundle exec rake test
```

Equivalent shortcut:

```sh
bundle exec rake
```

To run a single test file:

```sh
bundle exec ruby -Ilib -Itest test/test_<name>.rb
```

To run a single test method, pass `-n`:

```sh
bundle exec ruby -Ilib -Itest test/test_<name>.rb -n test_<method>
```

All tests must pass before committing.

## Type checking (RBS + Steep)

Type checking is being introduced incrementally. Signatures live under `sig/`, and
`Steepfile` lists only the `lib/` files that already have a matching `.rbs`, so
`steep check` stays green while coverage grows file by file.

Run the type check:

```sh
bundle exec steep check
```

`bundle exec rake` runs the test suite and the type check together (`default: [test, steep]`).

Dependency-gem signatures come from `ruby/gem_rbs_collection` via `rbs collection`.
The downloaded types live in `.gem_rbs_collection/` (gitignored); only
`rbs_collection.yaml` is committed. After cloning, install them once:

```sh
bundle exec rbs collection install
```

To add type coverage for another file:

1. Write its signature under `sig/<path>.rbs` (mirror the `lib/` path).
2. Add the file to the `check` list in `Steepfile`.
3. Run `bundle exec steep check` and resolve any errors before committing.

Keep `steep check` green — never add a file to `Steepfile` without its signature.

## Architecture

`tempest` is a terminal Bluesky client that speaks the AT Protocol directly. It does not use any third-party Bluesky SDK; HTTP and WebSocket are wired by hand.

### External protocols and services

- **AT Protocol** — the underlying federated protocol. See <https://atproto.com/> and the spec index at <https://atproto.com/specs>.
- **XRPC** — AT Protocol's HTTP-based RPC convention. `tempest` calls endpoints under `https://bsky.social/xrpc/<nsid>` such as `com.atproto.server.createSession`, `com.atproto.server.refreshSession`, `com.atproto.repo.createRecord`, `app.bsky.feed.getTimeline`, `app.bsky.graph.getFollows`, `app.bsky.actor.getProfile`.
- **Jetstream** — Bluesky's JSON firehose over WebSocket. Public endpoints are listed at <https://github.com/bluesky-social/jetstream>. Cursors are unix-microseconds (`time_us`) and the default replay window on public instances is 24 hours; `StreamManager` uses a conservative 12-hour cutoff and falls back to `getTimeline` for longer gaps.
- **Bluesky lexicons** (record schemas, NSIDs): <https://github.com/bluesky-social/atproto/tree/main/lexicons>
- **Bluesky API reference**: <https://docs.bsky.app/>

### Component map

Transport and domain:

- `Tempest::HTTP` — minimal HTTP/JSON wrapper.
- `Tempest::Session` / `Tempest::SessionStore` — JWT auth, refresh, on-disk session cache.
- `Tempest::XRPCClient` — calls XRPC endpoints with automatic 401-refresh-retry.
- `Tempest::Timeline` / `Tempest::Post` / `Tempest::Follows` — typed wrappers around the XRPC responses.
- `Tempest::HandleResolver` — DID → handle cache (uses `app.bsky.actor.getProfile`, seeded from follows at startup).
- `Tempest::CursorStore` / `Tempest::TimelineStore` — disk persistence for the last seen `time_us` and a 50-post timeline snapshot.

Jetstream live feed:

- `Tempest::Jetstream::Client` — WebSocket consumer; builds the subscription URL with `wantedCollections` / `wantedDids` / `cursor`.
- `Tempest::Jetstream::Decoder` — JSON → `Event`.
- `Tempest::Jetstream::Subscription` — decides between server-side `wantedDids` filtering and firehose + client-side filtering, based on Jetstream's 10 000-DID cap.
- `Tempest::Jetstream::StreamManager` — runs the consumer in a background thread, reconnects with cursor preservation, applies exponential backoff, emits `StreamStatus` lifecycle events, and throttles cursor persistence.

REPL and CLI:

- `Tempest::REPL::Runner` — main REPL loop, command dispatch, timeline bootstrap, stream event rendering.
- `Tempest::REPL::Screen` — earthquake-style split layout via DECSTBM (scrolling region above, prompt fixed at the bottom). Writes are mutex-serialized so background Jetstream events and synchronous REPL output do not interleave their ANSI sequences.
- `Tempest::REPL::Formatter` — single-line formatting for posts, events, and status lines.
- `Tempest::REPL::Dispatcher` — input string → command.
- `Tempest::REPL::AsyncOutput` — Reline-aware output wrapper used when the split-screen `Screen` is not enabled.
- `Tempest::CLI` — startup orchestration: sign-in, `--feed=home|self` selection, follows fetch, subscription plan, wiring everything together, then `runner.bootstrap_timeline` → `runner.auto_start_stream` → `runner.run`.

### Runtime flow at a glance

1. `Tempest::CLI.run` signs in (reusing the cached session if possible) and constructs the XRPC client.
2. `build_subscription` chooses between `:self` (own DID only) and `:home` (own DID + follows); when follows exceed Jetstream's `wantedDids` cap, the plan switches to firehose mode plus a client-side filter.
3. `StreamManager` is started in a background thread. It loads any persisted cursor, reconnects with that cursor on disconnect/error, and emits `StreamStatus(:disconnected/:reconnecting/:live/:gapped)` so the `Runner` can render status lines.
4. The `Runner` first replays the on-disk timeline snapshot, then fetches `getTimeline` for the diff, then enters the REPL.


