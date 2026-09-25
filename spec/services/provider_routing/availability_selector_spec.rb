require "rails_helper"

RSpec.describe ProviderRouting::AvailabilitySelector do
  let(:user) { Factories.user(claude_oauth_token: "oat-test", codex_api_key: "sk-test") }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(repository: repository, user: user, job_provider_setting: "default") }

  before do
    allow_any_instance_of(User).to receive(:promote_first_user_to_admin)
  end

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

    it "fails over before checking availability when the preferred candidate has no configured credentials" do
      user.update!(codex_api_key: nil, provider_availability_pause_thresholds: { "codex" => 0, "claude" => 0 })
      ProviderRoutingRule.create!(
        scope_type: "repository",
        scope_id: repository.id,
        task_key: "initial",
        candidates: [ { "provider" => "codex" }, { "provider" => "claude" } ]
      )
      allow(App::ProviderAvailability).to receive(:for_user).with(user, "claude", now: anything).and_return(
        { state: "available" }
      )
      allow(App::ProviderAvailability).to receive(:for_user).with(user, "codex", now: anything).and_return(
        { state: "available" }
      )

      decision = described_class.call(
        job: job,
        task_key: "initial",
        original_candidate: described_class.candidate(provider: "codex")
      )

      expect(decision.candidate.provider).to eq("claude")
      expect(decision).to be_failover
      expect(decision).not_to be_exhausted
      expect(App::ProviderAvailability).not_to have_received(:for_user).with(user, "codex", now: anything)
    end

    it "marks an uncredentialed sole candidate exhausted with auth-error availability" do
      user.update!(codex_api_key: nil, agent_provider: "codex", provider_availability_pause_thresholds: { "codex" => 0 })
      allow(App::ProviderAvailability).to receive(:for_user)

      decision = call

      expect(decision.candidate.provider).to eq("codex")
      expect(decision).to be_exhausted
      expect(decision.artifact).to include(
        "candidate_availability_state" => "auth_error",
        "unavailable" => include(
          "provider" => "codex",
          "reason" => "provider_credentials_missing"
        )
      )
      expect(App::ProviderAvailability).not_to have_received(:for_user)
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

    describe "explicit repository provider vs. user-scoped routing rules" do
      # The repository is configured for a specific provider ("codex" here,
      # standing in for the provider the original report used), but the user
      # also has a routing rule favoring another provider. The
      # repository provider must win while it's healthy, and a real failover
      # away from it must still be attributed to the repository provider as
      # the original choice.
      before do
        repository.update!(agent_provider: "codex")
        ProviderRoutingRule.create!(scope_type: "user", scope_id: user.id, task_key: "default", candidates: [ { "provider" => "claude" } ])
      end

      it "selects the repository's explicit provider over the user-scoped rule when it is healthy" do
        allow(App::ProviderAvailability).to receive(:for_user).with(user, "codex", now: anything).and_return({ state: "available" })

        decision = described_class.call(
          job: job,
          task_key: "initial",
          original_candidate: described_class.candidate(provider: "codex")
        )

        expect(decision.candidate.provider).to eq("codex")
        expect(decision).not_to be_failover
      end

      it "fails over to the user-scoped rule's candidate when the repository provider is unavailable, attributing the original choice to the repository provider" do
        allow(App::ProviderAvailability).to receive(:for_user).with(user, "codex", now: anything).and_return({ state: "auth_error", open: true })
        allow(App::ProviderAvailability).to receive(:for_user).with(user, "claude", now: anything).and_return({ state: "available" })

        decision = described_class.call(
          job: job,
          task_key: "initial",
          original_candidate: described_class.candidate(provider: "codex")
        )

        expect(decision.candidate.provider).to eq("claude")
        expect(decision).to be_failover
        expect(decision.artifact["original_provider"]).to eq("codex")
      end
    end
  end
end

RSpec.describe ProviderRouting::AvailabilitySelector::Decision do
  def candidate(provider:)
    ProviderRouting::AvailabilitySelector.candidate(provider: provider)
  end

  def decision(availability:)
    described_class.new(
      candidate: candidate(provider: "codex"),
      original_candidate: candidate(provider: "claude"),
      reason: "provider_usage_exhausted",
      availability: availability,
      candidate_availability: nil,
      decided_at: Time.zone.parse("2026-01-01T00:00:00Z"),
      exhausted: false
    )
  end

  describe "#artifact" do
    it "surfaces the earliest reset_at from the real producer shape (string window keys, symbol reset_at key)" do
      availability = {
        state: "exhausted",
        usage: {
          windows: {
            "five_hour" => { reset_at: "2026-01-01T05:00:00Z" },
            "weekly" => { reset_at: "2026-01-05T00:00:00Z" }
          }
        }
      }

      artifact = decision(availability: availability).artifact

      expect(artifact.dig("unavailable", "reset_at")).to be_a(String).and eq("2026-01-01T05:00:00Z")
    end

    it "does not raise ArgumentError when reset_at values are a mix of Time objects and ISO8601 strings" do
      availability = {
        state: "exhausted",
        usage: {
          windows: {
            "five_hour" => { reset_at: Time.zone.parse("2026-01-01T05:00:00Z") },
            "weekly" => { reset_at: "2026-01-05T00:00:00Z" }
          }
        }
      }

      expect { decision(availability: availability).artifact }.not_to raise_error
      expect(decision(availability: availability).artifact.dig("unavailable", "reset_at")).to be_a(String).and eq("2026-01-01T05:00:00Z")
    end

    it "serializes reset_at as a plain ISO8601 string across a JSON round-trip, matching sibling timestamp fields" do
      availability = {
        state: "exhausted",
        usage: {
          windows: {
            "five_hour" => { reset_at: "2026-01-01T05:00:00Z" }
          }
        }
      }

      artifact = decision(availability: availability).artifact
      round_tripped = ActiveSupport::JSON.decode(ActiveSupport::JSON.encode(artifact))

      expect(round_tripped.dig("unavailable", "reset_at")).to eq("2026-01-01T05:00:00Z")
    end

    it "omits reset_at when no window carries one" do
      availability = { state: "exhausted", usage: {} }

      artifact = decision(availability: availability).artifact

      expect(artifact.dig("unavailable", "reset_at")).to be_nil
    end
  end
end
