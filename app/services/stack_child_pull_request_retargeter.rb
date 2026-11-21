# Points the open PRs of a landed Job's stack children at the branch the
# parent landed into, before the parent's branch is deleted.
#
# GitHub closes every open PR whose base branch is deleted, and a closed PR
# cannot be retargeted or reopened onto a missing base. StackRebaseCoordinator
# also retargets children, but only once the parent Job closes -- and a step
# handler's closure is applied when its Workflow finishes, after the step has
# already deleted the branch. Retargeting here, ahead of the delete, keeps the
# child PRs alive; the coordinator's later retarget is then a no-op.
class StackChildPullRequestRetargeter
  def self.call(...) = new(...).call

  def initialize(client:, parent:, base:, skip_job_ids: [], log: nil)
    @client = client
    @parent = parent
    @base = base
    @skip_job_ids = Array(skip_job_ids)
    @log = log
  end

  def call
    return [] if base.blank?

    children.filter_map do |child|
      client.update_pull_request_base(child.repository.slug, child.pr_number, base: base)
      log("retargeted #{child.slug} PR ##{child.pr_number} to #{base} before deleting #{parent.branch_name}")
      child
    rescue StandardError => e
      # Branch cleanup is best-effort after a landing; a failed retarget must
      # not fail the landing that already published.
      log("could not retarget #{child.slug} PR ##{child.pr_number} to #{base}: #{e.class}: #{e.message}")
      nil
    end
  end

  private

  attr_reader :client, :parent, :base, :skip_job_ids

  def children
    parent.stack_children
      .where.not(pr_number: nil)
      .where.not(id: skip_job_ids)
      .includes(:repository)
      .reject(&:closed?)
  end

  def log(message)
    @log ? @log.call(message) : Rails.logger.info("[StackChildPullRequestRetargeter] #{message}")
  end
end
