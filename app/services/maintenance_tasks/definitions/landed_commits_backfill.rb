module MaintenanceTasks
  module Definitions
    class LandedCommitsBackfill < Base
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
        return Result.new(done: true, processed: 0, failed: 0, message: "Landed commit backfill is complete.", level: "info") unless repository

        task.current_step_key = "repository"
        task.current_step_title = "Backfill #{repository.slug}"

        result = Jobs::LandedCommitsBackfill.new(repository: repository).call
        mark_repository_processed(task, repository)

        message = "Checked #{result.checked} landing(s) in #{repository.slug}; recorded #{result.commits_recorded} commit(s)."
        message += " #{result.errors} item(s) could not be backfilled and were left for a future run." if result.errors.to_i.positive?

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
        processed_ids = Array(task.checkpoint["processed_repository_ids"]).map(&:to_i)
        candidate_repository_scope.where.not(id: processed_ids).order(:id).first
      end

      def mark_repository_processed(task, repository)
        task.checkpoint_will_change!
        task.checkpoint["processed_repository_ids"] = (Array(task.checkpoint["processed_repository_ids"]) + [ repository.id ]).uniq
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
