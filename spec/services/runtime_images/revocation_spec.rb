require "rails_helper"

RSpec.describe RuntimeImages::Revocation do
  it "allows registration before revocation and refuses registration after revocation under the image lock" do
    namespace = RuntimeImageNamespace.create!(name: "revocation-race", owner_kind: "test", owner_ref: "race", provider_key: "test")
    image = RuntimeImage.create!(runtime_image_namespace: namespace, digest: "sha256:#{'a' * 64}",
      platform: "linux/amd64", source_kind: "test", source_ref: "race", availability: "available",
      verification_state: "candidate", published_at: Time.current)

    expect { described_class.assert_launchable!(image.digest) }.not_to raise_error
    image.mark_revoked!(reason: "compromised")

    expect { described_class.assert_launchable!(image.digest) }
      .to raise_error(RuntimeImages::NotPullable, /revoked before process launch/)
  end

  it "refuses a digest when a matching image in another namespace is revoked" do
    digest = "sha256:#{'b' * 64}"
    available_namespace = RuntimeImageNamespace.create!(name: "available-copy", owner_kind: "test", owner_ref: "available", provider_key: "test")
    revoked_namespace = RuntimeImageNamespace.create!(name: "revoked-copy", owner_kind: "test", owner_ref: "revoked", provider_key: "test")
    RuntimeImage.create!(runtime_image_namespace: available_namespace, digest:, platform: "linux/amd64",
      source_kind: "test", source_ref: "available", availability: "available",
      verification_state: "candidate", published_at: Time.current)
    revoked = RuntimeImage.create!(runtime_image_namespace: revoked_namespace, digest:, platform: "linux/amd64",
      source_kind: "test", source_ref: "revoked", availability: "available",
      verification_state: "candidate", published_at: Time.current)
    revoked.mark_revoked!(reason: "compromised")

    expect { described_class.assert_launchable!(digest) }
      .to raise_error(RuntimeImages::NotPullable, /revoked before process launch/)
  end
end
