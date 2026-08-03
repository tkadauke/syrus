module AutoApproveModes
  extend ActiveSupport::Concern

  OPTIONS = [
    {
      value: "never",
      label: "Never",
      preview: "No direct rule; Jobs can still inherit a repository or user default."
    },
    {
      value: "if_graders_pass",
      label: "If graders pass",
      preview: "Jobs using this rule enter landing after repo-committed graders pass."
    },
    {
      value: "if_graders_pass_and_tagged_safe",
      label: "If graders pass and tagged safe",
      preview: "Jobs using this rule also need the safe tag before landing."
    }
  ].freeze

  MODES = OPTIONS.map { |option| option.fetch(:value) }.freeze

  def self.options
    OPTIONS.map(&:dup)
  end

  def self.option_for(mode)
    OPTIONS.find { |option| option.fetch(:value) == mode.to_s }
  end

  included do
    validates :auto_approve_mode, presence: true, inclusion: { in: MODES }
    enum :auto_approve_mode, MODES.index_with(&:itself), prefix: true, validate: true
  end
end
