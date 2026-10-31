class Coworkers::Coworker < ApplicationRecord
  self.table_name = "coworkers"
  include Mentionable
  include PluginDataCleanup

  STATES = %w[active paused archived].freeze
  AVATAR_KEYS = %w[comet orbit prism sprout wave spark].freeze
  AVATAR_MAX_BYTES = 5.megabytes

  belongs_to :owner_user, class_name: "User"
  has_one :handle_record, as: :owner, class_name: "Handle", dependent: :destroy
  has_many :grants, class_name: "Coworkers::Grant", dependent: :destroy, inverse_of: :coworker
  has_many :coworker_chats, class_name: "Coworkers::Chat", dependent: :destroy, inverse_of: :coworker
  has_many :chats, through: :coworker_chats, source: :chat_session
  has_many :chat_agents, class_name: "Coworkers::ChatAgent", dependent: :destroy, inverse_of: :coworker
  has_many :received_chat_shares, as: :target, class_name: "ChatShare", dependent: :destroy
  has_one_attached :avatar, dependent: :purge

  normalizes :handle, with: ->(value) { HandleRegistry.normalize(value) }

  validates :name, :workspace_repo, presence: true
  validates :handle, presence: true, format: { with: Handle::FORMAT }, uniqueness: { case_sensitive: false }
  validates :state, inclusion: { in: STATES }
  validates :chat_effort, inclusion: { in: ChatSession::EFFORT_LEVELS }, allow_nil: true
  validates :accent_hex, format: { with: Appearance::ColorPalette::HEX_PATTERN }
  validates :avatar_key, inclusion: { in: AVATAR_KEYS }, allow_nil: true
  validate :avatar_is_image

  before_validation :assign_default_color, if: -> { accent_hex.blank? && handle.present? }
  before_update :rename_handle!, if: :will_save_change_to_handle?
  after_create :claim_handle!
  after_destroy :release_handle!

  def display_name = name
  def handle = self[:handle]
  def subtitle = role_summary
  def kind = "coworker"
  def accent_hex = self[:accent_hex]
  def agentic? = true
  def execution_workload_policy = Coworkers::ExecutionWorkloadPolicy.new
  def avatar_url = avatar.attached? ? Rails.application.routes.url_helpers.rails_blob_path(avatar, only_path: true) : nil
  def avatar_key = self[:avatar_key]
  def addressable_in?(chat)
    Coworkers::Chat.exists?(coworker_id: id, chat_session_id: chat.id) ||
      Coworkers::ChatAgent.exists?(coworker_id: id, chat_session_id: chat.id)
  end
  def schedules = ScheduledTasks::Task.where(coworker_id: id)
  def chat_configuration = attributes.symbolize_keys.slice(:chat_provider, :chat_model, :chat_effort).compact

  def workspace_repository
    match = workspace_repo.match(%r{github\.com[:/]([^/]+)/([^/]+?)(?:\.git)?\z}i)
    return unless match

    Repository.where("LOWER(owner) = ? AND LOWER(name) = ?", match[1].downcase, match[2].downcase).first
  end

  # A coworker sees only its own conversations and chats explicitly shared
  # with it. The owner's role (including admin) must never widen this scope.
  def readable_chat_session_ids
    own_ids = coworker_chats.select(:chat_session_id)
    shared_ids = ChatShare.where(target_type: self.class.polymorphic_name, target_id: id).select(:chat_session_id)
    ChatSession.where(id: own_ids).or(ChatSession.where(id: shared_ids)).active.distinct.ids
  end
  private

  def assign_default_color
    used = self.class.where(owner_user_id: owner_user_id).where.not(id: id).pluck(:accent_hex)
    self.accent_hex = Appearance::ColorPalette.next_default_color(used) || Appearance::ColorPalette.default_agent_order.first
  end
  def claim_handle! = HandleRegistry.claim!(handle: handle, owner: self)
  def rename_handle! = HandleRegistry.rename!(owner: self, handle: handle)
  def release_handle! = HandleRegistry.release!(owner: self)

  def avatar_is_image
    return unless avatar.attached?

    errors.add(:avatar, "must be an image") unless avatar.blob.content_type.to_s.start_with?("image/")
    errors.add(:avatar, "must be smaller than 5 MB") if avatar.blob.byte_size > AVATAR_MAX_BYTES
  end
end
