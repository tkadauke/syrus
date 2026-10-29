module Mentionables
  class Syrus
    include Mentionable

    def mentionable_id = "syrus"
    def handle = "syrus"
    def display_name = "Syrus"
    def subtitle = "Engineer"
    def kind = "syrus"
    def avatar_url = nil
    # Blush is the closest library color to the previous light-mode Syrus
    # initials color (#e9b7aa) by OKLab distance.
    def accent_hex = "#FBCFD3"
    def agentic? = true
    def addressable_in?(_chat) = true
  end
end
