module Filters
  module Chips
    module DesignDocs
      class Visibility < Syrus::Host::Filters::Chips::EnumColumn
        filter_name "visibility"
        label "Visibility"
        column :visibility
        values(*::DesignDocs::DesignDoc::VISIBILITIES)
      end
    end
  end
end
