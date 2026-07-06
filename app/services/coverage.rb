# Require Ruby's stdlib Coverage before Zeitwerk creates this namespace so that
# bootsnap's `Coverage.running?` guard remains valid (bootsnap checks this to
# avoid recompiling files while coverage is active). Without this, Zeitwerk's
# implicit namespace module would shadow the C-extension and raise NoMethodError.
require "coverage"

module Coverage
end
