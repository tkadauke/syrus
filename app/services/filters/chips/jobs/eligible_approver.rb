module Filters
  module Chips
    module Jobs
      # Filters jobs by "would this user's approval satisfy the job's
      # review policy" — different from OwnerUserId's raw ownership check.
      # A repo owner/collaborator whose vote would count under the job's
      # review policy is not necessarily the job's owner (see
      # ReviewPolicies::{Self,TwoPerson,FinalSay}Policy). Resolves per the
      # job's repository `review_policy`:
      #   self       — only the effective owner (owner_user_id.presence || user_id).
      #   two_person — the effective owner, or anyone who isn't the raw
      #                creator (mirrors ReviewPolicies::TwoPersonPolicy's
      #                approval_from_non_owner?, which imposes no
      #                repo-membership restriction — the same "not the raw
      #                creator" shape as Job#can_add_job_approval?).
      #   final_say  — the effective owner, or one of
      #                repository.final_approver_ids.
      # Supports the same "me" special value as OwnerUserId's :is/:is_not,
      # plus picking a specific team member via schema_values.
      class EligibleApprover < Base
        filter_name "eligible_approver"
        label "Eligible approver"
        bucket :enum
        operators :is, :is_not

        values(
          { "value" => "me", "label" => "Me" }
        )

        # Called by Filters::Schema when building the filter schema for a
        # user. Returns the "me" symbolic value plus all team members so the
        # filter dropdown supports "Eligible approver is Alice".
        def self.schema_values(user)
          base = [ { "value" => "me", "label" => "Me" } ]
          user_opts = User.order(Arel.sql("LOWER(email_address) ASC"), :id)
                         .map { |u| { "value" => u.id.to_s, "label" => u.email_address } }
          base + user_opts
        end

        # Reuses Job::EFFECTIVE_OWNER_SQL (bind name :id) instead of
        # hand-rolling the ownership-fallback predicate a second time, so a
        # future change to that rule can't silently drift between the two
        # call sites.
        ELIGIBILITY_SQL = <<~SQL.squish.freeze
          (#{Job::EFFECTIVE_OWNER_SQL})
          OR (repositories.review_policy = 'two_person' AND jobs.user_id != :id)
          OR (repositories.review_policy = 'final_say' AND jobs.repository_id IN (
            SELECT repository_id FROM repository_final_approvers WHERE user_id = :id
          ))
        SQL

        # Scopes +base+ (a Job relation) to jobs where +user_id+'s approval
        # would satisfy the job's repository review_policy. Shared with
        # Attention#apply_inbox so the "would satisfy" definition lives in
        # exactly one place.
        def self.eligible_for(base, user_id)
          return base.none if user_id.blank?

          base.joins(:repository).where(ELIGIBILITY_SQL, id: user_id)
        end

        def apply
          case op
          when :is     then eligible_scope
          when :is_not then scope.where.not(id: eligible_scope.select(:id))
          else unsupported_op!
          end
        end

        private

        def eligible_scope
          target_id = resolve_target_user_id
          return scope.none unless target_id

          self.class.eligible_for(scope, target_id)
        end

        def resolve_target_user_id
          case value.to_s
          when "me" then user&.id
          else Integer(value, exception: false)
          end
        end
      end
    end
  end
end
