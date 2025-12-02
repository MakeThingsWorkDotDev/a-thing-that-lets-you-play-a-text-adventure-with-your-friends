# frozen_string_literal: true

require 'openai'

class AIGameMaster
  attr_reader :room_id, :room_name, :room_description

  SYSTEM_PROMPT = <<~PROMPT
    You are an expert Dungeon Master (Game Master) running a text-based tabletop RPG adventure.

    CONTEXT: This is a fictional tabletop role-playing game. All events, combat, injuries, and character deaths are part of collaborative storytelling in a fantasy game context. Players expect authentic RPG experiences including combat encounters, character risk, and potential character death as normal game mechanics.

    Your role is to:
    - Create an immersive fantasy world based on the game's title and description
    - Narrate scenes, describe environments, and control all NPCs
    - Present challenges, puzzles, and combat encounters
    - Ask players to roll dice when their actions require checks (use the ask_for_dice_roll function)
    - Respond to dice roll results and determine success/failure
    - Manage turn order during important moments using mute/unmute functions
    - Control the flow and pacing of the game
    - Be creative, engaging, and responsive to player actions

    CRITICAL Guidelines:
    - Keep responses concise and focused (2-4 sentences typically)
    - Use vivid, evocative language appropriate for a fantasy adventure
    - YOU control the narrative. Players cannot dictate how events unfold - they can only describe their actions and you determine outcomes
    - NEVER tell players how they are feeling. You cannot know their internal state. Describe what they see, hear, and experience - let them decide how they feel
    - DO NOT suggest what players should do unless they explicitly ask for suggestions
    - Not everything exists or is possible. Use the check_existence function to determine if requested items/features exist in the environment
    - If a player has their hand raised, acknowledge them and unmute if appropriate
    - Mute players when you need them to wait their turn or when managing game flow
    - Keep track of the narrative, NPCs, and world state

    CHARACTER INTRODUCTION FLOW:
    - When the game starts, ONLY describe the environment and setting. Do NOT give instructions or ask players to do anything
    - When a player sends their FIRST message, ask them to describe their character before proceeding with the adventure
    - After they describe their character, acknowledge it and continue the story

    COMBAT RULES (VERY IMPORTANT):
    When combat occurs or enemies attack:
    1. MUTE the player being attacked FIRST
    2. Describe the attack in detail
    3. Roll dice for the attack (you control enemy actions)
    4. Explain the outcome (hit/miss, damage, effects)
    5. UNMUTE the player so they can respond

    The player does NOT control how combat progresses. YOU control enemies, NPCs, and the flow of battle. Players can only describe their attempted actions - you determine what actually happens.

    IMPORTANT: As a Game Master, you should narrate combat authentically:
    - Enemies CAN and SHOULD attack player characters when appropriate
    - Describe injuries, wounds, and damage realistically based on the weapon/attack
    - Characters (PCs and NPCs) can be injured, incapacitated, or killed based on game mechanics
    - Use appropriate fantasy violence language (slashing, piercing, crushing, etc.)
    - This is collaborative storytelling - treat combat like any published RPG adventure would

    Available dice: d4, d6, d8, d10, d12, d20, d100
    Dice format examples: "1d20", "2d6+3", "1d20+5"

    You can use these functions to control the game:
    - send_message: Send a message as the Game Master
    - mute_player: Mute a player (use for turn management and combat)
    - unmute_player: Unmute a player
    - ask_for_dice_roll: Request a specific dice roll from a player (this automatically sends the message - do NOT call send_message after this)
    - get_raised_hands: See which players have their hand raised
    - check_existence: Determine if an item, feature, or NPC exists (use when players ask "is there a...")
    - end_game: End the adventure with a final message and "The End"

    CRITICAL - WHEN TO STOP AND WAIT:
    When you call ask_for_dice_roll, you MUST stop and wait for the player's response. Do NOT:
    - Call send_message again
    - Continue narrating
    - Make any other function calls
    - Respond with any text

    Your turn is OVER after calling ask_for_dice_roll. You will receive the player's dice roll result in the next message, and ONLY THEN should you continue the story.

    PERSISTENT WORLD SYSTEM (VERY IMPORTANT):
    You have access to a database system that tracks NPCs and items in the game world. Use these tools to create a living, persistent world:

    CHARACTER SYSTEM:
    - When you introduce a new NPC that players might interact with, IMMEDIATELY use create_character
    - Examples: bartender, guard, shopkeeper, monster, any named NPC
    - Set appropriate HP: 5-10 for civilians, 15-30 for guards/warriors, 50-100+ for bosses
    - Use damage_character when characters take damage (combat, traps, etc.)
    - Use heal_character for healing spells, potions, rest
    - Characters automatically die when HP reaches 0
    - Use list_characters to see who's in a location before describing a scene
    - Use get_character to check an NPC's current status before describing them

    ITEM SYSTEM:
    - When you describe items players might interact with, use create_item
    - Examples: weapons, potions, keys, treasure, documents, food, tools
    - Use give_item_to_character when NPCs or players acquire items
    - Use take_item_from_character when items are dropped, stolen, or traded
    - Use list_character_inventory to check what an NPC is carrying
    - Use list_items_in_location to see what's available in a location

    CURRENCY AND QUANTITIES (CRITICAL):
    - Items have a quantity field for stackable items (coins, arrows, potions, etc.)
    - When creating currency, use create_item with a quantity: create_item(name: "gold coins", quantity: 50)
    - NEVER remove entire currency items when players pay - use modify_item_quantity instead
    - Example transaction:
      * Player has "gold coins" (quantity: 50)
      * They pay 10 gold
      * Call modify_item_quantity(item_name: "gold coins", character_name: "PlayerName", change: -10)
      * Call modify_item_quantity(item_name: "gold coins", character_name: "Shopkeeper", change: +10)
    - If a character doesn't have an item yet, create it first, then modify quantity
    - Quantities work for any stackable item: arrows (x20), healing potions (x5), rations (x10), etc.

    TRANSPARENCY RULE - CRITICAL:
    NEVER mention that you're "creating a database record" or "updating character stats" or reference the system.
    Instead, weave it naturally into narration:
    - BAD: "I'm creating a character called the bartender with 10 HP"
    - GOOD: "Behind the bar stands a grizzled dwarf, polishing a glass..." (then call create_character)
    - BAD: "Let me check the database for the guard's HP"
    - GOOD: (silently call get_character, then narrate based on the result)

    WORKFLOW EXAMPLES:
    1. Player asks "What's in the tavern?"
       → Call list_characters with location "tavern"
       → If empty, call create_character for bartender/patrons as you describe them
       → Call list_items_in_location for "tavern"
       → Narrate the scene including characters and items

    2. Combat occurs with an NPC:
       → Call get_character to check their current HP
       → Roll for damage
       → Call damage_character with the damage amount
       → Narrate the result (if is_dead: true, describe their death)

    3. Player asks "Does the guard have a key?"
       → Call list_character_inventory for "guard"
       → Narrate based on result

    4. Player buys an item for 10 gold:
       → Call list_character_inventory to check player's gold
       → Call modify_item_quantity(item_name: "gold coins", character_name: "PlayerName", change: -10)
       → Call modify_item_quantity(item_name: "gold coins", character_name: "Shopkeeper", change: +10)
       → Call give_item_to_character to transfer the purchased item
       → Narrate the transaction

    These tools run in the background - players never see function calls, only your narration.

    Format all your narration and NPC dialogue in an engaging, dramatic style befitting a fantasy adventure.
  PROMPT

  def initialize(room_id, room_name, room_description, db, sockets, sockets_mutex, restore: false)
    @room_id = room_id
    @room_name = room_name
    @room_description = room_description
    @db = db
    @sockets = sockets
    @sockets_mutex = sockets_mutex
    @conversation_history = []
    @client = OpenAI::Client.new(access_token: ENV.fetch('OPENAI_API_KEY'))
    @ai_user_id = @db[:users].where(username: 'AI', is_ai: true).first[:id]

    # Initialize conversation with game setup
    if restore
      restore_game
    else
      initialize_game
    end
  end

  def initialize_game
    intro_message = "Welcome to #{@room_name}! #{@room_description}\n\nInitializing your adventure..."

    # Add system message and game context
    @conversation_history << {
      role: 'system',
      content: SYSTEM_PROMPT
    }

    @conversation_history << {
      role: 'system',
      content: "Game Title: #{@room_name}\nGame Description: #{@room_description}\n\nBegin the adventure by setting the scene. ONLY describe the environment and setting. Do NOT give any instructions to players or ask them to do anything. Just paint the scene."
    }

    # Send intro message and get AI's opening narration
    send_message_to_room(intro_message)
    process_ai_response
  end

  def restore_game
    # Add system message and game context
    @conversation_history << {
      role: 'system',
      content: SYSTEM_PROMPT
    }

    @conversation_history << {
      role: 'system',
      content: "Game Title: #{@room_name}\nGame Description: #{@room_description}\n\nYou are resuming an ongoing adventure. Review the recent message history below to understand the current situation."
    }

    # Load last 20 messages to give AI context
    messages = @db[:chat_messages]
      .join(:users, id: :user_id)
      .where(room_id: @room_id)
      .order(Sequel[:chat_messages][:created_at])
      .reverse
      .limit(20)
      .select(
        Sequel[:chat_messages][:message],
        Sequel[:chat_messages][:data],
        Sequel[:users][:username],
        Sequel[:users][:is_ai]
      )
      .all
      .reverse

    # Add messages to conversation history
    messages.each do |msg|
      if msg[:data] && msg[:data] != '{}'
        parsed_data = JSON.parse(msg[:data])
        if parsed_data['type'] == 'dice_roll'
          message_text = "#{msg[:username]} rolled #{parsed_data['command']}: #{format_dice_results(parsed_data)}"
        else
          message_text = "#{msg[:username]}: #{msg[:message]}"
        end
      else
        message_text = "#{msg[:username]}: #{msg[:message]}"
      end

      role = msg[:is_ai] ? 'assistant' : 'user'
      @conversation_history << {
        role: role,
        content: message_text
      }
    end

    puts "AI GM restored for room #{@room_id} with #{messages.length} messages of context"
  end

  def handle_player_message(username, message, data = nil)
    # Check if this is a dice roll result
    if data && data['type'] == 'dice_roll'
      user_message = "#{username} rolled #{data['command']}: #{format_dice_results(data)}"
    else
      user_message = "#{username}: #{message}"
    end

    @conversation_history << {
      role: 'user',
      content: user_message
    }

    process_ai_response
  end

  def handle_player_joined(username)
    @conversation_history << {
      role: 'system',
      content: "#{username} has joined the game."
    }

    process_ai_response
  end

  def handle_player_left(username)
    @conversation_history << {
      role: 'system',
      content: "#{username} has left the game."
    }

    process_ai_response
  end

  def handle_hand_raised(username)
    @conversation_history << {
      role: 'system',
      content: "#{username} has raised their hand and wants to speak."
    }

    process_ai_response
  end

  private

  def format_dice_results(data)
    dice_results = data['result_dice'].map { |roll, die| "d#{die}:#{roll}" }.join(", ")
    modifiers = data['modifiers'].any? ? " modifiers: #{data['modifiers'].join(', ')}" : ""
    "Individual: [#{dice_results}]#{modifiers} = Total: #{data['total']}"
  end

  def process_ai_response
    # Define functions the AI can call
    functions = [
      {
        type: 'function',
        function: {
          name: 'send_message',
          description: 'Send a message to the game room as the Game Master',
          parameters: {
            type: 'object',
            properties: {
              message: {
                type: 'string',
                description: 'The message to send to players'
              }
            },
            required: ['message']
          }
        }
      },
      {
        type: 'function',
        function: {
          name: 'mute_player',
          description: 'Mute a player to control turn order or game flow',
          parameters: {
            type: 'object',
            properties: {
              username: {
                type: 'string',
                description: 'The username of the player to mute'
              }
            },
            required: ['username']
          }
        }
      },
      {
        type: 'function',
        function: {
          name: 'unmute_player',
          description: 'Unmute a player so they can speak',
          parameters: {
            type: 'object',
            properties: {
              username: {
                type: 'string',
                description: 'The username of the player to unmute'
              }
            },
            required: ['username']
          }
        }
      },
      {
        type: 'function',
        function: {
          name: 'ask_for_dice_roll',
          description: 'Ask a specific player to roll dice for an action or check',
          parameters: {
            type: 'object',
            properties: {
              username: {
                type: 'string',
                description: 'The username of the player who should roll'
              },
              dice_spec: {
                type: 'string',
                description: 'The dice to roll (e.g., "1d20", "2d6+3")'
              },
              reason: {
                type: 'string',
                description: 'Why they need to roll (e.g., "for perception check", "for attack")'
              }
            },
            required: ['username', 'dice_spec', 'reason']
          }
        }
      },
      {
        type: 'function',
        function: {
          name: 'get_raised_hands',
          description: 'Get a list of players who currently have their hand raised',
          parameters: {
            type: 'object',
            properties: {}
          }
        }
      },
      {
        type: 'function',
        function: {
          name: 'check_existence',
          description: 'Check if an item, feature, NPC, or environmental element exists in the current context. Use this when players ask "is there a..." to determine if something exists. Returns true or false based on logical probability and narrative coherence.',
          parameters: {
            type: 'object',
            properties: {
              item_description: {
                type: 'string',
                description: 'What the player is asking about (e.g., "torch on the wall", "exit to the north", "shopkeeper")'
              }
            },
            required: ['item_description']
          }
        }
      },
      {
        type: 'function',
        function: {
          name: 'end_game',
          description: 'End the adventure with a final message and mute all players. Use this when the story reaches its natural conclusion.',
          parameters: {
            type: 'object',
            properties: {
              final_message: {
                type: 'string',
                description: 'The final narration to conclude the adventure'
              }
            },
            required: ['final_message']
          }
        }
      },
      {
        type: 'function',
        function: {
          name: 'create_character',
          description: 'Create a new NPC character in the game world with stats and description. Use this whenever you introduce a new character that players might interact with.',
          parameters: {
            type: 'object',
            properties: {
              name: {
                type: 'string',
                description: 'The character\'s name'
              },
              description: {
                type: 'string',
                description: 'Physical description and personality traits'
              },
              max_hp: {
                type: 'integer',
                description: 'Maximum hit points (default 10 for common NPCs, 20-50 for significant characters, 100+ for bosses)'
              },
              location: {
                type: 'string',
                description: 'Where the character is located (e.g., "tavern", "forest path", "throne room")'
              }
            },
            required: ['name', 'description', 'location']
          }
        }
      },
      {
        type: 'function',
        function: {
          name: 'get_character',
          description: 'Retrieve information about a character by name. Use this to check current HP, status, inventory, etc.',
          parameters: {
            type: 'object',
            properties: {
              name: {
                type: 'string',
                description: 'The character\'s name'
              }
            },
            required: ['name']
          }
        }
      },
      {
        type: 'function',
        function: {
          name: 'list_characters',
          description: 'List all characters in a specific location or all characters in the game.',
          parameters: {
            type: 'object',
            properties: {
              location: {
                type: 'string',
                description: 'Optional: filter by location. If omitted, returns all characters in the game.'
              }
            }
          }
        }
      },
      {
        type: 'function',
        function: {
          name: 'damage_character',
          description: 'Reduce a character\'s HP by a specific amount. If HP reaches 0 or below, character is automatically marked as dead.',
          parameters: {
            type: 'object',
            properties: {
              name: {
                type: 'string',
                description: 'The character\'s name'
              },
              damage: {
                type: 'integer',
                description: 'Amount of damage to deal'
              }
            },
            required: ['name', 'damage']
          }
        }
      },
      {
        type: 'function',
        function: {
          name: 'heal_character',
          description: 'Restore a character\'s HP by a specific amount (cannot exceed max HP).',
          parameters: {
            type: 'object',
            properties: {
              name: {
                type: 'string',
                description: 'The character\'s name'
              },
              healing: {
                type: 'integer',
                description: 'Amount of HP to restore'
              }
            },
            required: ['name', 'healing']
          }
        }
      },
      {
        type: 'function',
        function: {
          name: 'update_character_location',
          description: 'Move a character to a new location.',
          parameters: {
            type: 'object',
            properties: {
              name: {
                type: 'string',
                description: 'The character\'s name'
              },
              new_location: {
                type: 'string',
                description: 'The new location'
              }
            },
            required: ['name', 'new_location']
          }
        }
      },
      {
        type: 'function',
        function: {
          name: 'create_item',
          description: 'Create a new item in the game world.',
          parameters: {
            type: 'object',
            properties: {
              name: {
                type: 'string',
                description: 'The item\'s name'
              },
              description: {
                type: 'string',
                description: 'Description of the item'
              },
              quantity: {
                type: 'integer',
                description: 'Quantity for stackable items (coins, arrows, potions). Default is 1.'
              },
              location: {
                type: 'string',
                description: 'Where the item is located (e.g., "on the bar", "in the chest", "lying on the ground")'
              }
            },
            required: ['name', 'description', 'location']
          }
        }
      },
      {
        type: 'function',
        function: {
          name: 'modify_item_quantity',
          description: 'Add or subtract from an item\'s quantity. Use this for currency transactions, consuming potions, using arrows, etc.',
          parameters: {
            type: 'object',
            properties: {
              item_name: {
                type: 'string',
                description: 'The item\'s name'
              },
              character_name: {
                type: 'string',
                description: 'The character who owns the item (optional - leave empty for items in the world)'
              },
              change: {
                type: 'integer',
                description: 'Amount to change (positive to add, negative to subtract). If quantity reaches 0 or below, item is removed.'
              }
            },
            required: ['item_name', 'change']
          }
        }
      },
      {
        type: 'function',
        function: {
          name: 'give_item_to_character',
          description: 'Transfer an item to a character\'s inventory. Item must exist first.',
          parameters: {
            type: 'object',
            properties: {
              item_name: {
                type: 'string',
                description: 'The item\'s name'
              },
              character_name: {
                type: 'string',
                description: 'The character who receives the item'
              }
            },
            required: ['item_name', 'character_name']
          }
        }
      },
      {
        type: 'function',
        function: {
          name: 'take_item_from_character',
          description: 'Remove an item from a character\'s inventory and place it in the world.',
          parameters: {
            type: 'object',
            properties: {
              item_name: {
                type: 'string',
                description: 'The item\'s name'
              },
              character_name: {
                type: 'string',
                description: 'The character who loses the item'
              },
              new_location: {
                type: 'string',
                description: 'Where the item ends up (e.g., "on the ground", "on the table")'
              }
            },
            required: ['item_name', 'character_name', 'new_location']
          }
        }
      },
      {
        type: 'function',
        function: {
          name: 'list_character_inventory',
          description: 'List all items a character is carrying.',
          parameters: {
            type: 'object',
            properties: {
              character_name: {
                type: 'string',
                description: 'The character\'s name'
              }
            },
            required: ['character_name']
          }
        }
      },
      {
        type: 'function',
        function: {
          name: 'list_items_in_location',
          description: 'List all items in a specific location that are not in character inventories.',
          parameters: {
            type: 'object',
            properties: {
              location: {
                type: 'string',
                description: 'The location to search'
              }
            },
            required: ['location']
          }
        }
      }
    ]

    response = @client.chat(
      parameters: {
        model: 'gpt-5-nano',
        messages: @conversation_history,
        tools: functions,
        tool_choice: 'auto'
      }
    )

    message = response.dig('choices', 0, 'message')

    # Add assistant's response to history
    @conversation_history << message

    # Check if AI wants to call functions
    if message['tool_calls']
      should_continue = true

      message['tool_calls'].each do |tool_call|
        function_name = tool_call.dig('function', 'name')
        arguments = JSON.parse(tool_call.dig('function', 'arguments'))

        result = execute_function(function_name, arguments)

        # Add function result to conversation
        @conversation_history << {
          role: 'tool',
          tool_call_id: tool_call['id'],
          content: result.to_json
        }

        # Check if this is a terminal function that ends the AI's turn
        # send_message: AI has narrated, turn is over
        # ask_for_dice_roll: Waiting for player input (also calls send_message internally)
        # end_game: Game is over
        if ['send_message', 'ask_for_dice_roll', 'end_game'].include?(function_name)
          should_continue = false
        end
      end

      # Only continue for query functions like get_raised_hands, check_existence, mute_player, unmute_player
      if should_continue
        process_ai_response
      end
    elsif message['content']
      # If AI responded with text but didn't call send_message, send it anyway
      send_message_to_room(message['content'])
    end
  rescue => e
    puts "AI Error: #{e.message}"
    puts e.backtrace.join("\n")
  end

  def execute_function(function_name, arguments)
    case function_name
    when 'send_message'
      send_message_to_room(arguments['message'])
      { success: true }
    when 'mute_player'
      mute_player(arguments['username'])
    when 'unmute_player'
      unmute_player(arguments['username'])
    when 'ask_for_dice_roll'
      ask_for_dice_roll(arguments['username'], arguments['dice_spec'], arguments['reason'])
    when 'get_raised_hands'
      get_raised_hands
    when 'check_existence'
      check_existence(arguments['item_description'])
    when 'end_game'
      end_game(arguments['final_message'])
    when 'create_character'
      create_character(arguments['name'], arguments['description'], arguments['max_hp'], arguments['location'])
    when 'get_character'
      get_character(arguments['name'])
    when 'list_characters'
      list_characters(arguments['location'])
    when 'damage_character'
      damage_character(arguments['name'], arguments['damage'])
    when 'heal_character'
      heal_character(arguments['name'], arguments['healing'])
    when 'update_character_location'
      update_character_location(arguments['name'], arguments['new_location'])
    when 'create_item'
      create_item(arguments['name'], arguments['description'], arguments['quantity'], arguments['location'])
    when 'modify_item_quantity'
      modify_item_quantity(arguments['item_name'], arguments['character_name'], arguments['change'])
    when 'give_item_to_character'
      give_item_to_character(arguments['item_name'], arguments['character_name'])
    when 'take_item_from_character'
      take_item_from_character(arguments['item_name'], arguments['character_name'], arguments['new_location'])
    when 'list_character_inventory'
      list_character_inventory(arguments['character_name'])
    when 'list_items_in_location'
      list_items_in_location(arguments['location'])
    else
      { error: 'Unknown function' }
    end
  end

  def send_message_to_room(message)
    return if message.nil? || message.strip.empty?

    # Save message to database
    @db[:chat_messages].insert(
      room_id: @room_id,
      user_id: @ai_user_id,
      message: message,
      data: '{}'
    )

    # Broadcast to websocket
    broadcast_to_room({
      html: render_ai_message(message),
      user_id: @ai_user_id
    })
  end

  def mute_player(username)
    user = @db[:users].where(username: username).first
    return { error: 'User not found' } unless user

    @db[:user_rooms]
      .where(user_id: user[:id], room_id: @room_id)
      .update(is_muted: true)

    # Broadcast mute status
    broadcast_to_room({
      type: 'mute_status',
      user_id: user[:id],
      is_muted: true,
      username: username
    })

    { success: true, message: "#{username} has been muted" }
  end

  def unmute_player(username)
    user = @db[:users].where(username: username).first
    return { error: 'User not found' } unless user

    @db[:user_rooms]
      .where(user_id: user[:id], room_id: @room_id)
      .update(is_muted: false, hand_raised: false)

    # Broadcast mute status
    broadcast_to_room({
      type: 'mute_status',
      user_id: user[:id],
      is_muted: false,
      username: username
    })

    { success: true, message: "#{username} has been unmuted" }
  end

  def ask_for_dice_roll(username, dice_spec, reason)
    message = "@#{username}, please roll #{dice_spec} #{reason}. Use: /roll #{dice_spec}"
    send_message_to_room(message)
    { success: true, message: "Asked #{username} to roll #{dice_spec}" }
  end

  def get_raised_hands
    raised = @db[:user_rooms]
      .join(:users, id: :user_id)
      .where(room_id: @room_id, hand_raised: true)
      .select(Sequel[:users][:username])
      .all
      .map { |r| r[:username] }

    { players_with_hands_raised: raised }
  end

  def check_existence(item_description)
    # Use a simple randomization with some logic
    # 60% chance of existence for reasonable requests
    # This adds unpredictability and realism
    exists = rand < 0.6

    {
      exists: exists,
      item_description: item_description,
      message: exists ? "Yes, #{item_description} exists" : "No, #{item_description} does not exist"
    }
  end

  def end_game(final_message)
    # Send the final message
    send_message_to_room(final_message)

    # Add "The End" message
    send_message_to_room("\n\n~~ THE END ~~")

    # Mute all players in the room
    players = @db[:users]
      .join(:user_rooms, user_id: :id)
      .where(room_id: @room_id)
      .where(Sequel[:users][:is_ai] => false)
      .select(Sequel[:users][:id], Sequel[:users][:username])
      .all

    players.each do |player|
      @db[:user_rooms]
        .where(user_id: player[:id], room_id: @room_id)
        .update(is_muted: true)

      # Broadcast mute status
      broadcast_to_room({
        type: 'mute_status',
        user_id: player[:id],
        is_muted: true,
        username: player[:username]
      })
    end

    { success: true, message: "Game ended and all players muted" }
  end

  def render_ai_message(message)
    # This should match the GM message template
    username = 'AI'
    <<~HTML.strip
      <div class="my-1 p-1 border-l-4 border-terminal-green-500 pl-2">
        <span class="font-bold text-terminal-green-500">[GM] #{username}:</span>
        <span class="text-terminal-green-500">#{CGI.escapeHTML(message)}</span>
      </div>
    HTML
  end

  def broadcast_to_room(data)
    @sockets_mutex.synchronize do
      if @sockets[@room_id]
        @sockets[@room_id].each do |socket|
          socket.send(JSON.generate(data))
        end
      end
    end
  end

  # Character management functions
  def create_character(name, description, max_hp = nil, location = nil)
    max_hp ||= 10

    # Check if character already exists
    existing = @db[:characters].where(room_id: @room_id, name: name).first
    return { error: "Character '#{name}' already exists in this game" } if existing

    @db[:characters].insert(
      room_id: @room_id,
      name: name,
      description: description,
      max_hp: max_hp,
      current_hp: max_hp,
      is_dead: false,
      location: location
    )

    {
      success: true,
      message: "Created character '#{name}' with #{max_hp} HP at '#{location}'"
    }
  end

  def get_character(name)
    character = @db[:characters].where(room_id: @room_id, name: name).first
    return { error: "Character '#{name}' not found" } unless character

    # Get character's inventory
    items = @db[:items].where(room_id: @room_id, character_id: character[:id]).all

    {
      name: character[:name],
      description: character[:description],
      hp: "#{character[:current_hp]}/#{character[:max_hp]}",
      is_dead: character[:is_dead],
      location: character[:location],
      inventory: items.map { |i| { name: i[:name], description: i[:description], quantity: i[:quantity] } }
    }
  end

  def list_characters(location = nil)
    query = @db[:characters].where(room_id: @room_id)
    query = query.where(location: location) if location

    characters = query.all.map do |c|
      {
        name: c[:name],
        description: c[:description],
        hp: "#{c[:current_hp]}/#{c[:max_hp]}",
        is_dead: c[:is_dead],
        location: c[:location]
      }
    end

    {
      characters: characters,
      count: characters.length
    }
  end

  def damage_character(name, damage)
    character = @db[:characters].where(room_id: @room_id, name: name).first
    return { error: "Character '#{name}' not found" } unless character

    new_hp = [character[:current_hp] - damage, 0].max
    is_dead = new_hp <= 0

    @db[:characters].where(id: character[:id]).update(
      current_hp: new_hp,
      is_dead: is_dead
    )

    {
      success: true,
      name: name,
      damage: damage,
      new_hp: new_hp,
      max_hp: character[:max_hp],
      is_dead: is_dead,
      message: is_dead ? "#{name} has been killed!" : "#{name} took #{damage} damage (#{new_hp}/#{character[:max_hp]} HP remaining)"
    }
  end

  def heal_character(name, healing)
    character = @db[:characters].where(room_id: @room_id, name: name).first
    return { error: "Character '#{name}' not found" } unless character
    return { error: "Cannot heal a dead character" } if character[:is_dead]

    new_hp = [character[:current_hp] + healing, character[:max_hp]].min

    @db[:characters].where(id: character[:id]).update(current_hp: new_hp)

    {
      success: true,
      name: name,
      healing: healing,
      new_hp: new_hp,
      max_hp: character[:max_hp],
      message: "#{name} restored #{healing} HP (#{new_hp}/#{character[:max_hp]} HP)"
    }
  end

  def update_character_location(name, new_location)
    character = @db[:characters].where(room_id: @room_id, name: name).first
    return { error: "Character '#{name}' not found" } unless character

    old_location = character[:location]
    @db[:characters].where(id: character[:id]).update(location: new_location)

    {
      success: true,
      name: name,
      old_location: old_location,
      new_location: new_location,
      message: "#{name} moved from '#{old_location}' to '#{new_location}'"
    }
  end

  # Item management functions
  def create_item(name, description, quantity = nil, location)
    quantity ||= 1

    @db[:items].insert(
      room_id: @room_id,
      character_id: nil,
      name: name,
      description: description,
      quantity: quantity,
      location: location
    )

    quantity_str = quantity > 1 ? " (x#{quantity})" : ""
    {
      success: true,
      message: "Created item '#{name}'#{quantity_str} at '#{location}'"
    }
  end

  def modify_item_quantity(item_name, character_name = nil, change)
    # Find the item
    query = @db[:items].where(room_id: @room_id, name: item_name)

    if character_name
      character = @db[:characters].where(room_id: @room_id, name: character_name).first
      return { error: "Character '#{character_name}' not found" } unless character
      query = query.where(character_id: character[:id])
    else
      query = query.where(character_id: nil)
    end

    item = query.first
    return { error: "Item '#{item_name}' not found" } unless item

    new_quantity = item[:quantity] + change

    if new_quantity <= 0
      # Remove item entirely
      @db[:items].where(id: item[:id]).delete
      {
        success: true,
        item_name: item_name,
        old_quantity: item[:quantity],
        new_quantity: 0,
        removed: true,
        message: "#{item_name} quantity reduced to 0 and removed"
      }
    else
      # Update quantity
      @db[:items].where(id: item[:id]).update(quantity: new_quantity)
      {
        success: true,
        item_name: item_name,
        old_quantity: item[:quantity],
        new_quantity: new_quantity,
        removed: false,
        message: "#{item_name} quantity changed from #{item[:quantity]} to #{new_quantity}"
      }
    end
  end

  def give_item_to_character(item_name, character_name)
    item = @db[:items].where(room_id: @room_id, name: item_name, character_id: nil).first
    return { error: "Item '#{item_name}' not found or already owned" } unless item

    character = @db[:characters].where(room_id: @room_id, name: character_name).first
    return { error: "Character '#{character_name}' not found" } unless character

    @db[:items].where(id: item[:id]).update(
      character_id: character[:id],
      location: nil
    )

    {
      success: true,
      message: "#{character_name} received '#{item_name}'"
    }
  end

  def take_item_from_character(item_name, character_name, new_location)
    character = @db[:characters].where(room_id: @room_id, name: character_name).first
    return { error: "Character '#{character_name}' not found" } unless character

    item = @db[:items].where(room_id: @room_id, name: item_name, character_id: character[:id]).first
    return { error: "#{character_name} doesn't have '#{item_name}'" } unless item

    @db[:items].where(id: item[:id]).update(
      character_id: nil,
      location: new_location
    )

    {
      success: true,
      message: "#{character_name} lost '#{item_name}' (now at '#{new_location}')"
    }
  end

  def list_character_inventory(character_name)
    character = @db[:characters].where(room_id: @room_id, name: character_name).first
    return { error: "Character '#{character_name}' not found" } unless character

    items = @db[:items].where(room_id: @room_id, character_id: character[:id]).all

    {
      character: character_name,
      items: items.map { |i| { name: i[:name], description: i[:description], quantity: i[:quantity] } },
      count: items.length
    }
  end

  def list_items_in_location(location)
    items = @db[:items].where(room_id: @room_id, character_id: nil)
    items = items.where(Sequel.like(:location, "%#{location}%")) if location

    {
      location: location,
      items: items.all.map { |i| { name: i[:name], description: i[:description], quantity: i[:quantity], location: i[:location] } },
      count: items.count
    }
  end
end
