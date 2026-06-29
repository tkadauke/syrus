class EpicVersion < ApplicationRecord
  belongs_to :epic
  belongs_to :user, optional: true
end
