# Runaway protection for merge trains and job bundles.
#
# Runaway protection (Job#runaway_protection) means automatic retries wait for
# an operator. Single-Job landing honours that through the operator's
# approval: approving a runaway-protected Job buys one landing attempt, and a
# transient failure of that attempt fails the landing back to :implemented
# instead of deferring it (LandingFailureHandler#runaway_retry_refused?), so
# the landing queue does not relaunch it on its own.
#
# Train dispatch is where that promise leaked. MergeTrainDispatcher and
# JobBundleDispatcher launch through WorkUnits::Launcher.instantiate, which
# never consults the WorkIntents::Gates::RunawayProtection intent gate, and a
# failed train defers its members back to :approved on paths that never reach
# LandingFailureHandler's runaway check (a rebuild-required base move, a
# teardown, an agent withdrawing another member). The reconciler's
# rebuild_merge_train repair then relaunched the train at once, and the
# landing queue after the cooldown, with nothing bounding it: the runaway
# limits stop counting once the flag is set.
#
# The rule is single-Job landing's: one automatic attempt per operator
# consent. Consent is an approval by a named operator (`approved_by_user`),
# or else the moment runaway protection was set -- an approval nobody made
# (an auto-approval rule, review ingestion, the rebuild repair's own
# re-approval) buys nothing. Once a train containing the member has failed or
# been cancelled since that consent, the member holds every dispatch of its
# train, automatic and rebuild alike, with a named reason, until an operator
# re-approves it or clears runaway protection with a manual retry.
#
# The member is held rather than excluded: an Epic lands all-or-nothing, so a
# train without it would land a partial Epic or never become ready, and an
# epicless bundle would just keep relaunching the protected Job inside the
# next bundle that picks it up. The RunawayProtection intent gate itself is
# not used because it refuses while the flag is set at all, which would make
# an operator's approval of a runaway-protected Epic child worthless while the
# same approval lands a single Job.
module MergeTrains
  module RunawayHold
    REASON_PREFIX = "runaway protection holds".freeze

    module_function

    # The first member whose consent was already spent on a failed train,
    # with that train, or nil.
    def spent_member(members)
      Array(members).each do |job|
        next unless job.runaway_protected?

        train = failed_train_since_consent(job)
        return [ job, train ] if train
      end
      nil
    end

    def reason_for(members)
      job, train = spent_member(members)
      return nil unless job

      "#{REASON_PREFIX} #{job.slug} (#{job.runaway_protection}): merge train ##{train.id} already failed since an operator " \
        "last approved it; re-approve #{job.slug} or retry it manually before Syrus tries again"
    end

    def consent_at(job)
      return job.approved_at if job.approved_by_user_id.present? && job.approved_at.present?

      job.runaway_protection_at
    end

    def failed_train_since_consent(job)
      since = consent_at(job)
      scope = MergeTrain
        .joins(:members)
        .where(merge_train_members: { job_id: job.id }, state: %w[failed cancelled])
      scope = scope.where(MergeTrain.arel_table[:created_at].gteq(since)) if since
      scope.order(:id).last
    end
  end
end
