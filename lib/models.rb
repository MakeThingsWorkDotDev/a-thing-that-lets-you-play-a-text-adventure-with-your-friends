# frozen_string_literal: true

# Sequel model classes for the game engine

class World < Sequel::Model
  one_to_many :locations
  one_to_many :characters
  one_to_many :items
  one_to_many :containers
  one_to_many :connections
  one_to_many :rooms
  one_to_many :quests
  one_to_many :game_events

  def before_create
    self.world_state ||= '{}'
    super
  end
end

class Location < Sequel::Model
  many_to_one :world
  many_to_one :parent_location, class: :Location
  one_to_many :characters
  one_to_many :containers
  one_to_many :items
  one_to_many :connections_from, key: :from_location_id, class: :Connection
  one_to_many :connections_to, key: :to_location_id, class: :Connection
  one_to_many :child_locations, key: :parent_location_id, class: :Location

  def before_create
    self.state ||= '{}'
    super
  end

  def exits
    connections_from_dataset.where(is_visible: true).all
  end
end

class Connection < Sequel::Model
  many_to_one :world
  many_to_one :from_location, class: :Location
  many_to_one :to_location, class: :Location
  many_to_one :required_item, class: :Item
end

class Character < Sequel::Model
  many_to_one :world
  many_to_one :user
  many_to_one :location
  one_to_many :items
  one_to_many :containers

  def before_create
    self.additional_stats ||= '{}'
    super
  end

  def player_character?
    !user_id.nil?
  end

  def npc?
    user_id.nil?
  end

  def stat_modifier(stat_value)
    ((stat_value - 10) / 2.0).floor
  end
end

class Container < Sequel::Model
  many_to_one :world
  many_to_one :location
  many_to_one :character
  one_to_many :items
end

class Item < Sequel::Model
  many_to_one :world
  many_to_one :location
  many_to_one :character
  many_to_one :container

  def before_create
    self.properties ||= '{}'
    super
  end
end

class Quest < Sequel::Model
  many_to_one :world
  many_to_one :room
  one_to_many :quest_objectives

  def all_objectives_complete?
    required_objectives = quest_objectives_dataset.where(is_optional: false).all
    required_objectives.all? { |obj| obj.is_completed }
  end
end

class QuestObjective < Sequel::Model
  many_to_one :quest

  def target
    return nil unless target_type && target_id
    Object.const_get(target_type)[target_id]
  end
end

class GameEvent < Sequel::Model
  many_to_one :world
  many_to_one :room

  def before_create
    self.event_data ||= '{}'
    super
  end

  def actor
    return nil unless actor_type && actor_id
    Object.const_get(actor_type)[actor_id]
  end

  def target
    return nil unless target_type && target_id
    Object.const_get(target_type)[target_id]
  end
end

class Room < Sequel::Model
  many_to_one :world
  many_to_one :current_location, class: :Location
  one_to_many :user_rooms
  one_to_many :chat_messages
  one_to_many :quests

  def players
    user_rooms.map(&:user)
  end

  def player_characters
    user_rooms.map(&:character).compact
  end
end

class UserRoom < Sequel::Model
  many_to_one :user
  many_to_one :room
  many_to_one :character
end

class ChatMessage < Sequel::Model
  many_to_one :room
  many_to_one :user
  many_to_one :character
end

class User < Sequel::Model
  one_to_many :characters
  one_to_many :user_rooms

  def player_character_in_world(world_id)
    characters_dataset.where(world_id: world_id, character_type: 'player').first
  end
end
