# Closes an Epic's GitHub tracking issue once the Epic is done.
#
# A tracking issue carries the trigger label and the Epic marker, and
# `PollRepositoryJob` relies on the marker to route it to an Epic rather than
# ingesting it as work. Nothing used to close it, so a finished Epic left an
# open, labeled issue behind indefinitely. That is fine only while the marker
# parses: when the marker format changed, every stale tracking issue fell
# through to ordinary ingestion and became a work Job on an Epic whose
# children had already shipped, producing vague cleanup PRs. Ten of those were
# created in one hour on this repository.
#
# Closing the issue removes the issue from the poller's open-issue listing
# entirely, so it cannot be re-ingested regardless of how the marker contract
# evolves later. The marker parser's own backward compatibility is the other
# half of that defence; this is the half that keeps the repository tidy and
# makes a completed Epic look completed on GitHub.
class CloseEpicTrackingIssueJob < ApplicationJob
  queue_as :control_plane

  def perform(epic_id)
    @epic = Epic.find_by(id: epic_id)
    return unless @epic&.done?

    number = @epic.github_issue_number
    return unless number
    return unless (repository = @epic.repository)

    client = GithubClient.for(repository: repository, user: @epic.user)
    return if client.fetch_issue(repository.slug, number).state == "closed"

    client.close_issue(repository.slug, number)
  rescue => e
    Rails.logger.warn(
      "[CloseEpicTrackingIssueJob] failed to close tracking issue for Epic ##{epic_id}: #{e.class}: #{e.message}"
    )
  end
end
