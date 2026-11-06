require "rails_helper"

# Permission checks answer "should this agent be allowed to do this?" The
# harness has no intent to evaluate: it composes its own argv from values it
# chose and runs it as deterministic plumbing. Gating it with an agent policy
# blocked the harness with itself, once per kind, as separate outages.
#
# Every process kind must therefore be declared on one side of that line, so
# a new kind cannot quietly inherit either posture.
RSpec.describe "execution kind authorship" do
  # Harness plumbing: argv composed by Syrus, no model or operator input.
  HARNESS_KINDS = %w[
    grader git prepare format generate builder dependency_audit chat_prepare
    preview chat_stt deploy runtime_probe runtime_session media archive
    filesystem diagnostic
  ].freeze

  it "classifies every known process kind" do
    declared = Permissions::ExecutionGate::GATED_KINDS + HARNESS_KINDS

    expect(declared).to match_array(SpawnedProcess::KINDS),
      "every SpawnedProcess::KIND must be declared either gated or harness; " \
      "undeclared: #{(SpawnedProcess::KINDS - declared).inspect}, " \
      "unknown: #{(declared - SpawnedProcess::KINDS).inspect}"
  end

  it "declares no kind as both" do
    expect(Permissions::ExecutionGate::GATED_KINDS & HARNESS_KINDS).to be_empty
  end

  # The agent process is harness-composed argv, but it is the process that
  # runs the model, and the FailClosedHost ceiling that forces it into a
  # container is applied through the gate.
  it "keeps the agent process gated" do
    expect(Permissions::ExecutionGate::GATED_KINDS).to include("agent")
  end

  it "keeps operator-written shell commands gated" do
    expect(Permissions::ExecutionGate::GATED_KINDS).to include("chat_shell_command")
  end

  it "does not gate the git plumbing that publishes branches and checks out snapshots" do
    expect(HARNESS_KINDS).to include("git")
  end
end
