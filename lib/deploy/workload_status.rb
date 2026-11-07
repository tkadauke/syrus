# frozen_string_literal: true

module Deploy
  # Whether a workload has finished rolling, read from its own status fields.
  #
  # This replaces repeatedly re-invoking `kubectl rollout status --timeout=90s`
  # and grepping its English for "exceeded its progress deadline". Three
  # reasons. A structured read cannot be broken by kubectl rewording itself. It
  # answers *how far along* the rollout is, not just "not yet", so a slow
  # deploy and a stuck one stop looking identical. And `rollout status` holds a
  # watch open for its whole timeout, so the old loop's poll interval and its
  # diagnose interval were the same number, which is why asking for more
  # frequent progress reports meant tearing down and re-establishing a watch
  # more often.
  #
  # `generation` versus `observedGeneration` is the first gate for all three
  # kinds: until the controller has observed the spec we just changed, every
  # replica count still describes the previous rollout, and a status read
  # before then is how a rollout "completes" instantly without having started.
  class WorkloadStatus
    PROGRESS_DEADLINE_EXCEEDED = "ProgressDeadlineExceeded"

    attr_reader :target, :document

    def initialize(target:, document:)
      @target = target
      @document = document || {}
    end

    def kind
      document.fetch("kind", target.to_s.split("/").first.to_s).to_s.downcase
    end

    def converged?
      observed? && desired.positive? && updated == desired &&
        available == desired && !surplus? && revisions_settled?
    end

    # A Deployment whose ReplicaSet never made progress inside its own
    # progressDeadlineSeconds. Kubernetes has already given up; waiting out our
    # timeout on top of its timeout only delays the diagnosis.
    def failed?
      conditions.any? do |condition|
        condition["type"] == "Progressing" &&
          condition["status"] == "False" &&
          condition["reason"] == PROGRESS_DEADLINE_EXCEEDED
      end
    end

    def failure_message
      conditions
        .find { |condition| condition["reason"] == PROGRESS_DEADLINE_EXCEEDED }
        &.fetch("message", nil)
    end

    def observed?
      Integer(status["observedGeneration"] || 0) >= Integer(metadata["generation"] || 0)
    end

    def summary
      return "#{target}: controller has not observed the new spec yet" unless observed?

      "#{target}: #{updated}/#{desired} updated, #{available} available#{surplus_note}"
    end

    def desired
      case kind
      when "daemonset" then Integer(status["desiredNumberScheduled"] || 0)
      else Integer(spec["replicas"] || 0)
      end
    end

    def updated
      case kind
      when "daemonset" then Integer(status["updatedNumberScheduled"] || 0)
      else Integer(status["updatedReplicas"] || 0)
      end
    end

    def available
      case kind
      when "daemonset" then Integer(status["numberAvailable"] || 0)
      when "statefulset" then Integer(status["readyReplicas"] || 0)
      else Integer(status["availableReplicas"] || 0)
      end
    end

    # Pods from the previous revision that are still up. `rollout status` waits
    # for these too, and so must this: a deploy is not done while the old image
    # is still serving.
    def total
      case kind
      when "daemonset" then Integer(status["currentNumberScheduled"] || 0)
      else Integer(status["replicas"] || 0)
      end
    end

    def surplus?
      total > desired
    end

    # A StatefulSet reports its revisions rather than counting old pods, so
    # partition progress needs its own read.
    def revisions_settled?
      return true unless kind == "statefulset"

      status["currentRevision"].to_s == status["updateRevision"].to_s
    end

    private

    def surplus_note
      surplus? ? ", #{total - desired} from the previous revision still up" : ""
    end

    def metadata
      document["metadata"] || {}
    end

    def spec
      document["spec"] || {}
    end

    def status
      document["status"] || {}
    end

    def conditions
      Array(status["conditions"])
    end
  end
end
