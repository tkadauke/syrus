module Achievements
  # Contributes the reveal host to the Job detail page. The panel is offered only
  # while this user has an unacknowledged reveal about the Job being opened, so
  # a Job with nothing to reveal costs the page nothing.
  class UiSlots
    include Syrus::Host::UiSlot

    def self.ui_slots(slot:, context:)
      return [] unless slot == "job.detail"

      job = context[:job]
      user = context[:user]
      return [] if job.blank? || user.blank?
      return [] unless Achievements.enabled?
      return [] if Achievements::Reveals.new(user).pending_for_subject("job", job.id).empty?

      [
        {
          id: "achievements.job_reveal",
          component: "achievements/JobReveal",
          order: 900,
          cacheable: false,
          props: { job_id: job.id }
        }
      ]
    end
  end
end
