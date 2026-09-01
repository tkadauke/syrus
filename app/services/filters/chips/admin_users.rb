module Filters
  module Chips
    # Namespace anchor for admin-users chips. The actual chip classes
    # (Email, Admin, HasGithubToken, GhRate) live in
    # the per-file siblings under admin_users/ or provider plugins. This
    # file just defines the module — having the chip definitions ALSO
    # inline here caused a superclass-mismatch eager-load crash in
    # production (both files defined `Email` with different
    # superclasses; Zeitwerk's lazy autoload in dev hid it,
    # eager_load tripped on the second definition).
    module AdminUsers
    end
  end
end
