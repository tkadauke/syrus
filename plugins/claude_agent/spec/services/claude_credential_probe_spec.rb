require "rails_helper"

RSpec.describe ClaudeCredentialProbe do
  let(:user) do
    Factories.user(
      github_token: "ghp_secret",
      claude_oauth_token: "oat-secret"
    )
  end

  def runner_result(exit_status: 0, timed_out: false, silent_timed_out: false)
    ProcessRunner::Result.new(
      exit_status: exit_status,
      timed_out: timed_out,
      stopped: false,
      silent_timed_out: silent_timed_out,
      operator_killed: false,
      aliveness_failed: false,
      duration_s: 0.1,
      spawned_process_id: nil
    )
  end

  it "is registered as the Claude credential probe" do
    expect(CredentialProbe.probe_handler_for("claude_oauth_token")).to eq(described_class)
  end

  it "reports a missing Claude token without spawning a process" do
    user.update!(claude_oauth_token: nil)
    expect(ProcessRunner).not_to receive(:new)

    result = CredentialProbe.call(user: user, credential: "claude_oauth_token")

    expect(result.ok).to be false
    expect(result.message).to eq("Claude OAuth token is not configured.")
  end

  it "runs a cheap Claude CLI probe with the stored OAuth token" do
    captured = nil
    allow(ProcessRunner).to receive(:new) do |**kwargs|
      captured = kwargs
      instance_double(ProcessRunner, run: runner_result)
    end

    result = CredentialProbe.call(user: user, credential: "claude_oauth_token")

    expect(result.ok).to be true
    expect(result.message).to eq("Claude OAuth token is valid.")
    expect(captured[:env]).to include("CLAUDE_CODE_OAUTH_TOKEN" => "oat-secret")
    expect(captured[:command]).to include("claude", "--print", "--max-turns", "1")
    expect(captured[:timeout]).to eq(30)
  end

  describe ".claude_cli_ready" do
    it "probes ambient claude --print without injecting a token" do
      captured = nil
      allow(ProcessRunner).to receive(:new) do |**kwargs|
        captured = kwargs
        instance_double(ProcessRunner, run: runner_result)
      end

      result = CredentialProbe.claude_cli_ready(user: user)

      expect(result.ok).to be true
      expect(result.message).to include("Claude already works on this machine")
      expect(captured[:env]).not_to have_key("CLAUDE_CODE_OAUTH_TOKEN")
      expect(captured[:command]).to include("claude", "--print")
    end

    it "reports not-authenticated when the ambient probe fails" do
      allow(ProcessRunner).to receive(:new) do
        instance_double(ProcessRunner, run: runner_result(exit_status: 1))
      end

      result = CredentialProbe.claude_cli_ready(user: user)

      expect(result.ok).to be false
      expect(result.message).to include("not authenticated on this machine")
    end
  end

  it "redacts failed CLI output" do
    allow(ProcessRunner).to receive(:new) do |**kwargs|
      kwargs[:on_output_chunk].call("authentication failed for oat-secret\n")
      instance_double(ProcessRunner, run: runner_result(exit_status: 1))
    end

    result = CredentialProbe.call(user: user, credential: "claude_oauth_token")

    expect(result.ok).to be false
    expect(result.message).to include("authentication failed for [redacted]")
    expect(result.message).not_to include("oat-secret")
  end
end
