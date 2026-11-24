# frozen_string_literal: true

require "rails_helper"
require "syrus/plugin/test_kit"
require Rails.root.join("spec/fixtures/external_reviewer_contract_fake")

RSpec.describe Syrus::Plugin::ExternalReviewerContractKit do
  subject(:provider) { ExternalReviewerContractFake::Service }

  let(:facade) { Data.define(:id).new(id: 1) }
  let(:scenario) { :completed }
  let(:context) { review_context(rule: { scenario: }) }
  let(:refresh_context) do
    review_context(rule: { scenario: :completed }, external_id: "review-1", idempotency_key: "attempt-1")
  end
  let(:health) { Syrus::PluginRuntimeHealth.new }

  before do
    Syrus::PluginInvocation.runtime_health = health
    Syrus::PluginRegistry.register(disableable: true, experimental: false, requires_syrus: nil,
      name: "external_reviewer_contract_fake", version: "1.0.0", default_enabled: true,
      family_provides: [
        Syrus::Plugin::FamilyDeclaration.build(
          family: :review, provider: "ExternalReviewerContractFake::Service",
          provisional: %i[external_reviewer]
        )
      ]
    )
  end

  after { Syrus::PluginInvocation.runtime_health = Syrus::PluginRuntimeHealth.new }

  it_behaves_like "a valid external reviewer",
    context: -> { context }, refresh_context: -> { refresh_context }

  it "publishes the fake through the generated family catalog and plugin health payload" do
    expect(Syrus::PluginRegistry.capability_catalog(:review)).to include(
      plugin: "external_reviewer_contract_fake", family: :review, capability: :external_reviewer,
      provider: "ExternalReviewerContractFake::Service", key: nil, priority: 100
    )

    payload = Admin::PluginsPayload.new.show("external_reviewer_contract_fake").fetch(:plugin)
    expect(payload.fetch(:health).fetch(:state)).to eq("ok")
    expect(payload.fetch(:capabilities)).to include(
      family: "review", capability: "external_reviewer", provider: "ExternalReviewerContractFake::Service",
      key: nil, tier: "provisional", priority: 100
    )
  end

  it "withholds the family provider when its plugin is disabled" do
    PluginRecord.find_by!(name: "external_reviewer_contract_fake").update!(enabled: false)

    expect(Syrus::PluginRegistry.capability_catalog(:review).map { |c| c[:capability] }).not_to include(:external_reviewer)
    expect(Syrus::Plugin::Dispatch.call(:review, :external_reviewer, context)).to be_nil
  end

  it "dispatches the facet and completes synchronously through the service boundary" do
    service = Syrus::Plugin::Dispatch.call(:review, :external_reviewer, context)
    result = described_class.invoke(service, :submit, context)

    expect(result).to have_attributes(outcome: :completed, verdict: :approved)
    expect(result.artifacts.sole.name).to eq("review.json")
  end

  it "accepts asynchronously and refreshes to completion" do
    accepted = described_class.invoke(provider, :submit, review_context(rule: { scenario: :accepted }))
    refreshed = described_class.invoke(provider, :refresh, refresh_context)

    expect(accepted).to have_attributes(
      outcome: :accepted, external_id: "review-1", idempotency_key: "attempt-1", retry_after: 15
    )
    expect(refreshed).to have_attributes(outcome: :completed, verdict: :approved)
  end

  it "normalizes decline, retryable guidance, and terminal failure" do
    declined = described_class.invoke(provider, :submit, review_context(rule: { scenario: :declined }))
    retryable = described_class.invoke(provider, :submit, review_context(rule: { scenario: :retryable_failure }))
    terminal = described_class.invoke(provider, :submit, review_context(rule: { scenario: :terminal_failure }))

    expect(declined).to have_attributes(outcome: :declined, terminal?: true)
    expect(retryable).to have_attributes(outcome: :retryable_failure, retry_after: 30, retryable?: true)
    expect(terminal).to have_attributes(outcome: :terminal_failure, terminal?: true)
  end

  it "rejects malformed output in the conformance contract" do
    malformed = review_context(rule: { scenario: :malformed })

    expect {
      described_class.validate!(provider:, context: malformed, refresh_context:)
    }.to raise_error(RSpec::Expectations::ExpectationNotMetError, /must return ExternalReviewResult/)
  end

  it "declines unsupported optional cancellation" do
    result = described_class.validate!(
      provider: ExternalReviewerContractFake::NoCancellation, context:, refresh_context:
    )

    expect(result.fetch(:cancel)).to have_attributes(outcome: :declined)
  end

  it "requires declared capabilities to match implemented optional methods" do
    invalid = Class.new(ExternalReviewerContractFake::NoCancellation) do
      def self.capabilities = [ :cancellation ]
    end

    expect {
      described_class.validate!(provider: invalid, context:, refresh_context:)
    }.to raise_error(RSpec::Expectations::ExpectationNotMetError, /declare cancellation exactly/)
  end

  it "records failures and timeouts and opens the provider circuit" do
    failed_context = review_context(rule: { scenario: :raise })
    5.times { described_class.invoke(provider, :submit, failed_context) }
    expect(health.failures(plugin: "external_reviewer_contract_fake").sole).to have_attributes(
      extension_point: "review", operation: "submit", exception_class: "RuntimeError"
    )
    expect(health.circuits(plugin: "external_reviewer_contract_fake").sole.state).to eq(:open)

    Syrus::PluginInvocation.runtime_health = Syrus::PluginRuntimeHealth.new
    timed_out = described_class.invoke(
      provider, :submit, review_context(rule: { scenario: :slow }), timeout: 0.001
    )
    expect(timed_out).to have_attributes(outcome: :declined)
    expect(Syrus::PluginInvocation.runtime_health.failures.sole.exception_class).to eq("Timeout::Error")
  end

  it "passes only immutable public snapshots and cannot mutate host lifecycle state through results" do
    expect(context.repository).to be_frozen
    expect(context.job).to be_frozen
    expect(context.connected_account).to be_frozen
    expect(context.client).to be_frozen

    job = Factories.job
    workflow = job.workflows.first
    before = [ job.reload.attributes, workflow.reload.attributes ]
    result = described_class.invoke(provider, :submit, context)

    expect { result.metadata[:state] = "changed" }.to raise_error(FrozenError)
    expect([ job.reload.attributes, workflow.reload.attributes ]).to eq(before)
  end

  private

  def review_context(rule:, external_id: nil, idempotency_key: nil)
    Syrus::Plugin::ExternalReviewContext.new(
      repository: facade, job: facade, pull_request: facade,
      base_sha: "a" * 40, head_sha: "b" * 40, diff_review_version: 3,
      trigger: { kind: "required" }, rule:, links: { pull_request: "https://example.test/pr/1" },
      summary: "Review this", evidence: [ { kind: "diff" } ], connected_account: facade, client: facade,
      external_id:, idempotency_key:
    )
  end
end
