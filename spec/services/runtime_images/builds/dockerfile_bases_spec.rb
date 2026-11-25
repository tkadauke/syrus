require "rails_helper"

RSpec.describe RuntimeImages::Builds::DockerfileBases do
  it "lists base references, skipping scratch and earlier stages" do
    text = "# c\nFROM --platform=$BUILDPLATFORM golang:1.22 AS build\nFROM build AS test\nfrom alpine@sha256:#{"a" * 64}\nFROM scratch\n"
    expect(described_class.references(text)).to eq([ "golang:1.22", "alpine@sha256:#{"a" * 64}" ])
  end

  it "uses the pinned digest, else the builder-listed digest, else none" do
    listed = [ { "names" => [ "docker.io/library/debian:12" ], "digest" => "sha256:#{"b" * 64}" } ]
    resolved = described_class.resolve([ "alpine@sha256:#{"a" * 64}", "debian:12", "unknown:1" ], listed)
    expect(resolved).to eq([
      { "reference" => "alpine@sha256:#{"a" * 64}", "pinned" => true, "digest" => "sha256:#{"a" * 64}" },
      { "reference" => "debian:12", "pinned" => false, "digest" => "sha256:#{"b" * 64}" },
      { "reference" => "unknown:1", "pinned" => false }
    ])
  end

  it "ignores malformed digests from the builder" do
    resolved = described_class.resolve([ "debian" ], [ { "names" => [ "debian:latest" ], "digest" => "not-a-digest" } ])
    expect(resolved.first).not_to have_key("digest")
  end
end
