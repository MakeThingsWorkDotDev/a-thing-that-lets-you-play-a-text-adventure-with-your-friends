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
    DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
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
