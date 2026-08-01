require "set"

class JobDependency < ApplicationRecord
  belongs_to :job
  belongs_to :depends_on_job, class_name: "Job", optional: true
  belongs_to :depends_on_epic, class_name: "Epic", optional: true
  belongs_to :unresolved_chat_proposal, class_name: "ChatProposal", optional: true
  belongs_to :created_by_user, class_name: "User", optional: true

  enum :source, { parsed: "parsed", manual: "manual" }, validate: true

  validate :exactly_one_target
  validate :no_self_reference
  validate :no_cycle
  validate :pending_fields_consistent
  validate :linear_chain_in_simple_mode

  after_save_commit :materialize_derived_epic_dependency, if: :depends_on_job_id?
  after_save_commit :refresh_same_epic_reconciliation, if: :same_epic_job_dependency?

  scope :resolved, -> { where.not(depends_on_job_id: nil) }
  scope :pending, -> { where(depends_on_job_id: nil, depends_on_epic_id: nil) }

  def pending?
    depends_on_job_id.nil? && depends_on_epic_id.nil?
  end

  def resolved?
    !pending?
  end

  def unresolved_slug
    return nil unless pending?
    return unresolved_chat_proposal.slug if unresolved_chat_proposal

    "#{unresolved_owner}/#{unresolved_repo}##{unresolved_number}"
  end

  def pending_reference_kind
    return nil unless pending?
    return "proposal" if unresolved_chat_proposal_id.present?

    "github_issue"
  end

  def pending_reference_state
    return nil unless pending?
    return "actionable" unless unresolved_chat_proposal
    return "actionable" if unresolved_chat_proposal.proposed?
    return "resolvable" if unresolved_chat_proposal.job_id.present?

    "orphaned"
  end

  def dependency_succeeded?
    return depends_on_epic.done? if depends_on_epic_id.present?
    return resolved_dependency_succeeded? if resolved?

    referenced_epic&.done? == true
  end

  def execution_dependency_satisfied?
    dependency_succeeded? || same_epic_dependency_ready_for_execution?
  end

  def referenced_epic
    return nil unless pending?
    return nil unless job&.user

    repository = job.user.repositories.find_by(owner: unresolved_owner, name: unresolved_repo)
    return nil unless repository

    repository.epics.find_by(github_issue_url: unresolved_github_issue_url)
  end

  # Promote a pending row to a resolved row. Caller passes the Job that
  # now exists for the previously-unresolved reference; we clear the
  # unresolved_* columns and set depends_on_job_id. Save runs the cycle
  # check against the now-real dependency.
  def resolve!(depends_on_job:)
    raise "already resolved" if resolved?

    update!(
      depends_on_job: depends_on_job,
      unresolved_chat_proposal: nil,
      unresolved_owner: nil,
      unresolved_repo: nil,
      unresolved_number: nil
    )
  end

  private

  def resolved_dependency_succeeded?
    depends_on_job.dependency_succeeded? || same_epic_dependency_approved?
  end

  def same_epic_dependency_approved?
    return false if job&.epic_id.blank?
    return false unless depends_on_job&.epic_id == job.epic_id

    depends_on_job.approved? || depends_on_job.landing?
  end

  def same_epic_dependency_ready_for_execution?
    return false if job&.epic_id.blank?
    return false unless depends_on_job&.epic_id == job.epic_id

    depends_on_job.implemented? &&
      depends_on_job.pr_number.present? &&
      depends_on_job.branch_name.present? &&
      depends_on_job.head_sha.present?
  end

  def unresolved_github_issue_url
    "https://github.com/#{unresolved_owner}/#{unresolved_repo}/issues/#{unresolved_number}"
  end

  def exactly_one_target
    target_count = [
      depends_on_job_id.present?,
      depends_on_epic_id.present?,
      unresolved_chat_proposal_id.present?,
      unresolved_reference_present?
    ].count(true)

    errors.add(:base, "must reference a Job, an Epic, or carry an unresolved reference") if target_count.zero?
    errors.add(:base, "must reference exactly one dependency target") if target_count > 1
  end

  def pending_fields_consistent
    return if unresolved_chat_proposal_id.present?
    return unless unresolved_reference_present?

    if unresolved_owner.blank? || unresolved_repo.blank? || unresolved_number.blank?
      errors.add(:base, "pending rows need owner, repo, and number")
    end
  end

  def no_self_reference
    return if depends_on_epic_id.present?
    return if job_id.blank? || depends_on_job_id.blank?

    errors.add(:depends_on_job, "can't be the same Job") if job_id == depends_on_job_id
  end

  def no_cycle
    return if depends_on_epic_id.present?
    return if job_id.blank? || depends_on_job_id.blank?
    return if job_id == depends_on_job_id

    errors.add(:depends_on_job, "would create a cycle") if reaches_job?(depends_on_job_id, job_id, Set.new)
  end

  def reaches_job?(current_id, target_id, seen)
    return true if current_id == target_id
    return false if seen.include?(current_id)

    seen << current_id
    self.class.resolved.where(job_id: current_id).pluck(:depends_on_job_id).any? do |next_id|
      reaches_job?(next_id, target_id, seen)
    end
  end

  def materialize_derived_epic_dependency
    dependent_epic = job&.epic
    upstream_epic = depends_on_job&.epic
    return if dependent_epic.blank? || upstream_epic.blank?
    return if dependent_epic == upstream_epic

    EpicDependency.find_or_create_by!(
      epic: dependent_epic,
      depends_on_epic: upstream_epic,
      derived: true
    )
  end

  def refresh_same_epic_reconciliation
    job.epic.maybe_create_reconciliation_job!(raise_on_invalid_graph: false)
  end

  def same_epic_job_dependency?
    job&.epic_id.present? && depends_on_job&.epic_id == job.epic_id
  end

  def unresolved_reference_present?
    unresolved_owner.present? || unresolved_repo.present? || unresolved_number.present?
  end

  def linear_chain_in_simple_mode
    return unless AppSetting.simple?
    return if depends_on_job_id.blank?

    # Only enforce within the same epic.
    job_epic_id = job&.epic_id
    return if job_epic_id.blank?
    return unless Job.where(id: depends_on_job_id, epic_id: job_epic_id).exists?

    # No merge: this job must not already have another dependency within the same epic.
    existing_upstream = self.class
                            .where(job_id: job_id)
                            .where.not(id: id)
                            .joins(:depends_on_job)
                            .where(jobs: { epic_id: job_epic_id })
    if existing_upstream.exists?
      errors.add(:base, "Simple mode requires features to be implemented in sequence. This job would create a parallel branch.")
      return
    end

    # No fork: the upstream job must not already have another downstream job in the same epic.
    existing_downstream = self.class
                              .where(depends_on_job_id: depends_on_job_id)
                              .where.not(job_id: job_id)
                              .joins(:job)
                              .where(jobs: { epic_id: job_epic_id })
    if existing_downstream.exists?
      errors.add(:base, "Simple mode requires features to be implemented in sequence. This job would create a parallel branch.")
    end
  end
end
