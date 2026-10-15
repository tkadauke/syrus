module Steps
  # Resolves whether a purpose-specific JobPrLink still points at a reusable
  # pull request. GitHub is authoritative for links recorded as open; a link
  # already recorded as merged is terminal and does not need another API call.
  class LinkedPullRequest
    Result = Data.define(:state, :number)

    def initialize(link:, repository:, user:)
      @link = link
      @repository = repository
      @user = user
    end

    def resolve
      return Result.new(state: :missing, number: nil) if link&.pr_number.blank?
      return Result.new(state: :merged, number: link.pr_number) if link.metadata.to_h["pr_state"] == "merged"

      pull = client.pull_request(repository.slug, link.pr_number, bypass_cache: true)
      state = if pull_value(pull, :merged) || pull_value(pull, :merged_at).present?
        :merged
      elsif pull_value(pull, :state).to_s == "open"
        :open
      else
        :closed
      end
      Result.new(state: state, number: link.pr_number)
    rescue Octokit::NotFound
      Result.new(state: :missing, number: nil)
    end

    private

    attr_reader :link, :repository, :user

    def client
      @client ||= GithubClient.for(repository: repository, user: user)
    end

    def pull_value(pull, key)
      pull.respond_to?(key) ? pull.public_send(key) : pull[key]
    end
  end
end
