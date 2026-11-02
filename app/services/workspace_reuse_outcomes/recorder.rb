module WorkspaceReuseOutcomes
  class Recorder
    class << self
      def record(run:, kind:, outcome:, **attributes)
        return unless run&.step&.workflow&.job&.repository

        attributes = attributes.merge(yield) if block_given?

        WorkspaceReuseOutcome.create!(
          repository: run.job.repository,
          workflow: run.workflow,
          step: run.step,
          run: run,
          kind: kind,
          outcome: outcome,
          backend: backend_identity(run),
          occurred_at: Time.current,
          **attributes.compact
        )
      rescue StandardError => error
        Rails.logger.warn(
          "[WorkspaceReuseOutcomes::Recorder] recording failed: #{error.class}: #{error.message}"
        )
        nil
      end

      # Execution routing happens before an outcome may be known. Keep the
      # selected backend on this in-memory Run instance so recording does not
      # add a database write to every command invocation.
      def note_backend(run:, backend:)
        return unless run

        run.instance_variable_set(:@workspace_reuse_backend_identity, backend)
      end

      private

      def backend_identity(run)
        noted = run.instance_variable_get(:@workspace_reuse_backend_identity)
        return noted if noted.present?

        backend = ProcessRunner.backend
        return "local" if backend.is_a?(Execution::Router) || backend.is_a?(Execution::Local)

        backend.class.name.to_s.underscore.presence || "custom"
      end
    end
  end
end
