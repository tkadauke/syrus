module WorkspaceReuseOutcomes
  class Recorder
    class << self
      def record(run:, kind:, outcome:, **attributes)
        return unless run&.step&.workflow&.job&.repository

        WorkspaceReuseOutcome.create!(
          repository: run.job.repository,
          workflow: run.workflow,
          step: run.step,
          run: run,
          kind: kind,
          outcome: outcome,
          backend: backend_identity,
          occurred_at: Time.current,
          **attributes.compact
        )
      rescue StandardError => error
        Rails.logger.warn(
          "[WorkspaceReuseOutcomes::Recorder] recording failed: #{error.class}: #{error.message}"
        )
        nil
      end

      def record_backend(run:, backend:)
        return unless run

        WorkspaceReuseOutcome.where(run: run).update_all(backend: backend)
      rescue StandardError => error
        Rails.logger.warn(
          "[WorkspaceReuseOutcomes::Recorder] backend recording failed: #{error.class}: #{error.message}"
        )
        nil
      end

      private

      def backend_identity
        backend = ProcessRunner.backend
        return "local" if backend.is_a?(Execution::Router) || backend.is_a?(Execution::Local)

        backend.class.name.to_s.underscore.presence || "custom"
      end
    end
  end
end
