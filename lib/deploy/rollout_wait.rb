# frozen_string_literal: true

module Deploy
  # Wait for a workload to finish rolling, reading its own status.
  #
  # The previous implementation re-invoked `kubectl rollout status
  # --timeout=90s` in a loop and grepped its English output for "exceeded its
  # progress deadline". That coupled three unrelated things to one number:
  # `rollout status` holds a watch open for its whole timeout, so the interval
  # at which the operator got a progress report was also the interval at which
  # a watch was torn down and re-established, and the only way to hear more
  # often was to churn watches faster. Reading status directly separates them,
  # and answers *how far along* the rollout is rather than just "not yet".
  class RolloutWait
    attr_reader :context

    def initialize(context)
      @context = context
      @diagnostics = Diagnostics.new(context)
    end

    def wait!(target)
      reporter.step("#{label}: waiting for #{target}")

      waiter.until(
        label: "#{label}: #{target}",
        timeout: config.rollout_timeout,
        poll: config.rollout_poll_interval,
        report_every: config.rollout_report_interval,
        on_timeout: ->(_) { reporter.detail(@diagnostics.describe(target)) }
      ) do
        document = kubectl.get_json(target)
        status = WorkloadStatus.new(target: target, document: document)

        # Kubernetes has already given up on this ReplicaSet. Sitting out our
        # own timeout on top of its timeout only delays the diagnosis.
        if status.failed?
          next Waiter.failed(
            "exceeded its progress deadline#{status.failure_message ? ": #{status.failure_message}" : ""}",
            detail: @diagnostics.describe(target)
          )
        end

        next Waiter.converged if status.converged?
        next Waiter.converged if surge_rolled?(document)

        reporter.detail(@diagnostics.summarise(target)) if config.rollout_verbose?
        Waiter.pending(status.summary)
      end
    end

    private

    # A DaemonSet that surges (maxSurge) starts each node's new pod beside the
    # old one, and the old one then drains its in-flight Runs for up to an
    # hour. Kubernetes does not count a node as updated until that old pod is
    # gone, so the status-based check waited out the drain, timed out, and
    # unwound a successful deploy into a rollback. The rollout is done once
    # every scheduled node has a ready, non-terminating pod on the current
    # template; draining pods are expected, not pending work.
    def surge_rolled?(document)
      return false unless document.is_a?(Hash) && document["kind"].to_s == "DaemonSet"

      surge = document.dig("spec", "updateStrategy", "rollingUpdate", "maxSurge")
      return false if surge.nil? || surge.to_s.delete("%").to_i.zero?
      return false if document.dig("status", "observedGeneration").to_i < document.dig("metadata", "generation").to_i

      selector = document.dig("spec", "selector", "matchLabels")
      return false unless selector.is_a?(Hash) && selector.any?

      desired = document.dig("status", "desiredNumberScheduled").to_i
      return false unless desired.positive?

      template_images = Array(document.dig("spec", "template", "spec", "containers")).map { |container| container["image"] }.sort
      pods = Array(kubectl.get_json("pods", "-l", selector.map { |key, value| "#{key}=#{value}" }.join(","))&.dig("items"))
      current_nodes = pods.select do |pod|
        pod.dig("metadata", "deletionTimestamp").nil? && ready?(pod) &&
          Array(pod.dig("spec", "containers")).map { |container| container["image"] }.sort == template_images
      end.filter_map { |pod| pod.dig("spec", "nodeName") }.uniq

      current_nodes.size >= desired
    end

    def ready?(pod)
      Array(pod.dig("status", "conditions")).any? { |condition| condition["type"] == "Ready" && condition["status"] == "True" }
    end

    def kubectl = context.kubectl
    def config = context.config
    def reporter = context.reporter
    def waiter = context.waiter
    def label = context.label
  end
end
