module {{MODULE_NAME}}
  class Widget < Syrus::Host::ApplicationRecord
    self.table_name = "{{PLUGIN_NAME}}_widgets"
  end
end
