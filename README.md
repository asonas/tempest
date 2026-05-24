# tempest

`tempest` is a REPL-style terminal client for [Bluesky](https://bsky.app/), inspired by the classic Twitter client [earthquake](https://github.com/jugyo/earthquake). It speaks the AT Protocol directly: XRPC for reads and writes, and Jetstream for the live timeline feed.

This is an unofficial, third-party client. It is not affiliated with or endorsed by Bluesky Social, PBC.

## Features

- Earthquake-style split layout: a scrolling timeline on top, a prompt at the bottom.
- Auto-started [Jetstream](https://github.com/bluesky-social/jetstream) feed so new posts appear as they happen.
- Home timeline fetch on demand.
- Post by simply typing — anything that is not a `:command` is sent as a new post.
- Session cache with automatic token refresh; the email sign-in code is requested only once.
- DID-to-handle resolution with in-memory caching.

## Requirements

- Ruby 4.0 or later
- A Bluesky account and an [app password](https://bsky.app/settings/app-passwords)
- [libvips](https://www.libvips.org/) for avatar thumbnail rendering (`brew install vips` on macOS, `apt install libvips42` on Debian/Ubuntu)

## Installation

Once published to RubyGems:

```sh
gem install tempest-rb
```

The installed executable is `tempest` (the gem name on RubyGems is `tempest-rb` because `tempest` was already taken).

Or from a local checkout:

```sh
git clone https://github.com/asonas/tempest.git
cd tempest
bundle install
bundle exec exe/tempest
```

## Upgrading

The gem on RubyGems is `tempest-rb`, while the executable it ships is `tempest`.

If you installed it with `gem install`:

```sh
gem update tempest-rb
```

To check the currently installed version:

```sh
tempest --version
```

If you use Bundler in your own project, bump the requirement in your `Gemfile` and run `bundle update tempest-rb` instead.

## Usage

Set your credentials in the environment and run `tempest`:

```sh
export TEMPEST_IDENTIFIER="your-handle.bsky.social"
export TEMPEST_APP_PASSWORD="xxxx-xxxx-xxxx-xxxx"
tempest
```

The first sign-in may prompt for the email code Bluesky sends as a second factor. After a successful sign-in the session is cached at `$XDG_CONFIG_HOME/tempest/accounts/<did>/session.json` (defaults to `~/.config/tempest/accounts/<did>/session.json`), and subsequent launches refresh tokens silently.

### Multiple accounts

`tempest` keeps each account's session, Jetstream cursor, and timeline snapshot under `~/.config/tempest/accounts/<did>/`. A top-level `accounts.json` index records which account is the default and which alternate accounts are known to the client.

To add a second account, run `tempest login` and supply the handle and app password interactively:

```sh
tempest login
# identifier: tempest-dev.bsky.social
# app password: ****
# signing in...
# logged in as @tempest-dev.bsky.social (did:plc:...)
```

List the accounts known to `tempest`. The default is marked with `*`.

```sh
tempest accounts list
# * @asonas.bsky.social (did:plc:abcdef) https://bsky.social  added 2026-05-18
#   @tempest-dev.bsky.social (did:plc:ghijkl) https://bsky.social  added 2026-05-18
```

Switch the default account:

```sh
tempest accounts set-default tempest-dev.bsky.social
```

Pick the account just for one invocation with `--user`. The flag accepts a handle or a DID and works on every subcommand:

```sh
tempest --user tempest-dev.bsky.social
tempest --user did:plc:ghijkl feed me --format=json
tempest post "from the dev account" --user tempest-dev.bsky.social
```

For bots and scripts where stability matters, pass the DID directly. Handles can be changed by their owner; DIDs do not.

If you have been using a single-account installation of an earlier `tempest` release, the legacy `~/.config/tempest/session.json` is migrated to the new per-DID layout on the next start. The migration is one-shot, idempotent, and prints a one-line notice to stderr when it runs.

### REPL commands

| Command          | Description                                      |
|------------------|--------------------------------------------------|
| `:timeline`      | Fetch and print the home timeline                |
| `:stream on/off` | Toggle the Jetstream live feed                   |
| `:compose`       | Open your editor to compose a multi-line post    |
| `:open $LX`      | Open the URL with id `$LX` in the browser        |
| `:help`          | Show in-app help                                 |
| `:quit`          | Exit (`Ctrl-D` works too)                        |
| `$XX <text>`     | Reply to the post with id `$XX`                  |

Anything else you type is sent as a new post.

`:compose` hands the terminal over to your editor so you can write a longer post without fighting the single-line prompt. The editor is picked from `$VISUAL`, then `$EDITOR`, and falls back to `vi`. Lines that start with `#` are treated as comments and stripped; save with an empty body to cancel. Remember to `export` the variable in your shell rc (`export EDITOR=nvim`) — without `export`, the value is not inherited by child processes and the fallback to `vi` kicks in.

Each post in the timeline is prefixed with a short `$XX` id, and URLs found inside posts get their own `$LX` ids. Use those ids with `$XX <text>` to reply or `:open $LX` to open a link. Like and repost events show the subject post's `$XX` id in trailing brackets (for example `liked @bob's post [$AA]`) whenever the original post is still in the session registry, so you can reply to it directly.

### CLI options

| Option            | Description                                                  |
|-------------------|--------------------------------------------------------------|
| `-h`, `--help`    | Show CLI help                                                |
| `-v`, `--version` | Show version                                                 |
| `--user <h\|did>` | Pick which account to act as (default: the entry marked default in `accounts.json`). Works on every subcommand except `login` / `accounts` |
| `--no-stream`     | Disable the auto-started Jetstream feed                      |
| `--feed=MODE`     | `home` (default, your follows + your own posts) or `self` (only your own posts) |

### Non-interactive CLI

Once you have signed in once with `tempest tui` or `tempest login`, you can call the CLI from scripts and tools:

```sh
tempest whoami --json
tempest post "今日もよろしくお願いします"
tempest feed me --since today --format json | jq '.text'
tempest feed author asonas.bsky.social --limit 20
tempest --user tempest-dev.bsky.social post "from the dev account"
```

`--format=json` emits newline-delimited JSON; one post per line. The schema is documented in `lib/tempest/post_view.rb`.

`--format=raw` emits the underlying `getAuthorFeed`/`getTimeline` response pretty-printed; do not rely on its shape.

`--format=line` (default when stdout is a TTY) prints the same single-line representation as the TUI scroll buffer.

The non-interactive subcommands require a cached session on disk for the resolved account. If a session is missing or expired, run `tempest login` (or `tempest tui` for the default account) to refresh it.

### Environment variables

| Variable                    | Purpose                                                                 |
|-----------------------------|-------------------------------------------------------------------------|
| `TEMPEST_IDENTIFIER`        | Your handle, e.g. `asonas.bsky.social`. Only consulted on first run, when `accounts.json` is absent. Use `tempest login` to add accounts thereafter. |
| `TEMPEST_APP_PASSWORD`      | Same precondition as `TEMPEST_IDENTIFIER`                               |
| `TEMPEST_AUTH_FACTOR_TOKEN` | Pre-supply an email sign-in code; usually unnecessary                   |
| `TEMPEST_NO_STREAM`         | Set to `1` to disable the auto-started Jetstream feed                   |
| `TEMPEST_FEED`              | `home` (default) or `self`; equivalent to `--feed`                      |
| `TEMPEST_OPEN_CMD`          | Command used by `:open $LX` to open URLs (default `open`); URL is passed as the single argument |
| `TEMPEST_DEBUG_LOG`         | Path to a debug log file (unset by default; see Diagnostics)            |
| `TEMPEST_DEBUG_LOG_LEVEL`   | `DEBUG`, `INFO` (default), or `WARN`                                    |
| `TEMPEST_WATCHDOG_THRESHOLD`| Seconds without a Jetstream event before a forced reconnect (default 90) |
| `TEMPEST_WATCHDOG_INTERVAL` | Seconds between watchdog checks (default 30)                            |
| `NO_COLOR`                  | Disable ANSI colors when set to any non-empty value                     |

The `TEMPEST_SESSION_PATH`, `TEMPEST_CURSOR_PATH`, `TEMPEST_TIMELINE_PATH`, and `TEMPEST_PDS_HOST` variables are no longer honored after 0.3.0. The legacy `TEMPEST_SESSION_PATH` is read once at migration time so that an existing override still maps cleanly into the new per-DID layout.

## Diagnostics

Set `TEMPEST_DEBUG_LOG` to a writable path and `tempest` will append timestamped notes about every Jetstream state transition to that file (rotated daily). When the variable is unset no file is created and the runtime behaves exactly as before. Example: `TEMPEST_DEBUG_LOG=~/tempest-debug.log tempest`.

A built-in watchdog runs alongside the Jetstream consumer regardless of logging: if no event arrives within `TEMPEST_WATCHDOG_THRESHOLD` seconds (default 90), it forces the consumer to reconnect. This protects the live feed against stalled sockets that the kernel still believes are alive, the typical failure mode after macOS sleep and wake.

To inspect the log, grep by component tag: `grep '\[stream\]' ~/tempest-debug.log` shows connect, reconnect, gap, and disconnect events, while `grep '\[watchdog\]' ~/tempest-debug.log` shows forced reconnects.

## Development

```sh
bundle install
bundle exec rake test
```

The test suite uses Ruby's bundled `minitest`-style harness under `test/`.

## License

Released under the [MIT License](LICENSE). See `LICENSE` for the full text.

## Acknowledgements

- The [AT Protocol](https://atproto.com/) and [Bluesky](https://bsky.app/) teams for the open protocol and the Jetstream firehose.
- [earthquake](https://github.com/jugyo/earthquake) for the original REPL-style terminal client design.
