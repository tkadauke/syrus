require "rails_helper"
require "support/coworker_base_release_helpers"

RSpec.describe RuntimeImages::BuildRequests do
  include CoworkerBaseReleaseHelpers

  let(:service) { described_class.new }
  let(:files) { { "smoke-test" => "#!/bin/sh\ntrue\n", "Dockerfile" => "FROM scratch\n" } }

  it "deduplicates identical file maps independently of wall clock and RubyGems archive configuration" do
    first = travel_to(Time.utc(2026, 1, 1)) { submit }
    allow(Gem).to receive(:source_date_epoch).and_return(Time.utc(2030, 1, 1))
    second = travel_to(Time.utc(2027, 1, 1)) { submit }

    expect(second).to eq(first)
    expect(RuntimeImageBuildRequest.where(id: first.id)).to contain_exactly(first)
  end

  it "creates a distinct request when the runtime provider contract changes" do
    allow(RuntimeImages::RuntimeAbi).to receive(:digest).and_return("sha256:#{'a' * 64}")
    first = submit

    allow(RuntimeImages::RuntimeAbi).to receive(:digest).and_return("sha256:#{'b' * 64}")
    second = submit

    expect(second).not_to eq(first)
    expect(second.recipe_digest).not_to eq(first.recipe_digest)
    expect(RuntimeImageBuildRequest.where(id: [ first.id, second.id ])).to contain_exactly(first, second)
  end

  it "exposes only a currently supported base as a rebuild target" do
    allow(BaseRebuildDiscoveryJob).to receive(:perform_later)
    release = active_base

    expect(service.base_for_rebuild(release.id)).to have_attributes(
      id: release.id, digest: release.digest, runtime_abi: release.runtime_abi
    )

    base_releases.set_support_deadline!(release, until_time: 1.minute.ago, actor: "operator")
    expect(service.base_for_rebuild(release.id)).to be_nil
  end

  private

  def submit
    service.submit(owner_kind: "test", owner_ref: "stable-source", source_kind: "test", source_ref: "source",
                   files: files, recipe: { "dockerfile" => "Dockerfile" }, requester_kind: "test", requester_ref: "1")
  end
end
