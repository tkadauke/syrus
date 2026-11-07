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
        status = WorkloadStatus.new(target: target, document: kubectl.get_json(target))

        # Kubernetes has already given up on this ReplicaSet. Sitting out our
        # own timeout on top of its timeout only delays the diagnosis.
        if status.failed?
          next Waiter.failed(
            "exceeded its progress deadline#{status.failure_message ? ": #{status.failure_message}" : ""}",
            detail: @diagnostics.describe(target)
          )
        end

        next Waiter.converged if status.converged?

        reporter.detail(@diagnostics.summarise(target)) if config.rollout_verbose?
        Waiter.pending(status.summary)
      end
    end

    private

    def kubectl = context.kubectl
    def config = context.config
    def reporter = context.reporter
    def waiter = context.waiter
    def label = context.label
  end
end
