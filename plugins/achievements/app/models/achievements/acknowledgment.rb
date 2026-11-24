module Achievements
  # One user's acknowledgment of one unlock ("I have seen this"). Per-user even
  # for instance unlocks, so acknowledging never changes canonical unlock state.
  class Acknowledgment < ApplicationRecord
    self.table_name = "achievements_acknowledgments"

    belongs_to :unlock, class_name: "Achievements::Unlock", inverse_of: :acknowledgments

    validates :user_id, :acknowledged_at, presence: true
    validates :user_id, uniqueness: { scope: :unlock_id }
  end
end
