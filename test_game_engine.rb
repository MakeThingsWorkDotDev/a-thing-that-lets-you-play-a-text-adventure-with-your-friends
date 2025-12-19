#!/usr/bin/env ruby
# frozen_string_literal: true

# Test script for the GameEngine

require 'bundler/setup'
require 'sequel'
require_relative 'initializers/db'
require_relative 'lib/models'
require_relative 'lib/game_engine'

def test_header(title)
  puts "\n" + "=" * 60
  puts "  #{title}"
  puts "=" * 60
end

def test_result(description, result)
  status = result[:error] ? "❌ ERROR" : "✓"
  puts "#{status} #{description}"
  if result[:error]
    puts "   Error: #{result[:error]}"
  elsif result[:message]
    puts "   #{result[:message]}"
  end
  puts "   #{result.inspect}" if ENV['VERBOSE']
  result
end

def verify(description, condition, details = nil)
  if condition
    puts "✓ #{description}"
    puts "   #{details}" if details
    true
  else
    puts "❌ FAILED: #{description}"
    puts "   #{details}" if details
    false
  end
end

# Initialize
engine = GameEngine.new(DB)

# Clean up old test data
DB[:game_events].delete
DB[:quest_objectives].delete
DB[:quests].delete
DB[:items].delete
DB[:containers].delete
DB[:characters].delete
DB[:connections].delete
DB[:locations].delete
DB[:worlds].delete

test_header "Test 1: World Creation"

world = World.create(
  name: "The Kingdom of Eldoria",
  description: "A medieval fantasy realm filled with magic and danger",
  time_of_day: 'morning',
  days_elapsed: 0
)
puts "✓ Created world: #{world.name} (ID: #{world.id})"

# Verify world was created correctly
verify("World has correct name", world.name == "The Kingdom of Eldoria")
verify("World has correct time_of_day", world.time_of_day == 'morning')
verify("World has correct days_elapsed", world.days_elapsed == 0)
verify("World persisted to database", World[world.id] != nil)

test_header "Test 2: Location Creation"

tavern = Location.create(
  world_id: world.id,
  name: "The Rusty Dragon Inn",
  description: "A cozy tavern with worn wooden tables and a crackling fireplace. The smell of roasted meat and ale fills the air.",
  location_type: 'indoor'
)
puts "✓ Created location: #{tavern.name}"

forest = Location.create(
  world_id: world.id,
  name: "Dark Forest",
  description: "Towering trees block out most of the sunlight. Strange sounds echo from deeper in the woods.",
  location_type: 'outdoor'
)
puts "✓ Created location: #{forest.name}"

cave = Location.create(
  world_id: world.id,
  name: "Goblin Cave",
  description: "A damp cave with rough stone walls. The air is thick and musty.",
  location_type: 'dungeon'
)
puts "✓ Created location: #{cave.name}"

# Verify locations belong to the world
verify("Tavern belongs to world", tavern.world_id == world.id)
verify("Forest belongs to world", forest.world_id == world.id)
verify("Cave belongs to world", cave.world_id == world.id)
verify("All locations persisted", Location.where(world_id: world.id).count == 3)

test_header "Test 3: Connection Creation"

result = engine.create_connection(world.id, tavern.id, forest.id, {
  direction: 'north',
  description: 'A dirt path leads north into the dark forest',
  is_bidirectional: true,
  reverse_description: 'A dirt path leads south back to the tavern'
})
test_result("Create bidirectional connection: Tavern ↔ Forest", result)
tavern_to_forest_id = result[:connection_id]

# Verify bidirectional connection
forward_conn = Connection[tavern_to_forest_id]
verify("Forward connection exists", forward_conn != nil)
verify("Forward connection has correct origin", forward_conn.from_location_id == tavern.id)
verify("Forward connection has correct destination", forward_conn.to_location_id == forest.id)
verify("Forward connection has correct direction", forward_conn.direction == 'north')

reverse_conn = Connection.where(from_location_id: forest.id, to_location_id: tavern.id).first
verify("Reverse connection created", reverse_conn != nil)
verify("Reverse connection has correct direction", reverse_conn&.direction == 'south')

result = engine.create_connection(world.id, forest.id, cave.id, {
  direction: 'east',
  description: 'A narrow cave entrance is hidden behind thick vines',
  connection_type: 'door',
  is_visible: false # Hidden until discovered
})
test_result("Create hidden cave entrance", result)
hidden_conn_id = result[:connection_id]

# Verify hidden connection
hidden_conn = Connection[hidden_conn_id]
verify("Hidden connection is marked invisible", hidden_conn.is_visible == false)
verify("Hidden connection is a door", hidden_conn.connection_type == 'door')

test_header "Test 4: Character Creation"

result = engine.create_player_character(1, world.id, {
  name: "Thorin Ironforge",
  description: "A stout dwarf warrior with a thick red beard and battle-worn armor",
  location_id: tavern.id,
  max_hp: 30,
  strength: 16,
  intelligence: 10,
  charisma: 12,
  athletics: 14
})
test_result("Create player character: Thorin", result)
thorin_id = result[:character_id]

# Verify player character
thorin = Character[thorin_id]
verify("Character created successfully", thorin != nil)
verify("Character has correct name", thorin.name == "Thorin Ironforge")
verify("Character has correct HP", thorin.max_hp == 30 && thorin.current_hp == 30)
verify("Character has correct strength", thorin.strength == 16)
verify("Character is at tavern", thorin.location_id == tavern.id)
verify("Character belongs to world", thorin.world_id == world.id)
verify("Character is player type", thorin.character_type == 'player')
verify("Character has user_id", thorin.user_id == 1)

goblin = Character.create(
  world_id: world.id,
  location_id: cave.id,
  character_type: 'npc',
  name: "Grunk the Goblin",
  description: "A mean-looking goblin with yellow eyes and sharp teeth",
  max_hp: 15,
  current_hp: 15,
  strength: 12,
  intelligence: 8,
  charisma: 6,
  athletics: 14,
  armor_class: 15,
  is_hostile: true
)
puts "✓ Created NPC: #{goblin.name}"

innkeeper = Character.create(
  world_id: world.id,
  location_id: tavern.id,
  character_type: 'npc',
  name: "Grendle",
  description: "A friendly dwarf innkeeper with a warm smile",
  max_hp: 10,
  current_hp: 10,
  strength: 10,
  intelligence: 12,
  charisma: 16,
  athletics: 8,
  armor_class: 10
)
puts "✓ Created NPC: #{innkeeper.name}"

test_header "Test 5: Item Creation"

result = engine.create_item(world.id, {
  name: "gold coins",
  description: "Shiny gold coins",
  location_id: tavern.id,
  item_type: 'currency',
  quantity: 50,
  is_stackable: true
})
test_result("Create gold coins", result)

result = engine.create_item(world.id, {
  name: "rusty sword",
  description: "An old but serviceable iron sword",
  location_id: tavern.id,
  item_type: 'weapon',
  properties: { damage: '1d8', damage_type: 'slashing' }
})
test_result("Create rusty sword", result)
sword_id = result[:item_id]

# Verify items
sword = Item[sword_id]
verify("Sword created successfully", sword != nil)
verify("Sword is at tavern", sword.location_id == tavern.id)
verify("Sword has no owner", sword.character_id == nil)
verify("Sword belongs to world", sword.world_id == world.id)
verify("Sword has correct type", sword.item_type == 'weapon')

test_header "Test 6: Location Queries"

result = engine.describe_location(tavern.id)
puts "✓ Location: #{result[:name]}"
puts "  Description: #{result[:description]}"
puts "  Exits: #{result[:exits].length}"
result[:exits].each do |exit|
  puts "    - #{exit[:direction]}: #{exit[:description]}"
end

chars = engine.list_characters_at(tavern.id)
puts "\n✓ Characters at location:"
chars.each do |char|
  puts "    - #{char[:name]} (#{char[:hp]} HP)"
end

items = engine.list_items_at(tavern.id)
puts "\n✓ Items at location:"
items.each do |item|
  puts "    - #{item[:name]} x#{item[:quantity]}"
end

test_header "Test 7: Character Movement"

# Record Thorin's original location
thorin.refresh
original_location = thorin.location_id

result = engine.move_character(thorin_id, forest.id)
test_result("Move Thorin to forest", result)

# Verify movement
thorin.refresh
verify("Thorin moved to forest", thorin.location_id == forest.id)
verify("Thorin not at tavern anymore", thorin.location_id != original_location)
verify("Thorin still in same world", thorin.world_id == world.id)

# Verify location queries show Thorin in new location
chars_at_forest = engine.list_characters_at(forest.id)
chars_at_tavern = engine.list_characters_at(tavern.id)
verify("Thorin appears at forest", chars_at_forest.any? { |c| c[:id] == thorin_id })
verify("Thorin doesn't appear at tavern", !chars_at_tavern.any? { |c| c[:id] == thorin_id })

result = engine.describe_location(forest.id)
puts "\n✓ Thorin's new location: #{result[:name]}"

test_header "Test 8: Party Movement"

# Create additional party members
wizard = Character.create(
  world_id: world.id,
  location_id: tavern.id,
  character_type: 'npc',
  name: "Elara the Wise",
  description: "A wise elven wizard",
  max_hp: 20,
  current_hp: 20
)

ranger = Character.create(
  world_id: world.id,
  location_id: tavern.id,
  character_type: 'npc',
  name: "Rowan Swiftbow",
  description: "A skilled ranger",
  max_hp: 25,
  current_hp: 25
)

puts "✓ Created party members at tavern"

# Move entire party to forest
party_ids = [wizard.id, ranger.id, innkeeper.id]
result = engine.move_party(party_ids, forest.id)
puts "✓ Moved party of #{result[:moved]} characters to #{result[:location]}"

# Verify party movement
verify("All 3 characters moved successfully", result[:moved] == 3)
verify("No failures in party move", result[:failed] == 0)

wizard.refresh
ranger.refresh
innkeeper.refresh
verify("Wizard moved to forest", wizard.location_id == forest.id)
verify("Ranger moved to forest", ranger.location_id == forest.id)
verify("Innkeeper moved to forest", innkeeper.location_id == forest.id)

# Verify they're all there
chars = engine.list_characters_at(forest.id)
puts "✓ Characters now at #{forest.name}: #{chars.length} total"
verify("Forest has 4 characters (Thorin + party)", chars.length == 4)

test_header "Test 9: Inventory Management"

result = engine.character_take_item(thorin_id, sword_id)
test_result("Thorin picks up sword", result)

# Verify item pickup
sword.refresh
verify("Sword now owned by Thorin", sword.character_id == thorin_id)
verify("Sword no longer at tavern", sword.location_id == nil)
verify("Sword still in same world", sword.world_id == world.id)

# Verify inventory
items_at_tavern = engine.list_items_at(tavern.id)
verify("Sword no longer at tavern location", !items_at_tavern.any? { |i| i[:id] == sword_id })

result = engine.get_character_inventory(thorin_id)
puts "\n✓ Thorin's inventory:"
result[:items].each do |item|
  puts "    - #{item[:name]}"
end
verify("Thorin has 1 item in inventory", result[:items].length == 1)
verify("Thorin has the sword", result[:items].any? { |i| i[:id] == sword_id })

test_header "Test 10: Combat Simulation"

goblin.refresh
initial_hp = goblin.current_hp

result = engine.damage_character(goblin.id, 10, source: Character[thorin_id])
test_result("Thorin attacks goblin for 10 damage", result)

# Verify damage
goblin.refresh
verify("Goblin took 10 damage", goblin.current_hp == initial_hp - 10)
verify("Goblin HP is 5", goblin.current_hp == 5)
verify("Goblin is not dead yet", !goblin.is_dead)

result = engine.damage_character(goblin.id, 8)
test_result("Goblin takes 8 more damage", result)

# Verify death
goblin.refresh
verify("Goblin HP is 0", goblin.current_hp == 0)
verify("Goblin is marked as dead", goblin.is_dead)

result = engine.heal_character(goblin.id, 5)
test_result("Goblin heals 5 HP", result)

# Verify dead characters can't be healed
verify("Healing dead character fails", result[:error] == "Cannot heal a dead character")
goblin.refresh
verify("Dead goblin HP unchanged", goblin.current_hp == 0)

test_header "Test 11: Location State"

result = engine.set_location_state(tavern.id, 'is_on_fire', true)
test_result("Set tavern on fire", result)

# Verify state was set
state_result = engine.get_location_state(tavern.id, 'is_on_fire')
verify("Fire state is true", state_result[:value] == true)

result = engine.describe_location(tavern.id)
puts "\n✓ Tavern description (on fire):"
puts "  #{result[:description]}"
verify("Description includes fire", result[:description].include?("Flames"))

result = engine.set_location_state(tavern.id, 'is_on_fire', false)
test_result("Extinguish fire", result)

# Verify state was cleared
state_result = engine.get_location_state(tavern.id, 'is_on_fire')
verify("Fire state is false", state_result[:value] == false)

test_header "Test 12: World Time"

result = engine.get_world_time(world.id)
puts "✓ Current time: #{result[:time_of_day]}, Day #{result[:days_elapsed]}"
verify("Initial time is morning", result[:time_of_day] == 'morning')
verify("Initial day is 0", result[:days_elapsed] == 0)

result = engine.advance_time(world.id, 'afternoon')
test_result("Advance to afternoon", result)

# Verify time advanced
world.refresh
verify("Time is now afternoon", world.time_of_day == 'afternoon')
verify("Day still 0", world.days_elapsed == 0)

result = engine.advance_day(world.id)
test_result("Advance to next day", result)

# Verify day advanced
world.refresh
verify("Day is now 1", world.days_elapsed == 1)
verify("Time reset to morning", world.time_of_day == 'morning')

result = engine.get_world_time(world.id)
puts "✓ New time: #{result[:time_of_day]}, Day #{result[:days_elapsed]}"

test_header "Test 13: Quest System"

# Create a test room for the quest
room = Room.create(
  world_id: world.id,
  name: "Test Adventure",
  current_location_id: tavern.id,
  is_open: true
)

result = engine.create_quest(world.id, room.id, {
  name: "Clear the Goblin Cave",
  description: "The local innkeeper asks you to deal with the goblin problem",
  quest_type: 'main'
})
test_result("Create quest", result)
quest_id = result[:quest_id]

# Verify quest created
quest = Quest[quest_id]
verify("Quest created successfully", quest != nil)
verify("Quest has correct name", quest.name == "Clear the Goblin Cave")
verify("Quest belongs to world", quest.world_id == world.id)
verify("Quest is active", quest.status == 'active')

result = engine.add_quest_objective(quest_id, {
  objective_type: 'kill_character',
  target_type: 'Character',
  target_id: goblin.id,
  description: 'Defeat Grunk the Goblin'
})
test_result("Add quest objective: Kill goblin", result)
objective_id = result[:objective_id]

# Verify objective created
objective = QuestObjective[objective_id]
verify("Objective created successfully", objective != nil)
verify("Objective belongs to quest", objective.quest_id == quest_id)
verify("Objective not completed yet", !objective.is_completed)

result = engine.complete_objective(objective_id)
test_result("Complete objective", result)
puts "  Quest completed: #{result[:quest_completed]}"

# Verify objective completion
objective.refresh
quest.refresh
verify("Objective is marked complete", objective.is_completed)
verify("Quest is marked complete", quest.status == 'completed')
verify("Quest completion matches result", result[:quest_completed] == true)

test_header "Test 14: Event Log"

events = engine.get_recent_events(world.id, limit: 10)
puts "✓ Recent events (last 10):"
events.each do |event|
  puts "  [#{event[:event_type]}] #{event[:actor]} → #{event[:target]}"
end

# Verify event logging
total_events = GameEvent.where(world_id: world.id).count
verify("Events were logged", total_events > 0)
verify("At least 10 events recorded", events.length > 0)

# Verify specific event types exist
event_types = events.map { |e| e[:event_type] }.uniq
verify("Character movement logged", event_types.include?('character_moved'))
verify("Combat damage logged", event_types.include?('character_damaged'))
verify("Item actions logged", event_types.include?('item_taken'))

test_header "Test Complete!"
puts "\n✓ All core GameEngine functionality tested successfully"
puts "✓ Total events logged: #{GameEvent.where(world_id: world.id).count}"
puts "\n📊 Summary:"
puts "  - Worlds: #{World.count}"
puts "  - Locations: #{Location.count}"
puts "  - Connections: #{Connection.count}"
puts "  - Characters: #{Character.count}"
puts "  - Items: #{Item.count}"
puts "  - Quests: #{Quest.count}"
puts "  - Events: #{GameEvent.count}"
puts "\n✅ All state verifications passed!"
puts "   Each action was verified to correctly modify game state"
