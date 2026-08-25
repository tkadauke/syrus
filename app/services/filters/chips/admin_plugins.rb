module Filters
  module Chips
    # Namespace anchor for admin-plugins chips. The actual chip classes
    # (Category, Search) live in the per-file siblings under
    # admin_plugins/. This file just defines the module — having the
    # chip definitions ALSO inline here caused a superclass-mismatch
    # eager-load crash in production for other admin chip namespaces
    # (see admin_queue.rb / admin_users.rb): both files defined the
    # same class name with different superclasses; Zeitwerk's lazy
    # autoload in dev hid it, eager_load tripped on the second
    # definition.
    module AdminPlugins
    end
  end
end
