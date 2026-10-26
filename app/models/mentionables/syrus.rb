module Mentionables
  class Syrus
    include Mentionable

    def mentionable_id = "syrus"
    def handle = "syrus"
    def display_name = "Syrus"
    def subtitle = "Engineer"
    def kind = "syrus"
    def avatar_url = "/bundled-avatars/syrus.svg"
    def color_key = "coral-deep"
    def agentic? = true
    def addressable_in?(_chat) = true
  end
end
