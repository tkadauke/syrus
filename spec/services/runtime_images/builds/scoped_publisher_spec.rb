require "rails_helper"
require "support/synthetic_runtime_image_provider"

RSpec.describe RuntimeImages::Builds::ScopedPublisher do
  let(:provider) { SyntheticRuntimeImageProvider.new }
  let(:service) { RuntimeImages::Service.new(provider: provider) }
  let(:namespace) { RuntimeImageNamespace.create!(name: "acme/widgets", owner_kind: "k", owner_ref: "1", provider_key: provider.key) }
  let(:other) { RuntimeImageNamespace.create!(name: "acme/other", owner_kind: "k", owner_ref: "2", provider_key: provider.key) }
  let(:source) { RuntimeImages::Builds::SourceCapture.capture(kind: "git", ref: "git://repo", revision: "c" * 40) }
  let(:request) do
    RuntimeImages::Builds::Orchestrator.new.submit(namespace: namespace, source: source, recipe: {}, platform: "linux/amd64",
                                                  requester_kind: "t", requester_ref: "1")
  end
  let(:publisher) { described_class.new(service: service, request: request) }
  let(:attrs) { { source_kind: "git", source_ref: "git://repo", source_digest: source.digest, platform: "linux/amd64", payload: "bytes" } }

  it "publishes into the request's namespace" do
    image = publisher.publish(**attrs)
    expect(image.runtime_image_namespace).to eq(namespace)
    expect(publisher.inspect_image(image)).to be_present
  end

  it "refuses to publish into another namespace" do
    expect { publisher.publish(namespace: other, **attrs) }.to raise_error(described_class::OutOfScope)
    expect(RuntimeImage.count).to eq(0)
  end

  it "refuses to inspect another namespace's image" do
    foreign = service.publish(namespace: other, **attrs)
    expect { publisher.inspect_image(foreign) }.to raise_error(described_class::OutOfScope)
  end

  it "exposes no revoke, delete, pull, or resolve authority" do
    expect(publisher).not_to respond_to(:revoke, :delete, :pull, :resolve, :retain)
  end
end
