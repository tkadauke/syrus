require "rails_helper"
require "support/synthetic_runtime_image_provider"

RSpec.describe RuntimeImages::BuiltImages do
  # Each instance is one worker's private Docker image store. Nothing is
  # shared between them except the registry (the provider).
  class IndependentImageStore < RuntimeImages::WorkerCache::Engine
    attr_reader :images, :pulls

    def initialize(images = {})
      @images = images
      @pulls = []
    end

    def build!(reference, payload) = (@images[reference] = { payload: payload })

    def export_oci(reference, platform:, timeout: 600)
      @images.fetch(reference).fetch(:payload)
    end

    def pull(reference, timeout:, auth: nil)
      @pulls << reference
      @images[reference] = { digest: reference.split("@").last }
    end

    def digests(reference) = @images.key?(reference) ? [ @images[reference][:digest] ].compact : []
    def size_bytes(_reference) = 10
    def remove(reference) = @images.delete(reference)
    def disk_usage = { total_bytes: 1000, free_bytes: 900 }
  end

  let(:provider) { SyntheticRuntimeImageProvider.new(key: "synthetic-built") }
  let(:service) { RuntimeImages::Service.new(provider: provider) }
  let(:store_a) { IndependentImageStore.new }
  let(:store_b) { IndependentImageStore.new }
  let(:scan) do
    RuntimeImages::Verifications::SupplyChainScanner::Scan.new(
      sbom: { "bomFormat" => "CycloneDX", "components" => [] }, report: { "Results" => [] },
      scanner_name: "trivy", scanner_version: "0.76.2", database_version: "2026-11-26T12:00:00Z", scanned_at: Time.current
    )
  end
  let(:scanner) { instance_double(RuntimeImages::Verifications::SupplyChainScanner, call: scan) }
  let(:worker_a) do
    described_class.new(service: service, engine: store_a, provider_key: "synthetic-built", cache: cache_for(store_a, "worker-a"),
                        supply_chain_scanner: scanner)
  end
  let(:worker_b) { described_class.new(service: service, engine: store_b, provider_key: "synthetic-built", cache: cache_for(store_b, "worker-b")) }
  let(:identity) { { owner_kind: "devcontainer", owner_ref: "repo-7", source_kind: "devcontainer", source_ref: "rev-abc-123" } }

  before { RuntimeImages::Providers.register(provider) }
  after { RuntimeImages::Providers.unregister("synthetic-built") }

  def cache_for(engine, hostname)
    RuntimeImages::WorkerCache.new(engine: engine, service: service, hostname: hostname)
  end

  it "is available only while its provider is registered" do
    expect(worker_a.available?).to be(true)
    RuntimeImages::Providers.unregister("synthetic-built")
    expect(worker_a.available?).to be(false)
  end

  it "lets a second worker with an independent image store run an image built on the first" do
    store_a.build!("local-build", { manifest: "{}", blobs: {} })

    expect(worker_b.find(**identity)).to be_nil
    published = worker_a.publish_local(local_reference: "local-build", provenance: { "revision" => "abc" }, **identity)

    expect(published).to be_verified_candidate
    expect(published.runtime_image_verification_attempts.last).to be_accepted
    expect(published.runtime_image_verification_attempts.last.scan_evidence).to have_attributes(
      scanner_name: "trivy", scanner_version: "0.76.2", image_digest: published.digest
    )
    found = worker_b.find(**identity)
    expect(found).to eq(published)
    expect(found.provenance).to eq("revision" => "abc")
    expect(found.digest).to match(RuntimeImage::DIGEST_FORMAT)
    expect(store_b.images).to be_empty

    reference = worker_b.acquire(found) { |ref| ref }

    expect(reference).to eq(found.locator)
    expect(reference).to include("@#{found.digest}")
    expect(store_b.pulls).to eq([ found.locator ])
    expect(store_a.pulls).to be_empty
  end

  it "does not find an image once it is revoked" do
    store_a.build!("local-build", { manifest: "{}", blobs: {} })
    image = worker_a.publish_local(local_reference: "local-build", **identity)

    service.revoke(image, reason: "bad")

    expect(worker_b.find(**identity)).to be_nil
  end

  it "does not find or acquire an image after its verification attestation expires" do
    store_a.build!("local-build", { manifest: "{}", blobs: {} })
    image = worker_a.publish_local(local_reference: "local-build", **identity)
    RuntimeImageVerificationAttestation.where(id: image.runtime_image_verification_attestations.last.id)
      .update_all(expires_at: 1.second.ago)

    expect(worker_b.find(**identity)).to be_nil
    expect { service.pull(image) }.to raise_error(RuntimeImages::NotPullable)
  end

  it "keeps images of different owners in different namespaces" do
    store_a.build!("local-build", { manifest: "{}", blobs: {} })
    worker_a.publish_local(local_reference: "local-build", **identity)

    expect(worker_b.find(**identity.merge(owner_ref: "repo-8"))).to be_nil
    expect(RuntimeImageNamespace.pluck(:name)).to contain_exactly(a_string_starting_with("devcontainer-repo-7-"))
  end

  it "does not let owners whose names normalize identically share a namespace" do
    store_a.build!("local-build", { manifest: "{}", blobs: {} })
    slash = identity.merge(owner_ref: "repo/a")
    dash = identity.merge(owner_ref: "repo-a")
    worker_a.publish_local(local_reference: "local-build", **slash)
    worker_a.publish_local(local_reference: "local-build", **dash)

    expect(RuntimeImageNamespace.count).to eq(2)
    expect(worker_a.find(**slash).runtime_image_namespace).not_to eq(worker_a.find(**dash).runtime_image_namespace)
  end

  it "does not reuse another provider's namespace for the same owner" do
    RuntimeImages::Providers.register(SyntheticRuntimeImageProvider.new(key: "synthetic-other"))
    other_service = RuntimeImages::Service.new(provider: RuntimeImages::Providers.fetch("synthetic-other"))
    other = described_class.new(service: other_service, engine: store_a, provider_key: "synthetic-other", supply_chain_scanner: scanner)
    store_a.build!("local-build", { manifest: "{}", blobs: {} })
    worker_a.publish_local(local_reference: "local-build", **identity)
    other.publish_local(local_reference: "local-build", **identity)

    expect(RuntimeImageNamespace.pluck(:provider_key)).to contain_exactly("synthetic-built", "synthetic-other")
    expect(other.find(**identity).runtime_image_namespace.provider_key).to eq("synthetic-other")
  ensure
    RuntimeImages::Providers.unregister("synthetic-other")
  end
end
