class PluginDesiredState < ApplicationRecord
  SINGLETON_KEY = 1

  attribute :apply_processes, :json, default: -> { [] }

  validates :singleton_key, inclusion: { in: [ SINGLETON_KEY ] }
  validates :revision, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  def self.current
    find_or_create_by!(singleton_key: SINGLETON_KEY)
  rescue ActiveRecord::RecordNotUnique
    find_by!(singleton_key: SINGLETON_KEY)
  end
end
