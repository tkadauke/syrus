require "set"

class MakeOperatorBriefingsOptIn < ActiveRecord::Migration[8.1]
  class BriefingSubscription < ActiveRecord::Base
    self.table_name = "operator_briefing_subscriptions"
  end

  class Feedback < ActiveRecord::Base
    self.table_name = "operator_briefing_feedbacks"
  end

  class Briefing < ActiveRecord::Base
    self.table_name = "operator_briefing_briefings"
  end

  class TopicRevision < ActiveRecord::Base
    self.table_name = "operator_briefing_topic_revisions"
  end

  class Workflow < ActiveRecord::Base
    self.table_name = "workflows"
  end

  def up
    return unless table_exists?(:operator_briefing_subscriptions)

    change_column_default :operator_briefing_subscriptions, :enabled, false

    disabled_ids = []
    BriefingSubscription.where(enabled: true).find_each do |subscription|
      next if grandfathered_user_ids.include?(subscription.user_id)

      subscription.update_columns(enabled: false, updated_at: Time.current)
      disabled_ids << subscription.id
    end

    cancel_disabled_briefing_work!(disabled_ids)
  end

  def down
    return unless table_exists?(:operator_briefing_subscriptions)

    change_column_default :operator_briefing_subscriptions, :enabled, true
  end

  private

  def grandfathered_user_ids
    # Preserve scheduling only for operators with concrete briefing interaction.
    # Rows created by passive scheduler/UI seeding alone are turned off below.
    @grandfathered_user_ids ||= begin
      ids = []
      ids.concat(feedback_user_ids)
      ids.concat(dive_workflow_user_ids)
      ids.concat(topic_revision_user_ids)
      ids.compact.uniq.to_set
    end
  end

  def feedback_user_ids
    return [] unless table_exists?(:operator_briefing_feedbacks)

    Feedback.distinct.pluck(:user_id)
  end

  def dive_workflow_user_ids
    return [] unless table_exists?(:workflows)

    Workflow.where(trigger_kind: "briefing_dive").distinct.pluck(:user_id)
  end

  def topic_revision_user_ids
    return [] unless table_exists?(:operator_briefing_topic_revisions) && table_exists?(:operator_briefing_briefings)

    TopicRevision
      .joins("INNER JOIN operator_briefing_briefings ON operator_briefing_briefings.id = operator_briefing_topic_revisions.briefing_id")
      .distinct
      .pluck("operator_briefing_briefings.owner_user_id")
  end

  def cancel_disabled_briefing_work!(subscription_ids)
    return if subscription_ids.empty?

    OperatorBriefing::OptOutCleanup.cancel_for_subscription_ids!(subscription_ids)
  rescue NameError
    # Fresh installs can run plugin migrations before the plugin app tree is loaded.
  end
end
