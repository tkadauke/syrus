# frozen_string_literal: true

require_relative "deploy_helper"

RSpec.describe Deploy::WorkloadStatus do
  def status(target, document)
    described_class.new(target: target, document: document)
  end

  describe "a Deployment" do
    it "is converged when every replica is updated, available and alone" do
      expect(status("deployment/syrus-web", DeploySpec.deployment("syrus-web"))).to be_converged
    end

    # Until the controller has observed the spec we just changed, every replica
    # count still describes the previous rollout -- which is how a rollout
    # "completes" instantly without having started.
    it "is not converged before the controller observes the new spec" do
      document = DeploySpec.deployment("syrus-web", generation: 3, observed: 2)

      expect(status("deployment/syrus-web", document)).not_to be_converged
      expect(status("deployment/syrus-web", document).summary)
        .to include("has not observed the new spec")
    end

    it "is not converged while a pod from the previous revision is still up" do
      document = DeploySpec.deployment("syrus-web", total: 3)

      expect(status("deployment/syrus-web", document)).not_to be_converged
      expect(status("deployment/syrus-web", document).summary)
        .to include("1 from the previous revision still up")
    end

    it "reports how far along it is rather than just 'not yet'" do
      document = DeploySpec.deployment("syrus-web", replicas: 3, updated: 1, available: 1, total: 3)

      expect(status("deployment/syrus-web", document).summary)
        .to eq("deployment/syrus-web: 1/3 updated, 1 available")
    end

    # Kubernetes has already given up on this ReplicaSet. Sitting out our own
    # timeout on top of its timeout only delays the diagnosis.
    it "is failed once Kubernetes reports its progress deadline exceeded" do
      document = DeploySpec.deployment("syrus-web", updated: 0, available: 0, conditions: [
        {
          "type" => "Progressing", "status" => "False",
          "reason" => "ProgressDeadlineExceeded",
          "message" => "ReplicaSet syrus-web-abc has timed out progressing."
        }
      ])

      expect(status("deployment/syrus-web", document)).to be_failed
      expect(status("deployment/syrus-web", document).failure_message).to include("timed out progressing")
    end

    # A workload scaled to zero has nothing to converge, and treating it as
    # converged would pass a rollout that replaced nothing.
    it "is not converged when nothing is desired" do
      expect(status("deployment/x", DeploySpec.deployment("x", replicas: 0, updated: 0, available: 0, total: 0)))
        .not_to be_converged
    end
  end

  describe "a DaemonSet" do
    def daemonset(desired: 6, updated: 6, available: 6, current: 6)
      {
        "kind" => "DaemonSet",
        "metadata" => { "name" => "syrus-worker-compute", "generation" => 4 },
        "status" => {
          "observedGeneration" => 4, "desiredNumberScheduled" => desired,
          "updatedNumberScheduled" => updated, "numberAvailable" => available,
          "currentNumberScheduled" => current
        }
      }
    end

    it "counts nodes rather than replicas" do
      expect(status("daemonset/syrus-worker-compute", daemonset)).to be_converged
    end

    it "is not converged while a node still runs the previous revision" do
      expect(status("daemonset/syrus-worker-compute", daemonset(updated: 4, available: 5)))
        .not_to be_converged
    end
  end

  describe "a StatefulSet" do
    def statefulset(current: "rev-2", update: "rev-2")
      {
        "kind" => "StatefulSet",
        "metadata" => { "name" => "syrus-plugin", "generation" => 2 },
        "spec" => { "replicas" => 1 },
        "status" => {
          "observedGeneration" => 2, "updatedReplicas" => 1, "readyReplicas" => 1,
          "replicas" => 1, "currentRevision" => current, "updateRevision" => update
        }
      }
    end

    it "is converged once its revisions agree" do
      expect(status("statefulset/syrus-plugin", statefulset)).to be_converged
    end

    # A StatefulSet reports its progress as revisions rather than by counting
    # old pods, so the replica counts alone can look finished mid-rollout.
    it "is not converged while an update revision is outstanding" do
      expect(status("statefulset/syrus-plugin", statefulset(current: "rev-1")))
        .not_to be_converged
    end
  end
end
