# frozen_string_literal: true

# Test script demonstrating how to use the /game-engine endpoint
# This shows various ways to call game engine methods via HTTP

require 'json'
require 'net/http'
require 'uri'

# Example usage with curl commands (copy and paste these into your terminal after logging in):

puts <<~EXAMPLES
  === Game Engine Endpoint Examples ===

  The endpoint accepts POST requests to /game-engine with JSON body:
  {
    "action": "method_name",
    "params": { "param1": value1, "param2": value2 }
  }

  === Create a World ===
  curl -X POST http://localhost:4567/game-engine \\
    -H "Content-Type: application/json" \\
    -b cookies.txt \\
    -d '{
      "action": "create_world",
      "params": {
        "name": "The Dark Forest",
        "description": "A mysterious forest shrouded in mist",
        "created_by": 1
      }
    }'

  === Create a Location ===
  curl -X POST http://localhost:4567/game-engine \\
    -H "Content-Type: application/json" \\
    -b cookies.txt \\
    -d '{
      "action": "create_location",
      "params": {
        "world_id": 1,
        "name": "Forest Entrance",
        "description": "The edge of a dark forest"
      }
    }'

  === Create a Player Character ===
  curl -X POST http://localhost:4567/game-engine \\
    -H "Content-Type: application/json" \\
    -b cookies.txt \\
    -d '{
      "action": "create_player_character",
      "params": {
        "user_id": 1,
        "world_id": 1,
        "name": "Thorin",
        "description": "A brave warrior",
        "location_id": 1,
        "max_hp": 20,
        "strength": 14,
        "intelligence": 10
      }
    }'

  === Move Character ===
  curl -X POST http://localhost:4567/game-engine \\
    -H "Content-Type: application/json" \\
    -b cookies.txt \\
    -d '{
      "action": "move_character",
      "params": {
        "character_id": 1,
        "to_location_id": 2
      }
    }'

  === Move Party ===
  curl -X POST http://localhost:4567/game-engine \\
    -H "Content-Type: application/json" \\
    -b cookies.txt \\
    -d '{
      "action": "move_party",
      "params": {
        "character_ids": [1, 2, 3],
        "to_location_id": 2
      }
    }'

  === Damage Character ===
  curl -X POST http://localhost:4567/game-engine \\
    -H "Content-Type: application/json" \\
    -b cookies.txt \\
    -d '{
      "action": "damage_character",
      "params": {
        "character_id": 1,
        "amount": 5
      }
    }'

  === Create Item ===
  curl -X POST http://localhost:4567/game-engine \\
    -H "Content-Type: application/json" \\
    -b cookies.txt \\
    -d '{
      "action": "create_item",
      "params": {
        "world_id": 1,
        "location_id": 1,
        "name": "Iron Sword",
        "description": "A well-crafted iron blade",
        "item_type": "weapon"
      }
    }'

  === Get Recent Events ===
  curl -X POST http://localhost:4567/game-engine \\
    -H "Content-Type: application/json" \\
    -b cookies.txt \\
    -d '{
      "action": "get_recent_events",
      "params": {
        "world_id": 1,
        "limit": 10
      }
    }'

  === Available Actions ===
  All methods from the GameEngine are available:

  World Manager:
  - get_world_time
  - advance_time
  - advance_day
  - set_world_state
  - get_world_state

  Location Manager:
  - create_world
  - create_location
  - create_connection
  - get_location_details
  - get_available_exits

  Character Manager:
  - move_character
  - move_party
  - damage_character
  - heal_character
  - character_take_item
  - character_drop_item
  - get_character_inventory
  - create_player_character
  - get_player_character
  - kill_character

  Container Manager:
  - create_container
  - open_container
  - close_container
  - lock_container
  - unlock_container
  - put_item_in_container
  - take_item_from_container
  - get_container_contents

  Item Manager:
  - create_item
  - move_item_to_location
  - destroy_item
  - get_items_at_location

  Combat Manager:
  - initiate_combat
  - attack
  - end_combat
  - get_combat_state

  Quest Manager:
  - create_quest
  - create_quest_objective
  - update_objective_progress
  - complete_objective
  - complete_quest
  - fail_quest
  - get_active_quests

  Event Logger:
  - log
  - get_recent_events
  - get_events

  === Notes ===
  - You must be logged in (use cookies.txt to store session)
  - To save cookies: curl -c cookies.txt -X POST http://localhost:4567/login -d "username=admin&password=yourpass"
  - If params include room_id, you must have access to that room
  - All responses are JSON
  - Errors return { "error": "message" }
EXAMPLES
