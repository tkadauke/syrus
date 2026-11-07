# frozen_string_literal: true

module Deploy
  # Everything a deploy has to put back, unwound in reverse order.
  #
  # This replaces ten module-level `ACTIVE_*` variables and a cleanup function
  # whose statement order had to be kept in agreement with the order the phases
  # ran in, by hand, forever. Registering an undo next to the thing it undoes
  # makes that agreement structural: Flux is suspended first, so it is resumed
  # last, because a stack says so rather than because someone remembered.
  #
  # Three rules the previous version got wrong or could not express:
  #
  # A failing undo must not skip the ones beneath it. Leaving Flux suspended
  # because a cronjob patch failed is how a cluster stops reconciling for a
  # weekend.
  #
  # An undo may decline. Some work is more dangerous to interrupt than to leave
  # running -- a migration mid-ALTER above all -- and the only thing that can
  # judge that is the undo itself, looking at live state at the moment of
  # unwinding. `Decline` says "deliberately left alone" and prints why.
  #
  # And the order is reported, so an operator reading a failed deploy's tail
  # can see exactly what state the cluster was left in.
  class ControlStack
    # Raised by an undo block that has decided the safe thing is to leave the
    # resource as it is. Not an error: the message explains the choice.
    class Decline < StandardError; end

    Entry = Struct.new(:description, :action, keyword_init: true)

    def initialize(reporter:)
      @reporter = reporter
      @entries = []
      @unwound = false
    end

    def push(description, &action)
      @entries << Entry.new(description: description, action: action)
      self
    end

    # Work that completed successfully and whose undo is no longer wanted --
    # a cronjob already resumed by the happy path, say. Matched on description
    # so a phase can retire its own entry without holding a handle.
    def discharge(description)
      @entries.reject! { |entry| entry.description == description }
      self
    end

    def pending
      @entries.map(&:description)
    end

    def empty?
      @entries.empty?
    end

    def unwind(interrupted: false)
      return if @unwound

      @unwound = true
      @reporter.step("cleaning up deploy controls") if @entries.any? && interrupted

      while (entry = @entries.pop)
        begin
          entry.action.call
        rescue Decline => e
          @reporter.warn("left #{entry.description} in place: #{e.message}")
        rescue StandardError => e
          @reporter.error("could not restore #{entry.description}: #{e.message}")
        end
      end
    end
  end
end
