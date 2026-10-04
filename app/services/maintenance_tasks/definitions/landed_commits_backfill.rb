module MaintenanceTasks
  module Definitions
    class LandedCommitsBackfill < Base
      UnresolvedLandingsError = Class.new(StandardError)
      PROCESSED_REPOSITORY_IDS = "processed_repository_ids".freeze
      RETRY_UNRESOLVED_REPOSITORY_IDS = "retry_unresolved_repository_ids".freeze
      UNRESOLVED_REPOSITORIES = "unresolved_repositories".freeze
      IRRECOVERABLE_REPOSITORIES = "irrecoverable_repositories".freeze
      MAX_FAILURE_DETAILS_PER_REPOSITORY = 25
      MAX_FAILURE_MESSAGE_LENGTH = 240

      key "landed_commits_backfill"
      title "Backfill landed commit records"
      summary "Records historical landed commits so repository history can attribute old Syrus landings accurately."
      category "backfill"
      recurrence "one_off"
      required_role "admin"
      concurrency_key "landed_commits_backfill"
      batch_size 1
      max_parallelism 1
      documentation_path Rails.root.join("app/services/maintenance_tasks/docs/landed_commits_backfill.md")

      step "repository", "Backfill one repository", "Synchronizes the repository's bare clone and records missing LandedCommit rows for historical job and merge-train landings."

      def estimate_total_units
        pending_repository_scope.count
      end

      def pending_reason
        "#{estimate_total_units} repository/repositories have historical landings without landed commit records."
      end

      def perform_batch(task)
        repository = next_repository(task)
        return complete_or_fail_unresolved!(task) unless repository

        task.current_step_key = "repository"
        task.current_step_title = "Backfill #{repository.slug}"

        result = Jobs::LandedCommitsBackfill.new(repository: repository).call
        mark_repository_processed(task, repository)
        retryable_errors = retryable_error_count(result)
        irrecoverable_errors = irrecoverable_error_count(result)

        if retryable_errors.positive?
          unresolved_entry = mark_repository_unresolved(task, repository, result)
        else
          clear_repository_unresolved(task, repository)
        end
        irrecoverable_entry = if irrecoverable_errors.positive?
          mark_repository_irrecoverable(task, repository, result)
        else
          clear_repository_irrecoverable(task, repository)
          nil
        end

        message = "Checked #{result.checked} landing(s) in #{repository.slug}; recorded #{result.commits_recorded} commit(s)."
        message += " #{retryable_errors} item(s) could not be backfilled; this task will fail after the current pass unless they are resolved." if retryable_errors.positive?
        message += " #{irrecoverable_errors} historical item(s) were classified as irrecoverable and skipped." if irrecoverable_errors.positive?

        metadata = {}
        metadata[UNRESOLVED_REPOSITORIES] = [ unresolved_entry ] if unresolved_entry
        metadata[IRRECOVERABLE_REPOSITORIES] = [ irrecoverable_entry ] if irrecoverable_entry

        Result.new(
          done: false,
          processed: 1,
          failed: retryable_errors,
          message: message,
          level: result.errors.to_i.positive? ? "warning" : "progress",
          metadata: metadata
        )
      end

      private

      def next_repository(task)
        processed_ids = Array(task.checkpoint[PROCESSED_REPOSITORY_IDS]).map(&:to_i) - retry_unresolved_repository_ids(task)
        pending_repository_scope.where.not(id: processed_ids).order(:id).first
      end

      def mark_repository_processed(task, repository)
        task.checkpoint_will_change!
        task.checkpoint[PROCESSED_REPOSITORY_IDS] = (Array(task.checkpoint[PROCESSED_REPOSITORY_IDS]) + [ repository.id ]).uniq
        task.checkpoint[RETRY_UNRESOLVED_REPOSITORY_IDS] = retry_unresolved_repository_ids(task) - [ repository.id ]
      end

      def mark_repository_unresolved(task, repository, result)
        task.checkpoint_will_change!
        unresolved = unresolved_repositories(task).reject { |entry| entry["id"].to_i == repository.id }
        entry = repository_failure_entry(repository, result, retryable: true)
        unresolved << entry
        task.checkpoint[UNRESOLVED_REPOSITORIES] = unresolved
        entry
      end

      def clear_repository_unresolved(task, repository)
        unresolved = unresolved_repositories(task)
        return if unresolved.empty?

        task.checkpoint_will_change!
        task.checkpoint[UNRESOLVED_REPOSITORIES] = unresolved.reject { |entry| entry["id"].to_i == repository.id }
      end

      def mark_repository_irrecoverable(task, repository, result)
        task.checkpoint_will_change!
        irrecoverable = irrecoverable_repositories(task).reject { |entry| entry["id"].to_i == repository.id }
        entry = repository_failure_entry(repository, result, retryable: false)
        irrecoverable << entry
        task.checkpoint[IRRECOVERABLE_REPOSITORIES] = irrecoverable
        entry
      end

      def clear_repository_irrecoverable(task, repository)
        irrecoverable = irrecoverable_repositories(task)
        return if irrecoverable.empty?

        task.checkpoint_will_change!
        task.checkpoint[IRRECOVERABLE_REPOSITORIES] = irrecoverable.reject { |entry| entry["id"].to_i == repository.id }
      end

      def complete_or_fail_unresolved!(task)
        unresolved = pending_unresolved_repositories(task)
        if unresolved.empty?
          task.checkpoint_will_change!
          task.checkpoint[UNRESOLVED_REPOSITORIES] = []
          task.checkpoint.delete(RETRY_UNRESOLVED_REPOSITORY_IDS)
          return Result.new(done: true, processed: 0, failed: 0, message: "Landed commit backfill is complete.", level: "info")
        end

        task.checkpoint_will_change!
        task.checkpoint[RETRY_UNRESOLVED_REPOSITORY_IDS] = unresolved.map { |entry| entry["id"].to_i }.uniq
        task.save! if task.persisted?
        slugs = unresolved.map { |entry| entry["slug"].presence || "repository ##{entry["id"]}" }
        raise UnresolvedLandingsError,
              "Landed commit backfill left unresolved historical landings in #{slugs.to_sentence}; " \
              "see checkpoint.unresolved_repositories for per-landing failure details."
      end

      def unresolved_repositories(task)
        repository_failure_entries(task, UNRESOLVED_REPOSITORIES)
      end

      def irrecoverable_repositories(task)
        repository_failure_entries(task, IRRECOVERABLE_REPOSITORIES)
      end

      def repository_failure_entries(task, key)
        Array(task.checkpoint[key]).filter_map do |entry|
          next unless entry.respond_to?(:to_h)

          normalized = entry.to_h.stringify_keys.slice("id", "slug", "errors", "failure_details", "failure_details_omitted")
          normalized["failure_details"] = normalize_failure_details(normalized["failure_details"])
          normalized["failure_details_omitted"] = normalized["failure_details_omitted"].to_i
          normalized
        end
      end

      def pending_unresolved_repositories(task)
        unresolved = unresolved_repositories(task)
        return [] if unresolved.empty?

        pending_ids = pending_repository_scope.where(id: unresolved.map { |entry| entry["id"].to_i }).pluck(:id).map(&:to_i)
        pending = unresolved.select { |entry| pending_ids.include?(entry["id"].to_i) }
        if pending.size != unresolved.size
          task.checkpoint_will_change!
          task.checkpoint[UNRESOLVED_REPOSITORIES] = pending
        end
        pending
      end

      def retry_unresolved_repository_ids(task)
        Array(task.checkpoint[RETRY_UNRESOLVED_REPOSITORY_IDS]).map(&:to_i)
      end

      def repository_failure_entry(repository, result, retryable:)
        failures = Array(result.failures).select { |failure| failure_retryable?(failure) == retryable }
        details = normalize_failure_details(failures)
        error_count = failures.empty? && retryable ? result.errors.to_i : failures.size
        {
          "id" => repository.id,
          "slug" => repository.slug,
          "errors" => error_count,
          "failure_details" => details,
          "failure_details_omitted" => [ error_count - details.size, 0 ].max
        }
      end

      def normalize_failure_details(failures)
        Array(failures).first(MAX_FAILURE_DETAILS_PER_REPOSITORY).filter_map do |failure|
          attrs = failure.respond_to?(:to_h) ? failure.to_h : failure
          next unless attrs.respond_to?(:to_h)

          attrs.to_h.stringify_keys.slice(
            "repository_slug", "landable_type", "landable_id", "landable_slug", "exception_class", "message"
          ).tap do |entry|
            entry["message"] = entry["message"].to_s.truncate(MAX_FAILURE_MESSAGE_LENGTH, omission: "...") if entry["message"].present?
          end.compact
        end
      end

      def candidate_repository_scope
        Repository.where(id: regular_job_repository_ids).or(
          Repository.where(id: merge_train_repository_ids)
        )
      end

      def pending_repository_scope
        ids = irrecoverable_repository_ids
        return candidate_repository_scope if ids.empty?

        candidate_repository_scope.where.not(id: ids)
      end

      def irrecoverable_repository_ids
        task = MaintenanceTask.where(definition_key: key, recurrence: "one_off").order(created_at: :desc, id: :desc).first
        return [] unless task

        irrecoverable_repositories(task).map { |entry| entry["id"].to_i }.uniq
      end

      def retryable_error_count(result)
        return result.retryable_errors if result.respond_to?(:retryable_errors)

        Array(result.failures).count { |failure| failure_retryable?(failure) }
      end

      def irrecoverable_error_count(result)
        return result.irrecoverable_errors if result.respond_to?(:irrecoverable_errors)

        Array(result.failures).count { |failure| !failure_retryable?(failure) }
      end

      def failure_retryable?(failure)
        attrs = failure.respond_to?(:to_h) ? failure.to_h : failure
        return true unless attrs.respond_to?(:to_h)

        attrs.to_h.stringify_keys.fetch("retryable", true)
      end

      def regular_job_repository_ids
        Job.where.not(landed_sha: nil)
           .where.not(kind: "external_pr")
           .where.not(id: MergeTrainMember.select(:job_id))
           .where.not(
             id: LandedCommit.where(landable_type: "Job").select(:landable_id)
           )
           .select(:repository_id)
      end

      def merge_train_repository_ids
        MergeTrain.where(state: "succeeded")
                  .where.not(integration_sha: nil)
                  .where(<<~SQL.squish)
                    NOT EXISTS (
                      SELECT 1
                      FROM landed_commits
                      WHERE landed_commits.sha = merge_trains.integration_sha
                        AND (
                          (
                            merge_trains.epic_id IS NOT NULL
                            AND landed_commits.landable_type = 'Epic'
                            AND landed_commits.landable_id = merge_trains.epic_id
                          )
                          OR (
                            merge_trains.epic_id IS NULL
                            AND landed_commits.landable_type = 'MergeTrain'
                            AND landed_commits.landable_id = merge_trains.id
                          )
                        )
                    )
                  SQL
                  .select(:repository_id)
      end
    end
  end
end
