# Database setup
DATABASE_PATH = 'text-adventure.sqlite3'

DB = Sequel.sqlite(DATABASE_PATH)

# Create tables
unless DB.table_exists?(:admins)
  DB.create_table :admins do
    primary_key :id
    TrueClass :is_setup_complete, default: false
    DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
  end
end

unless DB.table_exists?(:magic_links)
  DB.create_table :magic_links do
    primary_key :id
    String :token, unique: true, null: false
    DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
    DateTime :expires_at
    Integer :used_count, default: 0
    TrueClass :is_active, default: true
  end
end

unless DB.table_exists?(:users)
  DB.create_table :users do
    primary_key :id
    String :username, unique: true, null: false
    String :password_digest, null: false
    Integer :magic_link_id
    TrueClass :is_admin, default: false
    TrueClass :is_ai, default: false
    DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
  end
end

unless DB.table_exists?(:rooms)
  DB.create_table :rooms do
    primary_key :id
    TrueClass :is_open
    Integer :created_by
    Integer :game_master_id
    String :name, null: false
    String :description
    Integer :world_id
    Integer :current_location_id
    DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
  end
end

unless DB.table_exists?(:user_rooms)
  DB.create_table :user_rooms do
    primary_key :id
    Integer :user_id
    Integer :room_id
    String :player_name
    TrueClass :is_muted, default: false
    TrueClass :hand_raised, default: false
    Integer :character_id
    DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
  end
end

unless DB.table_exists?(:chat_messages)
  DB.create_table :chat_messages do
    primary_key :id
    Integer :room_id
    Integer :user_id
    Integer :character_id
    String :message
    String :data, default: "{}"
    DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
  end
end

unless DB.table_exists?(:characters)
  DB.create_table :characters do
    primary_key :id
    Integer :room_id
    Integer :world_id
    Integer :location_id
    Integer :user_id # NULL for NPCs, set for player characters
    String :character_type, default: 'npc'
    String :name, null: false
    String :description
    Integer :max_hp, default: 10
    Integer :current_hp, default: 10
    TrueClass :is_dead, default: false
    String :location # Legacy field for backward compatibility
    String :faction
    Integer :created_by
    Integer :strength, default: 10
    Integer :intelligence, default: 10
    Integer :charisma, default: 10
    Integer :athletics, default: 10
    Integer :armor_class, default: 10
    TrueClass :is_hostile, default: false
    Integer :gold, default: 0
    String :additional_stats, text: true # JSON
    DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
  end
end

# Add gold column to existing characters table if it doesn't exist
if DB.table_exists?(:characters) && !DB[:characters].columns.include?(:gold)
  DB.alter_table :characters do
    add_column :gold, Integer, default: 0
  end
end

unless DB.table_exists?(:items)
  DB.create_table :items do
    primary_key :id
    Integer :room_id
    Integer :character_id
    Integer :world_id
    Integer :location_id
    Integer :container_id
    String :name, null: false
    String :description
    Integer :quantity, default: 1
    String :item_type, default: 'misc'
    TrueClass :is_stackable, default: false
    Integer :cost, default: 0
    String :properties, text: true # JSON
    String :location # Legacy field: if not owned by character, where it is (e.g., "on the table")
    DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
  end
end

# Migrate existing items table: remove weight, add cost
if DB.table_exists?(:items)
  if DB[:items].columns.include?(:weight)
    DB.alter_table :items do
      drop_column :weight
    end
  end

  if !DB[:items].columns.include?(:cost)
    DB.alter_table :items do
      add_column :cost, Integer, default: 0
    end
  end
end

unless DB.table_exists?(:worlds)
  DB.create_table :worlds do
    primary_key :id
    String :name, null: false
    String :description, text: true
    Integer :created_by
    TrueClass :is_template, default: false
    String :time_of_day, default: 'morning'
    Integer :days_elapsed, default: 0
    String :world_state, text: true # JSON
    DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
  end
end

unless DB.table_exists?(:locations)
  DB.create_table :locations do
    primary_key :id
    Integer :world_id, null: false
    Integer :parent_location_id
    String :name, null: false
    String :description, text: true
    String :location_type # indoor, outdoor, dungeon, etc.
    String :state, text: true # JSON for dynamic state
    Integer :map_x # X coordinate on visual map (0-based grid)
    Integer :map_y # Y coordinate on visual map (0-based grid)
    DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
  end
end

# Add map coordinates to existing locations table if they don't exist
if DB.table_exists?(:locations)
  if !DB[:locations].columns.include?(:map_x)
    DB.alter_table :locations do
      add_column :map_x, Integer
      add_column :map_y, Integer
    end
  end
end

unless DB.table_exists?(:connections)
  DB.create_table :connections do
    primary_key :id
    Integer :world_id, null: false
    Integer :from_location_id, null: false
    Integer :to_location_id, null: false
    String :connection_type, default: 'passage' # passage, door, portal, teleporter, magical
    String :direction, null: false
    String :description, text: true
    TrueClass :is_visible, default: true
    TrueClass :is_locked, default: false
    TrueClass :is_open, default: true
    Integer :required_item_id
    TrueClass :is_bidirectional, default: false
    String :reverse_description, text: true
    DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
  end
end

unless DB.table_exists?(:containers)
  DB.create_table :containers do
    primary_key :id
    Integer :world_id, null: false
    Integer :location_id
    Integer :character_id
    String :name, null: false
    String :description, text: true
    TrueClass :is_locked, default: false
    TrueClass :is_open, default: true
    Integer :capacity
    DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
  end
end

unless DB.table_exists?(:quests)
  DB.create_table :quests do
    primary_key :id
    Integer :world_id, null: false
    Integer :room_id, null: false
    String :name, null: false
    String :description, text: true
    String :quest_type, default: 'main' # main, side, personal
    String :status, default: 'active' # active, completed, failed, abandoned
    DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
    DateTime :completed_at
  end
end

unless DB.table_exists?(:quest_objectives)
  DB.create_table :quest_objectives do
    primary_key :id
    Integer :quest_id, null: false
    String :objective_type, default: 'custom' # reach_location, acquire_item, kill_character, custom
    String :target_type # Location, Item, Character
    Integer :target_id
    Integer :quantity, default: 1
    Integer :current_progress, default: 0
    Integer :display_order, default: 0
    TrueClass :is_completed, default: false
    String :description, text: true
    TrueClass :is_optional, default: false
    DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
  end
end

# Migrate quest_objectives table: make objective_type nullable/default, add display_order
if DB.table_exists?(:quest_objectives)
  # Add display_order if it doesn't exist
  if !DB[:quest_objectives].columns.include?(:display_order)
    DB.alter_table :quest_objectives do
      add_column :display_order, Integer, default: 0
    end
  end

  # Check if objective_type needs to be made nullable
  begin
    test_obj = DB[:quest_objectives].insert(
      quest_id: -1,
      description: 'TEST_DELETE_ME'
    )
    DB[:quest_objectives].where(id: test_obj).delete
  rescue Sequel::NotNullConstraintViolation, Sequel::ConstraintViolation
    puts "Migrating quest_objectives table to make objective_type default to 'custom'..."

    DB.transaction do
      DB.rename_table :quest_objectives, :quest_objectives_old

      DB.create_table :quest_objectives do
        primary_key :id
        Integer :quest_id, null: false
        String :objective_type, default: 'custom'
        String :target_type
        Integer :target_id
        Integer :quantity, default: 1
        Integer :current_progress, default: 0
        Integer :display_order, default: 0
        TrueClass :is_completed, default: false
        String :description, text: true
        TrueClass :is_optional, default: false
        DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      end

      DB[:quest_objectives].insert(DB[:quest_objectives_old].select_all)
      DB.drop_table :quest_objectives_old

      puts "Quest objectives table migration complete!"
    end
  end
end

unless DB.table_exists?(:game_events)
  DB.create_table :game_events do
    primary_key :id
    Integer :world_id, null: false
    Integer :room_id
    String :event_type, null: false
    String :actor_type
    Integer :actor_id
    String :target_type
    Integer :target_id
    String :event_data, text: true # JSON
    Integer :created_by
    DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
  end
end

unless DB.table_exists?(:world_builder_conversations)
  DB.create_table :world_builder_conversations do
    primary_key :id
    Integer :world_id, null: false
    String :role, null: false # 'system', 'user', 'assistant', 'tool'
    String :content, text: true # Message content
    String :tool_name # For tool/function calls
    String :tool_args, text: true # JSON of function arguments
    String :tool_result, text: true # JSON of function result
    DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP

    foreign_key [:world_id], :worlds, on_delete: :cascade
    index :world_id, name: :idx_wbc_world
  end
end

# Migrate quests table: make room_id nullable for WorldBuilder templates
if DB.table_exists?(:quests)
  # SQLite doesn't support ALTER COLUMN directly, so we need to check if it's already nullable
  # by trying to insert a test record or checking the schema
  # For now, we'll recreate the table if needed
  begin
    # Test if room_id can be null
    test_quest = DB[:quests].insert(
      world_id: -1,
      room_id: nil,
      name: 'TEST_QUEST_DELETE_ME',
      description: 'Test'
    )
    DB[:quests].where(id: test_quest).delete
  rescue Sequel::NotNullConstraintViolation, Sequel::ConstraintViolation
    # room_id is not nullable, need to recreate the table
    puts "Migrating quests table to make room_id nullable..."

    DB.transaction do
      # Rename old table
      DB.rename_table :quests, :quests_old

      # Create new table with nullable room_id
      DB.create_table :quests do
        primary_key :id
        Integer :world_id, null: false
        Integer :room_id # Made nullable for WorldBuilder templates
        String :name, null: false
        String :description, text: true
        String :quest_type, default: 'main'
        String :status, default: 'active'
        DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
        DateTime :completed_at
      end

      # Copy data from old table
      DB[:quests].insert(DB[:quests_old].select_all)

      # Drop old table
      DB.drop_table :quests_old

      puts "Quests table migration complete!"
    end
  end
end
