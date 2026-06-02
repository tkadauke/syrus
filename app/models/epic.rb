class Epic < ApplicationRecord
  include AASM
  include AutoApproveModes

  BOARD_STATES = %w[ backlog ready in_progress done ].freeze
  ARCHIVED_STATE = "archived"
  STATES = (BOARD_STATES + [ ARCHIVED_STATE ]).freeze
  MERGED_JOB_CLOSURE_REASONS = %w[ pr_merged external_pr_merged ].freeze

  attr_readonly :number

  belongs_to :user
  belongs_to :owner, class_name: "User", optional: true, inverse_of: :owned_epics
  belongs_to :repository
  belongs_to :owner_user, class_name: "User", optional: true, inverse_of: :dashboard_owned_epics
  has_many :jobs, dependent: :nullify
  has_many :dependencies,
           class_name: "EpicDependency",
           dependent: :destroy,
           inverse_of: :epic
  has_many :depends_on_epics, through: :dependencies, source: :depends_on_epic
  has_many :dependent_links,
           class_name: "EpicDependency",
           foreign_key: :depends_on_epic_id,
           dependent: :destroy,
           inverse_of: :depends_on_epic
  has_many :dependent_epics, through: :dependent_links, source: :epic

  validates :number, presence: true, numericality: { only_integer: true, greater_than: 0 }, uniqueness: true
  validates :title, presence: true
  validates :state, presence: true, inclusion: { in: STATES }
  validate :repository_belongs_to_user

  scope :claimed, -> { where.not(owner_user_id: nil) }
  scope :unclaimed, -> { where(owner_user_id: nil) }
  scope :owned_by, ->(user) { where(owner_user_id: user&.id) }
  scope :other_owned_by, ->(user) { claimed.where.not(owner_user_id: user&.id) }

  after_initialize :default_pending_epic_dependency_refs
  before_validation :assign_number, on: :create
  after_create :resolve_pending_child_jobs
  after_create :seed_parsed_epic_dependencies
  after_create :resolve_pending_epic_dependencies_targeting_self
  after_create_commit :broadcast_app_epic_created
  after_update_commit :broadcast_app_epic_updated

  scope :claimed, -> { where("owner_id IS NOT NULL OR owner_user_id IS NOT NULL") }
  scope :unclaimed, -> { where(owner_id: nil, owner_user_id: nil) }
  scope :owned_by, ->(user) { where("owner_id = :user_id OR owner_user_id = :user_id", user_id: user&.id) }
  scope :other_owned_by, ->(user) {
    where("(owner_id IS NOT NULL AND owner_id != :user_id) OR (owner_user_id IS NOT NULL AND owner_user_id != :user_id)", user_id: user&.id)
  }

  aasm column: :state, whiny_transitions: false do
    state :backlog, initial: true
    state :ready, :in_progress, :done, :archived

    event :auto_ready do
      transitions from: :backlog, to: :ready, guard: :ready_to_start?
    end

    event :move_to_backlog do
      transitions from: :ready, to: :backlog
    end

    event :start do
      transitions from: :ready, to: :in_progress, after: -> {
        self.state = "in_progress"
        claim!(user, force: true) unless claimed?
        unblock_child_jobs!
      }
    end

    event :unstart do
      transitions from: :in_progress, to: :ready, after: -> {
        self.state = "ready"
        restore_child_epic_blocks!
      }
    end

    event :auto_complete do
      transitions from: :in_progress, to: :done, guard: :complete?, after: :stamp_done_at
    end

    event :archive do
      transitions from: %i[backlog ready in_progress done], to: :archived, after: -> {
        self.state = "archived"
        self.archived_at = Time.current
        restore_child_epic_blocks!
      }
    end
  end

  def display_number
    "EPIC-#{number}"
  end

  def claimed?
    owner_id.present? || owner_user_id.present?
  end

  def claimable?
    backlog? || ready?
  end

  def claimed_by?(claimant)
    claimant_id = claimant&.id
    owner_id == claimant_id || owner_user_id == claimant_id
  end

  def claim!(claimant, force: false)
    raise ArgumentError, "claimant is required" unless claimant
    raise ArgumentError, "Epic cannot be claimed from #{state}" unless claimable? || force
    raise ArgumentError, "Epic is already claimed" if claimed? && !claimed_by?(claimant) && !force

    assign_owner!(claimant)
  end

  def unclaim!(claimant: nil, force: false)
    raise ArgumentError, "Epic cannot be unclaimed from #{state}" unless claimable? || force
    raise ArgumentError, "Epic is claimed by another user" if claimant && !claimed_by?(claimant) && !force

    transaction do
      update!(owner: nil, owner_user: nil, claimed_at: nil)
    end
  end

  def reassign!(new_owner, actor: nil)
    raise ArgumentError, "owner is required" unless new_owner
    raise ArgumentError, "Epic cannot be reassigned from #{state}" unless claimable? || in_progress?

    assign_owner!(new_owner)
  end

  def releases_jobs_for_execution?
    @releasing_jobs_for_execution || in_progress? || done?
  end

  def in_progress!
    override_state!("in_progress")
  end

  def ready_to_start?
    jobs.exists? && dependencies_done? && child_jobs_confirmed?
  end

  def complete?
    child_jobs = jobs.reload
    child_jobs.any? && child_jobs.all? { |job| job.closed? && MERGED_JOB_CLOSURE_REASONS.include?(job.closure_reason) }
  end

  def refresh_auto_state!
    if backlog? && may_auto_ready?
      auto_ready!
    elsif in_progress? && may_auto_complete?
      auto_complete!
    else
      false
    end
  end

  # Operator escape hatch for the card menu. This intentionally bypasses
  # the AASM graph while preserving side effects that matter to execution.
  def override_state!(target_state)
    target_state = target_state.to_s
    raise ArgumentError, "unknown Epic state: #{target_state}" unless STATES.include?(target_state)

    transaction do
      was_in_progress = in_progress?
      update!(
        state: target_state,
        done_at: target_state == "done" ? Time.current : nil,
        archived_at: target_state == "archived" ? Time.current : nil
      )
      if target_state == "in_progress"
        claim!(user, force: true) unless claimed?
        unblock_child_jobs!
      elsif (was_in_progress && %w[backlog ready].include?(target_state)) || target_state == "archived"
        restore_child_epic_blocks!
      end
    end
  end

  def in_progress!
    override_state!("in_progress")
  end

  def unblock_child_jobs!
    @releasing_jobs_for_execution = true
    begin
      jobs.find_each do |job|
        job.epic = self
        if job.blocked_by_epic? && job.may_release_epic_block?
          job.release_epic_block!
          # release_epic_block!'s after-callback (create_initial_run_if_needed)
          # bails when a workflow already exists, leaving any queued
          # workflow without a Run. Explicitly start pending workflows
          # so the chain actually advances.
          job.start_pending_workflows_if_dependencies_satisfied!
        else
          job.start_pending_workflows_if_dependencies_satisfied!
        end
      end
    ensure
      @releasing_jobs_for_execution = false
    end
  end

  def claim_child_jobs_to_owner!
    effective_owner_id = owner_id || owner_user_id
    return unless effective_owner_id

    jobs.includes(:repository).find_each do |job|
      next unless job.repository.user_id == effective_owner_id
      next if job.user_id == effective_owner_id

      job.update!(user: owner || owner_user)
    end
  end

  def restore_child_epic_blocks!
    jobs.find_each do |job|
      job.epic = self
      job.restore_epic_block_if_not_started!
    end
  end

  private

  def broadcast_app_epic_created
    broadcast_app_epic_event("created")
  end

  def broadcast_app_epic_updated
    broadcast_app_epic_event("updated")
  end

  def broadcast_app_epic_event(action)
    return unless user

    event = {
      type: "epic.updated",
      resource: "epic",
      id: id,
      changed: [ "epic.#{action}", *previous_changes.keys.map(&:to_s) ].uniq,
      occurred_at: Time.current.iso8601(3)
    }

    AppUserChannel.broadcast_to(user, event.as_json)
  end

  def assign_number
    self.number ||= (self.class.maximum(:number) || 0) + 1
  end

  def default_pending_epic_dependency_refs
    self.pending_epic_dependency_refs ||= []
  end

  def repository_belongs_to_user
    return unless repository && user
    return if repository.user_id == user_id

    errors.add(:repository, "must belong to the same user")
  end

  def dependencies_done?
    depends_on_epics.all?(&:done?)
  end

  def child_jobs_confirmed?
    jobs.where(state: "triaging").none?
  end

  def stamp_done_at
    self.done_at = Time.current
  end

  def assign_owner!(new_owner)
    transaction do
      update!(owner: new_owner, owner_user: new_owner, claimed_at: Time.current)
      claim_child_jobs_to_owner!
    end
  end

  def resolve_pending_child_jobs
    return if github_issue_url.blank?

    user.jobs
        .triaging
        .where(triaging_reason: "pending_epic_ref")
        .find_each do |job|
      job.resolve_pending_epic_ref!(self)
    end
  end

  def seed_parsed_epic_dependencies
    text = description.to_s
    return if text.blank?

    pending_refs = pending_epic_dependency_refs.to_a.map(&:to_h)

    JobDependencyParser.parse(text: text, default_repository: repository).each do |reference|
      if (target_epic = epic_for_dependency_reference(reference))
        create_parsed_epic_dependency!(target_epic, reference)
      else
        pending_ref = pending_epic_dependency_ref(reference)
        next if pending_refs.any? { |ref| ref.slice("owner", "repo", "number") == pending_ref.slice("owner", "repo", "number") }

        pending_refs << pending_ref
        Rails.logger.info(
          "[EpicDependency] epic ##{id}: Depends-on: " \
          "#{reference.owner}/#{reference.repo}##{reference.number} - " \
          "no Syrus Epic exists yet; recorded as pending"
        )
      end
    end

    update!(pending_epic_dependency_refs: pending_refs) if pending_refs != pending_epic_dependency_refs
  end

  def resolve_pending_epic_dependencies_targeting_self
    return if github_issue_url.blank?

    user.epics.where.not(id: id).find_each do |dependent_epic|
      pending_refs = dependent_epic.pending_epic_dependency_refs.to_a.map(&:to_h)
      matches, remaining = pending_refs.partition { |ref| pending_epic_dependency_ref_targets_self?(ref) }
      next if matches.empty?

      matches.each do |reference|
        dependent_epic.send(:create_parsed_epic_dependency!, self, reference)
      end
      dependent_epic.update!(pending_epic_dependency_refs: remaining)
    end
  end

  def epic_for_dependency_reference(reference)
    referenced_repository = user.repositories.find_by(owner: reference.owner, name: reference.repo)
    return unless referenced_repository

    referenced_repository.epics.find_by(github_issue_url: github_issue_url_for(reference))
  end

  def create_parsed_epic_dependency!(target_epic, reference)
    dependencies.find_or_create_by!(depends_on_epic: target_epic, derived: false)
  rescue ActiveRecord::RecordInvalid => e
    message = "[EpicDependency] epic ##{id}: rejected parsed Depends-on: " \
              "#{reference_slug(reference)} - #{e.record.errors.full_messages.to_sentence}"
    Rails.logger.warn(message)
  rescue ActiveRecord::RecordNotUnique => e
    Rails.logger.warn(
      "[EpicDependency] epic ##{id}: duplicate parsed Depends-on: " \
      "#{reference_slug(reference)} - #{e.message}"
    )
  end

  def pending_epic_dependency_ref(reference)
    {
      "owner" => reference.owner,
      "repo" => reference.repo,
      "number" => reference.number,
      "github_issue_url" => github_issue_url_for(reference)
    }
  end

  def pending_epic_dependency_ref_targets_self?(reference)
    reference.to_h["github_issue_url"] == github_issue_url
  end

  def github_issue_url_for(reference)
    "https://github.com/#{reference.owner}/#{reference.repo}/issues/#{reference.number}"
  end

  def reference_slug(reference)
    if reference.respond_to?(:owner)
      "#{reference.owner}/#{reference.repo}##{reference.number}"
    else
      "#{reference["owner"]}/#{reference["repo"]}##{reference["number"]}"
    end
  end
end
