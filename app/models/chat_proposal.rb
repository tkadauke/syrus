require "set"

class ChatProposal < ApplicationRecord
  MEDIA_ID_FORMAT = /\A(snapshot|chat_image):\d+\z/

  STATE_ALIASES = {
    "pending" => "proposed",
    "filed" => "confirmed",
    "discarded" => "withdrawn"
  }.freeze

  attribute :state, :string, default: "proposed"

  after_initialize :default_cross_entity_dependencies
  after_initialize :default_media_ids

  belongs_to :chat_session
  belongs_to :repository, optional: true
  belongs_to :job, optional: true
  belongs_to :epic, optional: true
  belongs_to :target_epic, class_name: "Epic", optional: true
  belongs_to :parent_proposal,
             class_name: "ChatProposal",
             optional: true,
             inverse_of: :child_proposals
  has_many :child_proposals,
           -> { order(:child_position, :created_at, :id) },
           class_name: "ChatProposal",
           foreign_key: :parent_proposal_id,
           inverse_of: :parent_proposal,
           dependent: :nullify

  has_many :dependency_edges,
           class_name: "ChatProposalDependency",
           foreign_key: :proposal_id,
           inverse_of: :proposal,
           dependent: :destroy
  has_many :dependencies, through: :dependency_edges, source: :depends_on

  has_many :dependent_edges,
           class_name: "ChatProposalDependency",
           foreign_key: :depends_on_id,
           inverse_of: :depends_on,
           dependent: :destroy
  has_many :dependents, through: :dependent_edges, source: :proposal

  has_many :messages, class_name: "ChatMessage", foreign_key: :proposal_id, dependent: :nullify

  enum :kind, {
    syrus_issue: "syrus_issue",
    github_issue: "github_issue",
    epic: "epic",
    job: "job"
  }, validate: true
  enum :state, {
    proposed: "proposed",
    confirmed: "confirmed",
    rejected: "rejected",
    withdrawn: "withdrawn"
  }, validate: true

  scope :pending, -> { proposed }

  validates :slug, :title, :body, presence: true
  validates :slug, uniqueness: { scope: :chat_session_id }
  validate :repository_belongs_to_chat_user
  validate :target_epic_matches_repository
  validate :media_ids_valid_format
  validate :media_ids_belong_to_chat_session, on: :create

  before_validation :default_repository, on: :create

  def state=(value)
    super(STATE_ALIASES.fetch(value.to_s, value))
  end

  def pending?
    proposed?
  end

  def filed?
    confirmed?
  end

  def discarded?
    withdrawn?
  end

  def resolved?
    confirmed? || rejected? || withdrawn?
  end

  def materialized_record
    job || epic
  end

  def effective_repository
    repository || chat_session.repository
  end

  def epic_bundle?
    epic?
  end

  def epic_dependency_tokens
    JSON.parse(epic_depends_on_tokens.presence || "[]")
  rescue JSON::ParserError
    []
  end

  def active_child_proposals
    child_proposals.where.not(state: "rejected")
  end

  def materialized_label
    case materialized_record
    when Job
      job.slug
    when Epic
      epic.slug
    end
  end

  def reset_to_proposed_after_edit!
    update!(state: "proposed", edited_at: Time.current)
  end

  def self.topological_sort(scope)
    proposals = scope.to_a
    ids = proposals.map(&:id).compact
    return proposals if ids.empty?

    position_by_id = ids.each_with_index.to_h
    incoming_counts = ids.to_h { |id| [ id, 0 ] }
    outgoing_by_dependency = Hash.new { |hash, key| hash[key] = [] }

    ChatProposalDependency.where(proposal_id: ids, depends_on_id: ids).pluck(:proposal_id, :depends_on_id).each do |proposal_id, depends_on_id|
      incoming_counts[proposal_id] += 1
      outgoing_by_dependency[depends_on_id] << proposal_id
    end

    queue = ids.select { |id| incoming_counts[id].zero? }
               .sort_by { |id| position_by_id[id] }
    sorted_ids = []

    until queue.empty?
      id = queue.shift
      sorted_ids << id

      outgoing_by_dependency[id].sort_by { |dependent_id| position_by_id[dependent_id] }.each do |dependent_id|
        incoming_counts[dependent_id] -= 1
        next unless incoming_counts[dependent_id].zero?

        insert_at = queue.index { |queued_id| position_by_id[queued_id] > position_by_id[dependent_id] } || queue.length
        queue.insert(insert_at, dependent_id)
      end
    end

    raise ArgumentError, "cycle detected in chat proposals" if sorted_ids.length != ids.length

    records_by_id = proposals.index_by(&:id)
    sorted_ids.map { |id| records_by_id.fetch(id) }
  end

  def self.transitive_upstream_closure(proposals)
    transitive_closure(proposals) do |frontier_ids|
      ChatProposalDependency.where(proposal_id: frontier_ids).pluck(:depends_on_id)
    end
  end

  def self.transitive_downstream_closure(proposals)
    transitive_closure(proposals) do |frontier_ids|
      ChatProposalDependency.where(depends_on_id: frontier_ids).pluck(:proposal_id)
    end
  end

  def self.transitive_closure(proposals)
    starting_ids = proposals.to_a.map(&:id).compact
    seen_ids = Set.new(starting_ids)
    frontier_ids = starting_ids

    until frontier_ids.empty?
      next_ids = yield(frontier_ids).compact - seen_ids.to_a
      next_ids.each { |id| seen_ids << id }
      frontier_ids = next_ids
    end

    Set.new(where(id: seen_ids.to_a).to_a)
  end
  private_class_method :transitive_closure

  private

  def default_repository
    self.repository ||= chat_session&.repository
  end

  def default_cross_entity_dependencies
    self.depends_on_epic_ids = [] if has_attribute?(:depends_on_epic_ids) && depends_on_epic_ids.nil?
    self.depends_on_job_ids = [] if has_attribute?(:depends_on_job_ids) && depends_on_job_ids.nil?
  end

  def default_media_ids
    self.media_ids = [] if has_attribute?(:media_ids) && media_ids.nil?
  end

  def media_ids_valid_format
    return unless media_ids.is_a?(Array)

    media_ids.each do |ref|
      next if MEDIA_ID_FORMAT.match?(ref.to_s)

      errors.add(:media_ids, "contains invalid entry '#{ref}'; must be snapshot:ID or chat_image:ID")
    end
  end

  def media_ids_belong_to_chat_session
    return unless chat_session && media_ids.is_a?(Array)

    media_ids.each do |ref|
      next unless MEDIA_ID_FORMAT.match?(ref.to_s)

      kind, id_str = ref.split(":", 2)
      id = id_str.to_i

      case kind
      when "snapshot"
        unless chat_session.whiteboard_snapshots.exists?(id)
          errors.add(:media_ids, "contains snapshot:#{id} that does not belong to this chat session")
        end
      when "chat_image"
        unless chat_session.attached_repository_documents.exists?(id)
          errors.add(:media_ids, "contains chat_image:#{id} that does not belong to this chat session")
        end
      end
    end
  end

  def repository_belongs_to_chat_user
    return unless repository && chat_session
    return if repository.user_id == chat_session.user_id

    errors.add(:repository, "must belong to the chat user")
  end

  def target_epic_matches_repository
    return unless target_epic

    if chat_session && target_epic.user_id != chat_session.user_id
      errors.add(:target_epic, "must belong to the chat user")
    end

    repo = effective_repository
    return unless repo && target_epic.repository_id != repo.id

    errors.add(:target_epic, "must belong to the proposal repository")
  end
end
