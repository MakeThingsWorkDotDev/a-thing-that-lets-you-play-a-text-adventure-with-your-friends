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
    DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
  end
end

# Add is_muted column to existing user_rooms table if it doesn't exist
unless DB[:user_rooms].columns.include?(:is_muted)
  DB.alter_table :user_rooms do
    add_column :is_muted, TrueClass, default: false
  end
end

# Add hand_raised column to existing user_rooms table if it doesn't exist
unless DB[:user_rooms].columns.include?(:hand_raised)
  DB.alter_table :user_rooms do
    add_column :hand_raised, TrueClass, default: false
  end
end

unless DB.table_exists?(:chat_messages)
  DB.create_table :chat_messages do
    primary_key :id
    Integer :room_id
    Integer :user_id
    String :message
    String :data, default: "{}"
    DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
  end
end

unless DB.table_exists?(:characters)
  DB.create_table :characters do
    primary_key :id
    Integer :room_id, null: false
    String :name, null: false
    String :description
    Integer :max_hp, default: 10
    Integer :current_hp, default: 10
    TrueClass :is_dead, default: false
    String :location # e.g., "tavern", "forest clearing", "north tower"
    DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
  end
end

unless DB.table_exists?(:items)
  DB.create_table :items do
    primary_key :id
    Integer :room_id, null: false
    Integer :character_id # nullable - if owned by a character
    String :name, null: false
    String :description
    Integer :quantity, default: 1 # for stackable items like coins, arrows, potions
    String :location # if not owned by character, where it is (e.g., "on the table", "hanging on wall")
    DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
  end
end

# Add quantity column to existing items table if it doesn't exist
unless DB[:items].columns.include?(:quantity)
  DB.alter_table :items do
    add_column :quantity, Integer, default: 1
  end
end
