module Permissions
  # The master switch for the permission system.
  #
  # Every policy decision in the product funnels through PolicyEvaluator, so
  # turning enforcement off there turns it off everywhere at once: no asks, no
  # policy denials, every surface and role alike. That is the point. A
  # permission system is a classification of every tool, and one tool
  # classified wrong can make the product unusable -- a draft that an operator
  # must confirm anyway asking for permission first, a confirmation that
  # cannot be given. Diagnosing that is not an emergency procedure; it is
  # ordinary work, and it should not be done while the operator cannot use
  # their own instance. So there is one lever, not a profile change per
  # surface.
  #
  # What this does not touch: authentication, repository access, each tool's
  # own argument validation, and the confirmation cards that make a proposal a
  # proposal. Permissions decide whether a capability may be exercised at all;
  # everything else still decides what a caller may exercise it on.
  class Enforcement
    class << self
      def enforced?
        AppSetting.permissions_enforced?
      rescue ActiveRecord::ActiveRecordError, ActiveRecord::NoDatabaseError
        # Boot, migrations, and a database that cannot answer: enforce. The
        # switch is a deliberate operator action, never a consequence of the
        # settings row being unreadable.
        true
      end

      def disabled? = !enforced?
    end
  end
end
