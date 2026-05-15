class ChatBookmark < ApplicationRecord
  KINDS = %w[ topic epic_origin manual ].freeze

  belongs_to :chat_message, inverse_of: :bookmarks

  enum :kind, {
    topic: "topic",
    epic_origin: "epic_origin",
    manual: "manual"
  }, validate: true

  validates :label, :kind, presence: true
  validates :kind, inclusion: { in: KINDS }
end
