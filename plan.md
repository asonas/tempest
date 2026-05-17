# plan: inline Bluesky avatars via Kitty graphics protocol

Goal: each timeline line shows the poster's avatar as a 1-row-high inline image,
rendered with the Kitty graphics protocol. Format becomes:

    [$AA] [HH:MM] <icon>@handle: text

The icon occupies `c=2` cells of width and is rendered with `r=1,c=2,C=1` so
the cursor never moves and the rest of the line text stays on the same row.

Sources confirmed working (see `tmp/avatar_probe.rb`, run 2026-05-17):
- Ghostty + cmux renders Kitty graphics (sixel does not pass through cmux).
- ImageMagick is available locally and handles JPEG/WebP/PNG normalization.
- Bluesky CDN returns avatars whose Content-Type is JPEG or WebP.

## Architecture

New modules:

- `Tempest::Kitty` — pure escape-sequence generator. Takes PNG bytes, returns
  the `\e_G...\e\\` string. No I/O, no shell-outs. Easy to unit-test.
- `Tempest::AvatarStore` — DID → on-disk PNG path. Owns:
  - HTTP fetch of the avatar URL (mockable via injected fetcher).
  - Format normalization to PNG via ImageMagick (mockable via injected
    converter).
  - Disk cache keyed by DID and avatar CID (so a re-uploaded avatar invalidates
    the cache without server-side coordination).
  - Lazy / asynchronous warm-up: `#path_for(did)` returns `nil` until the
    image is ready; later calls return the path. The caller (Formatter) just
    degrades to no-icon when `nil` is returned.

Touched modules:

- `Tempest::REPL::Formatter#post_line` / `#event_line` / `#compose` — accept
  an optional `avatar_store`. When provided and a PNG path is available for
  the post's DID, prefix the handle label with the Kitty escape from
  `Tempest::Kitty.inline`. Otherwise behave exactly as today.
- `Tempest::CLI` — construct `AvatarStore` with the same `XRPCClient` (so we
  get session-aware getProfile calls and rate-limit handling for free), wire
  it into the `Runner`/`Formatter`.

Disabled paths:

- Sixel is dead (cmux drops it). We do not implement it.
- We do not introduce 24-bit color block fallback yet; that can be a later
  follow-up if Kitty is unavailable in some environment.

## Test list (TDD)

Work the list top-to-bottom. One test, then enough code to make it green,
then tidy, then commit. Add new items as they surface.

### Tempest::Kitty (pure encoder, no I/O)

- [x] `inline(png_bytes, rows: 1, cols: 2)` returns a string starting with
      `\e_G` and ending with `\e\\`.
- [x] The first chunk's control segment contains `a=T`, `f=100`, `r=1`, `c=2`,
      and `C=1` (cursor stays put).
- [x] PNG bytes are base64-encoded into the data segment (decode the data,
      assert it equals the input).
- [x] When the base64 payload exceeds 4096 bytes, output is split into multiple
      chunks: the first carries the controls with `m=1`, intermediate chunks
      carry only `m=1`, and the final chunk carries `m=0`.
- [x] `rows` and `cols` override defaults (e.g. `rows: 2, cols: 4`).
- [x] Accepts a file path: `inline(path)` where path is a String pointing at
      a file reads the bytes and behaves identically to passing bytes.

### Tempest::AvatarStore (DID → PNG path)

The store has two flavors that share a single resolution path:

- **Synchronous (test mode, `async: false`)**: `path_for(did)` does the full
  fetch+convert inline and returns the path (or nil on failure).
- **Asynchronous (default, `async: true`)**: `path_for(did)` returns whatever
  is already in the cache (nil for unknown DIDs) and enqueues background
  resolution for next time.

Sync path is implemented first; async wraps it.

Fakes:
- `FakeClient#get("app.bsky.actor.getProfile", query: { "actor" => did })`
  returns either `{ "avatar" => url }` or raises `Tempest::APIError`.
- `FakeFetcher#call(url)` returns `[bytes, content_type]`.
- `FakeConverter#call(bytes, content_type:)` returns PNG bytes.

Synchronous path:

- [x] `path_for(did)` (sync) calls getProfile, fetches the avatar, converts
      to PNG, writes to the cache dir, and returns the path.
- [x] The cached file name encodes both the DID and the avatar CID derived
      from the URL, so a different CID for the same DID produces a different
      file path.
- [x] Repeated `path_for(did)` calls with the same DID and same avatar CID
      do not re-fetch (assert FakeClient/FakeFetcher receive exactly one call).
- [x] When the profile has no avatar field, `path_for(did)` returns `nil` and
      negatively caches the result (no repeated getProfile calls).
- [x] When getProfile raises `Tempest::APIError`, `path_for(did)` returns `nil`
      and the failure is cached (no repeated calls).
- [x] When the converter raises, `path_for(did)` returns `nil` and the failure
      is cached.
- [x] `seed(did, png_path)` lets tests inject a known path without going
      through HTTP (mirror of `HandleResolver#seed`).

Asynchronous path:

- [x] In async mode, the first `path_for(did)` for an unknown DID returns
      `nil` and enqueues a background resolution. After the worker finishes,
      a subsequent call returns the resolved path.
- [x] Async failures (any of: API error, missing avatar, converter raise)
      are still negatively cached, so the worker isn't dispatched again.

### Tempest::REPL::Formatter (integration with AvatarStore)

- [ ] `post_line(post, avatar_store: nil)` matches today's output exactly when
      `avatar_store` is nil (regression guard).
- [ ] `post_line(post, avatar_store: store)` where `store.path_for(post.did)`
      returns nil also matches today's output (no icon when unavailable).
- [ ] `post_line(post, avatar_store: store)` where the store returns a real
      PNG path injects the Kitty escape immediately before `@handle`, with one
      space between the icon and `@`.
- [ ] `event_line` mirrors the above for Jetstream events that carry a DID.
- [ ] Icon rendering respects `Formatter.color`: when `Formatter.color` is
      false (test mode), no escape is emitted — same way ANSI colors are
      suppressed today. (Avoids polluting test snapshots.)

### Wiring

- [ ] `Tempest::CLI` builds an `AvatarStore` and passes it through to the
      `Runner` and `Formatter`. Smoke-test via the existing CLI test if
      possible; otherwise add a minimal new test.
- [ ] Manual verification: run tempest against the live timeline in cmux and
      visually confirm the icon appears before known handles.

## Out of scope (deliberate)

- Async refresh when an avatar CID changes mid-session (just wait until next
  session for now).
- LRU eviction of the on-disk cache (cache dir grows unbounded; acceptable
  for a personal client).
- Pre-warming the cache for all follows at startup (let it warm lazily).
- Cleanup of `tmp/graphics_probe.sh` / `tmp/avatar_probe.rb` (they live under
  the gitignored `tmp/` of the probe worktree, not this branch).
