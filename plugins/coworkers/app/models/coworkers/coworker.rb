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
  has_one_attached :avatar, dependent: :purge

  normalizes :handle, with: ->(value) { HandleRegistry.normalize(value) }

  validates :name, :workspace_repo, presence: true
  validates :handle, presence: true, format: { with: Handle::FORMAT }, uniqueness: { case_sensitive: false }
  validates :state, inclusion: { in: STATES }
  validates :chat_effort, inclusion: { in: ChatSession::EFFORT_LEVELS }, allow_nil: true
  validates :color_key, inclusion: { in: -> { Appearance::ColorPalette.keys } }
  validates :avatar_key, inclusion: { in: AVATAR_KEYS }, allow_nil: true
  validate :avatar_is_image

  before_validation :assign_default_color, if: -> { color_key.blank? && handle.present? }
  before_update :rename_handle!, if: :will_save_change_to_handle?
  after_create :claim_handle!
  after_destroy :release_handle!

  def display_name = name
  def handle = self[:handle]
  def subtitle = role_summary
  def kind = "coworker"
  def color_key = self[:color_key]
  def agentic? = true
  def avatar_url = avatar.attached? ? Rails.application.routes.url_helpers.rails_blob_path(avatar, only_path: true) : nil
  def addressable_in?(chat) = Coworkers::Chat.exists?(coworker_id: id, chat_session_id: chat.id)
  def schedules = ScheduledTasks::Task.none
  def chat_configuration = attributes.symbolize_keys.slice(:chat_provider, :chat_model, :chat_effort).compact

  # A coworker sees only its own conversations and chats explicitly shared
  # with it. The owner's role (including admin) must never widen this scope.
  def readable_chat_session_ids
    own_ids = coworker_chats.select(:chat_session_id)
    shared_ids = ChatShare.where(target_type: self.class.polymorphic_name, target_id: id).select(:chat_session_id)
    ChatSession.where(id: own_ids).or(ChatSession.where(id: shared_ids)).active.distinct.ids
  end

  private

  def assign_default_color = self.color_key = Appearance::ColorPalette.default_key(handle)
  def claim_handle! = HandleRegistry.claim!(handle: handle, owner: self)
  def rename_handle! = HandleRegistry.rename!(owner: self, handle: handle)
  def release_handle! = HandleRegistry.release!(owner: self)

  def avatar_is_image
    return unless avatar.attached?

    errors.add(:avatar, "must be an image") unless avatar.blob.content_type.to_s.start_with?("image/")
    errors.add(:avatar, "must be smaller than 5 MB") if avatar.blob.byte_size > AVATAR_MAX_BYTES
  end
end
