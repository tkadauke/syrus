module Steps
  # First step of the Epic merge-train. The dispatcher
  # (LandingQueueProcessor) has already created the MergeTrain + members
  # and locked the member Jobs into :landing. This step validates that
  # the train is still coherent and names the integration branch the
  # build step will create.
  class MergeTrainAssemble < Base
    include MergeTrainStep

    def call
      train = merge_train
      members = train.members.includes(:job).to_a
      raise StepFailed, "merge_train: no members to land" if members.empty?

      not_landing = members.map(&:job).reject(&:landing?)
      if not_landing.any?
        raise StepFailed, "merge_train: members not in :landing (#{not_landing.map(&:id).join(', ')})"
      end

      validate_epic_siblings!(train) if train.epic_backed?

      train.update!(integration_branch: train.default_integration_branch) if train.integration_branch.blank?

      log("merge_train: assembling #{train_label(train)} with #{members.size} member(s): #{member_summary(members)}", kind: "system")
    end

    private

    def validate_epic_siblings!(train)
      unapproved_open = train.epic.work_jobs.where.not(state: "closed").where.not(state: %w[approved landing])
      return unless unapproved_open.any?

      ids = unapproved_open.order(:id).pluck(:id)
      raise StepFailed, "merge_train: cannot assemble — #{ids.size} sibling(s) not yet approved (IDs: #{ids.join(', ')})"
    end

    def train_label(train)
      train.epic_backed? ? "Epic ##{train.epic_id}" : "job bundle ##{train.id}"
    end

    def member_summary(members)
      members.map { |m| "##{m.job.issue_number || m.job.id}" }.join(" → ")
    end
  end
end
