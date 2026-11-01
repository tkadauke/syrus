require "rails_helper"

RSpec.describe SyrusBrowser::PermissionProvider do
  it "declares separate observe, navigation, interaction, execution, upload, and close boundaries" do
    descriptors = described_class.permission_capability_descriptors.index_by(&:capability)

    expect(descriptors.keys).to contain_exactly(
      "browser.observe@v1", "browser.navigate@v1", "browser.interact@v1",
      "browser.execute@v1", "browser.upload@v1", "browser.close@v1"
    )
    expect(descriptors.fetch("browser.observe@v1").defaults.values.uniq).to eq([ :allow ])
    expect(descriptors.fetch("browser.execute@v1")).to have_attributes(
      risk: :high, maximum_autonomy: :invocation, authority_durations: [ :invocation ]
    )
    expect(descriptors.fetch("browser.upload@v1").defaults.values.uniq).to eq([ :ask ])
  end

  it "keeps navigation authority scoped to normalized loopback origins" do
    schema = described_class.permission_resource_scopes.fetch(:browser_session)
    origin = schema.normalize({ origin: "http://LOCALHOST:3100/path" }, context: {})
    other = schema.normalize({ origin: "http://127.0.0.1:3200" }, context: {})

    expect(origin).to have_attributes(status: :ok, value: { "origin" => "http://localhost:3100" })
    expect(schema.compare(origin.value, other.value, context: {}).value).to eq(:disjoint)
    expect(schema.normalize({ origin: "https://example.com" }, context: {}))
      .to have_attributes(status: :invalid, errors: include("origin must be an allowed loopback URL"))
  end

  it "fingerprints evaluate source and upload paths without exposing their contents" do
    evaluate = described_class.capability_descriptor("browser.execute/evaluate@v1")
    upload = described_class.capability_descriptor("browser.upload/file@v1")

    normalized = evaluate.normalize_fingerprint(function: "() => document.cookie")
    redacted = upload.redact(paths: [ "/tmp/private/report.txt" ])

    expect(normalized).to eq("function_sha256" => Digest::SHA256.hexdigest("() => document.cookie"))
    expect(redacted.fetch("paths").sole).to match(/\A\[PATH:[a-f0-9]{12}\]\z/)
    expect(redacted.to_json).not_to include("report.txt")
  end

  it "fingerprints form input without retaining credential text" do
    descriptor = described_class.capability_descriptor("browser.interact/action@v1")

    normalized = descriptor.normalize_fingerprint(target: "Password field", text: "secret-token")
    redacted = descriptor.redact(target: "Password field", text: "secret-token")

    expect(normalized).to eq(
      "target" => "Password field",
      "input_text_sha256" => Digest::SHA256.hexdigest("secret-token")
    )
    expect(redacted).to eq(normalized)
    expect(redacted.to_json).not_to include("secret-token")
  end

  it "fingerprints loopback URL credentials without retaining userinfo" do
    descriptor = described_class.capability_descriptor("browser.navigate/open@v1")

    normalized = descriptor.normalize_fingerprint(url: "http://user:secret@localhost:3000/path#fragment")
    redacted = descriptor.redact(url: "http://user:secret@localhost:3000/path#fragment")

    expect(normalized).to eq(
      "url" => "http://localhost:3000/path",
      "url_userinfo_sha256" => Digest::SHA256.hexdigest("user:secret")
    )
    expect(redacted).to eq(normalized)
    expect(URI.parse(redacted.fetch("url")).userinfo).to be_nil
    expect(redacted.to_json).not_to include("user:secret")
  end

  it "treats semantic browser interaction as uncertain while retaining the conservative ceiling" do
    descriptor = described_class.capability_descriptor("browser.interact/action@v1")
    result = Permissions::InvocationClassifier.call(descriptor:, arguments: { target: "submit" })

    expect(result).to have_attributes(
      operation: "browser.interact/action@v1", risk: :high,
      effects: contain_exactly(:local_read, :isolated_execution), fallback?: true
    )
  end
end
