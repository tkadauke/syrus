module HasProposer
  extend ActiveSupport::Concern

  included do
    belongs_to :proposer, polymorphic: true, optional: true
  end
end
