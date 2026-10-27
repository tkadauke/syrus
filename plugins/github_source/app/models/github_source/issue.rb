module GithubSource
  class Issue < ApplicationRecord
    self.table_name = "github_source_issues"

    belongs_to :repository

    validates :github_id, :number, :title, :state, :html_url, presence: true
    validates :github_id, uniqueness: { scope: :repository_id }
    validates :number, uniqueness: { scope: :repository_id }

    scope :open, -> { where(state: "open") }
    scope :closed, -> { where(state: "closed") }

    def delegated?(trigger_label)
      labels.any? { |label| label.fetch("name", nil) == trigger_label }
    end

    def body_excerpt
      body.to_s.gsub(/\r?\n/, " ").truncate(180)
    end
  end
end
