require "rails_helper"

RSpec.describe ProviderRouting::AvailabilitySelector do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(repository: repository, user: user, job_provider_setting: "default") }

  def call(task_key: "initial")
    described_class.call(job: job, task_key: task_key)
  end

  describe "#call" do
    it "flags a sole candidate as exhausted when it is actively rate-limited, even though pause opt-in is off and no ProviderRoutingRule is configured" do
      user.update!(provider_availability_pause_thresholds: { "claude" => 0 })
      allow(App::ProviderAvailability).to receive(:for_user).with(user, "claude", now: anything).and_return(
        { state: "rate_limited", open: true }
      )

      decision = call

      expect(decision.candidate.provider).to eq("claude")
      expect(decision).to be_exhausted
      expect(App::ProviderAvailability).to have_received(:for_user).with(user, "claude", now: anything)
    end

    it "does not flag a sole candidate as exhausted when it actually reports available" do
      user.update!(provider_availability_pause_thresholds: { "claude" => 0 })
      allow(App::ProviderAvailability).to receive(:for_user).with(user, "claude", now: anything).and_return(
        { state: "available" }
      )

      decision = call

      expect(decision.candidate.provider).to eq("claude")
      expect(decision).not_to be_exhausted
    end

    it "fails over to a healthy candidate ahead of one that is actively erroring, regardless of per-provider pause opt-in" do
      user.update!(provider_availability_pause_thresholds: { "claude" => 0, "codex" => 0 })
      ProviderRoutingRule.create!(
        scope_type: "repository",
        scope_id: repository.id,
        task_key: "initial",
        candidates: [ { "provider" => "claude" }, { "provider" => "codex" } ]
      )
      allow(App::ProviderAvailability).to receive(:for_user).with(user, "claude", now: anything).and_return(
        { state: "auth_error", open: true }
      )
      allow(App::ProviderAvailability).to receive(:for_user).with(user, "codex", now: anything).and_return(nil)

      decision = described_class.call(
        job: job,
        task_key: "initial",
        original_candidate: described_class.candidate(provider: "claude")
      )

      expect(decision.candidate.provider).to eq("codex")
      expect(decision).to be_failover
      expect(decision).not_to be_exhausted
    end

    %w[open rate_limited exhausted auth_error].each do |state|
      it "treats state #{state.inspect} as actively unavailable regardless of pause opt-in" do
        user.update!(provider_availability_pause_thresholds: { "claude" => 0 })
        allow(App::ProviderAvailability).to receive(:for_user).with(user, "claude", now: anything).and_return(
          { state: state }
        )

        expect(call).to be_exhausted
      end
    end
  end
end
