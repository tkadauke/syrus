module MaintenanceTasks
  module Definitions
    class BareCloneRemoteScrub < Base
      key "bare_clone_remote_scrub"
      title "Scrub bare clone remote credentials"
      summary "Rewrites credential-bearing origin URLs from historical local bare-clone configs."
      category "cleanup"
      recurrence "one_off"
      required_role "admin"
      concurrency_key "bare_clone_remote_scrub"
      batch_size 100
      max_parallelism 1
      documentation_path Rails.root.join("app/services/maintenance_tasks/docs/bare_clone_remote_scrub.md")

      step "clone_configs", "Scrub bare clone configs", "Rewrites repository-backed clone remotes to anonymous URLs and removes orphaned credentialed remotes."

      def estimate_total_units
        scrubber.credentialed_remote_count
      end

      def pending_reason
        "#{estimate_total_units} bare clone config(s) have credential-bearing origin URLs."
      end

      def perform_batch(task)
        task.current_step_key = "clone_configs"
        task.current_step_title = "Scrub bare clone configs"

        result = scrubber.scrub_batch(limit: task.batch_size)
        message = "Checked #{result.processed} credentialed bare clone config(s); " \
                  "rewrote #{result.scrubbed}, removed #{result.removed} orphaned remote(s)."
        message += " #{result.failed} config(s) failed to update." if result.failed.positive?

        Result.new(
          done: result.done || result.failed.positive?,
          processed: result.processed,
          failed: result.failed,
          message: message,
          level: result.failed.positive? ? "warning" : "progress"
        )
      end

      private

      def scrubber
        RepositoryBareCloneRemoteScrubber.new
      end
    end
  end
end
