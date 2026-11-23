module Mockups
  # The chip set behind the Mockups list's filter bar.
  #
  # Registered rather than declared in core's Filters::Registry::SUBJECTS,
  # which is what lets the list ship with the plugin instead of core carrying a
  # subject for a feature it does not own.
  module FilterSubject
    CHIPS = {
      "title"      => "Mockups::Chips::Title",
      "created_at" => "Filters::Chips::CreatedAt",
      "updated_at" => "Filters::Chips::UpdatedAt"
    }.freeze

  end
end
