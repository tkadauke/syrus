# Wraps today's Epic access rules: the base visibility scope
# (`Epic.accessible_to(user)`, from repository membership) plus the
# repository write access plus owner/admin for unclaim, admin-only for
# reassigning via the `owner_user_id` param, and the product-owner advancement
# block. Global admins bypass all of it.
class EpicPolicy < ApplicationPolicy
  # Mutating an Epic requires effective write access to its repository.
  # Repository#member_at_least? includes direct memberships, team grants,
  # and the global-admin bypass.
  def write?
    record&.repository&.member_at_least?(user, "write") || false
  end

  # Mirrors EpicsController#unclaim's existing guard: only the current
  # claimant or an admin may release a claim.
  def unclaim?
    admin? || record.owner_user_id == user&.id
  end

  # Mirrors EpicsController#reassign's existing guard: reassigning via the
  # `owner_user_id` param is admin-only; the legacy `owner_id` param path is
  # not restricted here (see EpicsController#reassign).
  def reassign?(via_owner_user_id_param:)
    !via_owner_user_id_param || admin?
  end

  # Mirrors EpicsController#authorize_epic_action!'s existing guard: product
  # owners cannot advance an Epic into ready/in_progress/done.
  def advance_state?(target_state:)
    !(user&.product_owner? && target_state.to_s.in?(%w[ready in_progress done]))
  end

  # Scope intentionally does NOT bypass for admins: `Epic.accessible_to`
  # never did, and the index/find call sites this backs must not change
  # visibility. Admin bypass lives on the per-action predicates above,
  # mirroring the admin escapes EpicsController already had for unclaim
  # and reassign before this policy layer existed.
  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.accessible_to(user)
    end
  end
end
