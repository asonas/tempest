# CLI Subcommands Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add non-interactive subcommands (`post`, `feed`, `whoami`) to `tempest` so AI agents and scripts can invoke a single XRPC call and exit, while keeping the existing TUI entry point (`tempest` with no args) untouched.

**Architecture:** Split `Tempest::CLI.run` into a thin dispatcher plus `Tempest::Commands::*` modules. Add a `Tempest::PostView` schema firewall that translates AT Protocol post hashes into a stable JSON shape. Reuse `Tempest::XRPCClient`, `Tempest::Post`, and `Tempest::REPL::Formatter` (called without a registry).

**Tech Stack:** Ruby (existing project, no new gems). Minitest. The repo runs `bundle exec rake test` from the project root.

**Spec:** `docs/superpowers/specs/2026-05-17-cli-subcommands-design.md`

**Worktree:** `/Users/asonas/ghq/github.com/asonas/tempest/.worktrees/feature/cli-subcommands` — run every command from inside this worktree.

---

## File Map

New production files:
- `lib/tempest/commands.rb` — namespace + autoloads
- `lib/tempest/commands/base.rb` — shared auth + format/exit-code helpers
- `lib/tempest/commands/tui.rb` — existing `CLI.run` body, lifted verbatim
- `lib/tempest/commands/whoami.rb`
- `lib/tempest/commands/post.rb`
- `lib/tempest/commands/feed.rb`
- `lib/tempest/post_view.rb` — XRPC `feed.post` hash → stable Tempest::Hash
- `lib/tempest/output/json_writer.rb` — NDJSON output + error JSON
- `lib/tempest/output/line_writer.rb` — `REPL::Formatter` adapter for non-REPL contexts
- `lib/tempest/date_filter.rb` — `--since`/`--until` parsing + filtering
- `lib/tempest/handle_lookup.rb` — `app.bsky.actor.getProfile` handle → DID

New test files:
- `test/test_post_view.rb`
- `test/fixtures/feed_view/minimal.json`
- `test/fixtures/feed_view/with_facets.json`
- `test/fixtures/feed_view/reply.json`
- `test/fixtures/feed_view/with_embed_images.json`
- `test/output/test_json_writer.rb`
- `test/output/test_line_writer.rb`
- `test/commands/test_whoami.rb`
- `test/commands/test_post.rb`
- `test/commands/test_feed.rb`
- `test/test_date_filter.rb`
- `test/test_handle_lookup.rb`

Modified:
- `lib/tempest/cli.rb` — dispatcher, replaces existing body
- `test/test_cli.rb` — routing assertions added

---

## Task 1: Extract existing TUI into Commands::Tui (structural-only refactor)

**Files:**
- Create: `lib/tempest/commands.rb`
- Create: `lib/tempest/commands/tui.rb`
- Modify: `lib/tempest/cli.rb`

This is a Tidy First move. No behaviour change. All existing tests in `test/test_cli.rb` must still pass without modification.

- [ ] **Step 1: Run the full test suite to capture the green baseline**

```sh
bundle exec rake test
```

Expected: all tests pass. Note the test count for later comparison.

- [ ] **Step 2: Create the `Tempest::Commands` namespace**

Create `lib/tempest/commands.rb`:

```ruby
require_relative "../tempest"

module Tempest
  module Commands
  end
end
```

- [ ] **Step 3: Create `Tempest::Commands::Tui` by lifting the body of `Tempest::CLI.run`**

Create `lib/tempest/commands/tui.rb`. The body is everything `CLI.run` does today *except* the `--version`/`--help` short-circuits at the top. Move the require list with it.

```ruby
require_relative "../commands"
require_relative "../../tempest"
require_relative "../config"
require_relative "../debug_log"
require_relative "../session"
require_relative "../session_store"
require_relative "../cursor_store"
require_relative "../timeline_store"
require_relative "../xrpc_client"
require_relative "../handle_resolver"
require_relative "../avatar_store"
require_relative "../follows"
require_relative "../jetstream/client"
require_relative "../jetstream/stream_manager"
require_relative "../jetstream/subscription"
require_relative "../jetstream/watchdog"
require_relative "../repl/runner"
require_relative "../repl/formatter"
require_relative "../repl/async_output"
require_relative "../repl/screen"

module Tempest
  module Commands
    module Tui
      module_function

      def call(argv:, env:, stdout:, stderr:, stdin:,
               session_factory: Tempest::Session.method(:create),
               store: nil)
        # PASTE THE ENTIRE BODY OF THE EXISTING Tempest::CLI.run HERE,
        # starting from `Tempest::REPL::Formatter.color = ...` and ending
        # with the `rescue Tempest::Error => e ; ... ; 1` block.
        # Do not change any line. Only the surrounding `def run(...)` becomes
        # `def call(...)`.
      end

      # Lift these private helpers from CLI as-is (sign_in, nil_if_empty,
      # create_with_2fa, stream_default_on?, cursor_store, build_debug_logger,
      # watchdog_options, timeline_store, avatar_cache_dir, opener_for,
      # feed_mode, build_subscription, attach_store, help_text, RelineReader,
      # VALID_FEED_MODES).
      # Module-level constants (e.g. VALID_FEED_MODES) belong inside this module.
    end
  end
end
```

Concretely: copy every method and constant currently defined inside `module Tempest::CLI` (except `run`) into `module Tempest::Commands::Tui`. They are already `module_function`s, so the shape stays identical.

- [ ] **Step 4: Rewrite `lib/tempest/cli.rb` to delegate to `Commands::Tui`**

Replace the file entirely with:

```ruby
require_relative "../tempest"
require_relative "commands/tui"

module Tempest
  module CLI
    module_function

    def run(argv: ARGV, env: ENV, stdout: $stdout, stderr: $stderr, stdin: $stdin,
            session_factory: Tempest::Session.method(:create),
            store: nil)
      if argv.include?("--version") || argv.include?("-v")
        stdout.puts "tempest #{Tempest::VERSION}"
        return 0
      end

      if argv.include?("--help") || argv.include?("-h")
        stdout.puts Tempest::Commands::Tui.help_text
        return 0
      end

      Tempest::Commands::Tui.call(
        argv: argv, env: env, stdout: stdout, stderr: stderr, stdin: stdin,
        session_factory: session_factory, store: store,
      )
    end
  end
end
```

- [ ] **Step 5: Run the test suite — must be all green with zero modifications to existing tests**

```sh
bundle exec rake test
```

Expected: identical pass count to Step 1.

If anything fails: this means the lift was not verbatim. Roll back step 3 and 4, redo carefully. Do **not** change tests to make this pass.

- [ ] **Step 6: Commit (structural-only)**

```sh
git add lib/tempest/cli.rb lib/tempest/commands.rb lib/tempest/commands/tui.rb
git commit
```

Use the project's `/commit` skill. Commit message should make clear this is a structural-only move (no behaviour change), e.g. "Extract TUI bootstrap into Tempest::Commands::Tui".

---

## Task 2: Wire the subcommand dispatcher (no subcommands yet, just the routing scaffolding)

**Files:**
- Modify: `lib/tempest/cli.rb`
- Modify: `test/test_cli.rb`

- [ ] **Step 1: Write the failing routing test**

Append to `test/test_cli.rb`:

```ruby
class TestCLIRouting < Minitest::Test
  def test_unknown_subcommand_returns_64_and_writes_to_stderr
    err = StringIO.new
    status = Tempest::CLI.run(
      argv: ["nope"], env: {}, stdout: StringIO.new, stderr: err,
    )
    assert_equal 64, status
    assert_match(/unknown command/, err.string)
  end

  def test_explicit_tui_subcommand_reaches_tui_path
    # Reuse the same "missing env" path the existing TUI tests exercise to
    # prove we got into Commands::Tui without changing observable behaviour.
    err = StringIO.new
    status = Tempest::CLI.run(
      argv: ["tui"], env: {}, stdout: StringIO.new, stderr: err,
    )
    refute_equal 0, status
    assert_match(/TEMPEST_IDENTIFIER/, err.string)
  end

  def test_dashflag_only_argv_still_reaches_tui_path
    err = StringIO.new
    status = Tempest::CLI.run(
      argv: ["--no-stream"], env: {}, stdout: StringIO.new, stderr: err,
    )
    refute_equal 0, status
    assert_match(/TEMPEST_IDENTIFIER/, err.string)
  end
end
```

- [ ] **Step 2: Run the new tests and confirm two of three fail**

```sh
bundle exec ruby -Ilib -Itest test/test_cli.rb -n /TestCLIRouting/
```

Expected: `test_unknown_subcommand_returns_64_and_writes_to_stderr` fails (no dispatcher yet); the other two pass because the current code accepts arbitrary argv.

- [ ] **Step 3: Add the dispatcher to `lib/tempest/cli.rb`**

Replace `lib/tempest/cli.rb` with:

```ruby
require_relative "../tempest"
require_relative "commands/tui"

module Tempest
  module CLI
    SUBCOMMANDS = %w[tui post feed whoami].freeze

    module_function

    def run(argv: ARGV, env: ENV, stdout: $stdout, stderr: $stderr, stdin: $stdin,
            session_factory: Tempest::Session.method(:create),
            store: nil)
      if argv.include?("--version") || argv.include?("-v")
        stdout.puts "tempest #{Tempest::VERSION}"
        return 0
      end

      if argv.include?("--help") || argv.include?("-h")
        stdout.puts Tempest::Commands::Tui.help_text
        return 0
      end

      head = argv.first
      case
      when head.nil?, head.start_with?("-"), head == "tui"
        rest = (head == "tui") ? argv.drop(1) : argv
        Tempest::Commands::Tui.call(
          argv: rest, env: env, stdout: stdout, stderr: stderr, stdin: stdin,
          session_factory: session_factory, store: store,
        )
      when SUBCOMMANDS.include?(head)
        stderr.puts "subcommand not implemented yet: #{head}"
        1
      else
        stderr.puts "unknown command: #{head.inspect}"
        64
      end
    end
  end
end
```

- [ ] **Step 4: Run the full test suite**

```sh
bundle exec rake test
```

Expected: all tests pass (including the three new routing tests).

- [ ] **Step 5: Commit**

```sh
git add lib/tempest/cli.rb test/test_cli.rb
git commit
```

Use `/commit`. Subject: "Add subcommand dispatcher to Tempest::CLI".

---

## Task 3: `Tempest::Commands::Base` — shared auth, format selection, exit-code mapping

**Files:**
- Create: `lib/tempest/commands/base.rb`
- Create: `test/commands/test_base.rb`

`Base` is *not* a class to subclass. It is a module of class methods that produce a small `Context` value (session, client, format, stdout, stderr). Each subcommand calls `Base.with_context(argv:, env:, stdout:, stderr:) { |ctx| ... }`.

- [ ] **Step 1: Write the failing test for cache-only auth**

Create `test/commands/test_base.rb`:

```ruby
require_relative "../test_helper"
require "stringio"
require "tmpdir"
require "tempest/commands/base"
require "tempest/session"
require "tempest/session_store"

class TestCommandsBase < Minitest::Test
  def test_auth_returns_session_when_cached_session_refreshes_successfully
    Dir.mktmpdir do |dir|
      path = File.join(dir, "session.json")
      seed = Tempest::Session.new(
        access_jwt: "old",
        refresh_jwt: "old-refresh",
        did: "did:plc:x",
        handle: "asonas.bsky.social",
        pds_host: "https://bsky.social",
      )
      Tempest::SessionStore.new(path: path).save(seed, identifier: "asonas.bsky.social")

      def seed.refresh!
        @access_jwt = "new"
        self
      end

      store = Tempest::SessionStore.new(path: path)
      def store.load(**); end
      store.define_singleton_method(:load) { |**_| seed }

      session = Tempest::Commands::Base.authenticate(env: {}, store: store, stderr: StringIO.new)
      assert_equal "asonas.bsky.social", session.handle
    end
  end

  def test_auth_returns_nil_and_writes_error_when_no_cache
    Dir.mktmpdir do |dir|
      store = Tempest::SessionStore.new(path: File.join(dir, "missing.json"))
      err = StringIO.new
      session = Tempest::Commands::Base.authenticate(env: {}, store: store, stderr: err)
      assert_nil session
      assert_match(/no cached session/, err.string)
    end
  end
end
```

- [ ] **Step 2: Run the test and confirm it fails (file not found)**

```sh
bundle exec ruby -Ilib -Itest test/commands/test_base.rb
```

Expected: `LoadError` for `tempest/commands/base`.

- [ ] **Step 3: Implement `Tempest::Commands::Base.authenticate`**

Create `lib/tempest/commands/base.rb`:

```ruby
require_relative "../commands"
require_relative "../session_store"

module Tempest
  module Commands
    module Base
      module_function

      # Loads the cached session and refreshes it. Returns the session on
      # success. On failure (no cache, refresh rejected) writes a single
      # human-readable line to stderr and returns nil; callers translate the
      # nil into exit code 3.
      def authenticate(env:, stderr:, store: nil)
        store ||= Tempest::SessionStore.new(path: Tempest::SessionStore.default_path(env))
        session = store.load(identifier: env["TEMPEST_IDENTIFIER"], pds_host: env["TEMPEST_PDS_HOST"])
        if session.nil?
          stderr.puts "error: no cached session — run `tempest tui` once to sign in"
          return nil
        end
        session.on_change = ->(s) { store.save(s, identifier: s.identifier) }
        begin
          session.refresh!
        rescue Tempest::Error => e
          stderr.puts "error: cached session refresh failed: #{e.message}"
          return nil
        end
        session
      end
    end
  end
end
```

- [ ] **Step 4: Run the test, confirm it passes**

```sh
bundle exec ruby -Ilib -Itest test/commands/test_base.rb
```

Expected: 2 passes.

- [ ] **Step 5: Add the format-selection helper, test-first**

Add to `test/commands/test_base.rb` before its closing `end`:

```ruby
  class FakeIO
    def initialize(tty:); @tty = tty; end
    def tty?; @tty; end
  end

  def test_default_format_is_json_when_stdout_is_not_a_tty
    fmt = Tempest::Commands::Base.default_format(stdout: FakeIO.new(tty: false), env: {})
    assert_equal :json, fmt
  end

  def test_default_format_is_line_when_stdout_is_a_tty_and_no_color_unset
    fmt = Tempest::Commands::Base.default_format(stdout: FakeIO.new(tty: true), env: {})
    assert_equal :line, fmt
  end
```

Run:

```sh
bundle exec ruby -Ilib -Itest test/commands/test_base.rb
```

Expected: 2 new failures (`NoMethodError`).

- [ ] **Step 6: Implement `default_format`**

Append inside the `module Base` of `lib/tempest/commands/base.rb`:

```ruby
      VALID_FORMATS = %i[line json raw].freeze

      # Returns one of :line, :json, :raw. Callers may override with --format.
      def default_format(stdout:, env:)
        stdout.respond_to?(:tty?) && stdout.tty? ? :line : :json
      end

      # Parses --format=NAME from argv (destructive: returns [format, argv_without_flag]).
      # Raises ArgumentError on unknown format names.
      def take_format(argv, default:)
        out = []
        chosen = default
        argv.each do |arg|
          if (m = arg.match(/\A--format=(\S+)\z/))
            sym = m[1].to_sym
            raise ArgumentError, "invalid --format: #{m[1].inspect}" unless VALID_FORMATS.include?(sym)
            chosen = sym
          elsif arg == "--no-color"
            Tempest::REPL::Formatter.color = false if defined?(Tempest::REPL::Formatter)
          else
            out << arg
          end
        end
        [chosen, out]
      end
```

Add the require for `repl/formatter` at the top of `base.rb`:

```ruby
require_relative "../repl/formatter"
```

Run the tests:

```sh
bundle exec ruby -Ilib -Itest test/commands/test_base.rb
```

Expected: 4 passes.

- [ ] **Step 7: Add the exit-code mapping helper, test-first**

Append to `test/commands/test_base.rb`:

```ruby
  def test_exit_code_for_config_missing_returns_2
    e = Tempest::Config::MissingValue.new("missing")
    assert_equal 2, Tempest::Commands::Base.exit_code_for(e)
  end

  def test_exit_code_for_auth_returns_3
    e = Tempest::AuthenticationError.new("nope", code: "x")
    assert_equal 3, Tempest::Commands::Base.exit_code_for(e)
  end

  def test_exit_code_for_api_returns_4
    e = Tempest::APIError.new(503, "down")
    assert_equal 4, Tempest::Commands::Base.exit_code_for(e)
  end

  def test_exit_code_for_argument_error_returns_64
    assert_equal 64, Tempest::Commands::Base.exit_code_for(ArgumentError.new("bad flag"))
  end

  def test_exit_code_for_unknown_returns_1
    assert_equal 1, Tempest::Commands::Base.exit_code_for(StandardError.new("oops"))
  end
```

Require additions at top of the test file:

```ruby
require "tempest/config"
```

Run:

```sh
bundle exec ruby -Ilib -Itest test/commands/test_base.rb
```

Expected: 5 new failures.

- [ ] **Step 8: Implement `exit_code_for`**

Append inside `module Base`:

```ruby
      def exit_code_for(error)
        case error
        when Tempest::Config::MissingValue then 2
        when Tempest::AuthenticationError  then 3
        when Tempest::APIError             then 4
        when ArgumentError                 then 64
        else                                    1
        end
      end
```

Add requires at the top of `base.rb`:

```ruby
require_relative "../config"
```

Run:

```sh
bundle exec rake test
```

Expected: all tests pass.

- [ ] **Step 9: Commit**

```sh
git add lib/tempest/commands/base.rb test/commands/test_base.rb
git commit
```

Use `/commit`. Subject: "Add Tempest::Commands::Base helpers".

---

## Task 4: `Tempest::Commands::Whoami` (simplest end-to-end subcommand)

**Files:**
- Create: `lib/tempest/commands/whoami.rb`
- Create: `test/commands/test_whoami.rb`
- Modify: `lib/tempest/cli.rb`

- [ ] **Step 1: Write the failing test for default (`@handle (did)`) output**

Create `test/commands/test_whoami.rb`:

```ruby
require_relative "../test_helper"
require "stringio"
require "json"
require "tempest/commands/whoami"
require "tempest/session"

class TestCommandsWhoami < Minitest::Test
  def fake_session
    Tempest::Session.new(
      access_jwt: "a", refresh_jwt: "r",
      did: "did:plc:abc", handle: "asonas.bsky.social",
      pds_host: "https://bsky.social",
    )
  end

  def test_default_output_is_handle_and_did
    out = StringIO.new
    status = Tempest::Commands::Whoami.call(
      argv: [], session: fake_session, stdout: out, stderr: StringIO.new,
    )
    assert_equal 0, status
    assert_equal "@asonas.bsky.social (did:plc:abc)\n", out.string
  end
end
```

- [ ] **Step 2: Run and confirm failure (LoadError)**

```sh
bundle exec ruby -Ilib -Itest test/commands/test_whoami.rb
```

- [ ] **Step 3: Implement minimal `Tempest::Commands::Whoami`**

Create `lib/tempest/commands/whoami.rb`:

```ruby
require_relative "../commands"

module Tempest
  module Commands
    module Whoami
      module_function

      def call(argv:, session:, stdout:, stderr:)
        if argv.include?("--did") && argv.include?("--handle")
          stderr.puts "error: --did and --handle are mutually exclusive"
          return 64
        end
        if argv.include?("--did")
          stdout.puts session.did
        elsif argv.include?("--handle")
          stdout.puts session.handle
        elsif argv.include?("--json")
          require "json"
          stdout.puts JSON.generate(
            "handle" => session.handle,
            "did" => session.did,
            "pds_host" => session.pds_host,
          )
        else
          stdout.puts "@#{session.handle} (#{session.did})"
        end
        0
      end
    end
  end
end
```

- [ ] **Step 4: Run the test, confirm pass**

```sh
bundle exec ruby -Ilib -Itest test/commands/test_whoami.rb
```

- [ ] **Step 5: Write tests for the three flag variants and mutual exclusion**

Append to `test/commands/test_whoami.rb`:

```ruby
  def test_did_flag_outputs_only_did
    out = StringIO.new
    Tempest::Commands::Whoami.call(argv: ["--did"], session: fake_session, stdout: out, stderr: StringIO.new)
    assert_equal "did:plc:abc\n", out.string
  end

  def test_handle_flag_outputs_only_handle
    out = StringIO.new
    Tempest::Commands::Whoami.call(argv: ["--handle"], session: fake_session, stdout: out, stderr: StringIO.new)
    assert_equal "asonas.bsky.social\n", out.string
  end

  def test_json_flag_outputs_object_with_handle_did_pds_host
    out = StringIO.new
    Tempest::Commands::Whoami.call(argv: ["--json"], session: fake_session, stdout: out, stderr: StringIO.new)
    payload = JSON.parse(out.string)
    assert_equal "asonas.bsky.social", payload["handle"]
    assert_equal "did:plc:abc", payload["did"]
    assert_equal "https://bsky.social", payload["pds_host"]
  end

  def test_did_and_handle_are_mutually_exclusive
    err = StringIO.new
    status = Tempest::Commands::Whoami.call(
      argv: ["--did", "--handle"], session: fake_session, stdout: StringIO.new, stderr: err,
    )
    assert_equal 64, status
    assert_match(/mutually exclusive/, err.string)
  end
```

Run:

```sh
bundle exec ruby -Ilib -Itest test/commands/test_whoami.rb
```

Expected: 5 passes.

- [ ] **Step 6: Wire whoami into the CLI dispatcher**

Modify `lib/tempest/cli.rb`. Add `require_relative "commands/base"` and `require_relative "commands/whoami"` at the top, then replace the `when SUBCOMMANDS.include?(head)` branch:

```ruby
      when head == "whoami"
        session = Tempest::Commands::Base.authenticate(env: env, stderr: stderr)
        return 3 if session.nil?
        Tempest::Commands::Whoami.call(
          argv: argv.drop(1), session: session, stdout: stdout, stderr: stderr,
        )
      when SUBCOMMANDS.include?(head)
        stderr.puts "subcommand not implemented yet: #{head}"
        1
```

- [ ] **Step 7: Add an integration test in `test/test_cli.rb` that exercises the dispatch**

Append:

```ruby
  def test_whoami_routes_through_dispatcher
    Dir.mktmpdir do |dir|
      path = File.join(dir, "session.json")
      seed = Tempest::Session.new(
        access_jwt: "a", refresh_jwt: "r",
        did: "did:plc:abc", handle: "asonas.bsky.social",
        pds_host: "https://bsky.social",
      )
      def seed.refresh!; self; end
      Tempest::SessionStore.new(path: path).save(seed, identifier: "asonas.bsky.social")

      out = StringIO.new
      status = Tempest::CLI.run(
        argv: ["whoami"],
        env: { "TEMPEST_SESSION_PATH" => path },
        stdout: out, stderr: StringIO.new,
      )
      assert_equal 0, status
      assert_match(/@asonas.bsky.social/, out.string)
    end
  end
```

This relies on `SessionStore.default_path(env)` honouring `TEMPEST_SESSION_PATH`. Verify that contract in `lib/tempest/session_store.rb` before running; if the env var name differs, use whatever the file currently reads.

- [ ] **Step 8: Full test suite**

```sh
bundle exec rake test
```

Expected: all green.

- [ ] **Step 9: Commit**

```sh
git add lib/tempest/commands/whoami.rb test/commands/test_whoami.rb lib/tempest/cli.rb test/test_cli.rb
git commit
```

Use `/commit`. Subject: "Add tempest whoami subcommand".

---

## Task 5: `Tempest::PostView` — XRPC schema firewall

**Files:**
- Create: `lib/tempest/post_view.rb`
- Create: `test/test_post_view.rb`
- Create: `test/fixtures/feed_view/minimal.json`
- Create: `test/fixtures/feed_view/with_facets.json`
- Create: `test/fixtures/feed_view/reply.json`
- Create: `test/fixtures/feed_view/with_embed_images.json`

`PostView.from_feed_view(post_hash)` returns a `Hash` with the stable schema defined in the spec. Missing leaves become `nil` (or `[]` for `langs`/`facets`).

- [ ] **Step 1: Create the fixtures**

Create `test/fixtures/feed_view/minimal.json`:

```json
{
  "uri": "at://did:plc:abc/app.bsky.feed.post/k1",
  "cid": "bafyminimal",
  "author": { "did": "did:plc:abc", "handle": "alice.bsky.social", "displayName": "Alice" },
  "record": {
    "$type": "app.bsky.feed.post",
    "text": "hello",
    "createdAt": "2026-05-17T01:00:00.000Z",
    "langs": ["ja"]
  },
  "indexedAt": "2026-05-17T01:00:01.500Z",
  "likeCount": 0,
  "repostCount": 0,
  "replyCount": 0
}
```

Create `test/fixtures/feed_view/with_facets.json`:

```json
{
  "uri": "at://did:plc:abc/app.bsky.feed.post/k2",
  "cid": "bafyfacets",
  "author": { "did": "did:plc:abc", "handle": "alice.bsky.social", "displayName": "Alice" },
  "record": {
    "$type": "app.bsky.feed.post",
    "text": "see https://example.com please",
    "createdAt": "2026-05-17T02:00:00.000Z",
    "langs": ["ja"],
    "facets": [
      {
        "index": { "byteStart": 4, "byteEnd": 23 },
        "features": [
          { "$type": "app.bsky.richtext.facet#link", "uri": "https://example.com" }
        ]
      }
    ]
  },
  "indexedAt": "2026-05-17T02:00:00.900Z",
  "likeCount": 3,
  "repostCount": 1,
  "replyCount": 0
}
```

Create `test/fixtures/feed_view/reply.json`:

```json
{
  "uri": "at://did:plc:abc/app.bsky.feed.post/k3",
  "cid": "bafyreply",
  "author": { "did": "did:plc:abc", "handle": "alice.bsky.social" },
  "record": {
    "$type": "app.bsky.feed.post",
    "text": "thanks",
    "createdAt": "2026-05-17T03:00:00.000Z",
    "langs": ["ja"],
    "reply": {
      "root":   { "uri": "at://did:plc:bob/app.bsky.feed.post/root", "cid": "bafyroot" },
      "parent": { "uri": "at://did:plc:bob/app.bsky.feed.post/par",  "cid": "bafypar" }
    }
  },
  "indexedAt": "2026-05-17T03:00:00.100Z",
  "likeCount": 0,
  "repostCount": 0,
  "replyCount": 0
}
```

Create `test/fixtures/feed_view/with_embed_images.json`:

```json
{
  "uri": "at://did:plc:abc/app.bsky.feed.post/k4",
  "cid": "bafyembed",
  "author": { "did": "did:plc:abc", "handle": "alice.bsky.social" },
  "record": {
    "$type": "app.bsky.feed.post",
    "text": "look",
    "createdAt": "2026-05-17T04:00:00.000Z",
    "embed": { "$type": "app.bsky.embed.images" }
  },
  "embed": { "$type": "app.bsky.embed.images#view" },
  "indexedAt": "2026-05-17T04:00:00.000Z"
}
```

- [ ] **Step 2: Write the failing tests**

Create `test/test_post_view.rb`:

```ruby
require_relative "test_helper"
require "json"
require "tempest/post_view"

class TestPostView < Minitest::Test
  FIXTURE_DIR = File.expand_path("fixtures/feed_view", __dir__)

  def load_fixture(name)
    JSON.parse(File.read(File.join(FIXTURE_DIR, name)))
  end

  def test_minimal_fixture_produces_full_schema_with_nil_optional_fields
    view = Tempest::PostView.from_feed_view(load_fixture("minimal.json"))
    assert_equal "at://did:plc:abc/app.bsky.feed.post/k1", view[:uri]
    assert_equal "bafyminimal", view[:cid]
    assert_equal({ did: "did:plc:abc", handle: "alice.bsky.social", display_name: "Alice" }, view[:author])
    assert_equal "hello", view[:text]
    assert_equal "2026-05-17T01:00:00.000Z", view[:created_at]
    assert_equal "2026-05-17T01:00:01.500Z", view[:indexed_at]
    assert_equal ["ja"], view[:langs]
    assert_nil view[:reply]
    assert_equal [], view[:facets]
    assert_nil view[:embed][:kind]
    assert_equal 0, view[:like_count]
  end

  def test_with_facets_emits_link_facet_objects
    view = Tempest::PostView.from_feed_view(load_fixture("with_facets.json"))
    assert_equal 1, view[:facets].length
    f = view[:facets].first
    assert_equal :link, f[:kind]
    assert_equal "https://example.com", f[:uri]
    assert_equal 4, f[:byte_start]
    assert_equal 23, f[:byte_end]
    assert_equal 3, view[:like_count]
  end

  def test_reply_fixture_emits_reply_object_with_parent_and_root
    view = Tempest::PostView.from_feed_view(load_fixture("reply.json"))
    assert_equal "at://did:plc:bob/app.bsky.feed.post/par", view[:reply][:parent_uri]
    assert_equal "at://did:plc:bob/app.bsky.feed.post/root", view[:reply][:root_uri]
  end

  def test_embed_kind_strips_the_lexicon_prefix_and_view_suffix
    view = Tempest::PostView.from_feed_view(load_fixture("with_embed_images.json"))
    assert_equal :images, view[:embed][:kind]
  end

  def test_all_top_level_keys_are_always_present
    expected = %i[uri cid author text created_at indexed_at langs reply facets embed like_count repost_count reply_count]
    view = Tempest::PostView.from_feed_view(load_fixture("minimal.json"))
    assert_equal expected.sort, view.keys.sort
  end
end
```

Run:

```sh
bundle exec ruby -Ilib -Itest test/test_post_view.rb
```

Expected: LoadError.

- [ ] **Step 3: Implement `Tempest::PostView`**

Create `lib/tempest/post_view.rb`:

```ruby
require_relative "../tempest"

module Tempest
  module PostView
    EMBED_KINDS = {
      "app.bsky.embed.images"   => :images,
      "app.bsky.embed.record"   => :record,
      "app.bsky.embed.external" => :external,
      "app.bsky.embed.video"    => :video,
    }.freeze

    module_function

    def from_feed_view(post_hash)
      h = post_hash || {}
      author = h["author"] || {}
      record = h["record"] || {}
      reply  = record["reply"]

      {
        uri:          h["uri"],
        cid:          h["cid"],
        author: {
          did:          author["did"],
          handle:       author["handle"],
          display_name: author["displayName"],
        },
        text:         record["text"],
        created_at:   record["createdAt"],
        indexed_at:   h["indexedAt"],
        langs:        Array(record["langs"]),
        reply:        reply_view(reply),
        facets:       facets_view(record["facets"]),
        embed:        embed_view(h["embed"] || record["embed"]),
        like_count:   h["likeCount"]   || 0,
        repost_count: h["repostCount"] || 0,
        reply_count:  h["replyCount"]  || 0,
      }
    end

    def reply_view(reply)
      return nil unless reply.is_a?(Hash)
      parent = reply["parent"].is_a?(Hash) ? reply["parent"]["uri"] : nil
      root   = reply["root"].is_a?(Hash)   ? reply["root"]["uri"]   : nil
      { parent_uri: parent, root_uri: root }
    end

    def facets_view(facets)
      Array(facets).flat_map do |facet|
        idx = facet["index"] || {}
        Array(facet["features"]).filter_map do |feat|
          next unless feat["$type"] == "app.bsky.richtext.facet#link"
          {
            kind:       :link,
            uri:        feat["uri"],
            byte_start: idx["byteStart"],
            byte_end:   idx["byteEnd"],
          }
        end
      end
    end

    def embed_view(embed)
      return { kind: nil } unless embed.is_a?(Hash)
      type = embed["$type"].to_s.sub(/#view\z/, "")
      { kind: EMBED_KINDS[type] }
    end
  end
end
```

- [ ] **Step 4: Run, confirm all 5 pass**

```sh
bundle exec ruby -Ilib -Itest test/test_post_view.rb
```

- [ ] **Step 5: Full suite**

```sh
bundle exec rake test
```

- [ ] **Step 6: Commit**

```sh
git add lib/tempest/post_view.rb test/test_post_view.rb test/fixtures/feed_view/
git commit
```

Use `/commit`. Subject: "Add Tempest::PostView schema firewall".

---

## Task 6: `Tempest::Output::JsonWriter` — NDJSON + error JSON

**Files:**
- Create: `lib/tempest/output/json_writer.rb`
- Create: `test/output/test_json_writer.rb`

- [ ] **Step 1: Write the failing test**

Create `test/output/test_json_writer.rb`:

```ruby
require_relative "../test_helper"
require "stringio"
require "json"
require "tempest/output/json_writer"

class TestJsonWriter < Minitest::Test
  def test_write_posts_emits_one_json_object_per_line
    io = StringIO.new
    Tempest::Output::JsonWriter.new(io).write_posts([{ a: 1 }, { a: 2 }])
    lines = io.string.lines
    assert_equal 2, lines.length
    assert_equal({ "a" => 1 }, JSON.parse(lines[0]))
    assert_equal({ "a" => 2 }, JSON.parse(lines[1]))
  end

  def test_write_error_writes_single_line_object_with_code_and_message
    io = StringIO.new
    Tempest::Output::JsonWriter.new(io).write_error("oops", code: "api_error")
    assert_equal 1, io.string.lines.length
    payload = JSON.parse(io.string)
    assert_equal "oops", payload["error"]
    assert_equal "api_error", payload["code"]
  end

  def test_write_raw_pretty_prints_payload
    io = StringIO.new
    Tempest::Output::JsonWriter.new(io).write_raw({ "feed" => [{ "post" => { "uri" => "x" } }] })
    parsed = JSON.parse(io.string)
    assert_equal "x", parsed["feed"][0]["post"]["uri"]
    assert io.string.include?("\n  "), "expected pretty-printed JSON to contain indentation"
  end
end
```

- [ ] **Step 2: Run, confirm failure**

```sh
bundle exec ruby -Ilib -Itest test/output/test_json_writer.rb
```

- [ ] **Step 3: Implement `JsonWriter`**

Create `lib/tempest/output/json_writer.rb`:

```ruby
require "json"
require_relative "../../tempest"

module Tempest
  module Output
    class JsonWriter
      def initialize(io)
        @io = io
      end

      def write_posts(views)
        views.each { |v| @io.puts JSON.generate(v) }
      end

      def write_error(message, code:, details: nil)
        payload = { "error" => message, "code" => code }
        payload["details"] = details unless details.nil?
        @io.puts JSON.generate(payload)
      end

      def write_raw(payload)
        @io.puts JSON.pretty_generate(payload)
      end
    end
  end
end
```

- [ ] **Step 4: Run, confirm pass**

```sh
bundle exec ruby -Ilib -Itest test/output/test_json_writer.rb
```

- [ ] **Step 5: Commit**

```sh
git add lib/tempest/output/json_writer.rb test/output/test_json_writer.rb
git commit
```

Use `/commit`. Subject: "Add Tempest::Output::JsonWriter".

---

## Task 7: `Tempest::Output::LineWriter` — REPL::Formatter adapter

**Files:**
- Create: `lib/tempest/output/line_writer.rb`
- Create: `test/output/test_line_writer.rb`

- [ ] **Step 1: Write the failing test**

Create `test/output/test_line_writer.rb`:

```ruby
require_relative "../test_helper"
require "stringio"
require "tempest/output/line_writer"
require "tempest/post"

class TestLineWriter < Minitest::Test
  def post
    Tempest::Post.new(
      uri: "at://x", cid: "bafy", handle: "alice.bsky.social",
      display_name: "Alice", text: "hello world",
      created_at: "2026-05-17T01:00:00.000Z",
    )
  end

  def test_write_posts_emits_one_line_per_post_via_formatter
    Tempest::REPL::Formatter.color = false
    io = StringIO.new
    Tempest::Output::LineWriter.new(io).write_posts([post, post])
    assert_equal 2, io.string.lines.length
    assert_match(/@alice.bsky.social: hello world/, io.string.lines.first)
  end

  def test_write_error_writes_error_prefix_line
    io = StringIO.new
    Tempest::Output::LineWriter.new(io).write_error("kaboom", code: "x")
    assert_equal "error: kaboom\n", io.string
  end
end
```

Run:

```sh
bundle exec ruby -Ilib -Itest test/output/test_line_writer.rb
```

Expected: LoadError.

- [ ] **Step 2: Implement `LineWriter`**

Create `lib/tempest/output/line_writer.rb`:

```ruby
require_relative "../../tempest"
require_relative "../repl/formatter"

module Tempest
  module Output
    class LineWriter
      def initialize(io)
        @io = io
      end

      def write_posts(posts)
        posts.each { |p| @io.puts Tempest::REPL::Formatter.post_line(p) }
      end

      def write_error(message, code: nil, details: nil)
        @io.puts "error: #{message}"
      end
    end
  end
end
```

- [ ] **Step 3: Run, confirm pass**

```sh
bundle exec ruby -Ilib -Itest test/output/test_line_writer.rb
```

- [ ] **Step 4: Commit**

```sh
git add lib/tempest/output/line_writer.rb test/output/test_line_writer.rb
git commit
```

Use `/commit`. Subject: "Add Tempest::Output::LineWriter".

---

## Task 8: `Tempest::Commands::Post` + dispatcher wiring

**Files:**
- Create: `lib/tempest/commands/post.rb`
- Create: `test/commands/test_post.rb`
- Modify: `lib/tempest/cli.rb`
- Modify: `lib/tempest/post.rb` (add `langs:` keyword)
- Modify: `test/test_post.rb` (langs regression test)

### Pre-step: extend `Tempest::Post.create` to accept `langs:`

`Post.create` currently has no `langs:` parameter; this subcommand needs it. Make this change first as a structural step.

- [ ] **Step 0a: Write the failing langs test**

Append to `test/test_post.rb` (inside `class TestPostCreate`):

```ruby
  def test_create_writes_langs_into_record
    client = FakeClient.new("uri" => "at://x")
    Tempest::Post.create(client, did: "did:plc:abc", text: "hi", langs: ["ja", "en"])
    _, body = client.calls.first
    assert_equal ["ja", "en"], body[:record]["langs"]
  end

  def test_create_omits_langs_when_not_given
    client = FakeClient.new("uri" => "at://x")
    Tempest::Post.create(client, did: "did:plc:abc", text: "hi")
    _, body = client.calls.first
    refute body[:record].key?("langs")
  end
```

Run:

```sh
bundle exec ruby -Ilib -Itest test/test_post.rb -n /langs/
```

Expected: ArgumentError (unknown keyword: langs).

- [ ] **Step 0b: Extend `Post.create` signature**

In `lib/tempest/post.rb`, change:

```ruby
    def self.create(client, did:, text:, reply: nil,
                    created_at: Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S.%LZ"))
```

to:

```ruby
    def self.create(client, did:, text:, reply: nil, langs: nil,
                    created_at: Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S.%LZ"))
```

After the `record = { ... }` block, add:

```ruby
      record["langs"] = langs if langs && !langs.empty?
```

Run:

```sh
bundle exec rake test
```

Expected: green, including the two new langs tests.

- [ ] **Step 1: Write the first failing test (happy path)**

Create `test/commands/test_post.rb`:

```ruby
require_relative "../test_helper"
require "stringio"
require "json"
require "tempest/commands/post"
require "tempest/session"

class TestCommandsPost < Minitest::Test
  class FakeXRPCClient
    attr_reader :calls
    def initialize(post_response: nil, get_responses: {})
      @post_response = post_response
      @get_responses = get_responses
      @calls = []
    end
    def post(nsid, body:); @calls << [:post, nsid, body]; @post_response; end
    def get(nsid, query: nil); @calls << [:get, nsid, query]; @get_responses.fetch(nsid); end
  end

  def fake_session
    Tempest::Session.new(
      access_jwt: "a", refresh_jwt: "r",
      did: "did:plc:abc", handle: "asonas.bsky.social",
      pds_host: "https://bsky.social",
    )
  end

  def test_text_argument_creates_a_post_and_prints_human_line
    client = FakeXRPCClient.new(
      post_response: { "uri" => "at://did:plc:abc/app.bsky.feed.post/k", "cid" => "bafy" },
    )
    out = StringIO.new
    status = Tempest::Commands::Post.call(
      argv: ["hello world"], session: fake_session, client: client,
      stdout: out, stderr: StringIO.new, stdin: StringIO.new,
    )
    assert_equal 0, status
    posts = client.calls.select { |c| c.first == :post }
    assert_equal 1, posts.length
    _, nsid, body = posts.first
    assert_equal "com.atproto.repo.createRecord", nsid
    assert_equal "hello world", body[:record]["text"]
    assert_equal ["ja"], body[:record]["langs"]
    assert_match(%r{posted: at://}, out.string)
  end
end
```

Run:

```sh
bundle exec ruby -Ilib -Itest test/commands/test_post.rb
```

Expected: LoadError.

- [ ] **Step 2: Implement minimal `Tempest::Commands::Post`**

Create `lib/tempest/commands/post.rb`:

```ruby
require_relative "../commands"
require_relative "../post"

module Tempest
  module Commands
    module Post
      MAX_GRAPHEMES = 300

      module_function

      def call(argv:, session:, client:, stdout:, stderr:, stdin:)
        opts, positional = parse(argv)
        return 64 if opts[:invalid]

        text = read_text(positional, stdin: stdin)
        if text.nil? || text.strip.empty?
          stderr.puts "error: empty post text"
          return 64
        end
        if text.grapheme_clusters.length > MAX_GRAPHEMES
          stderr.puts "error: post exceeds #{MAX_GRAPHEMES} graphemes"
          return 64
        end

        record_extras = {}
        record_extras[:langs] = opts[:langs]
        reply = build_reply(opts[:reply_to])

        response = Tempest::Post.create(
          client, did: session.did, text: text, reply: reply,
          langs: opts[:langs],
        )

        if opts[:json]
          require "json"
          stdout.puts JSON.generate(
            "uri" => response["uri"], "cid" => response["cid"],
          )
        else
          stdout.puts "posted: #{response["uri"]}"
        end
        0
      end

      def parse(argv)
        opts = { langs: ["ja"], json: false, reply_to: nil, invalid: false }
        positional = []
        i = 0
        while i < argv.length
          a = argv[i]
          case a
          when "--lang"
            opts[:langs] = argv[i + 1].to_s.split(",")
            i += 2
          when /\A--lang=(.+)\z/
            opts[:langs] = $1.split(",")
            i += 1
          when "--reply-to"
            opts[:reply_to] = argv[i + 1]
            i += 2
          when /\A--reply-to=(.+)\z/
            opts[:reply_to] = $1
            i += 1
          when "--json"
            opts[:json] = true
            i += 1
          else
            positional << a
            i += 1
          end
        end
        [opts, positional]
      end

      def read_text(positional, stdin:)
        if positional == ["-"]
          stdin.read.to_s.chomp
        else
          positional.join(" ")
        end
      end

      # Look up the parent's cid via com.atproto.repo.getRecord. AT Proto
      # requires both uri and cid on a reply ref; we only have the URI from
      # the CLI flag, so the lookup is necessary.
      def build_reply(uri, client:)
        return nil if uri.nil? || uri.empty?
        repo, collection, rkey = parse_at_uri(uri)
        record = client.get(
          "com.atproto.repo.getRecord",
          query: { "repo" => repo, "collection" => collection, "rkey" => rkey },
        )
        { uri: record.fetch("uri"), cid: record.fetch("cid") }
      end

      def parse_at_uri(uri)
        match = uri.match(%r{\Aat://([^/]+)/([^/]+)/(.+)\z})
        raise ArgumentError, "invalid at:// URI: #{uri.inspect}" unless match
        [match[1], match[2], match[3]]
      end
    end
  end
end
```

Update the earlier `reply = build_reply(opts[:reply_to])` line inside `call` to pass the client:

```ruby
        reply = build_reply(opts[:reply_to], client: client)
```

- [ ] **Step 3: Run, confirm the happy-path test passes**

```sh
bundle exec ruby -Ilib -Itest test/commands/test_post.rb
```

If the existing `Tempest::Post.create` does not accept a `langs:` keyword argument, drop the `langs:` kw and remove the line `record_extras[:langs] = opts[:langs]`. The current `Post.create` signature in `lib/tempest/post.rb` is what governs — read it first; add `langs:` support to `Post.create` if the test demands it. **If you add `langs:` to `Post.create`, also extend `test/test_post.rb` with a regression test that langs flows into `record["langs"]`.**

- [ ] **Step 4: Add `--json`, stdin, and validation tests**

Append to `test/commands/test_post.rb`:

```ruby
  def test_json_flag_outputs_uri_and_cid_object
    client = FakeXRPCClient.new(post_response: { "uri" => "at://x", "cid" => "bafy" })
    out = StringIO.new
    Tempest::Commands::Post.call(
      argv: ["--json", "hi"], session: fake_session, client: client,
      stdout: out, stderr: StringIO.new, stdin: StringIO.new,
    )
    payload = JSON.parse(out.string)
    assert_equal "at://x", payload["uri"]
    assert_equal "bafy",   payload["cid"]
  end

  def test_dash_reads_text_from_stdin
    client = FakeXRPCClient.new(post_response: { "uri" => "at://x", "cid" => "bafy" })
    Tempest::Commands::Post.call(
      argv: ["-"], session: fake_session, client: client,
      stdout: StringIO.new, stderr: StringIO.new, stdin: StringIO.new("piped body\n"),
    )
    _, _, body = client.calls.find { |c| c.first == :post }
    assert_equal "piped body", body[:record]["text"]
  end

  def test_empty_text_fails_with_exit_code_64
    client = FakeXRPCClient.new(post_response: { "uri" => "at://x" })
    err = StringIO.new
    status = Tempest::Commands::Post.call(
      argv: ["   "], session: fake_session, client: client,
      stdout: StringIO.new, stderr: err, stdin: StringIO.new,
    )
    assert_equal 64, status
    assert_empty client.calls
    assert_match(/empty/, err.string)
  end

  def test_text_over_300_graphemes_fails_locally
    client = FakeXRPCClient.new(post_response: { "uri" => "at://x" })
    err = StringIO.new
    status = Tempest::Commands::Post.call(
      argv: ["あ" * 301], session: fake_session, client: client,
      stdout: StringIO.new, stderr: err, stdin: StringIO.new,
    )
    assert_equal 64, status
    assert_empty client.calls
    assert_match(/300 graphemes/, err.string)
  end

  def test_reply_to_looks_up_parent_cid_then_creates_post_with_reply_ref
    client = FakeXRPCClient.new(
      post_response: { "uri" => "at://x", "cid" => "bafy" },
      get_responses: {
        "com.atproto.repo.getRecord" => {
          "uri" => "at://did:plc:bob/app.bsky.feed.post/par",
          "cid" => "bafyparent",
        },
      },
    )
    Tempest::Commands::Post.call(
      argv: ["--reply-to", "at://did:plc:bob/app.bsky.feed.post/par", "ack"],
      session: fake_session, client: client,
      stdout: StringIO.new, stderr: StringIO.new, stdin: StringIO.new,
    )
    get_call = client.calls.find { |c| c.first == :get }
    assert_equal "com.atproto.repo.getRecord", get_call[1]
    assert_equal "did:plc:bob", get_call[2]["repo"]
    assert_equal "app.bsky.feed.post", get_call[2]["collection"]
    assert_equal "par", get_call[2]["rkey"]

    _, _, body = client.calls.find { |c| c.first == :post }
    assert_equal "at://did:plc:bob/app.bsky.feed.post/par",
                 body[:record]["reply"]["parent"]["uri"]
    assert_equal "bafyparent", body[:record]["reply"]["parent"]["cid"]
  end
```

Run:

```sh
bundle exec ruby -Ilib -Itest test/commands/test_post.rb
```

Expected: 5 passes.

- [ ] **Step 5: Wire `post` into the CLI dispatcher**

Modify `lib/tempest/cli.rb`. Add `require_relative "commands/post"` and `require_relative "xrpc_client"`, then add a `when head == "post"` branch above `when head == "whoami"`:

```ruby
      when head == "post"
        session = Tempest::Commands::Base.authenticate(env: env, stderr: stderr)
        return 3 if session.nil?
        Tempest::Commands::Post.call(
          argv: argv.drop(1), session: session,
          client: Tempest::XRPCClient.new(session),
          stdout: stdout, stderr: stderr, stdin: stdin,
        )
```

- [ ] **Step 6: Run full suite**

```sh
bundle exec rake test
```

- [ ] **Step 7: Commit**

```sh
git add lib/tempest/commands/post.rb test/commands/test_post.rb lib/tempest/cli.rb
git commit
```

Use `/commit`. Subject: "Add tempest post subcommand".

---

## Task 9: `Tempest::DateFilter` — parse `--since`/`--until` and filter

**Files:**
- Create: `lib/tempest/date_filter.rb`
- Create: `test/test_date_filter.rb`

- [ ] **Step 1: Write failing tests for parsing**

Create `test/test_date_filter.rb`:

```ruby
require_relative "test_helper"
require "time"
require "tempest/date_filter"

class TestDateFilter < Minitest::Test
  def test_today_returns_local_midnight
    now = Time.local(2026, 5, 17, 14, 30, 0)
    parsed = Tempest::DateFilter.parse("today", now: now)
    assert_equal Time.local(2026, 5, 17, 0, 0, 0), parsed
  end

  def test_yesterday_returns_previous_local_midnight
    now = Time.local(2026, 5, 17, 14, 30, 0)
    assert_equal Time.local(2026, 5, 16, 0, 0, 0),
                 Tempest::DateFilter.parse("yesterday", now: now)
  end

  def test_Nd_returns_n_days_before_local_midnight
    now = Time.local(2026, 5, 17, 14, 30, 0)
    assert_equal Time.local(2026, 5, 10, 0, 0, 0),
                 Tempest::DateFilter.parse("7d", now: now)
  end

  def test_iso_date_only_returns_local_midnight
    assert_equal Time.local(2026, 5, 17, 0, 0, 0),
                 Tempest::DateFilter.parse("2026-05-17")
  end

  def test_iso_datetime_with_offset_returns_exact_time
    expected = Time.iso8601("2026-05-17T05:00:00Z")
    assert_equal expected, Tempest::DateFilter.parse("2026-05-17T05:00:00Z")
  end

  def test_unknown_format_raises_argument_error
    assert_raises(ArgumentError) { Tempest::DateFilter.parse("never") }
  end

  def test_filter_drops_posts_outside_since_until
    posts = [
      { created_at: "2026-05-15T09:00:00Z" },
      { created_at: "2026-05-17T01:00:00Z" },
      { created_at: "2026-05-18T01:00:00Z" },
    ]
    kept = Tempest::DateFilter.filter(
      posts,
      since: Time.iso8601("2026-05-17T00:00:00Z"),
      until_at: Time.iso8601("2026-05-18T00:00:00Z"),
    )
    assert_equal ["2026-05-17T01:00:00Z"], kept.map { |p| p[:created_at] }
  end
end
```

Run:

```sh
bundle exec ruby -Ilib -Itest test/test_date_filter.rb
```

- [ ] **Step 2: Implement `DateFilter`**

Create `lib/tempest/date_filter.rb`:

```ruby
require "time"
require_relative "../tempest"

module Tempest
  module DateFilter
    module_function

    def parse(raw, now: Time.now)
      case raw
      when "today"     then local_midnight(now)
      when "yesterday" then local_midnight(now) - 86_400
      when /\A(\d+)d\z/ then local_midnight(now) - (Regexp.last_match(1).to_i * 86_400)
      when /\A\d{4}-\d{2}-\d{2}\z/ then Time.local(*raw.split("-").map(&:to_i))
      else
        Time.iso8601(raw)
      end
    rescue ArgumentError => e
      raise ArgumentError, "invalid date: #{raw.inspect}"
    end

    def filter(posts, since: nil, until_at: nil)
      posts.select do |p|
        ts = p[:created_at] || p["created_at"]
        next false if ts.nil?
        t = Time.iso8601(ts)
        (since.nil? || t >= since) && (until_at.nil? || t < until_at)
      end
    end

    def local_midnight(now)
      l = now.respond_to?(:localtime) ? now.localtime : now
      Time.local(l.year, l.month, l.day, 0, 0, 0)
    end
  end
end
```

- [ ] **Step 3: Run, confirm all pass**

```sh
bundle exec ruby -Ilib -Itest test/test_date_filter.rb
```

- [ ] **Step 4: Commit**

```sh
git add lib/tempest/date_filter.rb test/test_date_filter.rb
git commit
```

Use `/commit`. Subject: "Add Tempest::DateFilter".

---

## Task 10: `Tempest::HandleLookup` — resolve handle/DID input to a DID

**Files:**
- Create: `lib/tempest/handle_lookup.rb`
- Create: `test/test_handle_lookup.rb`

- [ ] **Step 1: Write the failing test**

Create `test/test_handle_lookup.rb`:

```ruby
require_relative "test_helper"
require "tempest/handle_lookup"

class TestHandleLookup < Minitest::Test
  class FakeClient
    def initialize(response); @response = response; end
    def get(nsid, query: nil); @response; end
  end

  def test_did_input_is_returned_unchanged_without_api_call
    client = FakeClient.new(nil)
    def client.get(*); raise "should not call"; end
    assert_equal "did:plc:abc",
                 Tempest::HandleLookup.resolve("did:plc:abc", client: client)
  end

  def test_handle_input_calls_get_profile_and_returns_did
    client = FakeClient.new("did" => "did:plc:abc", "handle" => "alice.bsky.social")
    assert_equal "did:plc:abc",
                 Tempest::HandleLookup.resolve("alice.bsky.social", client: client)
  end

  def test_at_prefix_stripped
    client = FakeClient.new("did" => "did:plc:abc")
    assert_equal "did:plc:abc",
                 Tempest::HandleLookup.resolve("@alice.bsky.social", client: client)
  end

  def test_unknown_handle_raises_tempest_error
    client = FakeClient.new(nil)
    def client.get(*); raise Tempest::APIError.new(400, "InvalidRequest"); end
    assert_raises(Tempest::APIError) do
      Tempest::HandleLookup.resolve("ghost.bsky.social", client: client)
    end
  end
end
```

Run:

```sh
bundle exec ruby -Ilib -Itest test/test_handle_lookup.rb
```

- [ ] **Step 2: Implement `HandleLookup`**

Create `lib/tempest/handle_lookup.rb`:

```ruby
require_relative "../tempest"

module Tempest
  module HandleLookup
    module_function

    def resolve(actor, client:)
      input = actor.to_s.sub(/\A@/, "")
      return input if input.start_with?("did:")
      response = client.get("app.bsky.actor.getProfile", query: { "actor" => input })
      response.fetch("did")
    end
  end
end
```

- [ ] **Step 3: Run, confirm pass**

```sh
bundle exec ruby -Ilib -Itest test/test_handle_lookup.rb
```

- [ ] **Step 4: Commit**

```sh
git add lib/tempest/handle_lookup.rb test/test_handle_lookup.rb
git commit
```

Use `/commit`. Subject: "Add Tempest::HandleLookup".

---

## Task 11: `Tempest::Commands::Feed` — `me` and `timeline` (no pagination yet)

**Files:**
- Create: `lib/tempest/commands/feed.rb`
- Create: `test/commands/test_feed.rb`
- Modify: `lib/tempest/cli.rb`

- [ ] **Step 1: Write the failing tests**

Create `test/commands/test_feed.rb`:

```ruby
require_relative "../test_helper"
require "stringio"
require "json"
require "tempest/commands/feed"
require "tempest/session"

class TestCommandsFeed < Minitest::Test
  class FakeClient
    attr_reader :calls
    def initialize(responses); @responses = responses; @calls = []; end
    def get(nsid, query: nil); @calls << [nsid, query]; @responses.fetch(nsid); end
  end

  def fake_session
    Tempest::Session.new(
      access_jwt: "a", refresh_jwt: "r",
      did: "did:plc:abc", handle: "asonas.bsky.social",
      pds_host: "https://bsky.social",
    )
  end

  def author_feed_response(items:)
    {
      "feed" => items.map { |i| { "post" => i } },
      "cursor" => nil,
    }
  end

  def base_post(created_at:, text: "hi", uri: "at://x", cid: "bafy")
    {
      "uri" => uri, "cid" => cid,
      "author" => { "did" => "did:plc:abc", "handle" => "alice.bsky.social" },
      "record" => { "$type" => "app.bsky.feed.post", "text" => text, "createdAt" => created_at },
      "indexedAt" => created_at,
    }
  end

  def test_me_calls_getAuthorFeed_with_self_did_and_emits_ndjson_when_format_json
    client = FakeClient.new(
      "app.bsky.feed.getAuthorFeed" => author_feed_response(items: [
        base_post(created_at: "2026-05-17T03:00:00Z"),
        base_post(created_at: "2026-05-17T02:00:00Z", uri: "at://y", cid: "bafy2"),
      ]),
    )
    out = StringIO.new
    status = Tempest::Commands::Feed.call(
      argv: ["me", "--format=json"], session: fake_session, client: client,
      stdout: out, stderr: StringIO.new,
    )
    assert_equal 0, status
    nsid, query = client.calls.first
    assert_equal "app.bsky.feed.getAuthorFeed", nsid
    assert_equal "did:plc:abc", query["actor"]
    assert_equal 50, query["limit"]
    lines = out.string.lines
    assert_equal 2, lines.length
    assert_equal "at://x", JSON.parse(lines.first)["uri"]
  end

  def test_timeline_calls_getTimeline
    client = FakeClient.new(
      "app.bsky.feed.getTimeline" => author_feed_response(items: [
        base_post(created_at: "2026-05-17T01:00:00Z"),
      ]),
    )
    out = StringIO.new
    status = Tempest::Commands::Feed.call(
      argv: ["timeline", "--format=json"], session: fake_session, client: client,
      stdout: out, stderr: StringIO.new,
    )
    assert_equal 0, status
    assert_equal "app.bsky.feed.getTimeline", client.calls.first.first
  end

  def test_limit_over_100_returns_64
    client = FakeClient.new({})
    err = StringIO.new
    status = Tempest::Commands::Feed.call(
      argv: ["me", "--limit=101"], session: fake_session, client: client,
      stdout: StringIO.new, stderr: err,
    )
    assert_equal 64, status
    assert_match(/limit/, err.string)
  end

  def test_since_filters_out_older_posts
    client = FakeClient.new(
      "app.bsky.feed.getAuthorFeed" => author_feed_response(items: [
        base_post(created_at: "2026-05-17T05:00:00Z", uri: "at://new"),
        base_post(created_at: "2026-05-15T05:00:00Z", uri: "at://old"),
      ]),
    )
    out = StringIO.new
    Tempest::Commands::Feed.call(
      argv: ["me", "--format=json", "--since=2026-05-16T00:00:00Z"],
      session: fake_session, client: client,
      stdout: out, stderr: StringIO.new,
    )
    uris = out.string.lines.map { |l| JSON.parse(l)["uri"] }
    assert_equal ["at://new"], uris
  end

  def test_format_line_emits_one_line_per_post
    Tempest::REPL::Formatter.color = false
    client = FakeClient.new(
      "app.bsky.feed.getAuthorFeed" => author_feed_response(items: [
        base_post(created_at: "2026-05-17T01:00:00Z"),
      ]),
    )
    out = StringIO.new
    Tempest::Commands::Feed.call(
      argv: ["me", "--format=line"], session: fake_session, client: client,
      stdout: out, stderr: StringIO.new,
    )
    assert_match(/@alice.bsky.social: hi/, out.string)
  end
end
```

- [ ] **Step 2: Run, confirm LoadError**

```sh
bundle exec ruby -Ilib -Itest test/commands/test_feed.rb
```

- [ ] **Step 3: Implement `Tempest::Commands::Feed` (single-page only for now)**

Create `lib/tempest/commands/feed.rb`:

```ruby
require_relative "../commands"
require_relative "../commands/base"
require_relative "../post"
require_relative "../post_view"
require_relative "../date_filter"
require_relative "../handle_lookup"
require_relative "../output/json_writer"
require_relative "../output/line_writer"

module Tempest
  module Commands
    module Feed
      DEFAULT_LIMIT = 50
      MAX_LIMIT = 100

      module_function

      def call(argv:, session:, client:, stdout:, stderr:)
        subcommand, rest = argv.first, argv.drop(1)
        unless %w[me timeline author].include?(subcommand)
          stderr.puts "usage: tempest feed me|timeline|author <handle> [opts]"
          return 64
        end

        opts, positional = parse(rest, stderr: stderr)
        return 64 if opts.nil?

        return 64 if opts[:limit] > MAX_LIMIT && stderr.puts("error: --limit must be <= #{MAX_LIMIT}")

        nsid, query = endpoint_for(subcommand, session: session, positional: positional, client: client)
        return 64 if nsid.nil?
        query["limit"] = opts[:limit]
        response = client.get(nsid, query: query)

        items = Array(response["feed"]).map { |entry| entry["post"] }
        items = filter_by_date(items, opts)
        emit(items, format: opts[:format], stdout: stdout)
        0
      end

      def parse(argv, stderr:)
        opts = { limit: DEFAULT_LIMIT, since: nil, until_at: nil, format: nil }
        positional = []
        i = 0
        while i < argv.length
          case argv[i]
          when /\A--limit=(\d+)\z/ then opts[:limit] = Regexp.last_match(1).to_i; i += 1
          when "--limit"           then opts[:limit] = argv[i + 1].to_i; i += 2
          when /\A--since=(.+)\z/  then opts[:since] = Tempest::DateFilter.parse(Regexp.last_match(1)); i += 1
          when "--since"           then opts[:since] = Tempest::DateFilter.parse(argv[i + 1]); i += 2
          when /\A--until=(.+)\z/  then opts[:until_at] = Tempest::DateFilter.parse(Regexp.last_match(1)); i += 1
          when "--until"           then opts[:until_at] = Tempest::DateFilter.parse(argv[i + 1]); i += 2
          when /\A--format=(\S+)\z/
            sym = Regexp.last_match(1).to_sym
            unless %i[line json raw].include?(sym)
              stderr.puts "error: invalid --format: #{Regexp.last_match(1).inspect}"
              return [nil, nil]
            end
            opts[:format] = sym
            i += 1
          when "--no-color"
            Tempest::REPL::Formatter.color = false
            i += 1
          else
            positional << argv[i]; i += 1
          end
        end
        opts[:format] ||= (stderr.respond_to?(:tty?) ? nil : nil) # placeholder; real default decided in emit
        [opts, positional]
      rescue ArgumentError => e
        stderr.puts "error: #{e.message}"
        [nil, nil]
      end

      def endpoint_for(subcommand, session:, positional:, client:)
        case subcommand
        when "me"
          ["app.bsky.feed.getAuthorFeed", { "actor" => session.did }]
        when "timeline"
          ["app.bsky.feed.getTimeline", {}]
        when "author"
          actor = positional.first
          if actor.nil? || actor.empty?
            return [nil, nil]
          end
          did = Tempest::HandleLookup.resolve(actor, client: client)
          ["app.bsky.feed.getAuthorFeed", { "actor" => did }]
        end
      end

      def filter_by_date(items, opts)
        return items if opts[:since].nil? && opts[:until_at].nil?
        items.select do |it|
          ts = it.dig("record", "createdAt")
          t = Time.iso8601(ts)
          (opts[:since].nil? || t >= opts[:since]) && (opts[:until_at].nil? || t < opts[:until_at])
        end
      end

      def emit(items, format:, stdout:)
        format ||= stdout.respond_to?(:tty?) && stdout.tty? ? :line : :json
        case format
        when :json
          views = items.map { |i| Tempest::PostView.from_feed_view(i) }
          Tempest::Output::JsonWriter.new(stdout).write_posts(views)
        when :line
          posts = items.map { |i| Tempest::Post.from_feed_view(i) }
          Tempest::Output::LineWriter.new(stdout).write_posts(posts)
        when :raw
          Tempest::Output::JsonWriter.new(stdout).write_raw({ "feed" => items.map { |i| { "post" => i } } })
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run feed tests, fix until green**

```sh
bundle exec ruby -Ilib -Itest test/commands/test_feed.rb
```

Expected: 5 passes.

- [ ] **Step 5: Wire `feed` into the dispatcher, and add a top-level error rescue**

Modify `lib/tempest/cli.rb`. Add `require_relative "commands/feed"`, then add a `when head == "feed"` branch and wrap *all* non-TUI subcommand branches in a single rescue that uses `Base.exit_code_for`. The final shape of the `case` becomes:

```ruby
      head = argv.first
      case
      when head.nil?, head.start_with?("-"), head == "tui"
        rest = (head == "tui") ? argv.drop(1) : argv
        return Tempest::Commands::Tui.call(
          argv: rest, env: env, stdout: stdout, stderr: stderr, stdin: stdin,
          session_factory: session_factory, store: store,
        )
      when SUBCOMMANDS.include?(head)
        begin
          dispatch_subcommand(head, argv, env: env, stdout: stdout, stderr: stderr, stdin: stdin)
        rescue Tempest::Error, ArgumentError => e
          stderr.puts "error: #{e.message}"
          Tempest::Commands::Base.exit_code_for(e)
        end
      else
        stderr.puts "unknown command: #{head.inspect}"
        64
      end
    end

    def dispatch_subcommand(head, argv, env:, stdout:, stderr:, stdin:)
      session = Tempest::Commands::Base.authenticate(env: env, stderr: stderr)
      return 3 if session.nil?
      client = Tempest::XRPCClient.new(session)
      case head
      when "whoami"
        Tempest::Commands::Whoami.call(
          argv: argv.drop(1), session: session,
          stdout: stdout, stderr: stderr,
        )
      when "post"
        Tempest::Commands::Post.call(
          argv: argv.drop(1), session: session, client: client,
          stdout: stdout, stderr: stderr, stdin: stdin,
        )
      when "feed"
        Tempest::Commands::Feed.call(
          argv: argv.drop(1), session: session, client: client,
          stdout: stdout, stderr: stderr,
        )
      end
```

This consolidates the per-subcommand wiring that earlier tasks scattered across the dispatcher. **Update the previous `when head == "post"` and `when head == "whoami"` branches by removing them — they are now handled by `dispatch_subcommand`.** Add `require_relative "xrpc_client"` if it is not already required by `cli.rb`.

- [ ] **Step 5b: Add a test that APIError exits with code 4**

Append to `test/commands/test_feed.rb`:

```ruby
  def test_api_error_propagates_to_exit_code_4_via_dispatcher
    Dir.mktmpdir do |dir|
      path = File.join(dir, "session.json")
      seed = Tempest::Session.new(
        access_jwt: "a", refresh_jwt: "r",
        did: "did:plc:abc", handle: "asonas.bsky.social",
        pds_host: "https://bsky.social",
      )
      def seed.refresh!; self; end
      Tempest::SessionStore.new(path: path).save(seed, identifier: "asonas.bsky.social")

      # Stub the XRPC client so any call raises Tempest::APIError.
      xrpc = Object.new
      def xrpc.get(*); raise Tempest::APIError.new(503, "down"); end
      def xrpc.post(*); raise Tempest::APIError.new(503, "down"); end
      Tempest::XRPCClient.singleton_class.send(:alias_method, :__orig_new, :new)
      Tempest::XRPCClient.define_singleton_method(:new) { |*| xrpc }

      err = StringIO.new
      status = Tempest::CLI.run(
        argv: ["feed", "me", "--format=json"],
        env: { "TEMPEST_SESSION_PATH" => path },
        stdout: StringIO.new, stderr: err,
      )
      assert_equal 4, status
      assert_match(/down/, err.string)
    ensure
      if Tempest::XRPCClient.singleton_class.method_defined?(:__orig_new)
        Tempest::XRPCClient.define_singleton_method(:new) { |s| Tempest::XRPCClient.__orig_new(s) }
        Tempest::XRPCClient.singleton_class.send(:remove_method, :__orig_new)
      end
    end
  end
```

This is the dirtier of the three plausible stub strategies (singleton patch of `XRPCClient.new`) but keeps the dispatcher under test without a refactor to inject the client factory. If a cleaner refactor naturally emerges during implementation, replace this test rather than keep the singleton patch.

Run:

```sh
bundle exec ruby -Ilib -Itest test/commands/test_feed.rb
```

Expected: green (including the new exit-4 test).

- [ ] **Step 6: Full suite**

```sh
bundle exec rake test
```

- [ ] **Step 7: Commit**

```sh
git add lib/tempest/commands/feed.rb test/commands/test_feed.rb lib/tempest/cli.rb
git commit
```

Use `/commit`. Subject: "Add tempest feed me/timeline subcommands".

---

## Task 12: Feed `author` + pagination cap

**Files:**
- Modify: `lib/tempest/commands/feed.rb`
- Modify: `test/commands/test_feed.rb`

- [ ] **Step 1: Write the failing tests**

Append to `test/commands/test_feed.rb`:

```ruby
  def test_author_resolves_handle_via_get_profile_then_calls_getAuthorFeed
    client = FakeClient.new(
      "app.bsky.actor.getProfile" => { "did" => "did:plc:bob", "handle" => "bob.bsky.social" },
      "app.bsky.feed.getAuthorFeed" => author_feed_response(items: [
        base_post(created_at: "2026-05-17T01:00:00Z"),
      ]),
    )
    out = StringIO.new
    status = Tempest::Commands::Feed.call(
      argv: ["author", "bob.bsky.social", "--format=json"],
      session: fake_session, client: client,
      stdout: out, stderr: StringIO.new,
    )
    assert_equal 0, status
    nsids = client.calls.map(&:first)
    assert_equal ["app.bsky.actor.getProfile", "app.bsky.feed.getAuthorFeed"], nsids
    assert_equal "did:plc:bob", client.calls[1][1]["actor"]
  end

  def test_pagination_follows_cursor_when_since_not_yet_crossed
    page1_items = (1..50).map { |i| base_post(created_at: "2026-05-17T#{format('%02d', i % 24)}:00:00Z", uri: "at://a#{i}", cid: "c#{i}") }
    page2_items = [base_post(created_at: "2026-05-15T01:00:00Z", uri: "at://b1", cid: "cb1")]
    client_responses = {
      "app.bsky.feed.getAuthorFeed" => { "feed" => page1_items.map { |i| { "post" => i } }, "cursor" => "next-cursor" },
    }
    # We'll swap the response after the first call to simulate the second page.
    cursor_called = false
    client = Class.new do
      def initialize(p1, p2); @p1 = p1; @p2 = p2; @calls = []; end
      attr_reader :calls
      def get(nsid, query: nil)
        @calls << [nsid, query]
        if query && query["cursor"]
          @p2
        else
          @p1
        end
      end
    end.new(
      { "feed" => page1_items.map { |i| { "post" => i } }, "cursor" => "next-cursor" },
      { "feed" => page2_items.map { |i| { "post" => i } }, "cursor" => nil },
    )

    out = StringIO.new
    Tempest::Commands::Feed.call(
      argv: ["me", "--format=json", "--since=2026-05-14T00:00:00Z", "--limit=50"],
      session: fake_session, client: client,
      stdout: out, stderr: StringIO.new,
    )
    assert_equal 2, client.calls.length
    assert_equal "next-cursor", client.calls[1][1]["cursor"]
  end

  def test_pagination_hard_caps_at_5_pages_and_warns
    page = { "feed" => [{ "post" => base_post(created_at: "2026-05-17T01:00:00Z") }], "cursor" => "more" }
    client = Class.new do
      def initialize(p); @p = p; @calls = []; end
      attr_reader :calls
      def get(_, query: nil); @calls << query; @p; end
    end.new(page)

    err = StringIO.new
    status = Tempest::Commands::Feed.call(
      argv: ["me", "--format=json", "--since=2020-01-01T00:00:00Z"],
      session: fake_session, client: client,
      stdout: StringIO.new, stderr: err,
    )
    assert_equal 0, status
    assert_equal 5, client.calls.length
    assert_match(/truncated/, err.string)
  end
```

- [ ] **Step 2: Add pagination loop to `Feed.call`**

Replace the body of `Feed.call` after argument parsing with:

```ruby
        nsid, base_query = endpoint_for(subcommand, session: session, positional: positional, client: client)
        if nsid.nil?
          stderr.puts "error: feed author requires a handle or DID"
          return 64
        end
        if opts[:limit] > MAX_LIMIT
          stderr.puts "error: --limit must be <= #{MAX_LIMIT}"
          return 64
        end

        items = []
        cursor = nil
        max_pages = 5
        pages = 0
        loop do
          query = base_query.merge("limit" => opts[:limit])
          query["cursor"] = cursor if cursor
          response = client.get(nsid, query: query)
          page_items = Array(response["feed"]).map { |entry| entry["post"] }
          items.concat(page_items)
          pages += 1
          cursor = response["cursor"]
          break if cursor.nil? || cursor.empty?
          break if pages >= max_pages
          break unless opts[:since]
          oldest = page_items.last && page_items.last.dig("record", "createdAt")
          break if oldest.nil?
          break if Time.iso8601(oldest) < opts[:since]
        end
        stderr.puts "warning: pagination cap of #{max_pages} pages reached; result truncated" if pages >= max_pages && !cursor.nil? && !cursor.empty?

        items = filter_by_date(items, opts)
        emit(items, format: opts[:format], stdout: stdout)
        0
```

- [ ] **Step 3: Run feed tests, then full suite**

```sh
bundle exec ruby -Ilib -Itest test/commands/test_feed.rb
bundle exec rake test
```

- [ ] **Step 4: Commit**

```sh
git add lib/tempest/commands/feed.rb test/commands/test_feed.rb
git commit
```

Use `/commit`. Subject: "Support feed author and paginate by --since".

---

## Task 13: Help text, README, and end-to-end smoke

**Files:**
- Modify: `lib/tempest/commands/tui.rb` (only `help_text`)
- Modify: `README.md`

- [ ] **Step 1: Extend the help output**

In `lib/tempest/commands/tui.rb`, modify the `help_text` method (the one lifted in Task 1). Replace the top section so the first lines mention subcommands:

```ruby
      def help_text
        <<~HELP
          Usage: tempest [subcommand] [options]

          Subcommands:
            tui                 (default) launch the interactive TUI
            post <text|->       create a post (use `-` to read text from stdin)
            feed me|timeline|author <handle> [opts]
                                read posts; --format=line|json|raw, --since, --until, --limit
            whoami              print the signed-in identity

          TUI options:
            -h, --help          Show this help
            -v, --version       Show version
            --no-stream         Disable the auto-started Jetstream feed
            --feed=MODE         Choose what the live feed subscribes to (home|self)

          [...existing environment block, unchanged...]
        HELP
      end
```

Preserve everything below the existing `Environment` heading exactly as it is.

- [ ] **Step 2: Add a CLI usage section to README.md**

Append a section under existing content (or before the "Architecture" reference if one exists):

````markdown
## Non-interactive CLI

Once you have signed in once with `tempest tui`, you can call the CLI from scripts and tools:

```sh
tempest whoami --json
tempest post "今日もよろしくお願いします"
tempest feed me --since today --format json | jq '.text'
tempest feed author asonas.bsky.social --limit 20
```

`--format=json` emits newline-delimited JSON; one post per line. The schema is documented in `lib/tempest/post_view.rb`.

`--format=raw` emits the underlying `getAuthorFeed`/`getTimeline` response pretty-printed; do not rely on its shape.

`--format=line` (default when stdout is a TTY) prints the same single-line representation as the TUI scroll buffer.

The non-interactive subcommands require a cached session on disk. If your cache is missing or expired, run `tempest tui` once to refresh it.
````

- [ ] **Step 3: Run the full suite once more**

```sh
bundle exec rake test
```

- [ ] **Step 4: Manual smoke (optional but recommended)**

Verify each subcommand against the live API using your signed-in cache:

```sh
bundle exec ruby -Ilib exe/tempest whoami
bundle exec ruby -Ilib exe/tempest whoami --json
bundle exec ruby -Ilib exe/tempest feed me --since today --format json | head
bundle exec ruby -Ilib exe/tempest feed author asonas.bsky.social --limit 5
```

Document anything surprising in a follow-up issue rather than fixing inline — the spec lists explicit non-goals.

- [ ] **Step 5: Commit**

```sh
git add lib/tempest/commands/tui.rb README.md
git commit
```

Use `/commit`. Subject: "Document CLI subcommands in help and README".

---

## Done criteria

- `bundle exec rake test` is green.
- `tempest`, `tempest tui`, `tempest --version`, `tempest --help` all work as before.
- `tempest whoami`, `tempest whoami --did`, `tempest whoami --handle`, `tempest whoami --json` print as specified.
- `tempest post "hi"`, `tempest post -`, `tempest post --reply-to <uri> "..."`, `tempest post --json "..."` post successfully against a live test account.
- `tempest feed me|timeline|author <h>` with `--format=json|line|raw`, `--since`, `--until`, `--limit` all behave as specified, including the pagination warning.
- README and `tempest --help` describe the new surface.
