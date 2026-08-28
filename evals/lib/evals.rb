# Manual eval harness for agent-prompt/skill compliance. Not part of the
# Rails autoload paths (evals/ is a top-level sibling of app/ and lib/), so
# it's loaded explicitly via evals/run.rb — see evals/README.md.
require "yaml"
require "json"
require "fileutils"
require "tmpdir"
require "time"

require_relative "evals/scenario"
require_relative "evals/setup_context"
require_relative "evals/fixture_workspace"
require_relative "evals/transcript_renderer"
require_relative "evals/agent_run"
require_relative "evals/verifier"
require_relative "evals/scenario_result"
require_relative "evals/result_store"
require_relative "evals/cli"

module Evals
end
