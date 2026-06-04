require "rails_helper"
require "open3"

# The healthcheck script runs as a fresh process from K8s liveness, not
# inside the Rails worker. Bundler isn't pre-activated there, so the
# script must activate gems itself before requiring mysql2. These tests
# spawn it as a subprocess so we exercise the same load path K8s does.
#
# Caveat: in a dev environment where mysql2 is installed into the
# system gemset (rbenv's gemdir), `require "mysql2"` will succeed even
# without `require "bundler/setup"` — so this spec can't fully
# reproduce the K3s container's deployment-install gem layout (where
# mysql2 only exists under vendor/bundle). The spec still pins useful
# behavior: the script must reach the env-var check without dying on
# any earlier require, and it must produce the expected exit code +
# diagnostic stderr when env vars are missing. That's enough to catch
# accidental removal of bundler setup AND removal of the env! guard
# both — even if it can't catch the specific K3s LoadError mode.
RSpec.describe "bin/healthcheck" do
  let(:script) { Rails.root.join("bin/healthcheck").to_s }

  # Bundler.with_unbundled_env approximates "process started by K8s with
  # no Bundler env vars set" — the conditions under which the K3s pod
  # was crashing with LoadError: cannot load such file -- mysql2.
  def spawn_clean(env_overrides = {})
    bundle_env = ENV.to_h.slice("BUNDLE_APP_CONFIG", "BUNDLE_PATH", "BUNDLE_USER_CACHE", "BUNDLE_USER_HOME")

    Bundler.with_unbundled_env do
      env = ENV.to_h.merge(bundle_env).merge(env_overrides)
      Open3.capture3(env, "ruby", script, unsetenv_others: true)
    end
  end

  it "loads mysql2 via Bundler.setup without LoadError" do
    # No DB env vars supplied → script should reach the env! check and
    # exit 2. The key thing being tested is that it DOESN'T die earlier
    # with LoadError on `require "mysql2"`.
    stdout, stderr, status = spawn_clean(
      "SYRUS_DATABASE_PASSWORD" => nil,
      "HOME" => ENV.fetch("HOME"),
      "PATH" => ENV.fetch("PATH")
    )

    expect(stderr).not_to include("LoadError")
    expect(stderr).not_to include("cannot load such file")
    expect(stderr).to include("missing required env var SYRUS_DATABASE_PASSWORD")
    expect(status.exitstatus).to eq(2), "expected exit 2 from env-check, got #{status.exitstatus}: stdout=#{stdout.inspect} stderr=#{stderr.inspect}"
  end
end
