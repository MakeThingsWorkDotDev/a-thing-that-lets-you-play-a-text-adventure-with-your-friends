# Game Master Engine Redesign Plan

## Problem Statement

The current `ai_game_master.rb` implementation is tightly coupled, difficult to follow, and mixes concerns between game state management and AI interaction. We need a clean separation between:

1. **Game Engine**: Manages world state, enforces rules, handles interactions
2. **AI Integration**: Queries the engine for context and executes actions through it

## Design Philosophy

### Core Principles

1. **Single Source of Truth**: The game engine owns all state
2. **Minimal AI Context**: AI receives only what's necessary, queries for more
3. **UI-First**: Engine designed to support human game masters via UI
4. **Tool-Based AI**: AI uses well-defined tools to interact with the world
5. **Separation of Concerns**: Game logic separate from AI logic

## High-Level Model Architecture

### Model Relationship Overview

```
World
 ├── time_of_day, days_elapsed (manual time tracking)
 ├── world_state (global flags/variables JSON)
 │
 ├── Locations (places in the world)
 │    ├── state (dynamic JSON: is_on_fire, water_level, etc.)
 │    ├── Connections (exits between locations)
 │    │    └── connection_type (passage, door, portal, teleporter, magical)
 │    ├── Characters (NPCs/PCs at this location)
 │    ├── Containers (chests, etc. at this location)
 │    └── Items (loose items on ground)
 │
 ├── Rooms (game sessions)
 │    ├── current_location_id → Location (where the party is now)
 │    ├── user_rooms (join table)
 │    │    ├── user_id → User
 │    │    ├── character_id → Character (player's character in this room)
 │    │    └── is_muted, hand_raised (session state)
 │    ├── ChatMessages (linked to character_id)
 │    └── Quests (active/completed quests for this session)
 │         └── QuestObjectives (goals: reach location, get item, kill character)
 │
 └── GameEvents (audit log of all state changes)
      ├── event_type, actor, target
      └── event_data (JSON details)

User
 └── Characters (player characters owned by this user across all worlds)
      └── character_type = 'player' (one per world typically)

Character (can be NPC or player character)
 ├── user_id → User (if player character, NULL if NPC)
 ├── Inventory: Items (carried by character)
 └── Inventory: Containers (bags, etc. carried by character)
      └── Items (inside carried containers)

Container
 └── Items (inside container)

Connection (represents an exit/door/passage)
 ├── from_location_id → Location
 ├── to_location_id → Location
 ├── required_item_id → Item (optional key)
 └── connection_type (passage/door/portal/teleporter/magical)

Quest
 └── QuestObjectives
      ├── objective_type (reach_location, acquire_item, kill_character)
      ├── target (polymorphic: Location, Item, or Character)
      └── progress tracking (current_progress / quantity)
```

---

### 1. World

The top-level container for an entire game setting.

**Purpose**: Represents the complete game universe with all its metadata and relationships.

**Attributes**:
- `id`: Unique identifier
- `name`: World name (e.g., "The Kingdom of Eldoria")
- `description`: High-level world description
- `created_by`: User who created this world
- `created_at`: Timestamp
- `is_template`: Boolean - can this be cloned for new games?
- `time_of_day`: String (morning, afternoon, evening, night) - manually advanced by GM
- `days_elapsed`: Integer - how many in-game days have passed
- `world_state`: JSON blob for global flags and variables

**Relationships**:
- Has many Locations
- Has many Characters (across all locations)
- Has many Items (across all containers/locations)

**Key Responsibilities**:
- Serve as the namespace for all game entities
- Provide world-wide queries (e.g., "find all characters", "search items")
- Enforce world-level rules and consistency

---

### 2. Location

A named place within the world where events can occur.

**Purpose**: Represents a distinct area/zone in the game world (tavern, forest, dungeon, etc.)

**Attributes**:
- `id`: Unique identifier
- `world_id`: Foreign key to World
- `name`: Location name (e.g., "The Rusty Dragon Inn")
- `description`: What players see when they enter
- `location_type`: Enum (indoor, outdoor, dungeon, wilderness, etc.)
- `parent_location_id`: Optional - for nested locations (room inside building)
- `state`: JSON blob for dynamic state (is_on_fire, water_level, is_dark, temperature, etc.)

**Relationships**:
- Belongs to World
- Has many Rooms (game sessions happening here)
- Has many Characters (currently at this location)
- Has many Containers (chests, barrels, etc. at this location)
- Has many Items (loose items on ground/environment)
- Has many Connections outbound (exits from this location)
- Has many Connections inbound (entrances to this location)
- Can have parent Location (for hierarchical structure)

**Key Responsibilities**:
- Track what's physically present at this location
- Manage location-specific state (is the door locked? is it on fire?)
- Provide location descriptions to players

---

### 3. Connection (aka Exit)

A directional link between two locations with its own state and description.

**Purpose**: Represents a passage, door, portal, or path from one location to another.

**Attributes**:
- `id`: Unique identifier
- `world_id`: Foreign key to World
- `from_location_id`: Foreign key to Location (source)
- `to_location_id`: Foreign key to Location (destination)
- `connection_type`: Enum (passage, door, portal, teleporter, magical) - default 'passage'
- `direction`: String (north, south, east, west, up, down, or custom like "through the red door")
- `description`: What the player sees (e.g., "A red door to your left stands open revealing a large hall")
- `is_visible`: Boolean (can players see this exit?)
- `is_locked`: Boolean
- `is_open`: Boolean (for doors/gates, always true for portals/teleporters)
- `required_item_id`: Foreign key to Item (key needed to unlock)
- `is_bidirectional`: Boolean (if true, creates reverse connection automatically)
- `reverse_description`: Text (description when traveling the opposite direction)

**Relationships**:
- Belongs to World
- Connects from one Location to another Location
- May require an Item to unlock/open

**Key Responsibilities**:
- Define traversable paths between locations
- Track door/passage state (open, locked, hidden)
- Provide contextual descriptions based on state
- Enforce requirements for passage (needs key, strength check, etc.)

**Examples**:
```ruby
# Simple bidirectional connection
Connection.create(
  from_location: tavern,
  to_location: town_square,
  direction: "north",
  description: "The main door leads north to the town square",
  is_bidirectional: true,
  reverse_description: "The tavern entrance is to the south"
)

# Locked door requiring a key
Connection.create(
  from_location: hallway,
  to_location: treasure_room,
  direction: "east",
  description: "A heavy iron door with an ornate lock bars passage to the east",
  is_locked: true,
  is_open: false,
  required_item: iron_key
)

# Hidden passage
Connection.create(
  from_location: library,
  to_location: secret_chamber,
  direction: "behind the bookshelf",
  description: "A narrow passage winds into darkness",
  is_visible: false  # Only visible after discovery
)
```

---

### 4. Room

A live game session where players interact.

**Purpose**: Represents an active game instance with players, tied to a location in the world.

**Attributes**:
- `id`: Unique identifier
- `world_id`: Foreign key to World
- `current_location_id`: Foreign key to Location (where the party currently is)
- `name`: Session name (e.g., "Friday Night Adventure")
- `game_master_id`: User or AI serving as GM
- `created_by`: User who created the session
- `session_state`: JSON blob for session-specific state
- `started_at`: Timestamp
- `ended_at`: Timestamp (null if active)

**Relationships**:
- Belongs to World
- Currently at a Location
- Has many PlayerCharacters (via user_rooms join table with character_id)
- Has many Users (via user_rooms join table)
- Has many ChatMessages
- Has one GameMaster (User or AI)

**Key Responsibilities**:
- Track which player characters are in this session
- Track current party location (all PCs move together unless separated)
- Manage session state (quest progress, session variables)
- Handle chat/messaging for this session
- Control turn order and mute status (per player character)
- Link users to their active character in this room

---

### 5. Character

Any sentient being in the game - player characters (PCs), NPCs, monsters, companions.

**Purpose**: Represents a living entity with stats, inventory, and state. Handles BOTH player characters and NPCs.

**Attributes**:
- `id`: Unique identifier
- `world_id`: Foreign key to World
- `user_id`: Foreign key to User (null for NPCs, set for player characters)
- `location_id`: Foreign key to Location (where they currently are)
- `name`: Character name
- `description`: Physical appearance and personality
- `character_type`: Enum (player, npc, monster, companion, vendor, etc.)
- `max_hp`: Maximum hit points
- `current_hp`: Current hit points
- `is_dead`: Boolean
- `strength`: Integer (1-20) - Physical power, melee damage
- `intelligence`: Integer (1-20) - Mental acuity, magic power, problem solving
- `charisma`: Integer (1-20) - Social influence, persuasion, leadership
- `athletics`: Integer (1-20) - Physical coordination, acrobatics, endurance
- `armor_class`: Integer (10-30) - Defense against attacks
- `additional_stats`: JSON blob for optional/custom stats (inventory weight limit, status effects, etc.)
- `is_hostile`: Boolean
- `faction`: String (optional - what group they belong to)
- `created_by`: User ID who created this character (for auditing)

**Relationships**:
- Belongs to World
- Belongs to User (if player character, null if NPC)
- Currently at a Location
- Has many Items (in inventory)
- Participates in Rooms (via user_rooms join table if PC)

**Key Responsibilities**:
- Track character state (HP, status effects)
- Manage character inventory
- Enforce character-level rules (can't heal if dead, etc.)
- Provide character descriptions
- Distinguish between player-controlled and AI/GM-controlled entities

**Player Character vs NPC**:
- `user_id IS NULL` + `character_type = 'npc'` → NPC controlled by GM/AI
- `user_id IS NOT NULL` + `character_type = 'player'` → Player character controlled by user
- A user can have different characters in different worlds
- A user can have multiple characters in the same world (e.g., if they switch characters or play in multiple rooms)

**Core Stats System**:

All characters have four core attributes (1-20 scale):

1. **Strength** (STR)
   - Physical power and melee combat effectiveness
   - Affects: Melee damage, carrying capacity, breaking objects
   - Checks: Breaking down doors, intimidation via physical presence, climbing with raw power

2. **Intelligence** (INT)
   - Mental acuity, reasoning, and magical ability
   - Affects: Magic damage/effectiveness, puzzle solving, knowledge recall
   - Checks: Deciphering ancient texts, identifying magical items, strategic planning

3. **Charisma** (CHA)
   - Social influence, persuasion, and leadership
   - Affects: Persuasion success, leadership effectiveness, trading prices
   - Checks: Convincing NPCs, negotiating deals, rallying allies, performance

4. **Athletics** (ATH)
   - Physical coordination, agility, and endurance
   - Affects: Dodge chance, movement speed, stamina
   - Checks: Acrobatics, dodging traps, stealth, running/swimming/climbing with finesse

**Typical Stat Distributions**:
- Common NPC: 10 in all stats (average human)
- Guard: STR 14, INT 10, CHA 8, ATH 12
- Wizard: STR 8, INT 18, CHA 12, ATH 10
- Rogue: STR 10, INT 12, CHA 14, ATH 16
- Warrior: STR 16, INT 10, CHA 12, ATH 14
- Dragon Boss: STR 20, INT 16, CHA 18, ATH 14

**Armor Class (AC)**:
- Base AC = 10 + (Athletics / 2) + equipment bonuses
- Attacks must roll higher than AC to hit
- Example: Character with ATH 14 and leather armor (+2) = AC 17

**Stat Checks**:
When AI/GM requests a roll for an action, the stat determines difficulty:
- Easy task: Roll 1d20, succeed if roll ≥ (10 - stat_modifier)
- Medium task: Roll 1d20, succeed if roll ≥ (15 - stat_modifier)
- Hard task: Roll 1d20, succeed if roll ≥ (20 - stat_modifier)
- Stat modifier = (stat - 10) / 2 (rounded down)

Example: Character with STR 16 (modifier +3) tries to break a door (medium task)
- Needs to roll ≥ 12 (15 - 3) on 1d20

---

### 6. Container

An object that can hold items (chest, barrel, bag, corpse).

**Purpose**: Represents a physical container for items in the world.

**Attributes**:
- `id`: Unique identifier
- `world_id`: Foreign key to World
- `location_id`: Foreign key to Location (where it is)
- `character_id`: Foreign key to Character (if it's being carried)
- `name`: Container name (e.g., "wooden chest", "leather bag")
- `description`: What it looks like
- `is_locked`: Boolean
- `is_open`: Boolean
- `capacity`: Integer (max items or weight)

**Relationships**:
- Belongs to World
- Located at a Location OR carried by a Character
- Contains many Items

**Key Responsibilities**:
- Track what items are inside
- Enforce capacity limits
- Manage locked/unlocked state
- Provide container descriptions

---

### 7. Item

Any physical object that can be interacted with.

**Purpose**: Represents a tangible object in the game world.

**Attributes**:
- `id`: Unique identifier
- `world_id`: Foreign key to World
- `location_id`: Foreign key to Location (if on ground/environment)
- `character_id`: Foreign key to Character (if in inventory)
- `container_id`: Foreign key to Container (if in a container)
- `name`: Item name (e.g., "gold coins", "rusty sword")
- `description`: What it looks like and what it does
- `item_type`: Enum (weapon, armor, consumable, currency, quest_item, misc)
- `quantity`: Integer (for stackable items)
- `is_stackable`: Boolean
- `weight`: Decimal (for encumbrance)
- `properties`: JSON blob (damage, armor_class, effects, etc.)

**Relationships**:
- Belongs to World
- Can be at a Location (on ground)
- Can be owned by a Character (in inventory)
- Can be inside a Container

**Key Responsibilities**:
- Track item state and quantity
- Provide item descriptions
- Define item properties (what does it do?)
- Handle stacking logic for currency and consumables

---

### 8. Quest

A trackable objective or goal for players to complete.

**Purpose**: Defines structured goals with completion criteria.

**Attributes**:
- `id`: Unique identifier
- `world_id`: Foreign key to World
- `room_id`: Foreign key to Room (which session is tracking this quest)
- `name`: Quest name (e.g., "Retrieve the Sacred Amulet")
- `description`: Quest details and story
- `quest_type`: Enum (main, side, personal)
- `status`: Enum (active, completed, failed, abandoned)
- `created_at`: Timestamp
- `completed_at`: Timestamp (null if not completed)

**Relationships**:
- Belongs to World
- Belongs to Room (session-specific)
- Has many QuestObjectives (completion criteria)

**Key Responsibilities**:
- Track quest progress
- Define what needs to be accomplished
- Notify when objectives are completed

---

### 9. QuestObjective

Individual completion criteria for a quest.

**Purpose**: Defines specific measurable goals (reach location, get item, kill character).

**Attributes**:
- `id`: Unique identifier
- `quest_id`: Foreign key to Quest
- `objective_type`: Enum (reach_location, acquire_item, kill_character, custom)
- `target_type`: String (Location, Item, Character) - what model is the target
- `target_id`: Integer - ID of the target entity
- `quantity`: Integer (for "collect 5 goblin ears" type objectives)
- `current_progress`: Integer (how many completed so far)
- `is_completed`: Boolean
- `description`: Human-readable objective (e.g., "Reach the Dragon's Lair")
- `is_optional`: Boolean (side objectives that don't block quest completion)

**Relationships**:
- Belongs to Quest

**Key Responsibilities**:
- Monitor game events for completion
- Track progress toward goal
- Validate completion criteria

**Examples**:
```ruby
# Reach a specific location
QuestObjective.create(
  objective_type: 'reach_location',
  target_type: 'Location',
  target_id: dragon_lair.id,
  description: 'Reach the Dragon\'s Lair'
)

# Acquire a specific item
QuestObjective.create(
  objective_type: 'acquire_item',
  target_type: 'Item',
  target_id: sacred_amulet.id,
  description: 'Retrieve the Sacred Amulet'
)

# Kill a specific character
QuestObjective.create(
  objective_type: 'kill_character',
  target_type: 'Character',
  target_id: dragon_boss.id,
  description: 'Slay the Ancient Dragon'
)

# Collect multiple of an item type
QuestObjective.create(
  objective_type: 'acquire_item',
  target_type: 'Item',
  target_id: goblin_ear.id,
  quantity: 5,
  current_progress: 0,
  description: 'Collect 5 Goblin Ears'
)
```

---

### 10. GameEvent

An audit log of significant game events for debugging and potential rollback.

**Purpose**: Track all important state changes in the game world.

**Attributes**:
- `id`: Unique identifier
- `world_id`: Foreign key to World
- `room_id`: Foreign key to Room (null for world-level events)
- `event_type`: String (character_created, item_moved, character_damaged, location_changed, quest_completed, etc.)
- `actor_type`: String (User, Character, System) - who/what caused this event
- `actor_id`: Integer - ID of the actor
- `target_type`: String - what was affected (Character, Item, Location, etc.)
- `target_id`: Integer - ID of the target
- `event_data`: JSON blob with event details
- `created_at`: Timestamp
- `created_by`: User ID who triggered this (null for system events)

**Relationships**:
- Belongs to World
- Optionally belongs to Room

**Key Responsibilities**:
- Log all significant game state changes
- Provide audit trail for debugging
- Enable potential rollback/undo functionality
- Track who did what and when

**Example Events**:
```ruby
# Character takes damage
GameEvent.create(
  event_type: 'character_damaged',
  actor_type: 'Character',
  actor_id: dragon.id,
  target_type: 'Character',
  target_id: player_character.id,
  event_data: {
    damage: 15,
    old_hp: 50,
    new_hp: 35,
    damage_type: 'fire'
  }
)

# Item transferred
GameEvent.create(
  event_type: 'item_transferred',
  actor_type: 'Character',
  actor_id: shopkeeper.id,
  target_type: 'Item',
  target_id: sword.id,
  event_data: {
    from_character_id: shopkeeper.id,
    to_character_id: player.id,
    transaction_type: 'purchase',
    price: 50
  }
)

# Location state changed
GameEvent.create(
  event_type: 'location_state_changed',
  actor_type: 'Character',
  actor_id: wizard.id,
  target_type: 'Location',
  target_id: tower.id,
  event_data: {
    state_key: 'is_on_fire',
    old_value: false,
    new_value: true,
    method: 'fireball_spell'
  }
)
```

---

## State Management Rules

### Location Hierarchy
- Items can be: on the ground at a Location, in a Container, or in a Character's inventory
- Containers can be: at a Location or in a Character's inventory
- Characters are always at a Location
- Only ONE of location_id/character_id/container_id should be set for any item

### Ownership Chain
```
World
  └─ Location
      ├─ Character (at this location)
      │   ├─ Item (in inventory)
      │   └─ Container (being carried)
      │       └─ Item (inside container)
      ├─ Container (at this location)
      │   └─ Item (inside container)
      └─ Item (on the ground)
```

### State Transitions
- Moving an item: Clear old location/character/container, set new one
- Character death: Items can be moved to a "corpse" container at the location
- Container destruction: Items spill to the location
- Character movement: Character location_id changes, carried items move with them

---

## Game Engine API Design

### Core Engine Class: `GameEngine`

The central orchestrator that all game interactions go through.

**Responsibilities**:
- Provide clean API for querying and modifying game state
- Enforce game rules and validate actions
- Emit events for UI/AI to react to
- Maintain consistency and referential integrity

**Example Methods**:

```ruby
class GameEngine
  # World Queries
  def describe_location(location_id)
  def list_characters_at(location_id)
  def list_items_at(location_id)
  def list_containers_at(location_id)

  # Character Actions (all automatically log events)
  def move_character(character_id, to_location_id)
  def damage_character(character_id, amount, source: nil)
  def heal_character(character_id, amount, source: nil)
  def character_take_item(character_id, item_id)
  def character_drop_item(character_id, item_id)
  def get_character_inventory(character_id)

  # Player Character Management
  def create_player_character(user_id, world_id, attributes)
  def get_player_character(user_id, world_id)
  def kill_character(character_id) # Sets is_dead, creates corpse container

  # Item Management
  def create_item(world_id, attributes)
  def move_item(item_id, to:) # to can be location/character/container
  def modify_item_quantity(item_id, change)
  def stack_items(item_id_1, item_id_2) # combine stackables

  # Container Management
  def open_container(container_id)
  def lock_container(container_id)
  def unlock_container(container_id)
  def list_container_contents(container_id)

  # World Building
  def create_location(world_id, attributes)
  def create_character(world_id, attributes)
  def create_container(world_id, attributes)
  def create_connection(world_id, from_location_id, to_location_id, attributes)

  # Connection Management
  def list_exits(location_id) # Get all visible exits from a location
  def get_connection(from_location_id, direction) # Find exit by direction
  def open_door(connection_id)
  def close_door(connection_id)
  def lock_door(connection_id, with_item_id)
  def unlock_door(connection_id, using_item_id)
  def reveal_exit(connection_id) # Make hidden exit visible
  def hide_exit(connection_id) # Make exit hidden
  def traverse_connection(character_id, connection_id) # Move through exit

  # Queries
  def find_character_by_name(world_id, name)
  def find_item_by_name(world_id, name, scope:) # scope: location/character/container
  def search_world(world_id, query)

  # World Time Management
  def get_world_time(world_id) # Returns { time_of_day, days_elapsed }
  def advance_time(world_id, to_time_of_day) # morning → afternoon → evening → night
  def advance_day(world_id) # Increment days_elapsed, reset to morning
  def set_world_state(world_id, key, value) # Set global state flag
  def get_world_state(world_id, key) # Get global state flag

  # Location State Management
  def get_location_state(location_id, key) # Get specific state value
  def set_location_state(location_id, key, value) # Set state (e.g., is_on_fire: true)
  def clear_location_state(location_id, key) # Remove a state flag
  def get_all_location_state(location_id) # Get entire state object

  # Quest Management
  def create_quest(world_id, room_id, attributes)
  def add_quest_objective(quest_id, attributes)
  def check_quest_progress(quest_id) # Check all objectives, update status
  def complete_objective(objective_id) # Mark objective complete
  def get_active_quests(room_id) # Get all active quests for a session
  def get_quest_details(quest_id) # Get quest with all objectives

  # Event Logging
  def log_event(world_id, event_type, attributes) # Create game event
  def get_events(world_id, filters: {}) # Query events with filters
  def get_recent_events(world_id, limit: 50) # Get last N events
  def rollback_to_event(event_id) # Potential future feature
end
```

---

## AI Integration Redesign

### Minimal Context Approach

When AI is invoked, it receives:

1. **Current Location Description**: Where the party is now
2. **Latest Player Message**: What the player just said/did
3. **Session Variables**: Quest flags, important state (very minimal)

That's it. No conversation history, no full world state.

### AI Tools

The AI has tools to query for more information:

**Context Tools**:
- `describe_location(location_id)` - Get full location description
- `list_visible_characters()` - See NPCs at current location
- `list_visible_items()` - See items at current location
- `get_character_info(name)` - Get character sheet
- `search_character_inventory(name)` - See what an NPC has

**Action Tools**:
- `narrate(message)` - Send narration to players
- `speak_as_npc(character_name, dialogue)` - NPC says something
- `move_party(to_location)` - Move everyone to new location
- `create_character(...)` - Spawn an NPC
- `damage_character(name, amount)` - Deal damage
- `give_item(from, to, item_name)` - Transfer item
- `ask_for_roll(player, dice_spec, reason)` - Request dice roll
- `open_door(direction)` - Open a door/passage
- `unlock_door(direction, key_name)` - Unlock a door with a key
- `reveal_exit(direction)` - Make a hidden passage visible

**World Query Tools**:
- `find_location_by_name(name)` - Search for a location
- `check_if_exists(thing)` - Ask engine if something exists
- `get_world_time()` - Get current time of day and days elapsed
- `get_location_state(key)` - Check location state (is_on_fire, etc.)

**World State Tools**:
- `set_location_state(key, value)` - Change location state (set fire, flood room, etc.)
- `advance_time(to_time_of_day)` - Change time of day (morning/afternoon/evening/night)
- `advance_day()` - Move to next day (when party sleeps or travels)

**Quest Tools**:
- `create_quest(name, description, type)` - Start a new quest
- `add_objective(quest_id, type, target, description)` - Add goal to quest
- `check_quest_progress(quest_id)` - Evaluate if objectives are complete
- `get_active_quests()` - List current active quests
- `complete_quest(quest_id)` - Mark quest as finished

### AI Flow Examples

**Example 1: Creating an NPC**
```
Player: "I look for the innkeeper"

AI receives:
  - location: "The Rusty Dragon Inn"
  - message: "I look for the innkeeper"

AI thinks: "Need to check if innkeeper exists here"

AI calls: list_visible_characters()
  - Returns: []

AI thinks: "No characters here, should I create one?"

AI calls: check_if_exists("innkeeper at The Rusty Dragon Inn")
  - Returns: { should_exist: true, reasoning: "Inns typically have innkeepers" }

AI calls: create_character(name: "Grendle", type: "npc", location: current_location)

AI calls: narrate("A stout dwarf emerges from the kitchen, wiping his hands on his apron.")
AI calls: speak_as_npc("Grendle", "Welcome to the Rusty Dragon! What can I get ye?")
```

**Example 2: Discovering and Using Exits**
```
Player: "I look around the room. Are there any doors?"

AI receives:
  - location: "Dusty Library"
  - message: "I look around the room. Are there any doors?"

AI calls: list_exits()
  - Returns: [
      { direction: "north", description: "A wooden door leads north", is_visible: true },
      { direction: "behind the bookshelf", description: "...", is_visible: false }
    ]

AI calls: narrate("You see a wooden door to the north. The room is lined with ancient bookshelves.")

---

Player: "I search behind the bookshelves"

AI calls: ask_for_roll("PlayerName", "1d20", "for perception check")

---

Player rolls: 18

AI thinks: "High roll, they find the hidden passage"

AI calls: reveal_exit("behind the bookshelf")
AI calls: narrate("As you push aside some dusty tomes, you notice one bookshelf is slightly askew. Behind it, a narrow passage winds into darkness.")
```

---

## Database Schema Changes

### New Tables

```sql
CREATE TABLE worlds (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  description TEXT,
  created_by INTEGER REFERENCES users(id),
  is_template BOOLEAN DEFAULT false,
  time_of_day TEXT DEFAULT 'morning',
  days_elapsed INTEGER DEFAULT 0,
  world_state TEXT, -- JSON
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE locations (
  id INTEGER PRIMARY KEY,
  world_id INTEGER REFERENCES worlds(id),
  parent_location_id INTEGER REFERENCES locations(id),
  name TEXT NOT NULL,
  description TEXT,
  location_type TEXT, -- indoor, outdoor, dungeon, etc.
  state TEXT, -- JSON for dynamic state (is_on_fire, water_level, etc.)
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE connections (
  id INTEGER PRIMARY KEY,
  world_id INTEGER REFERENCES worlds(id),
  from_location_id INTEGER REFERENCES locations(id),
  to_location_id INTEGER REFERENCES locations(id),
  connection_type TEXT DEFAULT 'passage', -- passage, door, portal, teleporter, magical
  direction TEXT NOT NULL,
  description TEXT,
  is_visible BOOLEAN DEFAULT true,
  is_locked BOOLEAN DEFAULT false,
  is_open BOOLEAN DEFAULT true,
  required_item_id INTEGER REFERENCES items(id),
  is_bidirectional BOOLEAN DEFAULT false,
  reverse_description TEXT,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Rooms become game sessions
ALTER TABLE rooms ADD COLUMN world_id INTEGER REFERENCES worlds(id);
ALTER TABLE rooms ADD COLUMN current_location_id INTEGER REFERENCES locations(id);

-- Characters get world and location references, and support for player characters
ALTER TABLE characters ADD COLUMN world_id INTEGER REFERENCES worlds(id);
ALTER TABLE characters ADD COLUMN user_id INTEGER REFERENCES users(id); -- NULL for NPCs, set for player characters
ALTER TABLE characters RENAME COLUMN location TO location_id;
ALTER TABLE characters ADD COLUMN character_type TEXT DEFAULT 'npc';
ALTER TABLE characters ADD COLUMN faction TEXT;
ALTER TABLE characters ADD COLUMN created_by INTEGER REFERENCES users(id);

-- Add core stat system
ALTER TABLE characters ADD COLUMN strength INTEGER DEFAULT 10;
ALTER TABLE characters ADD COLUMN intelligence INTEGER DEFAULT 10;
ALTER TABLE characters ADD COLUMN charisma INTEGER DEFAULT 10;
ALTER TABLE characters ADD COLUMN athletics INTEGER DEFAULT 10;
ALTER TABLE characters ADD COLUMN armor_class INTEGER DEFAULT 10;
ALTER TABLE characters ADD COLUMN additional_stats TEXT; -- JSON for custom/optional stats
-- Note: Rename existing 'stats' column to 'additional_stats' if it exists

-- user_rooms now links to character instead of storing character_name
ALTER TABLE user_rooms ADD COLUMN character_id INTEGER REFERENCES characters(id);
-- Migration note: Need to create Character records for existing character_name values first
-- then populate character_id, then drop character_name column
-- ALTER TABLE user_rooms DROP COLUMN character_name; -- Do this after migration

CREATE TABLE containers (
  id INTEGER PRIMARY KEY,
  world_id INTEGER REFERENCES worlds(id),
  location_id INTEGER REFERENCES locations(id),
  character_id INTEGER REFERENCES characters(id),
  name TEXT NOT NULL,
  description TEXT,
  is_locked BOOLEAN DEFAULT false,
  is_open BOOLEAN DEFAULT true,
  capacity INTEGER,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Items get proper references
ALTER TABLE items ADD COLUMN container_id INTEGER REFERENCES containers(id);
ALTER TABLE items ADD COLUMN item_type TEXT DEFAULT 'misc';
ALTER TABLE items ADD COLUMN is_stackable BOOLEAN DEFAULT false;
ALTER TABLE items ADD COLUMN weight DECIMAL;
ALTER TABLE items ADD COLUMN properties TEXT; -- JSON

CREATE TABLE quests (
  id INTEGER PRIMARY KEY,
  world_id INTEGER REFERENCES worlds(id),
  room_id INTEGER REFERENCES rooms(id),
  name TEXT NOT NULL,
  description TEXT,
  quest_type TEXT DEFAULT 'main', -- main, side, personal
  status TEXT DEFAULT 'active', -- active, completed, failed, abandoned
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  completed_at TIMESTAMP
);

CREATE TABLE quest_objectives (
  id INTEGER PRIMARY KEY,
  quest_id INTEGER REFERENCES quests(id),
  objective_type TEXT NOT NULL, -- reach_location, acquire_item, kill_character, custom
  target_type TEXT, -- Location, Item, Character
  target_id INTEGER,
  quantity INTEGER DEFAULT 1,
  current_progress INTEGER DEFAULT 0,
  is_completed BOOLEAN DEFAULT false,
  description TEXT,
  is_optional BOOLEAN DEFAULT false,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE game_events (
  id INTEGER PRIMARY KEY,
  world_id INTEGER REFERENCES worlds(id),
  room_id INTEGER REFERENCES rooms(id),
  event_type TEXT NOT NULL,
  actor_type TEXT, -- User, Character, System
  actor_id INTEGER,
  target_type TEXT,
  target_id INTEGER,
  event_data TEXT, -- JSON
  created_by INTEGER REFERENCES users(id),
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- chat_messages should link to character, not user
ALTER TABLE chat_messages ADD COLUMN character_id INTEGER REFERENCES characters(id);
-- Migration note: Look up character from user_rooms join for existing messages
-- ALTER TABLE chat_messages DROP COLUMN user_id; -- Do this after migration
```

---

## Dynamic Location State System

### Purpose
Allow locations to have mutable state that affects gameplay, descriptions, and available actions. This creates a living, reactive world.

### Implementation
Location state stored as JSON in the `state` column. GameEngine provides helper methods to get/set individual keys.

### Common State Flags

**Environmental Conditions**:
- `is_on_fire` (boolean) - Location is burning
- `water_level` (integer) - 0=dry, 1=ankle-deep, 2=waist-deep, 3=flooded
- `is_dark` (boolean) - No light sources active
- `temperature` (string) - "freezing", "cold", "comfortable", "hot", "scorching"
- `weather` (string) - "clear", "raining", "storming", "snowing"

**Structural State**:
- `is_collapsed` (boolean) - Room has collapsed/caved in
- `is_locked_down` (boolean) - All exits sealed
- `ceiling_height` (integer) - Changed by cave-ins, spells
- `visibility` (integer) - 0=pitch black, 100=bright daylight

**Puzzle/Gameplay State**:
- `lever_position` (string) - "up", "down"
- `statue_orientation` (string) - "north", "south", "east", "west"
- `pressure_plate_active` (boolean)
- `ritual_circle_activated` (boolean)
- `blood_spilled` (boolean) - For dark rituals

**Dynamic Description Impact**:
State should influence what players see:
```ruby
base_description = location.description
state = location.state || {}

# Add environmental modifiers
if state['is_on_fire']
  base_description += " Flames lick at the walls, filling the air with smoke."
end

if state['water_level'] && state['water_level'] > 0
  case state['water_level']
  when 1
    base_description += " Water covers the floor, reaching your ankles."
  when 2
    base_description += " You wade through waist-deep water."
  when 3
    base_description += " The room is completely flooded. You must swim."
  end
end

if state['is_dark']
  base_description = "It's pitch black. You can't see anything."
end
```

### GameEngine Integration

**Setting State**:
```ruby
# Character casts fireball
engine.set_location_state(tavern.id, 'is_on_fire', true)
engine.log_event(world.id, 'location_state_changed', {
  actor_type: 'Character',
  actor_id: wizard.id,
  target_type: 'Location',
  target_id: tavern.id,
  event_data: { key: 'is_on_fire', value: true, reason: 'fireball spell' }
})

# Character puts out fire
engine.set_location_state(tavern.id, 'is_on_fire', false)
```

**Querying State**:
```ruby
# Check if room is on fire before allowing entry
if engine.get_location_state(location.id, 'is_on_fire')
  return "The doorway is blocked by flames. You cannot enter."
end

# Check water level for movement penalties
water_level = engine.get_location_state(location.id, 'water_level') || 0
movement_cost = water_level > 2 ? 2 : 1  # Swimming takes longer
```

**State Affects Gameplay**:
- Fire spreads to connected rooms over time (background task)
- Flooded rooms may hide items on the floor
- Dark rooms prevent searching without light source
- Temperature affects HP drain (freezing = damage per turn)
- Collapsed rooms may create new connections or block old ones

### AI Integration
AI can query and manipulate location state:
```
Player: "I cast fireball at the wooden tavern"

AI calls: set_location_state('is_on_fire', true)
AI calls: narrate("The fireball explodes against the wooden beams. Within seconds, flames engulf the tavern.")

---

Player: "Is the room dark?"

AI calls: get_location_state('is_dark')
AI receives: true
AI calls: narrate("Yes, it's pitch black. You'll need a light source to see anything.")
```

---

## Automatic Event Logging System

### Purpose
Every state change in the game world is automatically logged to the `game_events` table. This creates a complete audit trail that enables:
- Full game history reconstruction
- Debugging broken game states
- Potential rollback/undo functionality
- Analytics and statistics
- Replay capability

### How It Works

All GameEngine methods that modify state automatically create event log entries before returning.

**Implementation Pattern**:
```ruby
def damage_character(character_id, amount, source: nil)
  character = db[:characters][id: character_id]
  old_hp = character[:current_hp]
  new_hp = [old_hp - amount, 0].max
  is_dead = new_hp <= 0

  # Update character
  db[:characters].where(id: character_id).update(
    current_hp: new_hp,
    is_dead: is_dead
  )

  # Automatically log event
  log_event(character[:world_id], 'character_damaged', {
    room_id: current_room_id,
    actor_type: source&.class&.name,
    actor_id: source&.id,
    target_type: 'Character',
    target_id: character_id,
    event_data: {
      damage: amount,
      old_hp: old_hp,
      new_hp: new_hp,
      is_dead: is_dead
    }
  })

  # Return result
  { success: true, new_hp: new_hp, is_dead: is_dead }
end
```

### Events Automatically Logged

**Character Events**:
- `character_created` - New character spawned
- `character_damaged` - HP reduced
- `character_healed` - HP restored
- `character_killed` - HP reached 0
- `character_moved` - Changed location
- `character_stat_changed` - Stat modified (buffed/debuffed)

**Item Events**:
- `item_created` - New item spawned in world
- `item_moved` - Item changed location/owner/container
- `item_taken` - Character picked up item
- `item_dropped` - Character dropped item
- `item_consumed` - Item used/destroyed (potion drunk, scroll read)
- `item_quantity_changed` - Stackable item quantity modified

**Location Events**:
- `location_state_changed` - State flag modified (fire, flood, etc.)
- `party_entered_location` - Players moved to location
- `connection_state_changed` - Door locked/unlocked/opened/closed

**Quest Events**:
- `quest_created` - New quest started
- `objective_completed` - Quest objective achieved
- `quest_completed` - All objectives complete
- `quest_failed` - Quest failed

**Container Events**:
- `container_opened` - Container accessed
- `container_locked` - Container locked
- `container_unlocked` - Container unlocked

### Event Data Structure

All events include:
- `world_id` - Which world this happened in
- `room_id` - Which session (null for world-level events)
- `event_type` - What happened
- `actor_type` / `actor_id` - Who/what caused this
- `target_type` / `target_id` - What was affected
- `event_data` - JSON with specific details
- `created_at` - When it happened
- `created_by` - User ID if user-initiated

### Querying Events

```ruby
# Get all damage events for a character
events = engine.get_events(world_id, filters: {
  event_type: 'character_damaged',
  target_type: 'Character',
  target_id: character_id
})

# Get last 20 events in a room
recent = engine.get_recent_events(world_id, room_id: room_id, limit: 20)

# Find when an item was created
creation = engine.get_events(world_id, filters: {
  event_type: 'item_created',
  target_id: item_id
}).first
```

### Future: Rollback System

With complete event logging, we can potentially implement rollback:

```ruby
def rollback_to_event(event_id)
  # Get all events after this one
  events = db[:game_events].where('id > ?', event_id).order(:created_at)

  # Reverse each event
  events.reverse.each do |event|
    case event[:event_type]
    when 'character_damaged'
      # Restore old HP
      character_id = event[:target_id]
      old_hp = event[:event_data]['old_hp']
      db[:characters].where(id: character_id).update(current_hp: old_hp)
    when 'item_moved'
      # Move item back
      # ... etc
    end
  end

  # Delete events after rollback point
  db[:game_events].where('id > ?', event_id).delete
end
```

---

## Player Character Workflow

### Character Creation
When a user joins a room for the first time in a world:

1. **Check for Existing Character**: Does the user have a character in this world?
   - Query: `Character.where(user_id: user.id, world_id: room.world_id, character_type: 'player')`

2. **If No Character Exists**:
   - Present character creation UI (name, description, stats)
   - Create Character record with `user_id`, `world_id`, `character_type: 'player'`
   - Set initial `location_id` to room's current_location

3. **Create user_rooms Record**:
   - Links user + room + character
   - Sets initial mute status, etc.

4. **Character Appears in World**:
   - Character now exists at the room's current location
   - AI/GM can see them via `list_characters_at(location)`
   - They have inventory, HP, stats like any other character

### Character Persistence
- Characters persist across room sessions in the same world
- User can create different characters for different worlds
- If user leaves a room, their character remains at that location in the world
- If user rejoins the same room later, they resume playing their existing character

### Character Death
- When character HP reaches 0, `is_dead` flag is set
- User can be prompted to create a new character
- Old character becomes a "corpse" (container) with their inventory

---

## Implementation Roadmap

### Phase 1: Core Data Models (Foundation)
1. **Database Migration**
   - Create new tables: `worlds`, `locations`, `connections`, `quests`, `quest_objectives`, `game_events`
   - Add columns to existing tables: Characters (stats, user_id), Rooms (world_id, current_location_id), user_rooms (character_id), chat_messages (character_id)
   - Migrate existing data where needed

2. **Sequel Models**
   - Create Ruby model classes for all entities
   - Define relationships and associations
   - Add validations

### Phase 2: GameEngine (Business Logic)
3. **Build GameEngine Class**
   - Implement all API methods documented above
   - Add automatic event logging to all state-changing methods
   - Ensure thread-safety for concurrent requests
   - Write comprehensive tests

4. **Quest System**
   - Implement quest creation and objective tracking
   - Build manual progress update methods
   - Create quest completion validation

5. **Location State System**
   - Implement dynamic state management
   - Build state-aware description generation
   - Create state query/update helpers

### Phase 3: AI Integration (Intelligence Layer)
6. **Refactor AI Game Master**
   - Rebuild with minimal context approach
   - Implement tool-based architecture
   - Remove conversation history (AI queries for context instead)
   - Add new tools: quests, time management, location state, stats

7. **AI Tool Functions**
   - Map AI tools to GameEngine methods
   - Implement automatic event logging from AI actions
   - Test AI's ability to manage complex scenarios

### Phase 4: User Interface (Presentation)
8. **World Building UI**
   - Create location editor
   - Connection/exit management interface
   - NPC creator with stat allocation
   - Item creator
   - Quest builder

9. **Character Creation UI**
   - Stat point allocation system
   - Character description editor
   - Starting equipment selection

10. **GM Control Panel**
    - Real-time world state viewer
    - Event log browser
    - Manual quest progress updates
    - Time/world state controls
    - Player character overview

11. **Player UI Enhancements**
    - Character sheet display
    - Inventory management
    - Quest tracker
    - Location descriptions with exits
    - Stat-based action prompts

### Phase 5: Testing & Polish
12. **Integration Testing**
    - Full game session simulation
    - Multi-player scenarios
    - Quest completion flows
    - Event log integrity

13. **Performance Optimization**
    - Database query optimization
    - Event log indexing
    - WebSocket efficiency

14. **Documentation**
    - API documentation for GameEngine
    - GM guide for world building
    - Player guide for character creation

---

## Summary

This redesigned architecture provides:

### **Separation of Concerns**
- **GameEngine**: Single source of truth for all game state
- **AI Integration**: Minimal context, tool-based interaction
- **Database**: Clean relational model with proper foreign keys
- **UI**: Human-friendly interfaces for building and playing

### **Rich Game World**
- **10 Core Models**: World, Location, Connection, Room, Character, Container, Item, Quest, QuestObjective, GameEvent
- **Dynamic State**: Locations can catch fire, flood, change over time
- **Persistent Characters**: Players own characters with stats, inventory, HP
- **Complex Navigation**: Connections with multiple types (doors, portals, teleporters)

### **Complete Tracking**
- **Event Log**: Every state change recorded for debugging/rollback
- **Quest System**: Trackable objectives with manual progress updates
- **Character Stats**: 4 core stats (STR, INT, CHA, ATH) + AC + HP
- **Time Management**: Manual progression (time_of_day, days_elapsed)

### **AI-Friendly Design**
- Minimal context sent to AI (current location + latest message)
- Tool-based API for AI to query and modify world state
- Clear separation between narration and game mechanics
- AI can create characters, manage quests, manipulate environment

### **Player-Friendly Design**
- Characters persist across sessions
- Clear stat system prevents ambiguity
- Rich inventory and item management
- Quest tracking shows progress
- Full game history via event log

This architecture is ready for implementation and scales from simple adventures to complex multi-session campaigns.

---

## Design Decisions (All Resolved ✅)

### Core Architecture
1. ✅ **Characters**: Unified model handles both PCs and NPCs - `user_id` field links to User for PCs, NULL for NPCs
2. ✅ **Rooms & Locations**: Rooms represent game sessions; the party can move between Locations within a Room via Connections
3. ✅ **user_rooms**: Links User + Room + Character (via character_id foreign key, not character_name string)
4. ✅ **Chat Messages**: Link to `character_id` instead of `user_id` - player can be inferred from character.user_id if needed

### Quest System
5. ✅ **Quest Structure**: Built-in Quest and QuestObjective models with specific goal types (reach location, acquire item, kill character)
6. ✅ **Quest Tracking**: Manual tracking - GM/AI must explicitly update objective progress (not automatic)

### Time & World State
7. ✅ **World Time**: Manual time progression (not automatic cycles) via `time_of_day` and `days_elapsed` fields, advanced by GM/players through API
8. ✅ **Location State**: JSON `state` field on Location model for dynamic changes (is_on_fire, water_level, is_dark, temperature, etc.)

### Event Logging
9. ✅ **Event Log Scope**: Log EVERY state change for complete audit trail, enabling full game rewind/rebuild
10. ✅ **Automatic Logging**: State changes (damage, item transfers, location state changes) automatically trigger event log entries

### Navigation & Connections
11. ✅ **Connection Complexity**: Keep simple for now (visibility, locked/passable). Can expand later if needed.
12. ✅ **One-Way Passages**: Simply don't create reciprocal connection. The destination location has different exits.
13. ✅ **Location Descriptions**: `describe_location` should include visible exits automatically
14. ✅ **Teleportation**: Special `connection_type` field (portal, teleporter, magical) to distinguish from normal passages

### Inventory & Stats
15. ✅ **Inventory**: Character-level inventory only (no separate "party inventory" concept)
16. ✅ **Character Stats**: Four core stats (Strength, Intelligence, Charisma, Athletics) with consistent 1-20 scale, plus Armor Class and HP
17. ✅ **Stat Usage**: Prevents ambiguity, creates consistent experience across all characters (PCs and NPCs)
