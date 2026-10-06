require "spec_helper"

RSpec.describe "bin/deploy image pre-pull" do
  let(:root) { File.expand_path("../..", __dir__) }
  let(:deploy) { File.read(File.join(root, "bin/deploy")) }

  # A compute pod measured in production spent four minutes with nothing
  # running while containerd pulled worker-dev. Serialized across the
  # DaemonSet that was ~17 minutes of a deploy spent fetching the same bytes
  # one node at a time, five nodes idle for each.
  it "warms the image before changing the live pod template" do
    prepull_at = deploy.index("prepull_worker_image \"$label\"")
    pin_at = deploy.index('pin_live_images "$label"')

    expect(prepull_at).not_to be_nil
    expect(pin_at).not_to be_nil
    expect(prepull_at).to be < pin_at,
      "pre-pulling after the image pin would warm nodes whose pods already paid the pull"
  end

  it "uses the image change as the only rollout trigger" do
    expect(deploy).not_to include("kubectl rollout restart"),
      "Flux removes imperative restart annotations and would replace every pod again"
  end

  # Staging keeps the anti-master nodeAffinity from apps/syrus.py; production
  # strips it, because its masters absorbed the worker role. Hardcoding either
  # rule warms the wrong nodes in the other environment -- and staging's nodes
  # have ~20GB disks against a multi-gigabyte image.
  it "copies placement from the live compute DaemonSet rather than hardcoding it" do
    expect(deploy).to include("jsonpath='{.spec.template.spec.affinity}'")
    expect(deploy).to include("jsonpath='{.spec.template.spec.tolerations}'")
    expect(deploy).not_to include("node-role.kubernetes.io"),
      "placement belongs to the workload being warmed, not to this script"
  end

  it "falls back to unconstrained placement when the DaemonSet declares none" do
    expect(deploy).to include('[ -n "$affinity" ] || affinity="{}"')
    expect(deploy).to include('[ -n "$tolerations" ] || tolerations="[]"')
  end

  # The rollout pulls the image itself if this does not, so every failure here
  # costs the time it was meant to save and nothing more. A deploy that aborts
  # because an optimization timed out would be strictly worse than no
  # optimization.
  it "never turns a pre-pull failure into a deploy failure" do
    helper = deploy[/^prepull_worker_image\(\) \{.*?\n\}/m]

    expect(helper).not_to be_nil
    expect(helper).to include("continuing without it")
    expect(helper).to include("continuing; the rollout will pull")
    expect(helper).to match(/return 0\s*$/)
  end

  it "removes the throwaway DaemonSet on every exit path" do
    expect(deploy).to match(/cleanup_rollout_controls\(\) \{.*?delete_prepull_daemonset/m),
      "an interrupted deploy must not leave a prepull DaemonSet pinning an old image"

    helper = deploy[/^prepull_worker_image\(\) \{.*?\n\}/m]
    expect(helper.scan("delete_prepull_daemonset").size).to be >= 2,
      "both the failure and success paths have to clean up"
  end

  # Every assertion here reads the script as text, which is why this bug
  # survived: the manifest interpolated $GHCR_PULL_SECRET_NAME, a name defined
  # nowhere. Under `set -u` the heredoc aborted, the apply never ran, and the
  # "never turn a pre-pull failure into a deploy failure" guarantee below
  # swallowed it -- so every deploy silently skipped the warm-up and each node
  # pulled a multi-gigabyte image cold during the rollout.
  it "interpolates only names the script actually defines" do
    helper = deploy[/^prepull_worker_image\(\) \{.*?\n\}/m]
    expect(helper).not_to be_nil

    referenced = helper.scan(/\$\{([A-Za-z_][A-Za-z0-9_]*)\}/).flatten.uniq
    expect(referenced).not_to be_empty

    undefined = referenced.reject do |name|
      deploy.match?(/^\s*(?:local\s+[^\n]*\b)?#{Regexp.escape(name)}=/) ||
        deploy.match?(/^\s*local\s+[^\n=]*\b#{Regexp.escape(name)}\b/) ||
        deploy.match?(/^\s*(?:export\s+)?#{Regexp.escape(name)}=/)
    end

    expect(undefined).to be_empty,
      "the pre-pull manifest interpolates #{undefined.join(', ')}, which bin/deploy never assigns; " \
      "under `set -u` that aborts the heredoc and silently skips the warm-up"
  end

  # The secret belongs to the workload being warmed, exactly like affinity and
  # tolerations. Hardcoding a name here would drift the moment a namespace used
  # a different one.
  it "copies image pull secrets from the live compute DaemonSet" do
    expect(deploy).to include("jsonpath='{.spec.template.spec.imagePullSecrets}'")
    expect(deploy).to include('[ -n "$pull_secrets" ] || pull_secrets="[]"')
  end

  it "can be skipped for a tag every node already has" do
    expect(deploy).to include('PREPULL="${PREPULL:-1}"')
    expect(deploy).to include('if [ "$PREPULL" = "0" ]')
  end

  # terminationGracePeriodSeconds: 0 because the pod holds no work -- it exists
  # only so that kubelet fetches the image.
  it "keeps the warming pod disposable" do
    helper = deploy[/^prepull_worker_image\(\) \{.*?\n\}/m]

    expect(helper).to include("terminationGracePeriodSeconds: 0")
    expect(helper).to include("cpu: 10m")
  end
end
