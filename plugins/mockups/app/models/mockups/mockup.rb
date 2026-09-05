module Mockups
  # An operator-facing mockup: a slug, a title, and the core PreviewPanel that
  # holds its files.
  #
  # The panel is deliberately not owned here. It is a generic multi-format
  # viewer (html, markdown, pdf, image -- JOB-3864) that other features render
  # into; this record is the first-class thing a person browses, searches and
  # links to.
  class Mockup < ApplicationRecord
    self.table_name = "mockups"

    SLUG_PREFIX = "MOCKUP".freeze
    SLUG_PATTERN = /\A#{SLUG_PREFIX}-(\d+)\z/i

    belongs_to :preview_panel
    belongs_to :user
    belongs_to :chat_session, optional: true

    validates :title, presence: true, length: { maximum: 200 }

    scope :for_user, ->(user) { where(user_id: user&.id) }
    scope :recent_first, -> { order(updated_at: :desc, id: :desc) }

    def slug = "#{SLUG_PREFIX}-#{id}"

    # Accepts a bare id ("12") or the prefixed slug ("MOCKUP-12"), matching how
    # JobEpicRefFinder resolves JOB-/EPIC- references.
    def self.id_from_ref(ref)
      value = ref.to_s.strip
      return value.to_i if value.match?(/\A\d+\z/)

      match = SLUG_PATTERN.match(value)
      match && match[1].to_i
    end

    def self.find_by_ref(ref)
      id = id_from_ref(ref)
      id && find_by(id: id)
    end

    # Republishing a panel updates its mockup rather than adding another, so
    # the slug stays stable while the operator iterates.
    def self.record_publish!(panel:, user:, title:, chat_session: nil)
      mockup = find_or_initialize_by(preview_panel_id: panel.id)
      mockup.user ||= user
      mockup.chat_session ||= chat_session
      mockup.title = title.to_s.strip.presence || mockup.title.presence || "Untitled mockup"
      mockup.published_at = Time.current
      mockup.save!
      mockup
    end
  end
end
