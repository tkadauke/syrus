require "rails_helper"

RSpec.describe ProviderAvailabilityPause do
  let(:user) { Factories.user(claude_oauth_token: "sk-ant-oat01-abc") }
  let(:job) { Factories.job(user: user, repository: Factories.repository(user: user)) }
  let(:workflow) { job.latest_workflow.tap { |w| w.update!(agent_provider: "claude") } }

  describe "#call for the claude provider" do
    it "refreshes a stale Claude usage probe before computing availability" do
      workflow # force Job/Workflow creation (which itself opportunistically probes) before stubbing
      allow(ClaudeUsageProbe).to receive(:stale?).with(user, now: anything).and_return(true)
      allow(ClaudeUsageProbe).to receive(:refresh_for).with(user: user)

      described_class.call(workflow: workflow)

      expect(ClaudeUsageProbe).to have_received(:refresh_for).with(user: user).once
    end

    it "does not refresh when the last Claude probe evidence is still fresh" do
      allow(ClaudeUsageProbe).to receive(:stale?).with(user, now: anything).and_return(false)
      allow(ClaudeUsageProbe).to receive(:refresh_for)

      described_class.call(workflow: workflow)

      expect(ClaudeUsageProbe).not_to have_received(:refresh_for)
    end

    it "does not probe when the user has no Claude OAuth token configured" do
      user.update!(claude_oauth_token: nil)
      allow(ClaudeUsageProbe).to receive(:refresh_for)

      described_class.call(workflow: workflow)

      expect(ClaudeUsageProbe).not_to have_received(:refresh_for)
    end

    it "never touches CodexUsageProbe while gating a Claude workflow" do
      allow(ClaudeUsageProbe).to receive(:stale?).and_return(false)
      allow(CodexUsageProbe).to receive(:refresh_for)

      described_class.call(workflow: workflow)

      expect(CodexUsageProbe).not_to have_received(:refresh_for)
    end

    it "pauses when provider availability reports a rate limit" do
      retry_at = 15.minutes.from_now
      allow(App::ProviderAvailability).to receive(:for_user).with(user, "claude", now: anything).and_return(
        {
          state: "rate_limited",
          open: true,
          retry_after: retry_at.iso8601,
          message: "Claude is rate-limited.",
          evidence: { current: { observed_at: 1.minute.ago.iso8601 } }
        }
      )

      decision = described_class.call(workflow: workflow)

      expect(decision).to be_pause
      expect(decision.reason).to eq("provider_rate_limited")
      expect(decision.retry_at.to_i).to eq(retry_at.to_i)
      expect(decision.details).to include(
        "provider" => "claude",
        "availability_state" => "rate_limited"
      )
    end

    it "selects the first configured failover provider that is available enough" do
      user.update!(
        codex_auth_mode: "api_key",
        codex_api_key: "sk-test",
        agent_provider_failover_policy: {
          "enabled" => true,
          "providers" => %w[codex],
          "causes" => %w[provider_transient],
          "override_explicit_pins" => false
        }
      )
      observed_at = 1.minute.ago
      failover = ProviderFailoverSelector::Decision.new(
        selected_provider: "codex",
        original_provider: "claude",
        reason: "provider_unavailable",
        availability: {
          state: "open",
          open: true,
          retry_after: 10.minutes.from_now.iso8601,
          evidence: { current: { observed_at: observed_at.iso8601 } }
        },
        candidate_availability: nil,
        decided_at: Time.current,
        manual_override: false
      )
      allow(App::ProviderAvailability).to receive(:for_user).with(user, "claude", now: anything).and_return(
        {
          state: "open",
          open: true,
          retry_after: 10.minutes.from_now.iso8601,
          evidence: { current: { observed_at: observed_at.iso8601 } }
        }
      )
      allow(App::ProviderAvailability).to receive(:for_user).with(user, "codex", now: anything).and_return(nil)
      allow(ProviderFailoverSelector).to receive(:call)
        .with(workflow: workflow, reason: "provider_unavailable", availability: kind_of(Hash), now: anything)
        .and_return(failover)

      decision = described_class.call(workflow: workflow)

      expect(decision).not_to be_pause
      expect(decision).to be_failover
      expect(decision.failover.artifact).to include(
        "original_provider" => "claude",
        "selected_provider" => "codex",
        "reason" => "provider_unavailable",
        "availability_state" => "open",
        "evidence_observed_at" => observed_at.iso8601,
        "automatic_failover" => true,
        "manual_override" => false
      )
    end

    it "does not select failover for a workflow that already has runs" do
      user.update!(
        codex_auth_mode: "api_key",
        codex_api_key: "sk-test",
        agent_provider_failover_policy: {
          "enabled" => true,
          "providers" => %w[codex],
          "causes" => %w[provider_transient],
          "override_explicit_pins" => false
        }
      )
      allow_any_instance_of(Job).to receive(:agent_provider_failover_candidates)
        .with(cause: "provider_transient")
        .and_return([ "codex" ])
      workflow.first_step.runs.create!(job: job, user: user, trigger_kind: workflow.trigger_kind, agent_provider: "claude")
      allow(App::ProviderAvailability).to receive(:for_user).with(user, "claude", now: anything).and_return(
        { state: "open", open: true, retry_after: 10.minutes.from_now.iso8601 }
      )
      allow(App::ProviderAvailability).to receive(:for_user).with(user, "codex", now: anything).and_return(nil)

      decision = described_class.call(workflow: workflow)

      expect(decision).to be_pause
      expect(decision).not_to be_failover
      expect(App::ProviderAvailability).not_to have_received(:for_user).with(user, "codex", now: anything)
    end
  end

  describe ProviderFailoverSelector do
    it "returns the first configured candidate whose availability is usable" do
      selector_job = instance_double(Job, agent_provider_failover_candidates: [ "codex" ])
      selector_workflow = instance_double(
        Workflow,
        user: user,
        job: selector_job,
        agent_provider: "claude",
        runs: instance_double(ActiveRecord::Relation, none?: true)
      )
      allow(App::ProviderAvailability).to receive(:for_user).with(user, "codex", now: anything).and_return(nil)

      decision = ProviderFailoverSelector.call(
        workflow: selector_workflow,
        reason: "provider_unavailable",
        availability: { state: "open", open: true }
      )

      expect(decision).to be_failover
      expect(decision.selected_provider).to eq("codex")
      expect(selector_job).to have_received(:agent_provider_failover_candidates).with(cause: "provider_transient")
    end
  end
end
