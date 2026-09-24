class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class

  class << self
    private

    def like_escape_sql
      connection.quote("\\")
    end
  end
end
