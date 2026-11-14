module GithubSource
  class IssueCache
    class << self
      def linked_open_pr_lookup_numbers(repository, issues)
        open_issues = Array(issues).select { |issue| issue.state.to_s == "open" }
        cached = Issue.where(repository: repository, number: open_issues.map(&:number)).index_by(&:number)
        ingested_numbers = repository.jobs.where(issue_number: open_issues.map(&:number)).where.not(issue_number: nil).pluck(:issue_number).index_with(true)
        open_issues.filter_map do |issue|
          next if ingested_numbers[issue.number]

          record = cached[issue.number]
          issue.number if record.nil? || record.linked_open_pr_checked_at.nil? || record.github_updated_at != issue.updated_at
        end
      end

      def synchronize!(repository, issues, linked_open_prs:, linked_lookup_numbers:, synced_at:, full_poll:)
        existing_by_number = Issue.where(repository: repository, number: Array(issues).map(&:number)).index_by(&:number)
        rows = Array(issues).map do |issue|
          cache_attributes(repository, issue, existing_by_number[issue.number], linked_open_prs, linked_lookup_numbers, synced_at)
        end
        Issue.upsert_all(rows) if rows.any?
        Issue.where(repository: repository).where.not(number: rows.map { |row| row[:number] }).delete_all if full_poll
        update_sync_metadata!(repository, synced_at, full_poll: full_poll)
      end

      def update_untagged_open_issue_count!(repository)
        count = Issue.where(repository: repository).open.count do |issue|
          names = issue.labels.map { |label| label["name"] }
          !names.include?(repository.trigger_label) && !names.include?(IngestPolicy::SKIP_LABEL)
        end
        repository.update_columns(untagged_open_issue_count: count, untagged_open_issues_checked_at: Time.current)
      end

      private

      def cache_attributes(repository, issue, existing, linked_open_prs, linked_lookup_numbers, synced_at)
        looked_up = linked_lookup_numbers.key?(issue.number)
        {
          id: existing&.id,
          repository_id: repository.id,
          github_id: issue.respond_to?(:id) && issue.id.present? ? issue.id : issue.number,
          number: issue.number,
          title: issue.respond_to?(:title) ? issue.title.to_s : "Issue #{issue.number}",
          body: issue.respond_to?(:body) ? issue.body.to_s : "",
          state: issue.state.to_s,
          html_url: issue.respond_to?(:html_url) && issue.html_url.present? ? issue.html_url.to_s : "https://github.com/#{repository.slug}/issues/#{issue.number}",
          author_login: issue.respond_to?(:user) ? issue.user&.login.to_s.presence : nil,
          labels: label_metadata(issue),
          github_created_at: issue.respond_to?(:created_at) ? issue.created_at : nil,
          github_updated_at: issue.respond_to?(:updated_at) ? issue.updated_at : nil,
          synced_at: synced_at,
          linked_open_pr: issue.state.to_s == "closed" ? nil : (looked_up ? linked_open_prs[issue.number] : existing&.linked_open_pr),
          linked_open_pr_checked_at: looked_up ? synced_at : existing&.linked_open_pr_checked_at,
          created_at: existing&.created_at || synced_at,
          updated_at: synced_at
        }
      end

      def label_metadata(issue)
        Array(issue.labels).map do |label|
          name = label.respond_to?(:name) ? label.name : label.to_h[:name] || label.to_h["name"]
          color = label.respond_to?(:color) ? label.color : label.to_h[:color] || label.to_h["color"]
          { "name" => name.to_s, "color" => color.to_s.presence || "6b7280" }
        end
      end

      def update_sync_metadata!(repository, synced_at, full_poll:)
        metadata = { github_issues_synced_at: synced_at }
        metadata[:github_issues_full_synced_at] = synced_at if full_poll
        repository.update_columns(metadata)
        repository.assign_attributes(metadata)
      end
    end
  end
end
