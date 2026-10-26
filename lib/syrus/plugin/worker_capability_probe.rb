module Syrus
  module Plugin
    # Contributes worker capability probes for a toolchain or runtime core knows
    # nothing about. A probe is a command whose success means "this worker can
    # run work that requires this capability"; RunQueueResolver then matches it
    # against the requirements graders and Jobs declare.
    #
    # Implementations own the knowledge of where their tooling lives. Core only
    # knows how to run a command and record the answer, which is why the Android
    # SDK's root and layout live in the Android plugin rather than here.
    #
    # Two constraints worth knowing before writing one:
    #
    # - Probes run with an EMPTY environment, and the sandbox supplies a bare
    #   `/usr/local/bin:/usr/bin:/bin:...` PATH. Anything a worker image adds
    #   through `ENV PATH` is invisible, so give an absolute path, not a bare
    #   command name. A probe that cannot find its tool looks exactly like a
    #   worker that does not have it.
    # - Probes run on every fresh worker process under a short timeout. Prefer a
    #   native binary over anything that starts a VM.
    module WorkerCapabilityProbe
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        # => [{ dimension:, token:, command: [...], diagnostic_key: nil }]
        #
        # `dimension` must be one of TargetGraph::ExecutionCapabilities::DIMENSIONS;
        # anything else is ignored rather than raising, so a plugin built against
        # a newer core cannot stop a worker from starting.
        def capability_probes(env: ENV)
          raise NotImplementedError, "#{name} must implement .capability_probes"
        end
      end
    end
  end
end
