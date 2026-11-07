# frozen_string_literal: true

module Deploy
  # Prove the cluster is running what we just pushed.
  #
  # A converged rollout is not the same claim. It can report success while the
  # pods serve an older image: an imperative restart annotation can be stripped
  # by Flux's next apply, leaving the controller with no progress to report and
  # nothing replaced; and a workload on an untagged image with
  # `imagePullPolicy: Always` can bring up new pods before kubelet notices that
  # `:latest` moved. Both end with a happy controller and stale code.
  #
  # So ask the pods. The Dockerfile bakes GIT_SHA into both images, which makes
  # a running container a direct witness of what it is running -- the only
  # witness that cannot be satisfied by a correct-looking controller status.
  #
  # Every check here is skipped in a dry run. There are no new pods to
  # interrogate, so they would compare against the previous revision and fail
  # a dry run that did exactly what it was asked to.
  class Verifications
    # kubectl exec races a rollout: the pod it resolved a moment ago can be
    # replaced between resolution and attach. Those errors are retried; a
    # genuine failure of the command is not.
    TRANSIENT_EXEC_ERRORS = Regexp.union(
      /failed to find container/,
      /container .* not found/,
      /pod .* not found/,
      /container is not running/,
      /unable to upgrade connection/
    )

    CONFINEMENT_PROBE = <<~RUBY
      snapshot = WorkerCapabilities.current
      runtime = Array(snapshot.dig(:capabilities, "runtime"))
      workers = InstanceVersion.fresh.where(role: "worker")
      live_admission = workers.any? { |worker| Array(WorkerCapabilities.normalize(worker.capabilities)["runtime"]).include?("confined_coworker") }
      manifest = Syrus::PluginRegistry.all_plugins.find { |plugin| plugin.name == "credential_store" }
      broker = manifest&.enabled? && Syrus::PluginRegistry.health.healthy?(manifest.name)
      unless runtime.include?("confined_coworker") && live_admission && broker
        warn({ runtime_verified: runtime.include?("confined_coworker"), live_admission: live_admission,
          broker_authorized: !!broker, diagnostics: snapshot[:diagnostics] }.to_json)
        exit 1
      end
      puts({ runtime_verified: true, live_admission: true, broker_authorized: true }.to_json)
    RUBY

    NATIVE_TOOLCHAIN_PROBE = <<~SH
      set -euo pipefail
      test "$(id -u)" = "1000"
      command -v gcc >/dev/null
      command -v make >/dev/null
      cd "$(mktemp -d)"
      ruby -rmkmf -e 'abort "native compiler smoke check failed" unless try_compile("int main(){return 0;}")'
    SH

    attr_reader :context

    def initialize(context)
      @context = context
    end

    def verify_all!(targets)
      return if waiter.skip?

      verify_revision!(targets)
      verify_native_toolchain!
      verify_coworker_confinement!
    end

    def verify_revision!(targets)
      mismatched = targets.select { |target| kubectl.exists?(target) }.filter_map do |target|
        running = exec_with_retry(target, "printenv", "GIT_SHA").out.strip
        next if running == sha

        reporter.error("#{label}/#{target}: pods running '#{running.empty? ? "<empty>" : running}' but expected #{sha}")
        target
      end
      return if mismatched.empty?

      raise Failure.new(
        "#{label}: rollout reported success but #{mismatched.join(", ")} still serve an older image",
        detail: <<~MSG
          Both the Flux desired-image overrides and the live workload images were
          pinned to #{sha}, so the usual remaining causes are:

            - A new pod failed its init (a migration crash, a missing secret) and
              was held un-Ready while old pods stayed alive. Check
              `kubectl get pods -n #{kubectl.namespace}` for Init:Error or
              CrashLoopBackOff.

            - A container runs an image from a repository this deploy does not
              know about, so nothing pinned it. Check
              `kubectl get deploy,ds,sts -n #{kubectl.namespace} -o yaml | grep image:`.
        MSG
      )
    end

    # The worker image's whole reason for existing is that an agent inside a
    # pod can build and test what it writes. If the toolchain layer is missing,
    # or gcc is not on the RunJob user's PATH, every native gem install in
    # every workflow fails -- one compile here is cheaper than finding out that
    # way.
    def verify_native_toolchain!
      worker_workloads.each do |workload|
        next unless kubectl.exists?(workload)

        reporter.step("#{label}/#{workload}: native build toolchain smoke check")
        result = exec_with_retry(workload, "bash", "-c", NATIVE_TOOLCHAIN_PROBE)
        next if result.success?

        raise Failure.new(
          "#{label}/#{workload}: worker pod cannot compile a native extension as uid 1000",
          detail: [
            result.out, result.stderr,
            "The workload is probably not running the worker-dev image, the toolchain",
            "layer was dropped from the build, or gcc/make are not on the PATH."
          ].reject { |part| part.to_s.strip.empty? }.join("\n")
        )
      end
    end

    # Opt-in: only a worker that declares it expects confinement is checked, so
    # a cluster that does not run confined coworkers is not failed for it.
    def verify_coworker_confinement!
      worker_workloads.each do |workload|
        next unless kubectl.exists?(workload)

        required = exec_with_retry(workload, "printenv", "SYRUS_VERIFY_COWORKER_CONFINEMENT").out.strip
        next unless %w[true 1].include?(required)

        reporter.step("#{label}/#{workload}: verifying coworker confinement admission")
        result = exec_with_retry(workload, "bin/rails", "runner", CONFINEMENT_PROBE)
        next if result.success?

        raise Failure.new(
          "#{label}/#{workload}: confined coworker rollout verification failed",
          detail: [ result.out, result.stderr ].reject { |part| part.to_s.strip.empty? }.join("\n")
        )
      end
    end

    private

    def exec_with_retry(target, *command, attempts: 5)
      result = nil

      attempts.times do |index|
        result = kubectl.exec(target, *command)
        return result if result.success?
        break unless transient?(result)

        if index < attempts - 1
          reporter.warn("#{label}/#{target}: exec target disappeared during rollout; retrying (#{index + 1}/#{attempts})")
          clock.sleep(5)
        end
      end

      result
    end

    def transient?(result)
      "#{result.out}\n#{result.stderr}".match?(TRANSIENT_EXEC_ERRORS)
    end

    def worker_workloads = config.worker_workloads
    def kubectl = context.kubectl
    def config = context.config
    def reporter = context.reporter
    def waiter = context.waiter
    def clock = context.clock
    def label = context.label
    def sha = context.sha
  end
end
