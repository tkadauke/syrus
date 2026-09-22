require "spec_helper"
require "json"
require "open3"
require "tmpdir"

RSpec.describe "bin/deploy plugin service images" do
  let(:root) { File.expand_path("../..", __dir__) }
  let(:deploy) { File.read(File.join(root, "bin/deploy")) }

  def bash(script, env = {})
    Open3.capture3(env, "bash", "-c", script, chdir: root)
  end

  # One naming rule for every script, or a deploy pushes an image the
  # cluster's manifests (or a release) name differently.
  it "names plugin images in one shared helper" do
    out, _err, status = bash(". bin/docker-image-lib; syrus_plugin_images ghcr.io/tkadauke")

    expect(status).to be_success
    expect(out).to include("plugins/git_mirror/container ghcr.io/tkadauke/syrus-plugin-git-mirror")
    expect(out).to include("plugins/plugin_runtime/container ghcr.io/tkadauke/syrus-plugin-runtime")
    %w[bin/deploy bin/publish-plugin-images .github/workflows/release.yml].each do |path|
      expect(File.read(File.join(root, path))).to include("syrus_plugin_images"), "#{path} should use the shared helper"
    end
  end

  # A git-mirror Deployment would otherwise never get a new image: nothing
  # built or pushed one, and nothing pinned it.
  it "builds, pushes, and verifies every plugin image at the deploy SHA" do
    build = deploy[/for i in \$\{PLUGIN_REGISTRIES.*?\n  done/m]

    expect(build).to include("docker build --platform linux/amd64")
    expect(build).to include('docker push "${plugin_registry}:${SHA}"')
    expect(build).to include('verify_pushed "${plugin_registry}" "${SHA}"')
    expect(deploy).to match(/--skip-build.*?for plugin_registry in .*?verify_pushed "\$\{plugin_registry\}" "\$\{SHA\}"/m)
  end

  it "pins plugin workloads before restarting and waits for them afterwards" do
    pin_at = deploy.index('pin_live_images "$label"')
    restart_at = deploy.index("kubectl rollout restart -n")
    wait_at = deploy.index('echo "→ ${label}: waiting for plugin workload ${dep}"')

    expect(deploy[/^pin_live_images\(\) \{.*?\n\}/m]).to include('pin_plugin_images "$label"')
    expect(pin_at).to be < restart_at
    expect(wait_at).to be > restart_at
  end

  # Without a Flux override, the next reconcile puts the workload back on
  # whatever tag its source names.
  it "adds plugin images to the Flux overrides it pins and verifies" do
    expect(deploy[/^flux_desired_images_patch\(\) \{.*?\n\}/m]).to include('ENV.fetch("PLUGIN_REGISTRIES")')
    expect(deploy[/^verify_flux_desired_images\(\) \{.*?\n\}/m]).to include('ENV.fetch("PLUGIN_REGISTRIES")')
  end

  # Workloads are named by the cluster, not by Syrus: found by image, at any
  # tag or digest, never by a prefix that happens to match.
  it "finds plugin containers by image" do
    workloads = { "items" => [
      { "kind" => "Deployment", "metadata" => { "name" => "git-mirror" },
        "spec" => { "template" => { "spec" => { "containers" => [ { "name" => "mirror", "image" => "ghcr.io/tkadauke/syrus-plugin-git-mirror:latest" } ] } } } },
      { "kind" => "Deployment", "metadata" => { "name" => "syrus-web" },
        "spec" => { "template" => { "spec" => { "containers" => [ { "name" => "syrus-web", "image" => "ghcr.io/tkadauke/syrus:abc" } ] } } } },
      { "kind" => "StatefulSet", "metadata" => { "name" => "pinned" },
        "spec" => { "template" => { "spec" => {
          "initContainers" => [ { "name" => "warm", "image" => "ghcr.io/tkadauke/syrus-plugin-git-mirror@sha256:deadbeef" } ],
          "containers" => [ { "name" => "lookalike", "image" => "ghcr.io/tkadauke/syrus-plugin-git-mirror-fork:1" } ]
        } } } }
    ] }

    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "kubectl"), "#!/bin/sh\ncat #{File.join(dir, 'workloads.json')}\n")
      File.chmod(0o755, File.join(dir, "kubectl"))
      File.write(File.join(dir, "workloads.json"), workloads.to_json)
      function = deploy[/^plugin_image_containers\(\) \{.*?\n\}/m]

      out, err, status = bash(<<~SH, { "PATH" => "#{dir}:#{ENV.fetch('PATH')}" })
        #{function}
        PLUGIN_REGISTRIES=(ghcr.io/tkadauke/syrus-plugin-git-mirror ghcr.io/tkadauke/syrus-plugin-runtime)
        plugin_image_containers kubeconfig namespace
      SH

      expect(status).to be_success, err
      expect(out.lines.map(&:chomp)).to eq([
        "deployment/git-mirror mirror ghcr.io/tkadauke/syrus-plugin-git-mirror",
        "statefulset/pinned warm ghcr.io/tkadauke/syrus-plugin-git-mirror"
      ])
    end
  end
end
