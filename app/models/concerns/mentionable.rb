module Mentionable
  KINDS = %w[human coworker syrus].freeze

  def mentionable_id = id
  def handle = raise(NotImplementedError)
  def display_name = raise(NotImplementedError)
  def subtitle = nil
  def kind = raise(NotImplementedError)
  def avatar_url = nil
  def avatar_key = nil
  def color_key = nil
  def agentic? = false
  def addressable_in?(_chat) = raise(NotImplementedError)
end
