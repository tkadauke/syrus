require "rails_helper"

RSpec.describe Coworkers::Environment do
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }
  let(:coworker) { build_coworker("env-one") }

  def build_coworker(handle)
    Coworkers::Coworker.create!(owner_user: owner, name: handle.titleize, handle: handle,
                                workspace_repo: repository.remote_url)
  end
  let(:digest) { "sha256:#{'a' * 64}" }

  def revision_for(environment, number: 1, **attrs)
    Coworkers::EnvironmentRevision.create!(environment: environment, number: number, source_digest: digest, **attrs)
  end

  it "allows one environment per coworker" do
    described_class.create!(coworker: coworker)
    expect(described_class.new(coworker: coworker)).not_to be_valid
    expect(coworker.reload.environment).to be_present
  end

  it "walks the lifecycle and rejects illegal transitions" do
    environment = described_class.create!(coworker: coworker)
    environment.transition_to!(:draft)
    expect { environment.transition_to!(:active) }.to raise_error(described_class::InvalidTransition)
    expect(environment.reload.state).to eq("draft")
  end

  it "rejects revisions that belong to another environment" do
    other = described_class.create!(coworker: build_coworker("env-two"))
    environment = described_class.create!(coworker: coworker)
    environment.candidate_revision = revision_for(other)
    expect(environment).not_to be_valid
  end

  it "keeps image data in the Runtime Image Service and references it" do
    expect(described_class.reflect_on_association(:active_runtime_image).klass).to eq(RuntimeImage)
    expect(described_class.reflect_on_association(:candidate_runtime_image).klass).to eq(RuntimeImage)
    expect(described_class.column_names).not_to include("digest", "locator")
  end

  it "destroys revisions with the coworker" do
    environment = described_class.create!(coworker: coworker)
    revision_for(environment)
    expect { coworker.destroy! }.to change(Coworkers::EnvironmentRevision, :count).by(-1)
  end

  describe Coworkers::EnvironmentRevision do
    let(:environment) { Coworkers::Environment.create!(coworker: coworker) }

    it "numbers revisions uniquely per environment" do
      revision_for(environment)
      expect(environment.next_revision_number).to eq(2)
      expect { revision_for(environment) }.to raise_error(ActiveRecord::RecordInvalid)
    end

    it "keeps source identity immutable" do
      revision = revision_for(environment)
      expect { revision.update!(source_digest: "sha256:#{'b' * 64}") }
        .to raise_error(ActiveRecord::ReadonlyAttributeError)
      expect(revision.reload.source_digest).to eq(digest)
    end

    it "validates digests and the compatibility window" do
      expect(described_class.new(environment: environment, number: 1, source_digest: "nope")).not_to be_valid
      bad = described_class.new(environment: environment, number: 1, source_digest: digest, compat_min: 3, compat_max: 1)
      expect(bad).not_to be_valid
      ok = revision_for(environment, compat_min: 1, compat_max: 3)
      expect(ok.compatible_with?(2)).to be(true)
      expect(ok.compatible_with?(4)).to be(false)
    end

    it "only moves along declared transitions" do
      revision = revision_for(environment)
      revision.transition_to!(:building)
      revision.transition_to!(:failed)
      expect { revision.transition_to!(:active) }.to raise_error(described_class::InvalidTransition)
    end
  end
end
