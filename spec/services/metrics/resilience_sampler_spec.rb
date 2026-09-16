require "rails_helper"

# ProviderCircuitBreaker, Installation/User rate-limit columns, and
# Repository's main-health enum are all ordinary ActiveRecord state (unlike
# solid_queue_*, see CLAUDE.md), so Metrics::ResilienceSource is exercised
# directly with real records here rather than through a fake -- only the
# per-source degradation guard needs a stand-in.
RSpec.describe Metrics::ResilienceSampler do
  class FakeResilienceSource
    attr_writer :provider_circuit_states, :github_rate_limit_remaining, :main_branch_broken_repository_count

    def initialize
      @provider_circuit_states = {}
      @github_rate_limit_remaining = {}
      @main_branch_broken_repository_count = 0
    end

    def provider_circuit_states(now: nil) = resolve(@provider_circuit_states)
    def github_rate_limit_remaining = resolve(@github_rate_limit_remaining)
    def main_branch_broken_repository_count = resolve(@main_branch_broken_repository_count)

    private

    def resolve(value)
      raise value if value.is_a?(Exception)

      value
    end
  end

  let(:cache) { ActiveSupport::Cache::MemoryStore.new }
  let(:user) { Factories.user }

  around do |example|
    original = Syrus::Metrics.registry
    Syrus::Metrics.reset!
    described_class.declare_metrics!
    example.run
  ensure
    Syrus::Metrics.instance_variable_set(:@registry, original)
  end

  before do
    allow(Rails).to receive(:cache).and_return(cache)
    ProviderCircuitBreaker.clear_read_cache!
  end

  # Metrics::ResilienceSource#provider_circuit_states runs
  # ProviderCircuitBreaker.call, which references
  # syrus_admission_decisions_total the moment a Run's owning Job goes
  # through the full WorkUnits launcher/admission path -- a metric this
  # spec's registry reset (see `around` above) has wiped. `job_with_run`
  # builds the minimal Job/Workflow/Step/Run graph without that launcher
  # (see Factories#job_with_run), the same seam Metrics::LandingSampler's
  # own spec uses for exactly this reason.
  def failed_agent_run(provider: "codex", outcome: "provider_transient", repository: nil)
    job = Factories.job_with_run(
      repository: repository || Factories.repository(user: user),
      run_attrs: {
        state: "failed",
        agent_provider: provider,
        agent_outcome: outcome,
        finished_at: Time.current - 1.minute
      }
    )
    job.runs.first
  end

  describe "#sample!" do
    it "reports every configured agent provider as closed with no recent failures" do
      described_class.sample!
      described_class.refresh_gauges!

      rendered = Syrus::Metrics.render
      expect(rendered).to include('syrus_provider_circuit_state{provider="claude"} 0')
      expect(rendered).to include('syrus_provider_circuit_state{provider="codex"} 0')
    end

    it "reports a provider as open when transient failures span unrelated jobs" do
      5.times { failed_agent_run }

      described_class.sample!
      described_class.refresh_gauges!

      expect(Syrus::Metrics.render).to include('syrus_provider_circuit_state{provider="codex"} 1')
    end

    it "distinguishes a usage-limit open state from an ordinary open state" do
      run = failed_agent_run(provider: "codex", outcome: "provider_usage_limit")
      RunDiagnostic.create!(run: run, error_class: "Steps::Base::StepFailed", error_message: "Codex API error: model gpt-5.5 weekly usage limit exhausted; check billing")
      run.create_run_failure_classification!(
        classification: "provider_usage_limit",
        confidence: 0.95,
        retryable: false,
        reason: "usage exhausted",
        classified_at: Time.current
      )

      described_class.sample!
      described_class.refresh_gauges!

      expect(Syrus::Metrics.render).to include('syrus_provider_circuit_state{provider="codex"} 2')
    end

    it "caches the lowest observed github rate-limit remaining by credential mode" do
      Factories.installation(user: user, gh_rate_limit_remaining: 300, gh_rate_limit_limit: 5000)
      Factories.installation(user: user, gh_rate_limit_remaining: 120, gh_rate_limit_limit: 5000)
      user.update_columns(gh_rate_limit_remaining: 900, gh_rate_limit_limit: 5000)

      described_class.sample!
      described_class.refresh_gauges!

      rendered = Syrus::Metrics.render
      expect(rendered).to include('syrus_github_rate_limit_remaining{credential_mode="app"} 120')
      expect(rendered).to include('syrus_github_rate_limit_remaining{credential_mode="pat"} 900')
    end

    it "omits a credential mode with no observed rate limit yet" do
      described_class.sample!
      described_class.refresh_gauges!

      expect(Syrus::Metrics.render).not_to include("syrus_github_rate_limit_remaining{")
    end

    it "caches the count of repositories whose default branch health is broken" do
      Factories.repository(user: user).update!(main_branch_health_enabled: true, ci_health: "broken")
      Factories.repository(user: user).update!(main_branch_health_enabled: true, grader_health: "broken")
      Factories.repository(user: user).update!(main_branch_health_enabled: true, ci_health: "healthy", grader_health: "healthy")
      # Health tracking disabled: must not count even though ci_health looks broken.
      Factories.repository(user: user).update!(main_branch_health_enabled: false, ci_health: "broken")

      described_class.sample!
      described_class.refresh_gauges!

      expect(Syrus::Metrics.render).to include("syrus_repositories_main_branch_broken_count 2")
    end

    # One unreachable source costs its own gauge, not the whole sample -- same
    # degradation posture as Metrics::QueueSampler/Metrics::FleetSampler.
    it "degrades one failing source without losing the rest of the sample" do
      source = FakeResilienceSource.new
      source.provider_circuit_states = ActiveRecord::StatementInvalid.new("no such table")
      source.github_rate_limit_remaining = { "app" => 42 }
      source.main_branch_broken_repository_count = 3

      expect { described_class.sample!(source: source) }.not_to raise_error
      described_class.refresh_gauges!

      rendered = Syrus::Metrics.render
      expect(rendered).to include('syrus_github_rate_limit_remaining{credential_mode="app"} 42')
      expect(rendered).to include("syrus_repositories_main_branch_broken_count 3")
      expect(rendered).not_to include("syrus_provider_circuit_state{")
    end
  end

  describe "#refresh_gauges!" do
    it "reports nothing rather than zeroes when no sample has been taken" do
      expect(described_class.refresh_gauges!).to be(false)
      expect(Syrus::Metrics.render).not_to include("syrus_provider_circuit_state{")
    end
  end
end
