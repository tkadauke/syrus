module Policy
  # One precedence rule for "what does this project want" (workflow-engine-v3 C0).
  #
  # `AutoApprovalRule` already builds an explicit ordered candidate chain --
  # ScheduledTask, Epic, Repository, User -- and reports which link answered.
  # This generalizes that; the plan calls it promotion rather than invention.
  #
  # The problem it fixes is that three sibling resolvers currently give three
  # different answers to "what if the repo does not say": one returns disabled
  # and relies on its caller to un-disable it, one returns the instance default
  # from inside itself, and one has no instance tier at all. Same question,
  # three shapes.
  #
  # Two properties matter more than the ordering itself:
  #
  #   * which tier answered is returned, not just the value, so a surprising
  #     posture can be traced instead of reverse-engineered;
  #   * a tier that *cannot be read* is not the same as a tier that said
  #     nothing. See Policy::Unreadable.
  class Resolver
    # A tier whose answer could not be read -- a GitHub outage, missing
    # credentials, an unparseable file. Distinct from nil, because degrading to
    # a default here is what silently relaxes a project's risk posture.
    Unreadable = Class.new(StandardError)

    Result = Data.define(:value, :source, :readable) do
      def readable? = readable
      def unreadable? = !readable
      def to_s = "#{value.inspect} from #{source}"
    end

    # `candidates` is an ordered list of [source_label, callable]. The first
    # candidate returning a non-nil value wins.
    def self.call(candidates:, default: nil, default_source: "default", fail_closed: true)
      candidates.each do |source, resolve|
        value =
          begin
            resolve.call
          rescue Unreadable => e
            # Policy that cannot be read fails closed: the caller defers rather
            # than proceeding under a default it did not choose.
            return Result.new(value: nil, source: "#{source} (unreadable: #{e.message})", readable: false) if fail_closed

            nil
          end

        return Result.new(value: value, source: source, readable: true) unless value.nil?
      end

      Result.new(value: default, source: default_source, readable: true)
    end
  end
end
