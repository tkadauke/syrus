module AutoApproveModes
  extend ActiveSupport::Concern

  MODES = %w[ never if_graders_pass if_graders_pass_and_tagged_safe ].freeze

  included do
    validates :auto_approve_mode, presence: true, inclusion: { in: MODES }
    enum :auto_approve_mode, MODES.index_with(&:itself), prefix: true, validate: true
  end
end
