class SearchRecord < ApplicationRecord
  self.abstract_class = true

  connects_to database: { writing: :search, reading: :search }
end
