# Per-partition result of a Scope#finalize call: either a hard failure
# reason (the partition can never be capped into a valid bundle, so the
# assembler should stop searching entirely rather than trying the next
# partition) or the ordered/capped member list to evaluate against
# Scope#min_bundle_size.
class LandingBundleAssembler::Scopes::Outcome < Data.define(:reason, :members)
end
