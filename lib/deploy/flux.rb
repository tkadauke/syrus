# frozen_string_literal: true

module Deploy
  # Flux reconciles the apps Kustomization from Git every ten minutes and
  # re-applies the manifest it finds there. That is exactly what you want
  # except during the few minutes when this script is replacing images, where
  # it would restore the previous image partway through the replacement.
  #
  # So: suspend the Kustomization, update its desired image overrides to this
  # revision, roll the live workloads, then resume. Updating the desired state
  # before the live state is what makes resuming a no-op instead of a second
  # rollout -- Flux comes back, compares, and finds the pod template it would
  # have written already running.
  #
  # The suspension is the dangerous part, because a suspension that is never
  # lifted stops a cluster reconciling indefinitely and nothing alerts on it.
  # An in-process cleanup handler is not enough: it does not run if the laptop
  # sleeps, the terminal closes, or the process is killed with -9. So suspend
  # also submits a server-side watchdog Job that resumes the Kustomization
  # after a TTL. On the normal path this script resumes first and the
  # watchdog's patch is a no-op; the watchdog is load-bearing only on the
  # paths where this script is no longer running.
  class Flux
    WATCHDOG_SERVICE_ACCOUNT = "syrus-deploy-watchdog"

    attr_reader :context

    def initialize(context)
      @context = context
      @suspended_by_deploy = false
      @image_snapshot = nil
      @ttl = nil
    end

    def present?
      return @present if defined?(@present)

      @present = kubectl.exists?("kustomization", config.flux_kustomization)
    end

    # The watchdog TTL has to outlast every bounded phase that runs while Flux
    # is down, which is only knowable once the cluster's real rollout targets
    # are counted -- an environment running a subset of the workloads, or extra
    # plugin services, needs a different number.
    def configure_ttl!(rollout_target_count)
      budget = config.flux_suspend_budget_seconds(rollout_target_count)
      override = config.flux_suspend_ttl_override

      if override.nil?
        @ttl = budget
        return
      end

      @ttl = override
      return unless override < budget

      reporter.warn(
        "#{label}: FLUX_SUSPEND_TTL=#{override}s is below the computed deploy budget of " \
        "#{budget}s for #{rollout_target_count} rollout target(s)"
      )
    end

    def suspend!
      unless present?
        reporter.step("#{label}: flux kustomization '#{config.flux_kustomization}' not found in '#{config.flux_namespace}' — proceeding without suspend")
        return
      end

      if already_suspended?
        # Someone suspended this deliberately. Track the image overrides so a
        # failure can still restore them, but never resume what this deploy did
        # not suspend -- that would silently undo an operator's decision.
        reporter.step("#{label}: flux kustomization/#{config.flux_kustomization} was already suspended — leaving it suspended")
        return
      end

      ensure_watchdog_rbac!
      reporter.step("#{label}: suspending flux kustomization/#{config.flux_kustomization} (auto-resume in #{Duration.humanize(ttl)} if I crash)")
      patch_suspend(true)
      @suspended_by_deploy = true
      controls.push("flux kustomization/#{config.flux_kustomization} suspension") { resume! }
      schedule_watchdog!
    end

    # Snapshot first, then pin. An ordinary failure restores the snapshot
    # before Flux is resumed, so a failed deploy leaves the desired state
    # naming the revision that is actually running rather than the one that
    # did not finish rolling out.
    def pin_desired_images!(registries)
      return unless present?

      @image_snapshot = { "spec" => { "images" => current_images } }
      controls.push("flux image overrides") { restore_desired_images! }

      reporter.step("#{label}: pinning flux image overrides to #{sha}")
      patch_images(desired_images(registries))
    end

    def resume!
      if @suspended_by_deploy && present?
        reporter.step("#{label}: resuming flux kustomization/#{config.flux_kustomization}")
        patch_suspend(false)
        request_reconcile!
      end
      @suspended_by_deploy = false
      controls.discharge("flux kustomization/#{config.flux_kustomization} suspension")
    end

    def verify_desired_images!(registries)
      return if waiter.skip?
      return unless present?

      expected = registries.to_h { |name| [ name, sha ] }
      live = current_images.to_h { |image| [ image["name"], image["newTag"] ] }
      missing = expected.filter_map { |name, tag| "#{name}:#{tag}" unless live[name] == tag }
      return if missing.empty?

      raise Failure.new(
        "#{label}: flux image overrides do not include expected revision tags",
        detail: missing.join("\n")
      )
    end

    # The happy path's successful pin is the state we want to keep, so retire
    # the restore entry rather than let the stack undo a good deploy.
    def accept_desired_images!
      @image_snapshot = nil
      controls.discharge("flux image overrides")
    end

    # configure_ttl! always runs first; this is the floor if it ever does not.
    def ttl
      @ttl ||= config.flux_suspend_budget_seconds(config.rollout_targets.length)
    end

    private

    def restore_desired_images!
      snapshot = @image_snapshot
      raise ControlStack::Decline, "nothing was recorded to restore" if snapshot.nil?

      reporter.step("#{label}: restoring previous Flux image overrides")
      result = patch_images(Array(snapshot.dig("spec", "images")))
      raise "flux rejected the restore patch: #{result.stderr.strip}" unless result.success?

      @image_snapshot = nil
    end

    def already_suspended?
      kubectl.jsonpath("kustomization", config.flux_kustomization, "{.spec.suspend}") == "true"
    end

    def current_images
      Array(kubectl.get_json("kustomization", config.flux_kustomization)&.dig("spec", "images"))
    end

    # Plugin images are overridden too, or Flux would put a pinned plugin
    # workload back on whatever tag its source names. An override for an image
    # no resource uses is inert, so listing one that is not deployed costs
    # nothing.
    def desired_images(registries)
      wanted = registries.map { |name| { "name" => name, "newTag" => sha } }
      wanted_names = wanted.map { |image| image["name"] }
      current_images.reject { |image| wanted_names.include?(image["name"]) } + wanted
    end

    def patch_images(images)
      kubectl.patch(
        "kustomization", config.flux_kustomization,
        patch: { "spec" => { "images" => images } },
        field_manager: config.flux_image_field_manager
      )
    end

    def patch_suspend(value)
      kubectl.patch("kustomization", config.flux_kustomization, patch: { "spec" => { "suspend" => value } })
    end

    def request_reconcile!
      kubectl.annotate(
        "kustomization", config.flux_kustomization,
        "reconcile.fluxcd.io/requestedAt=#{Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")}"
      )
    end

    # A ServiceAccount in the Flux namespace with get/patch on kustomizations,
    # and nothing else. Idempotent, and permanent: the cost is three objects
    # per cluster, against needing them to exist at the moment a deploy is
    # crashing.
    def ensure_watchdog_rbac!
      kubectl.apply(
        "apiVersion" => "v1",
        "kind" => "List",
        "items" => [
          {
            "apiVersion" => "v1", "kind" => "ServiceAccount",
            "metadata" => { "name" => WATCHDOG_SERVICE_ACCOUNT, "namespace" => config.flux_namespace }
          },
          {
            "apiVersion" => "rbac.authorization.k8s.io/v1", "kind" => "Role",
            "metadata" => { "name" => WATCHDOG_SERVICE_ACCOUNT, "namespace" => config.flux_namespace },
            "rules" => [
              {
                "apiGroups" => [ "kustomize.toolkit.fluxcd.io" ],
                "resources" => [ "kustomizations" ],
                "verbs" => %w[get patch]
              }
            ]
          },
          {
            "apiVersion" => "rbac.authorization.k8s.io/v1", "kind" => "RoleBinding",
            "metadata" => { "name" => WATCHDOG_SERVICE_ACCOUNT, "namespace" => config.flux_namespace },
            "subjects" => [
              {
                "kind" => "ServiceAccount",
                "name" => WATCHDOG_SERVICE_ACCOUNT,
                "namespace" => config.flux_namespace
              }
            ],
            "roleRef" => {
              "kind" => "Role",
              "name" => WATCHDOG_SERVICE_ACCOUNT,
              "apiGroup" => "rbac.authorization.k8s.io"
            }
          }
        ]
      )
    end

    def schedule_watchdog!
      kubectl.apply(
        "apiVersion" => "batch/v1",
        "kind" => "Job",
        "metadata" => {
          "name" => "syrus-flux-resume-#{Time.now.to_i}-#{Process.pid}",
          "namespace" => config.flux_namespace,
          "labels" => { "app" => WATCHDOG_SERVICE_ACCOUNT }
        },
        "spec" => {
          "ttlSecondsAfterFinished" => 60,
          "activeDeadlineSeconds" => ttl + 120,
          "backoffLimit" => 0,
          "template" => {
            "metadata" => { "labels" => { "app" => WATCHDOG_SERVICE_ACCOUNT } },
            "spec" => {
              "serviceAccountName" => WATCHDOG_SERVICE_ACCOUNT,
              "restartPolicy" => "Never",
              "securityContext" => {
                "runAsNonRoot" => true,
                "runAsUser" => 1001,
                "seccompProfile" => { "type" => "RuntimeDefault" }
              },
              "containers" => [
                {
                  "name" => "resume",
                  "image" => config.flux_watchdog_image,
                  "securityContext" => {
                    "allowPrivilegeEscalation" => false,
                    "capabilities" => { "drop" => [ "ALL" ] }
                  },
                  "command" => [ "/bin/sh", "-c" ],
                  "args" => [ watchdog_script ]
                }
              ]
            }
          }
        }
      )
    end

    def watchdog_script
      <<~SH
        sleep #{ttl}
        kubectl -n #{config.flux_namespace} patch kustomization #{config.flux_kustomization} --type merge -p '{"spec":{"suspend":false}}'
        echo "watchdog resumed kustomization/#{config.flux_kustomization}"
      SH
    end

    def kubectl = context.flux_kubectl
    def config = context.config
    def reporter = context.reporter
    def waiter = context.waiter
    def controls = context.controls
    def label = context.label
    def sha = context.sha
  end
end
