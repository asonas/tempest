# IdVars: Earthquake-Style Identifiers for Posts and Links

Status: Design
Date: 2026-05-15

## Background

`tempest` currently renders timeline posts and Jetstream events as
`[HH:MM] @handle: text`. Once a line scrolls past, there is no way for the
user to reference it again from the REPL. The original `earthquake` gem
solved this by assigning every printed tweet a short identifier such as
`$aa`, then accepting input like `$aa hello world` as a reply to that
tweet and `:open $aa` as "open the URLs in that tweet".

This spec ports that affordance to `tempest`, with one extension: each URL
that appears in a rendered post is also given its own identifier, so the
user can pick a single link to open.

## Goals

1. Every rendered post (from `Timeline.fetch` and from Jetstream commits) is
   prefixed with a unique short identifier of the form `$XX`.
2. Every URL inside a rendered post body is annotated with its own short
   identifier of the form `$LX`.
3. `$AA <text>` typed at the prompt creates a reply to the post that was
   assigned `$AA`.
4. `:open $LA` opens the URL that was assigned `$LA` in the user's browser.
5. Identifiers are stable for as long as their slot has not been reassigned.
   When the ring wraps around, the oldest identifier is overwritten and
   the previous mapping is forgotten.

## Non-Goals

- Persisting identifier ↔ post mappings across `tempest` restarts. The
  registry is in-memory only; a fresh process starts at `$AA`.
- Resolving the true root of a reply chain. v1 uses the picked post as
  both `parent` and `root` (see Reply Mechanics below).
- Constructing `app.bsky.richtext.facet` entries for the `@handle`
  prefix synthesised on reply. v1 sends the mention as plain text.
- Anything other than `http`/`https` URLs (no `at://` URIs, no mailto,
  no custom schemes).

## Identifier Scheme

Two independent generators share a single namespace under prefix `$`:

| Kind  | Range                | Slots | Examples                |
|-------|----------------------|-------|-------------------------|
| Post  | `"AA".."ZZ"`         | 676   | `$AA`, `$AB`, …, `$ZZ`  |
| Link  | `"LA".."LZ"`         | 26    | `$LA`, `$LB`, …, `$LZ`  |

Both ranges live under the same `$` prefix and the string keys do not
collide (`"$AA"` ≠ `"$LA"`), so a single lookup table can hold both.
After the last slot in a range is used, the generator wraps around to
the first slot in that range, overwriting the previous owner. The
overwritten owner's reverse mapping is also deleted so a stale id never
resolves to a recycled var.

The link generator's range deliberately starts at `LA` (not `AA`) so
post ids and link ids are visually distinguishable in the printed
output. Choosing only 26 slots for links is intentional: in normal use
the user follows up on a fresh link soon after seeing it, and 26
recent URLs is more than enough to keep the prompt usable.

## Components

### `Tempest::IdVar`

New stdlib-only class under `lib/tempest/id_var.rb`. Mirrors the design of
`Earthquake::IdVar::Gen` but without ActiveSupport.

```
Tempest::IdVar.new(range: "AA".."ZZ", prefix: "$")
  #generate(id) -> "$AA"
  #lookup(var)  -> id or nil
```

`generate(id)` returns the existing var for `id` if one exists,
otherwise advances to the next var, deletes any forward/reverse mapping
that pointed to that slot, and stores the new pair in both directions.

The generator is not thread-safe by itself. It will always be called
from the REPL render path (single thread or behind `Screen`'s mutex),
which provides the necessary serialization. This matches how the rest
of the rendering pipeline already works.

### `Tempest::REPL::Registry`

New class under `lib/tempest/repl/registry.rb`. Owns two `IdVar`
instances (post, link) plus two side tables that map `var` → original
domain object:

```
Registry#assign_post(post) -> "$AA"
Registry#assign_url(url)   -> "$LA"
Registry#find_post(var)    -> Tempest::Post | Tempest::Jetstream::Event | nil
Registry#find_url(var)     -> String | nil
```

`assign_post` is idempotent for the same post URI: re-rendering the same
post (e.g. timeline replay on bootstrap, then live event for the same
post) keeps the original identifier rather than burning a fresh slot.
Identity uses `uri` for `Post` and the constructed `at://did/coll/rkey`
URI for Jetstream events.

`assign_url` is similarly idempotent on the URL string within the
lifetime of its slot.

When a slot is overwritten, the side table entry for the displaced
identifier is also removed, so `find_post`/`find_url` returns nil for
recycled ids rather than the wrong object.

### `Tempest::REPL::Formatter`

`post_line(post, registry: nil)` and
`event_line(event, registry: nil, resolver: nil)` gain an optional
`registry` keyword. When `registry` is non-nil:

1. Call `registry.assign_post(post)` (or the event), prepend the result
   in `[$AA]` brackets before the existing `[HH:MM]` prefix.
2. Extract `http`/`https` URLs from the body text via
   `URI.extract(text, ["http", "https"])`.
3. For each URL, call `registry.assign_url(url)` and rewrite the body
   so the URL is followed inline by ` ($LA)`.

The colorless renderer (used by tests) emits, for example:

```
[$AA] [12:34] @alice.bsky.social: see https://example.com ($LA)
```

When `registry` is nil, the rendered output is unchanged from today.

`event_line` follows the same shape. For `:delete` operations the
formatter does not allocate an id (there is nothing to reply to or open
in a delete announcement).

URL annotation in the body deliberately uses ` ($LA)` (a leading space
and parentheses) rather than appending to the URL with no separator so
the URL stays recognisable to the user's terminal URL detector.

### `Tempest::REPL::Dispatcher`

Two new patterns are recognised before the existing fallback:

| Input          | Resulting command                          |
|----------------|--------------------------------------------|
| `$XX rest…`    | `Command(name: :reply, args: ["$XX", "rest…"])` |
| `:open $XX`    | `Command(name: :open,  args: ["$XX"])`     |
| `:open`        | `Command(name: :open,  args: [])` (error message in Runner) |

The `$XX` token is matched by `\A\$[A-Z]{2}\z` (exactly two uppercase
letters, matching both `"AA".."ZZ"` and `"LA".."LZ"` ranges). If the
token does not match this shape, fall through to the existing
post-as-status branch (so the user can still post text that happens to
start with `$`, e.g. `$5 for coffee` — the digit makes the pattern
fail).

The dispatcher remains pure: it does not consult the registry. The
Runner is responsible for resolving the var to a Post/URL and
producing a meaningful error if the lookup fails.

### `Tempest::Post.create`

Extended with an optional `reply:` keyword:

```ruby
Post.create(client, did:, text:, reply: nil, created_at: ...)
```

When `reply` is `{ uri:, cid: }`, the created record contains:

```
"reply" => { "root" => { "uri" => uri, "cid" => cid },
             "parent" => { "uri" => uri, "cid" => cid } }
```

In v1, `root` is set equal to `parent` unconditionally. This is
incorrect for replies several levels deep into a thread (AppView will
nest them under the picked parent rather than the original root), but
keeps the data model simple and matches `earthquake`'s behaviour. A
follow-up can fetch the parent record and copy through its `reply.root`
when present.

### `Tempest::Jetstream::Event`

Add `#at_uri` returning `"at://#{did}/#{collection}/#{rkey}"`. This is
the same string Bluesky's lexicons use as a record reference and is
what `Registry#assign_post` indexes on for events.

### `Tempest::REPL::Runner`

Three new private handlers:

- `handle_reply(var, text)`
  1. `post_or_event = @registry.find_post(var)`; if nil, print
     `unknown id: $XX` and return.
  2. Resolve the parent's `uri` and `cid` (Post has them directly;
     Event uses `at_uri` and its stored `cid`).
  3. Build the reply text as `"@#{handle} #{text}"` when the handle is
     known (Post#handle or HandleResolver lookup), else just `text`.
  4. Call `Tempest.post_create_reply` (a thin wrapper around the
     extended `Post.create`) and print the resulting URI like a normal
     post.

- `handle_open(var)`
  1. `url = @registry.find_url(var)`; if nil, print `unknown id: $XX`.
  2. If `var` is missing entirely (`:open` with no arg), print usage.
  3. Otherwise call `@opener.call(url)`. Default `@opener` is
     `->(u) { system("open", u) }`; tests inject a recording fake.

The Runner constructor gains `registry:` (defaulted to a fresh
`Registry.new`) and `opener:` (defaulted as above).

`bootstrap_timeline`, `handle_timeline`, and `handle_stream_event` all
pass `@registry` into `Formatter.post_line` / `Formatter.event_line` so
identifiers are assigned at render time. No code path renders a post
without going through the formatter, so the registry has full coverage.

## Data Flow

Rendering:

```
Post/Event arrives
  -> Formatter.post_line(post, registry: r)
       -> r.assign_post(post)            => "$AA"
       -> for each url in post.text:
            r.assign_url(url)            => "$LA"
       -> "[$AA] [12:34] @h: text https://… ($LA)"
  -> Screen.puts
```

Reply:

```
User types "$AA hoge"
  -> Dispatcher                          => Command(:reply, ["$AA","hoge"])
  -> Runner#handle_reply
       -> r.find_post("$AA")             => Post(uri:..., cid:..., handle:"alice")
       -> Post.create(client, did:..., text:"@alice hoge",
                      reply: {uri:..., cid:...})
       -> output "posted: at://..."
```

Open:

```
User types ":open $LA"
  -> Dispatcher                          => Command(:open, ["$LA"])
  -> Runner#handle_open
       -> r.find_url("$LA")              => "https://example.com"
       -> opener.call(url)
```

## Error Handling

- Unknown `$XX` in reply or open: print `unknown id: $XX`, do nothing
  else. The live feed must keep running.
- Reply with no text after the var (`$AA`): print
  `usage: $XX <text>`; do not call `Post.create`.
- `:open` with no var: print `usage: :open $LX`.
- Reply network failures: existing `rescue Tempest::Error` path in
  `handle_post` is reused.
- Opener failure: `system` returns false; print
  `error: failed to open <url>` but do not raise.

## Testing Strategy (TDD Order)

1. `Tempest::IdVar` unit:
   - first `generate(id)` returns `$AA`; second different `id` returns `$AB`
   - `generate` is idempotent on the same id within the same slot
   - wrap-around reuses `$AA` and clears the old reverse mapping
   - `lookup` of an unknown var returns nil
2. `Tempest::REPL::Registry`:
   - post and link ids are independent (`$AA` and `$LA` can both exist)
   - `assign_post` is idempotent per uri / per event's `at_uri`
   - `find_post` returns the original object; `find_url` returns the URL
   - recycled slot returns nil for the old var
3. `Formatter` with registry:
   - `post_line` prepends `[$AA]`, keeps `[HH:MM]`
   - URLs in body gain ` ($LA)` annotation
   - delete-event lines do not get a `$XX`
   - without `registry:` the existing output is unchanged
4. `Dispatcher`:
   - `"$AA hoge"` → `:reply` command
   - `":open $LA"` → `:open` command
   - `":open"` (no arg) → `:open` with empty args
   - `"$5 for coffee"` → `:post` (unchanged behaviour)
5. `Post.create` with `reply:`:
   - body carries `reply.root` and `reply.parent` both equal to the
     provided uri/cid
   - without `reply:` the body is unchanged
6. `Runner#handle_reply`:
   - unknown var prints `unknown id: $AA`, no client call
   - empty body prints `usage: $XX <text>`, no client call
   - happy path: posts with `@handle <text>` and reply context
7. `Runner#handle_open`:
   - unknown var prints `unknown id: $LA`, opener not called
   - missing var prints `usage: :open $LX`
   - happy path: opener is called with the registered URL
8. `Jetstream::Event#at_uri` returns the expected string.

All tests must pass before each commit. No mocks where a real object
would do; the opener is the only injected fake.

## Risks and Mitigations

- **Slot wrap-around hits an actively-tracked post.** Mitigated by
  giving posts 676 slots (~2.5 days of a quiet timeline at one post
  per 5 minutes). If real use shows it's tight we expand the range
  before adding eviction policy.
- **`URI.extract` greediness.** `URI.extract` is permissive about
  trailing punctuation. We accept whatever it returns in v1; if
  trailing `).` etc. ends up in links the user can copy-paste
  manually. A regex tightening is a follow-up.
- **`system("open", url)` blocking the REPL.** `open` returns
  immediately on macOS; on Linux `xdg-open` typically forks. We do not
  wait on the child explicitly. If a user binds `TEMPEST_OPEN_CMD` to
  something blocking, that is their concern.
- **Recycled-slot reply hitting the wrong post.** A user typing `$AA`
  after the slot was recycled will reach the *new* tenant of the slot,
  not the old. This matches `earthquake` behaviour and is expected.

## Open Decisions Recorded

- Display format: `[$AA] [HH:MM] @handle: text ...` (two bracket groups
  separated by a single space). Chosen for visual scannability over
  merging into `[$AA HH:MM]`.
- Range capitalisation: uppercase (`$AA`) per user request, distinct
  from `earthquake`'s lowercase `$aa`.
- Open command default: `system("open", url)` on macOS; override via
  `TEMPEST_OPEN_CMD` (single executable, URL appended as `argv[1]`).
- Identifier kept only in memory: no persistence.
- Mention facets: not generated in v1.
