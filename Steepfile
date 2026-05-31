# frozen_string_literal: true

# Type checking is being introduced incrementally. Only files that already have
# a matching signature under `sig/` are listed in `check` here; add a file to
# this target as soon as its `.rbs` is written so `steep check` stays green.
target :lib do
  signature "sig"

  check "lib/tempest/facet.rb"
end
