# frozen_string_literal: true

require 'json'

# Main GameEngine class: Single source of truth for all game state
# Orchestrates all game interactions, enforces rules, logs events
# Uses module inclusion for clean access to all manager methods
class GameEngine
  # Auto-load all manager modules from game_engine/ directory
  Dir.glob(File.join(__dir__, 'game_engine', '*.rb')).sort.each do |file|
    module_name = File.basename(file, '.rb')
    require_relative "game_engine/#{module_name}"
    include Object.const_get(module_name.split('_').map(&:capitalize).join)
  end

  def initialize(db)
    @db = db
  end
end
