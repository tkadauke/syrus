class SearchRecord < ApplicationRecord
  self.abstract_class = true

  connects_to database: { writing: :search, reading: :search }

  class << self
    private

    def bind(value)
      ActiveRecord::Relation::QueryAttribute.new(nil, value, ActiveRecord::Type::Value.new)
    end
  end
end
