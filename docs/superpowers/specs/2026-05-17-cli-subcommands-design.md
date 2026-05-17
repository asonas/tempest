# CLI Subcommands Design

Date: 2026-05-17
Status: Approved (pending implementation plan)

## Background and Motivation

`tempest` currently exposes a single entry point that drops the user into the TUI (`Tempest::CLI.run`). For Claude Code and other automated callers, the TUI is the wrong shape: we want one-shot commands that authenticate against the cached session, perform a single XRPC call, print a stable result, and exit.

The driving use case is "summarise my posts from today" invoked by an AI agent. That requires (a) listing a user's posts in a stable machine-readable form and (b) optionally posting from the same CLI without entering the TUI.

## Goals

- Add non-interactive subcommands for posting, reading feeds, and identifying the signed-in account.
- Provide a stable JSON output schema so AI callers can rely on field names without tracking AT Protocol schema changes.
- Keep the existing TUI entry point (`tempest` with no args) working unchanged.
- Reuse existing transport, session, and formatting code where it does not pull in Jetstream/REPL machinery.

## Non-goals (v1)

- Image attachments, quote posts, deletions.
- `like` / `repost` / `follow` mutations.
- Live streaming or Jetstream subscriptions outside the TUI.
- Time precision finer than one day for `--since` / `--until`.
- Writing output to a file (callers can redirect stdout).

## Subcommand Surface

```
tempest                            # existing TUI (preserved verbatim)
tempest tui [flags]                # explicit alias for the TUI; same flags as today
tempest post <text|->              # create a post
tempest feed me|timeline|author    # read a feed
tempest whoami                     # report the signed-in identity
tempest --version | --help         # existing
```

Routing rule in `Tempest::CLI.run`: if `argv[0]` matches a known subcommand name (`tui`, `post`, `feed`, `whoami`), dispatch to the corresponding `Commands::*`. Otherwise (no args, or only flags), fall through to the existing TUI bootstrap. `--version` and `--help` continue to be intercepted at the very top of `run`.

The dual provision of "bare `tempest`" and "`tempest tui`" is intentional: existing users keep their muscle memory, new users discover the explicit form via `--help`.

### `tempest post`

```
tempest post <text>                     # text from argv
tempest post -                          # text from stdin
  --lang ja[,en]                        # post langs; default "ja"
  --reply-to <at-uri>                   # reply target (parent and root set to the same ref)
  --json                                # success output: {"uri":..., "cid":..., "created_at":...}
                                        # default success output: "posted: <at-uri>"
```

Behaviour:

- Use existing `Tempest::Post.create` (URL facet detection already lives there).
- Empty text or text whose grapheme count exceeds 300 fails before any XRPC round-trip with exit code 64.
- `--reply-to` inherits the existing v1 behaviour where `root` is set equal to `parent`; deep-thread nesting is a known limitation, called out here so it does not regress silently.

### `tempest feed`

```
tempest feed me        [feed-flags]
tempest feed timeline  [feed-flags]
tempest feed author <handle|did> [feed-flags]

feed-flags:
  --limit N             # default 50, max 100 (over 100 fails with exit code 64)
  --since <DATE>        # createdAt lower bound (inclusive)
  --until <DATE>        # createdAt upper bound (exclusive)
  --format line|json|raw
  --no-color
```

- `me` calls `app.bsky.feed.getAuthorFeed` with `actor=<self.did>`.
- `author <handle>` resolves the handle via `app.bsky.actor.getProfile` first, then `getAuthorFeed`.
- `timeline` calls `app.bsky.feed.getTimeline`.
- `--since`/`--until` accept: ISO8601 (`2026-05-17T00:00:00Z` or `2026-05-17`), `today`, `yesterday`, or `Nd` (N days ago). All comparisons use the post record's `createdAt` field. Bare-date and keyword forms (`today`, `yesterday`, `Nd`) are resolved in the system local timezone — `today` means `Time.now.localtime.beginning_of_day`. ISO8601 inputs that include an explicit offset are honoured as written.
- Pagination: request `getAuthorFeed`/`getTimeline` with `limit=min(--limit, 100)` once. If the caller specified `--since` and the last item in the response is still newer than `--since`, follow `cursor` until either `--since` is crossed or the per-page result is empty. Cap at a hard internal limit of 5 pages to avoid runaway loops; if the cap is hit, emit a warning to stderr (still exit 0 with the partial result) so the caller can detect truncation.
- Filtering by `--since`/`--until` happens locally after the fetch.

### `tempest whoami`

```
tempest whoami                  # "@handle (did:plc:xxx)"
tempest whoami --json           # {"handle":..., "did":..., "pds_host":...}
tempest whoami --did            # did only (newline-terminated)
tempest whoami --handle         # handle only
```

`--did`, `--handle`, and `--json` are mutually exclusive.

## Output Contract

### `--format=line` (default when stdout is a TTY)

Reuses `Tempest::REPL::Formatter.post_line(post, registry: nil)`. Calling without a registry must produce the same one-line representation the TUI uses, minus the `[$AA]` post id. Colour is emitted iff `stdout.tty?` and `ENV["NO_COLOR"].to_s.empty?` and `--no-color` is absent.

### `--format=json` (default when stdout is not a TTY)

Newline-delimited JSON (NDJSON), one post object per line. Schema:

```json
{
  "uri": "at://did:plc:.../app.bsky.feed.post/3k...",
  "cid": "bafy...",
  "author": {
    "did": "did:plc:...",
    "handle": "asonas.bsky.social",
    "display_name": "asonas"
  },
  "text": "...",
  "created_at": "2026-05-17T09:00:00.000Z",
  "indexed_at": "2026-05-17T09:00:01.123Z",
  "langs": ["ja"],
  "reply": { "parent_uri": "at://...", "root_uri": "at://..." },
  "facets": [
    { "kind": "link", "uri": "https://...", "byte_start": 0, "byte_end": 20 }
  ],
  "embed": { "kind": "record" | "images" | "external" | "video" | null },
  "like_count": 0,
  "repost_count": 0,
  "reply_count": 0
}
```

Rules:

- All keys are always present. Missing values are emitted as `null` (or `[]` for `langs`/`facets`).
- `embed.kind` is the discriminator only; the full embed payload is not flattened in v1.
- `reply` is `null` when the post is not a reply.

A new module `Tempest::PostView.from_feed_view(post_hash) -> Hash` owns this transformation and acts as the schema firewall. Tests pin it to recorded XRPC fixtures so a change in the upstream `getAuthorFeed` response does not silently change our output.

### `--format=raw`

`JSON.pretty_generate(response)` where `response` is the raw XRPC body (or an array of `post` objects when a single response would normally hold multiple). Intended for debugging only; no stability guarantees.

### Error output

- `--format=line`: human-readable single line on stderr, matching the existing `error: ...` style.
- `--format=json` and `--format=raw`: a single-line JSON object on stderr:
  ```json
  {"error":"<message>","code":"<symbol>","details":{...}}
  ```
  `code` values include: `usage`, `config_missing`, `auth_failed`, `auth_cache_missing`, `api_error`, `not_found`, `internal`.

### Exit codes

| Code | Meaning                                                       |
|------|---------------------------------------------------------------|
| 0    | Success                                                       |
| 1    | Generic/internal error                                        |
| 2    | Configuration error (`Tempest::Config::MissingValue`)         |
| 3    | Authentication error (cache missing or refresh failed)        |
| 4    | Bluesky API error (HTTP 4xx/5xx surfaced as `Tempest::APIError`) |
| 64   | Usage error (invalid flag, bad date, limit > 100, etc.)       |

## Authentication for Non-interactive Commands

`Commands::Post`, `Commands::Feed`, and `Commands::Whoami` share a common path:

1. Load `SessionStore` from disk.
2. If a cached session is present, call `session.refresh!`. If refresh succeeds, proceed.
3. If the cache is missing or refresh fails, exit immediately with code 3 and the error contract above. **Do not prompt for credentials or 2FA codes** — those flows belong to `tempest tui`.

The TUI keeps its current behaviour (prompt for 2FA on demand, fall back to `TEMPEST_IDENTIFIER`/`TEMPEST_APP_PASSWORD`).

## Architecture

### Module layout

```
lib/tempest/
  cli.rb                       # routing only; existing TUI logic moves to commands/tui.rb
  commands/
    base.rb                    # shared: arg parsing, auth, output writer, error -> exit code
    tui.rb                     # current CLI.run body, lifted verbatim
    post.rb
    feed.rb
    whoami.rb
  output/
    json_writer.rb             # NDJSON / pretty JSON output, error JSON formatting
    line_writer.rb             # wraps REPL::Formatter for non-REPL contexts
  post_view.rb                 # XRPC post hash -> stable Tempest schema (firewall)
```

### `Commands::Base` responsibilities

- Parse shared flags: `--format`, `--no-color`, `--limit`.
- Decide default format from `stdout.tty?`.
- Build an authenticated `Tempest::XRPCClient` via the cache-only auth path above.
- Provide `out` (stdout writer) and `err` (stderr writer) bound to the chosen format.
- Convert `Tempest::Error` subclasses into the appropriate exit code and error payload.

Subcommands receive the prepared `client`, `session`, `out`, `err`, and remaining argv, and focus on their own logic. They do **not** instantiate `Jetstream::*`, `Screen`, `Watchdog`, or `HandleResolver`.

### Routing

`Tempest::CLI.run` becomes:

```ruby
def run(argv: ARGV, env: ENV, stdout: $stdout, stderr: $stderr, stdin: $stdin, ...)
  return print_version(stdout) if argv.include?("--version") || argv.include?("-v")
  return print_help(stdout)    if argv.include?("--help")    || argv.include?("-h")

  case argv.first
  when "post"    then Commands::Post.new(...).call(argv.drop(1))
  when "feed"    then Commands::Feed.new(...).call(argv.drop(1))
  when "whoami"  then Commands::Whoami.new(...).call(argv.drop(1))
  when "tui", nil, ->(a) { a.start_with?("-") }
    Commands::Tui.new(...).call(argv.dup)  # existing CLI.run body
  else
    stderr.puts "unknown command: #{argv.first}"
    64
  end
end
```

`Commands::Tui` is the existing `CLI.run` extracted with no behavioural change; this is a structural-only refactor done first per Tidy First.

## Test Strategy

Following the existing Minitest layout:

- `test/test_post_view.rb` — `PostView.from_feed_view` against recorded XRPC fixtures (one minimal post, one reply, one post with link facets, one with each `embed.kind`). The fixtures live in `test/fixtures/feed_view/*.json`.
- `test/commands/test_post.rb` — stub `XRPCClient`; verify `createRecord` body, success stdout in both `--json` and default modes, length/empty validation, exit codes.
- `test/commands/test_feed.rb` — feed for each of `me`/`timeline`/`author`; `--since today` filtering; NDJSON shape; default format selection by `stdout.tty?`; pagination cap warning; `--limit > 100` failure.
- `test/commands/test_whoami.rb` — three output modes, mutual exclusion.
- `test/test_cli.rb` — extended with routing-table tests: each subcommand dispatches, unknown command returns 64, bare/`tui`/`-` flags reach the TUI path.
- No real HTTP, no real Jetstream — consistent with existing tests.

## Risks and Trade-offs

- **Pagination edge case.** Capping at 5 pages means a caller running `tempest feed author <heavy-poster> --since 30d` may silently truncate. We surface this with a stderr warning and exit 0 with the partial result; spec consumers should treat absence of warning as "complete result".
- **Schema firewall maintenance.** `PostView` has to stay in sync with reality. The fixture-based tests catch silent upstream changes only when we re-record fixtures; the alternative (no firewall) is worse because it leaks AT Proto naming into automation scripts.
- **Reply nesting limitation.** Inherited from existing `Post.create`. Called out so it stays a conscious choice rather than a hidden bug.
- **TUI extraction is a structural change.** Done in a separate commit (Tidy First) before any behaviour changes land.

## Documentation Updates

- `README.md` — add a "CLI usage" section with examples for `post`, `feed me --since today --format json`, `whoami`.
- `tempest --help` — list subcommands; per-subcommand help via `tempest <sub> --help`.
