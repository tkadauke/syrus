# frozen_string_literal: true

module Deploy
  # Warm the worker-dev image on every node that will run a compute worker,
  # in parallel, before any pod is replaced.
  #
  # Measured on a production rollout: a compute pod spent three seconds in its
  # init container, then sat for four minutes with nothing running while
  # containerd pulled worker-dev, then started in three seconds. With the
  # DaemonSet serialised at maxUnavailable=1 that pull was paid six times in a
  # row, five nodes idle for each -- about seventeen minutes of a deploy, very
  # nearly all of it waiting on the same bytes. Pods on nodes that already had
  # the layers were ready in six seconds.
  #
  # Failing to pre-pull is not a deploy failure. The rollout that follows pulls
  # the image itself, exactly as it did before this phase existed, so a timeout
  # here costs the time it was meant to save and nothing else.
  class Prepull
    COMPUTE_DAEMONSET = "syrus-worker-compute"

    attr_reader :context

    def initialize(context)
      @context = context
    end

    def warm!
      unless config.prepull?
        reporter.step("#{label}: skipping image pre-pull (PREPULL=0)")
        return
      end

      unless kubectl.exists?("daemonset", COMPUTE_DAEMONSET)
        reporter.step("#{label}: no compute DaemonSet in #{kubectl.namespace} — skipping pre-pull")
        return
      end

      reporter.step("#{label}: pre-pulling #{config.worker_dev_registry}:#{sha} on every compute node")
      controls.push("pre-pull daemonset/#{config.prepull_daemonset}") { remove! }

      unless kubectl.apply(manifest).success?
        reporter.warn("#{label}: could not create the pre-pull DaemonSet — continuing without it")
        remove!
        return
      end

      wait_for_warm_nodes
      remove!
    end

    private

    def wait_for_warm_nodes
      waiter.until(
        label: "#{label}: pre-pull",
        timeout: config.prepull_timeout,
        poll: 5,
        report_every: 30
      ) do
        status = WorkloadStatus.new(
          target: "daemonset/#{config.prepull_daemonset}",
          document: kubectl.get_json("daemonset", config.prepull_daemonset)
        )
        status.converged? ? Waiter.converged : Waiter.pending(status.summary)
      end
      reporter.ok("#{label}: image warm on every compute node")
    rescue Failure => e
      # Deliberately swallowed: the rollout pulls the image itself. Reported so
      # a deploy that is slow for this reason is not mysterious.
      reporter.warn("#{label}: #{e.message} — continuing; the rollout will pull")
    end

    def remove!
      kubectl.delete("daemonset", config.prepull_daemonset)
      controls.discharge("pre-pull daemonset/#{config.prepull_daemonset}")
    end

    # Placement is copied from the live compute DaemonSet rather than written
    # out here, because environments genuinely differ in which nodes carry the
    # worker role: one cluster keeps an anti-control-plane nodeAffinity, another
    # lets its control-plane nodes run workers too. Hardcoding either rule
    # warms the wrong nodes in the other environment -- and warming a node that
    # will never run the workload is worse than wasteful when that node has a
    # small disk and this image is multi-gigabyte.
    def manifest
      labels = { "name" => config.prepull_daemonset }

      {
        "apiVersion" => "apps/v1",
        "kind" => "DaemonSet",
        "metadata" => { "name" => config.prepull_daemonset, "labels" => labels },
        "spec" => {
          "selector" => { "matchLabels" => labels },
          "template" => {
            "metadata" => { "labels" => labels },
            "spec" => {
              "terminationGracePeriodSeconds" => 0,
              "imagePullSecrets" => copied("imagePullSecrets", []),
              "affinity" => copied("affinity", {}),
              "tolerations" => copied("tolerations", []),
              "containers" => [
                {
                  "name" => "prepull",
                  "image" => "#{config.worker_dev_registry}:#{sha}",
                  "command" => [ "sleep", "600" ],
                  "resources" => { "requests" => { "cpu" => "10m", "memory" => "16Mi" } }
                }
              ]
            }
          }
        }
      }
    end

    def copied(key, fallback)
      value = compute_pod_spec[key]
      value.nil? ? fallback : value
    end

    def compute_pod_spec
      @compute_pod_spec ||=
        kubectl.get_json("daemonset", COMPUTE_DAEMONSET)&.dig("spec", "template", "spec") || {}
    end

    def kubectl = context.kubectl
    def config = context.config
    def reporter = context.reporter
    def waiter = context.waiter
    def controls = context.controls
    def label = context.label
    def sha = context.sha
  end
end
