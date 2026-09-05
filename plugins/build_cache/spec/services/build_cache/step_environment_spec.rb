require "rails_helper"

RSpec.describe BuildCache::StepEnvironment do
  it "forwards the sccache S3 credentials into step subprocesses" do
    expect(described_class.forwarded_env_keys).to include(
      "SCCACHE_BUCKET", "SCCACHE_ENDPOINT", "SCCACHE_REGION",
      "SCCACHE_S3_KEY_PREFIX", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"
    )
  end

  it "never forwards SCCACHE_BASEDIRS" do
    # Path normalization would let a gcov build cache-hit across workflows and
    # silently corrupt coverage output. See plugins/build_cache/docs/syrus_docs/sccache_build_cache.md.
    expect(described_class.forwarded_env_keys).not_to include("SCCACHE_BASEDIRS")
  end

  it "reaches step subprocesses through the prepare env forward list" do
    expect(Steps::Prepare.prep_env_forward).to include("SCCACHE_BUCKET")
  end

  it "leaves the base env intact when the plugin is disabled" do
    PluginRecord.find_or_create_by!(name: "build_cache").update!(enabled: false, disableable: true)

    forwarded = Steps::Prepare.prep_env_forward

    expect(forwarded).to include("PATH", "HOME")
    expect(forwarded).not_to include("SCCACHE_BUCKET")
  end
end
