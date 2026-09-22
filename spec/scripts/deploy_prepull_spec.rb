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
