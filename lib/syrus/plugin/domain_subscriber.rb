module Syrus
  module Plugin
    # Marker interface for plugins that react to things happening in the
    # product.
    #
    # The other extension points let a plugin contribute behavior when core
    # asks for it. This one lets a plugin observe. Without it, a subsystem that
    # must react to a Job closing or a grader finishing can only live in core,
    # because the only mechanism is an Active Record callback on a core model --
    # and a plugin monkey-patching a callback onto Job is not a boundary.
    #
    # Providers declare which events they want and handle them:
    #
    #   def self.subscriptions = { "job.closed" => :on_job_closed }
    #   def self.on_job_closed(event) = ...
    #
    # `event` is a Syrus::DomainEvent carrying ids and primitives, never Active
    # Record objects: subscribers must not depend on core model internals, and
    # async delivery has to survive the record changing underneath it.
    module DomainSubscriber
    end
  end
end
