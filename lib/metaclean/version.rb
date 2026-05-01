# frozen_string_literal: true

# ───────────────────────────────────────────────────────────────────────────
# Single source of truth for the program's version.
# Both the gemspec and `metaclean --version` read from here, so we only have
# one place to bump.
# ───────────────────────────────────────────────────────────────────────────

module Metaclean
  VERSION = '1.0.2'
end
