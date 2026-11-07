# frozen_string_literal: true

module Deploy
  # Give every worker a per-node mise cache on a hostPath.
  #
  # The worker-dev image ships mise and a multi-language toolchain, and each
  # worker would otherwise re-resolve and re-download runtimes into its own
  # ephemeral filesystem on every restart. One directory per node, shared by
  # whatever worker pod currently runs there, turns that into a first-boot
  # cost.
  #
  # `fsGroup` with `OnRootMismatch` is what makes the shared directory usable:
  # the worker runs as uid 1000, and without the group ownership fix a cache
  # written by a previous pod is unreadable by the next one. `OnRootMismatch`
  # rather than `Always` because recursively re-chowning a populated cache on
  # every pod start is exactly the multi-minute startup this cache exists to
  # avoid.
  class MiseCache
    WORKLOADS = [ %w[deployment syrus-worker-home], %w[daemonset syrus-worker-compute] ].freeze

    attr_reader :context

    def initialize(context)
      @context = context
    end

    def apply!
      reporter.step("#{label}: applying per-node mise cache worker mounts")
      WORKLOADS.each { |kind, name| patch(kind, name) }
    end

    private

    def patch(kind, name)
      return unless kubectl.exists?(kind, name)

      kubectl.patch(kind, name, type: "strategic", patch: {
        "spec" => {
          "template" => {
            "spec" => {
              "securityContext" => { "fsGroup" => 1000, "fsGroupChangePolicy" => "OnRootMismatch" },
              "containers" => [
                {
                  "name" => "syrus-worker",
                  "volumeMounts" => [
                    { "name" => "syrus-mise-cache", "mountPath" => "/opt/mise", "readOnly" => false }
                  ]
                }
              ],
              "volumes" => [
                {
                  "name" => "syrus-mise-cache",
                  "hostPath" => { "path" => config.mise_cache_host_path, "type" => "DirectoryOrCreate" }
                }
              ]
            }
          }
        }
      })
    end

    def kubectl = context.kubectl
    def config = context.config
    def reporter = context.reporter
    def label = context.label
  end
end
