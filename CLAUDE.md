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

