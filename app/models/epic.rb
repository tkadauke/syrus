class Epic < ApplicationRecord
  include AASM
  include AutoApproveModes

  # Raised by #start_implementing! when the Epic cannot move to
  # :in_progress (already running/finished, claimed by someone else,
  # or the actor is a product owner). Carries an operator-facing message.
  class NotStartable < StandardError; end

  BOARD_STATES = %w[ backlog ready in_progress done ].freeze
  ARCHIVED_STATE = "archived"
  STATES = (BOARD_STATES + [ ARCHIVED_STATE ]).freeze
  MERGED_JOB_CLOSURE_REASONS = %w[ pr_merged external_pr_merged ].freeze
  SUCCESSFUL_JOB_CLOSURE_REASONS = (MERGED_JOB_CLOSURE_REASONS + %w[ no_changes ]).freeze
  RECONCILIATION_MODES = %w[ pr feedback none ].freeze

  attr_readonly :number

  belongs_to :user
  belongs_to :owner, class_name: "User", optional: true, inverse_of: :owned_epics
  belongs_to :repository
  belongs_to :owner_user, class_name: "User", optional: true, inverse_of: :dashboard_owned_epics
  belongs_to :reconciliation_job, class_name: "Job", optional: true
  has_many :jobs, dependent: :nullify
  has_many :chat_proposals, dependent: :nullify
  has_many :versions, class_name: "EpicVersion", dependent: :destroy, inverse_of: :epic
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
  validate :user_is_repository_member

  after_initialize :default_pending_epic_dependency_refs
  before_validation :assign_number, on: :create
  before_create :generate_slug
  after_create :resolve_pending_child_jobs
  after_create :seed_parsed_epic_dependencies
  after_create :resolve_pending_epic_dependencies_targeting_self
  after_create_commit :enqueue_search_index_after_create
  after_create_commit :broadcast_app_epic_created
  after_update_commit :sync_job_epic_titles, if: :saved_change_to_title?
  after_update_commit :record_version, if: :title_or_description_changed?
  after_update_commit :enqueue_search_index_after_update
  after_update_commit :broadcast_app_epic_updated
  after_update_commit :refresh_dependent_epic_auto_states, if: :saved_change_to_state?
  before_destroy :clear_job_epic_titles

  scope :claimed, -> { where("owner_id IS NOT NULL OR owner_user_id IS NOT NULL") }
  scope :unclaimed, -> { where(owner_id: nil, owner_user_id: nil) }
  scope :owned_by, ->(user) { where("owner_id = :user_id OR owner_user_id = :user_id", user_id: user&.id) }
  scope :other_owned_by, ->(user) {
    where("(owner_id IS NOT NULL AND owner_id != :user_id) OR (owner_user_id IS NOT NULL AND owner_user_id != :user_id)", user_id: user&.id)
  }
  # Epics visible to a user: any epic on a repository they're a member of,
  # plus epics on upstream repositories of any repository they're a member of.
  scope :accessible_to, ->(user) {
    member_repo_ids = RepositoryMembership.where(user: user).select(:repository_id)
    upstream_ids = Repository.where(id: member_repo_ids).where.not(upstream_repository_id: nil).select(:upstream_repository_id)
    where(repository_id: member_repo_ids).or(where(repository_id: upstream_ids))
  }

  aasm column: :state, whiny_transitions: false do
    state :backlog, initial: true
    state :ready, :in_progress, :done, :archived

    event :auto_ready do
      transitions from: :backlog, to: :ready, guards: [ :ready_to_start?, :actor_can_advance? ]
    end

    event :move_to_backlog do
      transitions from: :ready, to: :backlog
    end

    event :start do
      transitions from: :ready, to: :in_progress, guard: :actor_can_advance?, after: ->(actor: nil, user: nil) {
        self.state = "in_progress"
        claim!(actor || user || self.user, force: true) unless claimed?
        unblock_child_jobs!
        maybe_create_reconciliation_job!
      }
    end

    event :unstart do
      transitions from: :in_progress, to: :ready, after: -> {
        self.state = "ready"
        restore_child_epic_blocks!
      }
    end

    event :auto_complete do
      transitions from: :in_progress, to: :done, guards: [ :complete?, :actor_can_advance? ], after: -> {
        stamp_done_at
        notify_epic_completed
      }
    end

    event :archive do
      transitions from: %i[backlog ready in_progress done], to: :archived, after: -> {
        self.state = "archived"
        self.archived_at = Time.current
        close_child_jobs_on_archive!
      }
    end
  end

  def slug
    App::Presentation.epic_slug(self)
  end

  alias_method :display_number, :slug

  def notify_epic_completed
    jobs.includes(:owner_user, :user).map { |job| job.owner_user || job.user }.uniq.each do |owner|
      NotificationService.create_for(
        user: owner,
        kind: "epic_completed",
        body: "Epic \"#{title}\" completed"
      )
    end
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
    @releasing_jobs_for_execution || ((in_progress? || done?) && dependencies_done?)
  end

  def sync_job_epic_titles
    jobs.update_all(epic_title: title)
  end

  def title_or_description_changed?
    saved_change_to_title? || saved_change_to_description?
  end

  def record_version
    title_change = saved_change_to_title
    description_change = saved_change_to_description

    versions.create!(
      user: Current.user,
      title_before: title_change&.first,
      title_after: title_change&.last,
      description_before: description_change&.first,
      description_after: description_change&.last
    )
  end

  def clear_job_epic_titles
    jobs.update_all(epic_title: nil)
  end

  def ready_to_start?
    jobs.exists? && dependencies_done? && child_jobs_confirmed?
  end

  def actor_can_advance?(actor: nil, user: nil)
    !epic_advancement_actor(actor || user)&.product_owner?
  end

  # Returns an AR relation for work jobs — all child jobs except the
  # reconciliation job itself. Used by complete?, stuck?, and all_jobs_closed?
  # so those predicates evaluate only the actual feature jobs.
  def work_jobs
    reconciliation_job_id.present? ? jobs.where.not(id: reconciliation_job_id) : jobs
  end

  def complete?
    child_jobs = work_jobs.reload
    child_jobs.any? && child_jobs.all? { |job| job.closed? && SUCCESSFUL_JOB_CLOSURE_REASONS.include?(job.closure_reason) }
  end

  # "Stuck" means the Epic is in progress but its children have all wound
  # down without landing — nothing is running and the Epic can't complete.
  # A jobless in-progress Epic (the form-created "start now, add children
  # later" path) is awaiting children, not stuck.
  def stuck?
    child_jobs = work_jobs.reload
    in_progress? &&
      child_jobs.any? &&
      child_jobs.none?(&:open?) &&
      !child_jobs.all? { |job| job.closed? && SUCCESSFUL_JOB_CLOSURE_REASONS.include?(job.closure_reason) }
  end

  def all_jobs_closed?
    child_jobs = work_jobs.reload
    child_jobs.any? && child_jobs.all?(&:closed?)
  end

  def all_jobs_approved?
    jobs.where.not(state: "closed").where.not(state: "approved").none?
  end

  # The effective reconciliation mode: Epic column → .syrus.yml → "pr".
  def resolved_reconciliation_mode
    RepoReconciliationPlan.for_epic(self).mode
  end

  # Creates a reconciliation Job if the Epic is in_progress, has 2+ work
  # jobs, and reconciliation mode is not "none". Idempotent — returns early
  # if a reconciliation job already exists.
  def maybe_create_reconciliation_job!
    return if @creating_reconciliation_job
    return if reconciliation_job_id.present?
    return if work_jobs.count < 2
    return if resolved_reconciliation_mode == "none"

    @creating_reconciliation_job = true
    # Use a fresh locked query instead of with_lock so this method is safe
    # to call even when self has unsaved changes (e.g. from an AASM after: callback).
    transaction do
      fresh = self.class.lock.find(id)
      return if fresh.reconciliation_job_id.present?

      create_reconciliation_job!(work_jobs.order(:id).to_a)
    end
  ensure
    @creating_reconciliation_job = nil
  end

  # Clears reconciliation_job_id if the linked reconciliation Job has closed.
  # Returns true when the field was cleared so refresh_auto_state! can skip
  # re-creation for the same refresh cycle.
  def clear_reconciliation_job_if_closed!
    return false unless reconciliation_job_id.present?
    return false unless reconciliation_job&.closed?

    update!(reconciliation_job_id: nil)
    true
  end

  def refresh_auto_state!
    if backlog? && may_auto_ready?
      auto_ready!
    elsif in_progress?
      released = release_child_jobs_if_ready!
      cleared = clear_reconciliation_job_if_closed!
      maybe_create_reconciliation_job! unless cleared
      return auto_complete! if may_auto_complete?

      released
    else
      false
    end
  end

  # Operator escape hatch for the card menu. This intentionally bypasses
  # the AASM graph while preserving side effects that matter to execution.
  def override_state!(target_state, actor: nil)
    target_state = target_state.to_s
    raise ArgumentError, "unknown Epic state: #{target_state}" unless STATES.include?(target_state)
    raise ArgumentError, "Product owners cannot advance Epics beyond backlog." if product_owner_advancement?(target_state, actor)

    transaction do
      was_in_progress = in_progress?
      update!(
        state: target_state,
        # Archiving keeps `done_at`: an Epic that landed and was later
        # archived still counts as landed (first-run setup completion).
        # Reopening (backlog/ready/in_progress) clears it.
        done_at: override_done_at(target_state),
        archived_at: target_state == "archived" ? Time.current : nil
      )
      if target_state == "in_progress"
        claim!(user, force: true) unless claimed?
        unblock_child_jobs!
        maybe_create_reconciliation_job!
      elsif was_in_progress && %w[backlog ready].include?(target_state)
        restore_child_epic_blocks!
      elsif target_state == "archived"
        close_child_jobs_on_archive!
      end
    end
  end

  def in_progress!
    override_state!("in_progress")
  end

  # "Start implementing" — the definite operator action (CLAUDE.md pattern:
  # re-check state, then dispatch side effects) that moves an Epic into
  # :in_progress and releases its held child Jobs. Prefers the AASM graph
  # (backlog → auto_ready → start); the override_state! fallback exists
  # ONLY for jobless form-created Epics (auto_ready requires jobs.exists?,
  # so the graph can never start them) so future children dispatch
  # immediately on creation. It must never bypass the EpicDependency gate:
  # an Epic with unfinished dependencies is not startable at all, and an
  # Epic that has child Jobs must be startable through the graph itself
  # (children confirmed) rather than force-released past it.
  def may_start_implementing?(actor: nil)
    return false unless backlog? || ready?
    return false unless actor_can_advance?(actor: actor)

    actor_user = epic_advancement_actor(actor)
    return false if claimed? && actor_user && !claimed_by?(actor_user)
    return false unless dependencies_done?

    # ready → start! flows through the graph. backlog must either be
    # graph-startable (has confirmed children, so auto_ready → start
    # works) or jobless (the sanctioned override fallback).
    ready? || jobs.none? || ready_to_start?
  end

  def start_implementing!(actor: nil)
    raise NotStartable, start_implementing_block_reason(actor) unless may_start_implementing?(actor: actor)

    transaction do
      auto_ready!(actor: actor) if backlog? && may_auto_ready?(actor: actor)
      if ready? && may_start?(actor: actor)
        start!(actor: actor)
      else
        # Jobless-Epic fallback. may_start_implementing? has already ruled
        # out unfinished dependencies and unconfirmed children; re-check the
        # invariant so a future guard change can't silently widen this
        # override back into a dependency-gate bypass.
        raise NotStartable, start_implementing_block_reason(actor) unless jobs.none? && dependencies_done?

        claim!(epic_advancement_actor(actor) || user, force: true) unless claimed?
        override_state!("in_progress", actor: actor)
      end
    end

    true
  end

  # Operator-facing display names of unfinished dependencies, used by the
  # NotStartable message and the detail payload's start-blocked hint.
  def unfinished_dependency_names
    dependencies.includes(:depends_on_epic, :depends_on_job).reject(&:dependency_succeeded?).filter_map do |dependency|
      next dependency.depends_on_job.slug if dependency.depends_on_job_id.present?

      dependency.depends_on_epic&.title
    end
  end

  def claim_unowned_child_jobs!(owner)
    jobs.where(owner_user_id: nil).update_all(owner_user_id: owner.id, updated_at: Time.current)
  end

  def reassign_child_jobs_to_owner!(owner)
    jobs.update_all(owner_user_id: owner.id, updated_at: Time.current)
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

  def close_child_jobs_on_archive!
    jobs.find_each do |job|
      next if job.closed?
      job.workflows.active.find_each do |workflow|
        workflow.cancel! if workflow.may_cancel?
        workflow.save!
      end
      job.close_with_reason!("epic_archived")
    end
  end

  private

  def create_reconciliation_job!(sibling_jobs)
    prompt = Prompts::EpicReconciliation.new(
      epic: self,
      jobs: sibling_jobs,
      reconciliation_mode: resolved_reconciliation_mode
    ).to_s

    recon_job = user.jobs.create!(
      repository: repository,
      kind: "direct",
      epic: self,
      issue_title: "Reconciliation: #{title}",
      issue_body: prompt,
      agent_provider: repository.effective_agent_provider,
      priority: "medium",
      state: "triaging"
    )

    sibling_jobs.each do |sibling|
      recon_job.dependencies.create!(
        depends_on_job: sibling,
        source: "manual",
        created_by_user: user
      )
    end

    # Set reconciliation_job_id BEFORE advancing triage so any callback
    # re-entering maybe_create_reconciliation_job! sees the field set and
    # returns early, preventing duplicate reconciliation jobs.
    update!(reconciliation_job_id: recon_job.id)

    recon_job.advance_after_triage! if recon_job.may_advance_after_triage?

    recon_job
  end

  def start_implementing_block_reason(actor)
    actor_user = epic_advancement_actor(actor)
    return I18n.t("api.epics.product_owner_forbidden") if actor_user&.product_owner?
    return I18n.t("api.epics.start_claimed_by_other") if (backlog? || ready?) && claimed? && actor_user && !claimed_by?(actor_user)
    if (backlog? || ready?) && !dependencies_done?
      return I18n.t("api.epics.start_blocked_by_dependencies", names: unfinished_dependency_names.to_sentence)
    end
    return I18n.t("api.epics.start_children_unconfirmed") if backlog? && jobs.exists? && !child_jobs_confirmed?

    I18n.t("api.epics.not_startable", state: state)
  end

  def override_done_at(target_state)
    case target_state
    when "done" then Time.current
    when "archived" then done_at
    end
  end

  def generate_slug
    base = title.to_s.parameterize.presence
    return unless base

    base = base.first(50)
    n = 1
    candidate = base
    loop do
      break unless Epic.where(slug: candidate).exists?
      candidate = "#{base.first(46)}-#{n}"
      n += 1
    end
    self[:slug] = candidate
  end

  def release_child_jobs_if_ready!
    return false unless dependencies_done?
    return false if @releasing_jobs_for_execution
    return false unless jobs.where(state: "blocked_by_epic").exists?

    unblock_child_jobs!
    true
  end

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

  def user_is_repository_member
    return unless repository && user
    return if repository.repository_memberships.exists?(user: user)

    errors.add(:repository, "must have an active membership for the current user")
  end

  def dependencies_done?
    dependencies.all?(&:dependency_succeeded?)
  end

  def child_jobs_confirmed?
    jobs.where(state: "triaging").none?
  end

  def product_owner_advancement?(target_state, actor)
    target_state.in?(%w[ready in_progress done]) && epic_advancement_actor(actor)&.product_owner?
  end

  def epic_advancement_actor(actor)
    actor.respond_to?(:user) ? actor.user : actor
  end

  def stamp_done_at
    self.done_at = Time.current
  end

  def refresh_dependent_epic_auto_states
    return unless done?

    dependent_epics.find_each(&:refresh_auto_state!)
  end

  def enqueue_search_index_after_create
    enqueue_search_index
  end

  def enqueue_search_index_after_update
    enqueue_search_index
  end

  def enqueue_search_index
    IndexEpicSearchJob.perform_later(id)
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
