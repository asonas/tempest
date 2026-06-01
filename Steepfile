# frozen_string_literal: true

# Type checking is being introduced incrementally. Only files that already have
# a matching signature under `sig/` are listed in `check` here; add a file to
# this target as soon as its `.rbs` is written so `steep check` stays green.
target :lib do
  signature "sig"

  check "lib/tempest/facet.rb"
  check "lib/tempest/date_filter.rb"
  check "lib/tempest/id_var.rb"
  check "lib/tempest/deprecated_envs.rb"
  check "lib/tempest/account_paths.rb"
  check "lib/tempest/timeline.rb"
  # NOTE: lib/tempest/post.rb is intentionally not checked yet. Its methods and
  # constants live inside a `Data.define(...) do ... end` block, which Steep does
  # not recognize as the class body. Checking it first requires refactoring that
  # block into a reopened `class Post` and hardening String-slice/encoding
  # nil-safety. The signature in sig/tempest/post.rbs is declared so that
  # consumers (e.g. timeline.rb) type-check against Post in the meantime.
end
