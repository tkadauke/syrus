class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class

  def self.like_escape_sql
    connection.quote("\\")
  end
  private_class_method :like_escape_sql
end
