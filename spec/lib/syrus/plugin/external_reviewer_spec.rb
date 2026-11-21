require "rails_helper"

RSpec.describe Syrus::Plugin::ExternalReviewer do
  let(:public_facade) { Object.new.freeze }

  def context(**overrides)
    defaults = {
      repository: public_facade, job: public_facade, pull_request: public_facade,
      base_sha: "a" * 40, head_sha: "b" * 40, diff_review_version: 3,
      trigger: { kind: "required" }, rule: { provider: "example" },
      links: { pull_request: "https://example.test/pr/1" }, summary: "Review this",
      evidence: [ { kind: "diff" } ], connected_account: public_facade, client: public_facade
    }
    Syrus::Plugin::ExternalReviewContext.new(**defaults.merge(overrides))
  end

  it "defines the provisional Review service capability" do
    capability = Syrus::Plugin::Family.fetch(:review).capabilities.fetch(:external_reviewer)

    expect(capability).to have_attributes(composition: :first_claim, absent: nil, tier: :provisional,
      context: Syrus::Plugin::ExternalReviewContext,
      return_contract: have_attributes(description: "Syrus::Plugin::ExternalReviewer"))
  end

  it "restores the built-in Review family after isolated registry tests reset it" do
    Syrus::Plugin::Family.reset!

    expect { Syrus::Plugin::Family.fetch(:review) }.to raise_error(ArgumentError, /Unknown plugin family/)

    Syrus::Plugin::Family.restore_built_ins!
    expect(Syrus::Plugin::Family.fetch(:review)).to equal(Syrus::Plugin::Families::Review)
  ensure
    Syrus::Plugin::Family.restore_built_ins!
  end

  it "publishes the complete provider capability vocabulary" do
    expect(described_class::CAPABILITIES).to contain_exactly(
      :artifact, :asynchronous_completion, :polling, :webhook_delivery, :feedback,
      :verdict, :cancellation, :provider_managed_github_publication
    )
  end

  it "keeps nested context input immutable" do
    links = { pull_request: [ "https://example.test/pr/1" ] }
    value = context(links:)
    links[:pull_request] << "changed"

    expect(value.links).to eq(pull_request: [ "https://example.test/pr/1" ])
    expect { value.links[:pull_request] << "nope" }.to raise_error(FrozenError)
  end

  it "rejects records, GithubClient instances, and raw credential strings" do
    expect { context(job: Job.new) }.to raise_error(ArgumentError, /public facade/)
    expect { context(connected_account: "oauth-token") }.to raise_error(ArgumentError, /raw credential/)

    stub_const("GithubClient", Class.new)
    expect { context(client: GithubClient.new) }.to raise_error(ArgumentError, /not GithubClient/)
  end

  it "requires exact base and head object ids" do
    expect { context(base_sha: "main") }.to raise_error(ArgumentError, /base_sha must be an exact Git object id/)
    expect { context(head_sha: "HEAD") }.to raise_error(ArgumentError, /head_sha must be an exact Git object id/)
  end

  it "normalizes outcomes, artifacts, publication, and retry semantics" do
    artifact = Syrus::Plugin::ExternalReviewArtifact.new(
      kind: :report, name: "review.json", content_type: "application/json",
      location: { external_id: "file-1" }, metadata: { pages: [ 1 ] }
    )
    result = Syrus::Plugin::ExternalReviewResult.retryable_failure(
      external_id: "review-1", idempotency_key: "attempt-1", retry_after: 30,
      artifacts: [ artifact ], feedback: [ { path: "app.rb" } ], verdict: :changes_requested,
      publication: :provider, metadata: { request_id: "opaque" }
    )

    expect(result).to be_retryable
    expect(result).not_to be_terminal
    expect(result.artifacts).to eq([ artifact ])
    expect(result.publication).to eq(:provider)
    expect { result.feedback.first[:path].replace("changed") }.to raise_error(FrozenError)
  end

  it "declines cancellation by default" do
    provider = Class.new { extend Syrus::Plugin::ExternalReviewer }

    expect(provider.cancel(context)).to eq(Syrus::Plugin::ExternalReviewResult.declined)
  end
end
