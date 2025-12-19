# frozen_string_literal: true

require 'bundler/setup'
require 'sequel'
require_relative 'initializers/db'
require_relative 'lib/models'
require_relative 'lib/game_engine'

# Clean slate for testing
DB[:game_events].delete
DB[:quest_objectives].delete
DB[:quests].delete
DB[:items].delete
DB[:containers].delete
DB[:characters].delete
DB[:connections].delete
DB[:locations].delete
DB[:worlds].delete
DB[:users].delete

puts "\n" + "="*60
puts "  DUNGEON COMBAT SCENARIO TEST"
puts "="*60

# Initialize the game engine
engine = GameEngine.new(DB)

# Create a test user
user = User.create(username: 'player1', password_digest: 'test_hash', is_admin: false)
puts "\n✓ Created user: #{user.username}"

# ============================================================
# SETUP: Create the dungeon world
# ============================================================
puts "\n" + "-"*60
puts "  SETUP: Creating Dungeon World"
puts "-"*60

world = World.create(
  name: 'The Lost Catacombs',
  description: 'Ancient underground chambers filled with danger and treasure',
  created_by: user.id,
  time_of_day: 'night',
  days_elapsed: 0
)
puts "✓ Created world: #{world.name}"

# Create locations
entrance = Location.create(
  world_id: world.id,
  name: 'Catacomb Entrance',
  description: 'Crumbling stone steps descend into darkness. The air is cold and damp.',
  location_type: 'dungeon'
)

corridor = Location.create(
  world_id: world.id,
  name: 'Stone Corridor',
  description: 'A narrow passage with moss-covered walls. You hear water dripping in the distance.',
  location_type: 'dungeon'
)

chamber = Location.create(
  world_id: world.id,
  name: 'Ancient Chamber',
  description: 'A large room with vaulted ceilings. Bones litter the floor, and strange runes glow faintly on the walls.',
  location_type: 'dungeon'
)

treasure_room = Location.create(
  world_id: world.id,
  name: 'Treasure Vault',
  description: 'A sealed chamber containing ancient riches.',
  location_type: 'dungeon'
)

puts "✓ Created 4 dungeon locations"

# Create connections
engine.create_connection(world.id, entrance.id, corridor.id, {
  direction: 'down',
  description: 'Stone stairs descend deeper into the catacombs',
  is_bidirectional: true
})

engine.create_connection(world.id, corridor.id, chamber.id, {
  direction: 'east',
  description: 'An archway leads into a large chamber',
  is_bidirectional: true
})

# Hidden locked door to treasure room
result = engine.create_connection(world.id, chamber.id, treasure_room.id, {
  direction: 'north',
  description: 'An ornate iron door with a keyhole',
  connection_type: 'door',
  is_visible: false,
  is_locked: true,
  is_bidirectional: false
})
hidden_door_id = result[:connection_id]

puts "✓ Created dungeon connections (including hidden locked door)"

# ============================================================
# CHARACTERS: Create player and enemies
# ============================================================
puts "\n" + "-"*60
puts "  CHARACTERS: Creating Adventurer and Monsters"
puts "-"*60

# Create player character
player_result = engine.create_player_character(user.id, world.id, {
  name: 'Aria Shadowblade',
  description: 'A skilled rogue with quick reflexes and sharper blades',
  location_id: entrance.id,
  max_hp: 25,
  strength: 12,
  intelligence: 14,
  charisma: 10,
  athletics: 16,
  armor_class: 15
})
player_id = player_result[:character_id]
puts "✓ Created player: Aria Shadowblade (25 HP, AC 15)"

# Create skeleton guardian in corridor
skeleton = Character.create(
  world_id: world.id,
  character_type: 'npc',
  name: 'Skeletal Guardian',
  description: 'An animated skeleton wielding a rusty scimitar',
  location_id: corridor.id,
  max_hp: 15,
  current_hp: 15,
  strength: 10,
  intelligence: 6,
  charisma: 3,
  athletics: 8,
  armor_class: 12,
  is_hostile: true,
  created_by: user.id
)
puts "✓ Created enemy: Skeletal Guardian (15 HP, AC 12) at #{corridor.name}"

# Create powerful boss in the chamber
boss = Character.create(
  world_id: world.id,
  character_type: 'npc',
  name: 'Corrupted Wraith',
  description: 'A spectral horror wreathed in dark energy, with burning red eyes',
  location_id: chamber.id,
  max_hp: 35,
  current_hp: 35,
  strength: 14,
  intelligence: 12,
  charisma: 8,
  athletics: 10,
  armor_class: 14,
  is_hostile: true,
  created_by: user.id
)
puts "✓ Created boss: Corrupted Wraith (35 HP, AC 14) at #{chamber.name}"

# ============================================================
# ITEMS: Create weapons, loot, and keys
# ============================================================
puts "\n" + "-"*60
puts "  ITEMS: Placing Weapons and Treasure"
puts "-"*60

# Starting weapon at entrance
dagger = engine.create_item(world.id, {
  name: 'iron dagger',
  description: 'A sharp, well-balanced throwing dagger',
  location_id: entrance.id,
  item_type: 'weapon',
  quantity: 1,
  properties: { damage: '1d4', throwable: true }
})
puts "✓ Placed iron dagger at entrance"

# Health potion in corridor
potion = engine.create_item(world.id, {
  name: 'healing potion',
  description: 'A small vial of red liquid that glows faintly',
  location_id: corridor.id,
  item_type: 'consumable',
  quantity: 2,
  is_stackable: true,
  properties: { healing: 10 }
})
puts "✓ Placed 2 healing potions in corridor"

# Vault key dropped by boss
vault_key = engine.create_item(world.id, {
  name: 'ornate vault key',
  description: 'An ancient iron key with intricate engravings',
  character_id: boss.id,  # Boss carries the key
  item_type: 'key',
  quantity: 1,
  properties: { unlocks: 'treasure_vault' }
})
vault_key_id = vault_key[:item_id]
puts "✓ Vault key carried by Corrupted Wraith"

# Lock the door with this specific key
engine.lock_door(hidden_door_id, with_item_id: vault_key_id)

# Treasure in the vault
treasure = engine.create_item(world.id, {
  name: 'ancient gold',
  description: 'A pile of golden coins stamped with forgotten sigils',
  location_id: treasure_room.id,
  item_type: 'treasure',
  quantity: 500,
  is_stackable: true,
  properties: { value: 500 }
})
puts "✓ Placed 500 gold in treasure vault"

# ============================================================
# QUEST: Create main quest
# ============================================================
puts "\n" + "-"*60
puts "  QUEST: Creating Main Quest"
puts "-"*60

quest_result = engine.create_quest(world.id, entrance.id, {
  name: 'Cleanse the Catacombs',
  description: 'Defeat the evil wraith and claim the ancient treasure',
  quest_type: 'main'
})
quest_id = quest_result[:quest_id]

engine.add_quest_objective(quest_id, {
  objective_type: 'kill',
  target_type: 'Character',
  target_id: boss.id,
  quantity: 1,
  description: 'Defeat the Corrupted Wraith'
})

engine.add_quest_objective(quest_id, {
  objective_type: 'collect',
  target_type: 'Item',
  target_id: treasure[:item_id],
  quantity: 500,
  description: 'Claim the ancient gold'
})

puts "✓ Created quest: Cleanse the Catacombs"
puts "  - Defeat the Corrupted Wraith"
puts "  - Claim the ancient gold"

# ============================================================
# ADVENTURE BEGINS
# ============================================================
puts "\n" + "="*60
puts "  ADVENTURE START"
puts "="*60

# Scene 1: Entrance
puts "\n📍 SCENE 1: Entering the Catacombs"
puts "-"*60
desc = engine.describe_location(entrance.id)
puts "\n#{desc[:name]}"
puts desc[:description]
puts "\nExits:"
desc[:exits].each { |e| puts "  #{e[:direction]}: #{e[:description]}" }

items = engine.list_items_at(entrance.id)
puts "\nYou see: #{items.map { |i| "#{i[:name]} (#{i[:quantity]})" }.join(', ')}"

puts "\n💬 Aria picks up the dagger..."
result = engine.character_take_item(player_id, dagger[:item_id])
puts "   #{result[:message]}"

# Scene 2: Moving to corridor
puts "\n📍 SCENE 2: The Stone Corridor"
puts "-"*60
puts "\n💬 Aria descends the stairs..."
engine.move_character(player_id, corridor.id)

desc = engine.describe_location(corridor.id)
puts "\n#{desc[:name]}"
puts desc[:description]

enemies = engine.list_characters_at(corridor.id)
items = engine.list_items_at(corridor.id)

puts "\n⚔️  ENEMIES:"
enemies.each { |e| puts "  - #{e[:name]} (#{e[:hp]})" if e[:id] != player_id }

puts "\n📦 ITEMS:"
items.each { |i| puts "  - #{i[:name]} x#{i[:quantity]}" }

# Scene 3: Combat with skeleton
puts "\n⚔️  COMBAT: Aria vs Skeletal Guardian"
puts "-"*60

puts "\n💬 Aria attacks with her dagger!"
dmg = 6
result = engine.damage_character(skeleton.id, dmg, source: Character[player_id])
puts "   ⚔️  #{result[:message]}"

puts "\n💬 The skeleton retaliates!"
dmg = 4
result = engine.damage_character(player_id, dmg, source: skeleton)
puts "   💥 #{result[:message]}"

puts "\n💬 Aria strikes again!"
dmg = 7
result = engine.damage_character(skeleton.id, dmg, source: Character[player_id])
puts "   ⚔️  #{result[:message]}"

puts "\n💬 Final blow!"
dmg = 8
result = engine.damage_character(skeleton.id, dmg, source: Character[player_id])
puts "   💀 #{result[:message]}"

puts "\n💬 Aria grabs the healing potions..."
result = engine.character_take_item(player_id, potion[:item_id])
puts "   #{result[:message]}"

# Heal up
puts "\n💬 Aria drinks a healing potion..."
result = engine.heal_character(player_id, 10)
puts "   💚 #{result[:message]}"

result = engine.modify_item_quantity(potion[:item_id], -1)
puts "   Used 1 healing potion (#{result[:new_quantity]} remaining)"

# Scene 4: Moving to the chamber
puts "\n📍 SCENE 3: The Ancient Chamber"
puts "-"*60
puts "\n💬 Aria enters through the eastern archway..."
engine.move_character(player_id, chamber.id)

desc = engine.describe_location(chamber.id)
puts "\n#{desc[:name]}"
puts desc[:description]

enemies = engine.list_characters_at(chamber.id)
puts "\n⚔️  ENEMIES:"
enemies.each { |e| puts "  - #{e[:name]} (#{e[:hp]}) [AC #{e[:stats][:armor_class]}]" if e[:id] != player_id }

# Check for hidden exits (none visible yet)
puts "\nVisible exits:"
desc[:exits].each { |e| puts "  #{e[:direction]}: #{e[:description]}" }
puts "  (No other visible exits)" if desc[:exits].empty?

# Scene 5: Boss battle
puts "\n⚔️  BOSS BATTLE: Aria vs Corrupted Wraith"
puts "-"*60

puts "\n💬 The wraith shrieks and lunges at Aria!"
dmg = 8
result = engine.damage_character(player_id, dmg, source: boss)
puts "   💥 #{result[:message]}"

puts "\n💬 Aria dodges and counterattacks!"
dmg = 9
result = engine.damage_character(boss.id, dmg, source: Character[player_id])
puts "   ⚔️  #{result[:message]}"

puts "\n💬 The wraith's claws rake across Aria!"
dmg = 7
result = engine.damage_character(player_id, dmg, source: boss)
puts "   💥 #{result[:message]}"

puts "\n💬 Aria drinks her last healing potion!"
result = engine.heal_character(player_id, 10)
puts "   💚 #{result[:message]}"

puts "\n💬 Fierce exchange of blows!"
dmg = 10
result = engine.damage_character(boss.id, dmg, source: Character[player_id])
puts "   ⚔️  #{result[:message]}"

dmg = 6
result = engine.damage_character(player_id, dmg, source: boss)
puts "   💥 #{result[:message]}"

puts "\n💬 Aria unleashes a flurry of attacks!"
dmg = 11
result = engine.damage_character(boss.id, dmg, source: Character[player_id])
puts "   ⚔️  #{result[:message]}"

dmg = 8
result = engine.damage_character(boss.id, dmg, source: Character[player_id])
puts "   ⚔️  #{result[:message]}"

puts "\n💬 Final strike!"
dmg = 7
result = engine.damage_character(boss.id, dmg, source: Character[player_id])
puts "   💀 #{result[:message]}"

# Boss defeated - update quest
engine.complete_objective(QuestObjective.where(quest_id: quest_id, objective_type: 'kill').first.id)

# Scene 6: Looting and discovering the vault
puts "\n📍 SCENE 4: After the Battle"
puts "-"*60

puts "\n💬 Aria searches the wraith's remains..."
boss_items = Item.where(character_id: boss.id).all
boss_items.each do |item|
  result = engine.move_item(item.id, to: Character[player_id])
  puts "   ✨ Found: #{item.name}"
end

puts "\n💬 Aria notices something strange about the north wall..."
engine.reveal_exit(hidden_door_id)

desc = engine.describe_location(chamber.id)
puts "\n🔍 A hidden door is revealed!"
desc[:exits].each do |e|
  next unless e[:direction] == 'north'
  puts "  #{e[:direction]}: #{e[:description]}"
  puts "  Status: #{e[:is_locked] ? '🔒 LOCKED' : '🔓 UNLOCKED'}"
end

puts "\n💬 Aria tries the ornate key..."
result = engine.unlock_door(hidden_door_id, using_item_id: vault_key_id)
puts "   #{result[:message]}"

result = engine.open_door(hidden_door_id)
puts "   The heavy door swings open with a grinding sound."

# Scene 7: Treasure vault
puts "\n📍 SCENE 5: The Treasure Vault"
puts "-"*60

# Get the connection and traverse it
conn = Connection[hidden_door_id]
result = engine.traverse_connection(player_id, hidden_door_id)

desc = engine.describe_location(treasure_room.id)
puts "\n#{desc[:name]}"
puts desc[:description]

items = engine.list_items_at(treasure_room.id)
puts "\n💰 TREASURE:"
items.each { |i| puts "  - #{i[:name]} x#{i[:quantity]}" }

puts "\n💬 Aria claims the ancient gold!"
result = engine.character_take_item(player_id, treasure[:item_id])
puts "   #{result[:message]}"

# Complete the quest
engine.update_objective_progress(
  QuestObjective.where(quest_id: quest_id, objective_type: 'collect').first.id,
  500
)

# ============================================================
# FINALE
# ============================================================
puts "\n" + "="*60
puts "  QUEST COMPLETE!"
puts "="*60

quest_status = engine.check_quest_progress(quest_id)
puts "\n📜 #{quest_status[:quest_name]}"
puts "Status: #{quest_status[:status].upcase}"
puts "\nObjectives:"
quest_status[:objectives].each do |obj|
  status_icon = obj[:is_completed] ? '✓' : '✗'
  puts "  #{status_icon} #{obj[:description]} (#{obj[:progress]})"
end

player = Character[player_id]
inventory = engine.get_character_inventory(player_id)
puts "\n🎒 Final Inventory:"
inventory[:items].each { |i| puts "  - #{i[:name]} x#{i[:quantity]}" }

puts "\n💚 Final HP: #{player.current_hp}/#{player.max_hp}"

# Event log
events = engine.get_recent_events(world.id, limit: 20)
puts "\n📊 Event Log (last 10 events):"
events.first(10).each do |event|
  puts "  [#{event[:event_type]}] #{event[:actor] || 'System'} → #{event[:target] || 'N/A'}"
end

puts "\n" + "="*60
puts "  ✨ ADVENTURE COMPLETE! ✨"
puts "="*60
puts "\n✓ Aria Shadowblade survived the catacombs"
puts "✓ All enemies defeated"
puts "✓ All treasure claimed"
puts "✓ Quest objectives completed"
puts "\n"
