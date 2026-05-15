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
| `:help`          | Show in-app help                                 |
| `:quit`          | Exit (`Ctrl-D` works too)                        |

Anything else you type is sent as a new post.

### CLI options

| Option          | Description                                |
|-----------------|--------------------------------------------|
| `-h`, `--help`  | Show CLI help                              |
| `-v`, `--version` | Show version                             |
| `--no-stream`   | Disable the auto-started Jetstream feed    |

### Environment variables

| Variable                    | Purpose                                                                 |
|-----------------------------|-------------------------------------------------------------------------|
| `TEMPEST_IDENTIFIER`        | Your handle, e.g. `asonas.bsky.social`                                  |
| `TEMPEST_APP_PASSWORD`      | An app password generated in Bluesky settings                           |
| `TEMPEST_PDS_HOST`          | Override PDS host (default `https://bsky.social`)                       |
| `TEMPEST_AUTH_FACTOR_TOKEN` | Pre-supply an email sign-in code; usually unnecessary                   |
| `TEMPEST_NO_STREAM`         | Set to `1` to disable the auto-started Jetstream feed                   |
| `TEMPEST_SESSION_PATH`      | Override the session cache path                                         |
| `NO_COLOR`                  | Disable ANSI colors when set to any non-empty value                     |

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
