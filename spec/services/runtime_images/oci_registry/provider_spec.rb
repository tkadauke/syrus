require "rails_helper"
require "webmock/rspec"

RSpec.describe RuntimeImages::OciRegistry::Provider do
  let(:registry) { "https://registry.test" }
  let(:configuration) do
    RuntimeImages::OciRegistry::Configuration.new(
      url: registry, repository_prefix: "syrus",
      credentials: {
        builder: RuntimeImages::OciRegistry::Credential.new(username: "b", secret: "builder-secret"),
        worker: RuntimeImages::OciRegistry::Credential.new(username: "w", secret: "worker-secret"),
        admin: RuntimeImages::OciRegistry::Credential.new(username: "a", secret: "admin-secret")
      }
    )
  end
  let(:provider) { described_class.new(configuration: configuration) }
  let(:namespace) { RuntimeImageNamespace.create!(name: "acme/web", owner_kind: "repository_devcontainer", owner_ref: "1", provider_key: "oci_registry") }
  let(:repo) { "syrus/repository-devcontainer/acme/web" }
  let(:manifest) { { "mediaType" => "application/vnd.oci.image.manifest.v1+json", "layers" => [] }.to_json }
  let(:digest) { "sha256:#{Digest::SHA256.hexdigest(manifest)}" }

  before do
    stub_request(:get, "#{registry}/token").with(query: hash_including("service" => "registry")).to_return do |req|
      scope = Rack::Utils.parse_query(URI.parse(req.uri.to_s).query)["scope"]
      { status: 200, body: { token: "tok-#{scope}", expires_in: 300 }.to_json }
    end
    stub_request(:any, /#{Regexp.escape(registry)}\/v2\//).with { |r| r.headers["Authorization"].nil? }
      .to_return(status: 401, headers: { "WWW-Authenticate" => %(Bearer realm="#{registry}/token",service="registry") })
  end

  def authed(method, path, scope)
    stub_request(method, "#{registry}#{path}").with(headers: { "Authorization" => "Bearer tok-#{scope}" })
  end

  it "publishes a manifest as the builder with a scoped push token and verifies the digest" do
    push = authed(:put, "/v2/#{repo}/manifests/#{digest}", "repository:#{repo}:pull,push")
      .to_return(status: 201, headers: { "Docker-Content-Digest" => digest })
    tag = authed(:put, "/v2/#{repo}/manifests/rev-1", "repository:#{repo}:pull,push")
      .to_return(status: 201, headers: { "Docker-Content-Digest" => digest })
    result = provider.publish(RuntimeImages::PublishRequest.new(namespace: namespace, source_kind: "dockerfile", source_ref: "rev-1",
                                                                source_digest: nil, platform: "linux/amd64", provenance: {}, payload: { manifest: manifest }))
    expect(result.digest).to eq(digest)
    expect(result.locator).to eq("registry.test/#{repo}@#{digest}")
    expect(push).to have_been_requested
    expect(tag).to have_been_requested
  end

  it "rejects a registry that reports a different digest" do
    authed(:put, "/v2/#{repo}/manifests/#{digest}", "repository:#{repo}:pull,push")
      .to_return(status: 201, headers: { "Docker-Content-Digest" => "sha256:#{'0' * 64}" })
    expect do
      provider.publish(RuntimeImages::PublishRequest.new(namespace: namespace, source_kind: "d", source_ref: "!", source_digest: nil,
                                                         platform: "linux/amd64", provenance: {}, payload: { manifest: manifest }))
    end.to raise_error(RuntimeImages::ProviderError, /reported digest/)
  end

  it "uploads missing blobs after verifying their digests" do
    blob = "layer"
    blob_digest = "sha256:#{Digest::SHA256.hexdigest(blob)}"
    scope = "repository:#{repo}:pull,push"
    authed(:head, "/v2/#{repo}/blobs/#{blob_digest}", scope).to_return(status: 404)
    authed(:post, "/v2/#{repo}/blobs/uploads/", scope).to_return(status: 202, headers: { "Location" => "/v2/#{repo}/blobs/uploads/u1" })
    upload = authed(:put, "/v2/#{repo}/blobs/uploads/u1?digest=#{blob_digest}", scope).to_return(status: 201)
    authed(:put, "/v2/#{repo}/manifests/#{digest}", scope).to_return(status: 201)
    provider.publish(RuntimeImages::PublishRequest.new(namespace: namespace, source_kind: "d", source_ref: "!", source_digest: nil,
                                                       platform: "linux/amd64", provenance: {}, payload: { manifest: manifest, blobs: { blob_digest => blob } }))
    expect(upload).to have_been_requested
    expect do
      provider.publish(RuntimeImages::PublishRequest.new(namespace: namespace, source_kind: "d", source_ref: "!", source_digest: nil,
                                                         platform: "linux/amd64", provenance: {}, payload: { manifest: manifest, blobs: { "sha256:#{'1' * 64}" => blob } }))
    end.to raise_error(RuntimeImages::ProviderError, /does not match/)
  end

  it "resolves a tag, verifying the manifest bytes hash to the reported digest" do
    authed(:get, "/v2/#{repo}/manifests/rev-1", "repository:#{repo}:pull").to_return(status: 200, body: manifest, headers: { "Docker-Content-Digest" => digest })
    resolution = provider.resolve(RuntimeImages::ResolveRequest.new(namespace: namespace, reference: "rev-1", platform: "linux/amd64"))
    expect(resolution.digest).to eq(digest)
  end

  it "rejects a tampered manifest body" do
    authed(:get, "/v2/#{repo}/manifests/#{digest}", "repository:#{repo}:pull").to_return(status: 200, body: manifest + " ")
    request = RuntimeImages::PullRequest.new(namespace: namespace, digest: digest, platform: "linux/amd64", locator: nil)
    expect { provider.pull(request) }.to raise_error(RuntimeImages::ProviderError, /requested digest/)
  end

  it "refuses an upload location on a different port of the registry host" do
    blob = "layer"
    blob_digest = "sha256:#{Digest::SHA256.hexdigest(blob)}"
    scope = "repository:#{repo}:pull,push"
    authed(:head, "/v2/#{repo}/blobs/#{blob_digest}", scope).to_return(status: 404)
    authed(:post, "/v2/#{repo}/blobs/uploads/", scope)
      .to_return(status: 202, headers: { "Location" => "https://registry.test:8443/v2/#{repo}/blobs/uploads/u1" })
    expect do
      provider.publish(RuntimeImages::PublishRequest.new(namespace: namespace, source_kind: "d", source_ref: "!", source_digest: nil,
                                                         platform: "linux/amd64", provenance: {}, payload: { manifest: manifest, blobs: { blob_digest => blob } }))
    end.to raise_error(RuntimeImages::ProviderError, /different host/)
  end

  it "selects the platform entry from an index" do
    child_manifest = "child-bytes"
    real_child = "sha256:#{Digest::SHA256.hexdigest(child_manifest)}"
    index = { "mediaType" => "application/vnd.oci.image.index.v1+json",
              "manifests" => [{ "digest" => "sha256:#{'d' * 64}", "platform" => { "os" => "linux", "architecture" => "arm64" } },
                              { "digest" => real_child, "platform" => { "os" => "linux", "architecture" => "amd64" } }] }.to_json
    authed(:get, "/v2/#{repo}/manifests/latest", "repository:#{repo}:pull").to_return(status: 200, body: index)
    authed(:get, "/v2/#{repo}/manifests/#{real_child}", "repository:#{repo}:pull").to_return(status: 200, body: child_manifest)
    resolution = provider.resolve(RuntimeImages::ResolveRequest.new(namespace: namespace, reference: "latest", platform: "linux/amd64"))
    expect(resolution.digest).to eq(real_child)
    expect do
      provider.resolve(RuntimeImages::ResolveRequest.new(namespace: namespace, reference: "latest", platform: "linux/s390x"))
    end.to raise_error(RuntimeImages::NotFound)
  end

  it "reports absence when inspecting a missing digest" do
    authed(:head, "/v2/#{repo}/manifests/#{digest}", "repository:#{repo}:pull").to_return(status: 404)
    inspection = provider.inspect_image(RuntimeImages::InspectRequest.new(namespace: namespace, digest: digest, platform: "linux/amd64"))
    expect(inspection.present).to be(false)
  end

  it "refuses to pull a locator from another namespace's repository" do
    request = RuntimeImages::PullRequest.new(namespace: namespace, digest: digest, platform: "linux/amd64",
                                             locator: "registry.test/syrus/coworker-environment/other@#{digest}")
    expect { provider.pull(request) }.to raise_error(RuntimeImages::NotPullable)
  end

  it "deletes as the administrator with delete scope and tolerates 404" do
    gone = authed(:delete, "/v2/#{repo}/manifests/#{digest}", "repository:#{repo}:pull,delete").to_return(status: 404)
    provider.revoke(RuntimeImages::RevokeRequest.new(namespace: namespace, digest: digest, platform: "linux/amd64", reason: "x"))
    expect(gone).to have_been_requested
  end

  it "raises Unsupported when the registry disables deletion" do
    authed(:delete, "/v2/#{repo}/manifests/#{digest}", "repository:#{repo}:pull,delete").to_return(status: 405)
    expect { provider.delete(RuntimeImages::DeleteRequest.new(namespace: namespace, digest: digest, platform: "linux/amd64")) }
      .to raise_error(RuntimeImages::Unsupported)
  end

  it "surfaces rejected credentials without leaking the secret" do
    stub_request(:get, "#{registry}/token").with(query: hash_including({})).to_return(status: 401)
    expect { provider.pull(RuntimeImages::PullRequest.new(namespace: namespace, digest: digest, platform: "linux/amd64", locator: nil)) }
      .to raise_error(RuntimeImages::ProviderError) { |e| expect(e.message).not_to include("worker-secret") }
  end

  it "mints a pull-only grant for one repository without exposing the deployment credential" do
    grant = provider.worker_pull_grant(namespace)
    expect(grant).to include(registry: "registry.test", repository: repo, actions: %w[pull])
    expect(grant[:token]).to eq("tok-repository:#{repo}:pull")
    expect(grant.to_s).not_to include("worker-secret")
  end

  it "does not hand out grants when the registry uses basic auth" do
    WebMock.reset!
    stub_request(:get, "#{registry}/v2/").to_return(status: 401, headers: { "WWW-Authenticate" => 'Basic realm="r"' })
    expect { provider.worker_pull_grant(namespace) }.to raise_error(RuntimeImages::Unsupported)
  end

  it "maps distinct owner kinds and namespaces to distinct repositories" do
    other = RuntimeImageNamespace.new(name: "acme/web", owner_kind: "coworker_environment", owner_ref: "2", provider_key: "oci_registry")
    layout = RuntimeImages::OciRegistry::RepositoryLayout.new(prefix: "syrus")
    expect(layout.repository_for(namespace)).not_to eq(layout.repository_for(other))
    other.owner_kind = "../x"
    expect { layout.repository_for(other) }.to raise_error(RuntimeImages::ProviderError)
  end
end
