module MaintenanceTasks
  module Definitions
    class LandedCommitsBackfill < Base
      UnresolvedLandingsError = Class.new(StandardError)
      PROCESSED_REPOSITORY_IDS = "processed_repository_ids".freeze
      RETRY_UNRESOLVED_REPOSITORY_IDS = "retry_unresolved_repository_ids".freeze
      UNRESOLVED_REPOSITORIES = "unresolved_repositories".freeze

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
        candidate_repository_scope.count
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
        if result.errors.to_i.positive?
          mark_repository_unresolved(task, repository, result.errors.to_i)
        else
          clear_repository_unresolved(task, repository)
        end

        message = "Checked #{result.checked} landing(s) in #{repository.slug}; recorded #{result.commits_recorded} commit(s)."
        message += " #{result.errors} item(s) could not be backfilled; this task will fail after the current pass unless they are resolved." if result.errors.to_i.positive?

        Result.new(
          done: false,
          processed: 1,
          failed: result.errors.to_i,
          message: message,
          level: result.errors.to_i.positive? ? "warning" : "progress"
        )
      end

      private

      def next_repository(task)
        processed_ids = Array(task.checkpoint[PROCESSED_REPOSITORY_IDS]).map(&:to_i) - retry_unresolved_repository_ids(task)
        candidate_repository_scope.where.not(id: processed_ids).order(:id).first
      end

      def mark_repository_processed(task, repository)
        task.checkpoint_will_change!
        task.checkpoint[PROCESSED_REPOSITORY_IDS] = (Array(task.checkpoint[PROCESSED_REPOSITORY_IDS]) + [ repository.id ]).uniq
        task.checkpoint[RETRY_UNRESOLVED_REPOSITORY_IDS] = retry_unresolved_repository_ids(task) - [ repository.id ]
      end

      def mark_repository_unresolved(task, repository, errors)
        task.checkpoint_will_change!
        unresolved = unresolved_repositories(task).reject { |entry| entry["id"].to_i == repository.id }
        unresolved << { "id" => repository.id, "slug" => repository.slug, "errors" => errors }
        task.checkpoint[UNRESOLVED_REPOSITORIES] = unresolved
      end

      def clear_repository_unresolved(task, repository)
        unresolved = unresolved_repositories(task)
        return if unresolved.empty?

        task.checkpoint_will_change!
        task.checkpoint[UNRESOLVED_REPOSITORIES] = unresolved.reject { |entry| entry["id"].to_i == repository.id }
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
              "see checkpoint.unresolved_repositories for per-repository error counts."
      end

      def unresolved_repositories(task)
        Array(task.checkpoint[UNRESOLVED_REPOSITORIES]).filter_map do |entry|
          next unless entry.respond_to?(:to_h)

          entry.to_h.stringify_keys.slice("id", "slug", "errors")
        end
      end

      def pending_unresolved_repositories(task)
        unresolved = unresolved_repositories(task)
        return [] if unresolved.empty?

        pending_ids = candidate_repository_scope.where(id: unresolved.map { |entry| entry["id"].to_i }).pluck(:id).map(&:to_i)
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

      def candidate_repository_scope
        Repository.where(id: regular_job_repository_ids).or(
          Repository.where(id: merge_train_repository_ids)
        )
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
