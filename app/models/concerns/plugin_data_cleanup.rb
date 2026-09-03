# Lets plugins clean up rows they own when a core record is destroyed, without
# declaring associations on the core model (see Syrus::DataCleanup).
#
# Runs in `before_destroy` so cleanup is inside the same transaction as the
# destroy, matching what `dependent: :destroy` did.
module PluginDataCleanup
  extend ActiveSupport::Concern

  included do
    before_destroy { Syrus::DataCleanup.run!(self) }
  end
end
