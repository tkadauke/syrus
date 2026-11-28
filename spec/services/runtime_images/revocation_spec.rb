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
end
