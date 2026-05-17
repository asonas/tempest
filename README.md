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

## Usage

Set your credentials in the environment and run `tempest`:

```sh
export TEMPEST_IDENTIFIER="your-handle.bsky.social"
export TEMPEST_APP_PASSWORD="xxxx-xxxx-xxxx-xxxx"
tempest
```

The first sign-in may prompt for the email code Bluesky sends as a second factor. After a successful sign-in the session is cached at `$XDG_CONFIG_HOME/tempest/session.json` (defaults to `~/.config/tempest/session.json`), and subsequent launches refresh tokens silently.

### REPL commands

| Command          | Description                                      |
|------------------|--------------------------------------------------|
| `:timeline`      | Fetch and print the home timeline                |
| `:stream on/off` | Toggle the Jetstream live feed                   |
| `:open $LX`      | Open the URL with id `$LX` in the browser        |
| `:help`          | Show in-app help                                 |
| `:quit`          | Exit (`Ctrl-D` works too)                        |
| `$XX <text>`     | Reply to the post with id `$XX`                  |

Anything else you type is sent as a new post.

Each post in the timeline is prefixed with a short `$XX` id, and URLs found inside posts get their own `$LX` ids. Use those ids with `$XX <text>` to reply or `:open $LX` to open a link. Like and repost events show the subject post's `$XX` id in trailing brackets (for example `liked @bob's post [$AA]`) whenever the original post is still in the session registry, so you can reply to it directly.

### CLI options

| Option            | Description                                                  |
|-------------------|--------------------------------------------------------------|
| `-h`, `--help`    | Show CLI help                                                |
| `-v`, `--version` | Show version                                                 |
| `--no-stream`     | Disable the auto-started Jetstream feed                      |
| `--feed=MODE`     | `home` (default, your follows + your own posts) or `self` (only your own posts) |

### Non-interactive CLI

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

### Environment variables

| Variable                    | Purpose                                                                 |
|-----------------------------|-------------------------------------------------------------------------|
| `TEMPEST_IDENTIFIER`        | Your handle, e.g. `asonas.bsky.social`                                  |
| `TEMPEST_APP_PASSWORD`      | An app password generated in Bluesky settings                           |
| `TEMPEST_PDS_HOST`          | Override PDS host (default `https://bsky.social`)                       |
| `TEMPEST_AUTH_FACTOR_TOKEN` | Pre-supply an email sign-in code; usually unnecessary                   |
| `TEMPEST_NO_STREAM`         | Set to `1` to disable the auto-started Jetstream feed                   |
| `TEMPEST_FEED`              | `home` (default) or `self`; equivalent to `--feed`                      |
| `TEMPEST_OPEN_CMD`          | Command used by `:open $LX` to open URLs (default `open`); URL is passed as the single argument |
| `TEMPEST_SESSION_PATH`      | Override the session cache path                                         |
| `TEMPEST_CURSOR_PATH`       | Override the Jetstream cursor cache path                                |
| `TEMPEST_TIMELINE_PATH`     | Override the timeline snapshot cache path                               |
| `TEMPEST_DEBUG_LOG`         | Path to a debug log file (unset by default; see Diagnostics)            |
| `TEMPEST_DEBUG_LOG_LEVEL`   | `DEBUG`, `INFO` (default), or `WARN`                                    |
| `TEMPEST_WATCHDOG_THRESHOLD`| Seconds without a Jetstream event before a forced reconnect (default 90) |
| `TEMPEST_WATCHDOG_INTERVAL` | Seconds between watchdog checks (default 30)                            |
| `NO_COLOR`                  | Disable ANSI colors when set to any non-empty value                     |

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
