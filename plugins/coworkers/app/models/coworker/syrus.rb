module Coworker
  class Syrus
    include Mentionable

    def self.for(user) = new(user)

    attr_reader :owner_user

    def initialize(user) = @owner_user = user
    def mentionable_id = "syrus"
    def handle = "syrus"
    def display_name = "Syrus"
    def name = display_name
    def subtitle = "Engineer"
    def role_summary = subtitle
    def kind = "syrus"
    def accent_hex = "#FBCFD3"
    def agentic? = true
    def addressable_in?(_chat) = true
    def grants = []
    def chats = owner_user.chat_sessions
    def schedules = ScheduledTasks::Task.where(user_id: owner_user.id)
    def workspace_repo = nil
    def avatar_key = nil
    def avatar_url = nil
    def state = "active"
    def persisted? = false
  end
end
