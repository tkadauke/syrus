require "rails_helper"

RSpec.describe RuntimeImages::Builds::DockerfileBases do
  it "lists base references, skipping scratch and earlier stages" do
    text = "# c\nFROM --platform=$BUILDPLATFORM golang:1.22 AS build\nFROM build AS test\nfrom alpine@sha256:#{"a" * 64}\nFROM scratch\n"
    expect(described_class.references(text)).to eq([ "golang:1.22", "alpine@sha256:#{"a" * 64}" ])
  end

  # The image a multi-stage build produces descends from its last stage only;
  # an approved base used by an earlier stage says nothing about it (F158).
  it "names the external image the final stage builds from, following stage aliases" do
    approved = "registry.test/base@sha256:#{"a" * 64}"
    copied_from = "FROM #{approved} AS build\nRUN make\nFROM other/runtime:1\nCOPY --from=build /out /out\n"
    built_on = "FROM #{approved} AS build\nRUN make\nFROM build\nRUN make install\n"

    expect(described_class.final_reference(copied_from)).to eq("other/runtime:1")
    expect(described_class.final_reference(built_on)).to eq(approved)
    expect(described_class.final_reference("FROM scratch\n")).to be_nil
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

  it "resolves ARG defaults and build-arg overrides in FROM references" do
    text = "ARG BASE=alpine:3.20\nARG TAG\nFROM $BASE\nFROM debian:${TAG:-12}\nFROM ${MISSING}\n"
    expect(described_class.references(text)).to eq([ "alpine:3.20", "debian:12", "${MISSING}" ])
    expect(described_class.references(text, "BASE" => "alpine:3.21", "TAG" => "13").first(2)).to eq([ "alpine:3.21", "debian:13" ])
  end
end
