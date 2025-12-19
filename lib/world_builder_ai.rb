# frozen_string_literal: true

require 'openai'
require 'json'
require 'securerandom'

# WorldBuilderAI: Conversational AI assistant for building RPG worlds
# Uses OpenAI GPT-4 with function calling to help users create locations,
# NPCs, items, and connections through natural language
class WorldBuilderAI
  attr_reader :world_id

  def initialize(world_id, db, sockets, sockets_mutex, restore: false)
    @world_id = world_id
    @db = db
    @sockets = sockets
    @sockets_mutex = sockets_mutex
    @game_engine = GameEngine.new(db)
    @pending_approvals = {}  # Store approval requests by ID
    @previous_response_id = nil  # Track previous response for chaining

    # Check for OpenAI API key
    if ENV['OPENAI_API_KEY']
      @client = OpenAI::Client.new(api_key: ENV['OPENAI_API_KEY'])
      @disabled = false
    else
      @disabled = true
      puts "[WorldBuilderAI] WARNING: OPENAI_API_KEY not set, AI disabled for world #{world_id}"
    end

    # Load or initialize conversation history
    if restore
      load_conversation
    else
      @conversation_history = [system_prompt]
      save_message('system', system_prompt[:content])
      send_greeting unless restore
    end
  end

  def handle_user_message(user_id, raw_message, context: nil, retry_count: 0)
    return if @disabled

    # Inject context into message if provided
    message = raw_message
    if context && retry_count == 0
      context_str = format_context(context)
      message = "#{context_str}\n\nUser request: #{raw_message}"
      puts "[WorldBuilderAI] Injected context: #{context_str}"
    end

    # Add user message to history (only on first attempt, not on retry)
    if retry_count == 0
      add_to_history('user', message)
      save_message('user', message)
    end

    # Show thinking status
    broadcast_status(true)

    begin
      # Build request for Responses API
      request_params = {
        model: 'gpt-5-mini',
        tools: available_functions,
        store: true  # Enable statefulness
      }

      # Build input message
      input_message = if message.is_a?(Array)
        message  # Already formatted (e.g., correction message)
      else
        [{
          type: 'message',
          role: 'user',
          content: message
        }]
      end

      # Use previous_response_id for chaining if available, otherwise use input
      if @previous_response_id
        request_params[:previous_response_id] = @previous_response_id
        request_params[:input] = input_message
      else
        # First message - include instructions (system prompt) and input
        request_params[:instructions] = system_prompt[:content]
        request_params[:input] = input_message
      end

      puts "[WorldBuilderAI] Calling Responses API with model: #{request_params[:model]}"
      puts "[WorldBuilderAI] Has previous_response_id: #{!@previous_response_id.nil?}"

      # Call Responses API with streaming
      response_content = ''
      function_calls = []
      final_response = nil

      stream = @client.responses.stream(request_params)
      puts "[WorldBuilderAI] Stream created successfully"

      stream.each do |event|
        puts "[WorldBuilderAI] Stream event: #{event.type}"

        case event.type
        when :'response.output_text.delta'
          # Streaming text chunk
          text = event.delta
          response_content += text if text
          broadcast_message_chunk(text) if text
        when :'response.function_call_arguments.delta'
          # Function call arguments streaming (collect but don't process yet)
          puts "[WorldBuilderAI] Function call arguments streaming..."
        when :'response.output_item.done'
          # Output item completed
          item = event.item
          puts "[WorldBuilderAI] Output item done: #{item.type.inspect}"
          if item.type == :function_call || item.type == 'function_call'
            puts "[WorldBuilderAI] Collected function call: #{item.name}"
            function_calls << item
          end
        when :'response.completed'
          # Response fully completed
          puts "[WorldBuilderAI] Response completed!"
          final_response = event.response
        when :error, :'response.failed'
          # Handle errors
          puts "[WorldBuilderAI] Stream error: #{event.inspect}"
          broadcast_error("AI Error: #{event.error&.message || 'Unknown error'}")
        else
          # Log other event types for debugging
          puts "[WorldBuilderAI] Unhandled event type: #{event.type}"
        end
      end

      puts "[WorldBuilderAI] Stream completed. Response content length: #{response_content.length}"
      puts "[WorldBuilderAI] Function calls collected: #{function_calls.length}"

      # Store response ID for future chaining
      if final_response && final_response.id
        @previous_response_id = final_response.id
        puts "[WorldBuilderAI] Stored response ID for chaining: #{@previous_response_id}"
      end

      broadcast_status(false)

      # Add assistant response to history
      if response_content && !response_content.empty?
        add_to_history('assistant', response_content)
        save_message('assistant', response_content)
        broadcast_message_complete
        puts "[WorldBuilderAI] Broadcasted message complete"
      else
        puts "[WorldBuilderAI] WARNING: No response content to broadcast"
      end

      # Handle function calls if any
      if function_calls && !function_calls.empty?
        puts "[WorldBuilderAI] Processing #{function_calls.length} function calls"
        # Pass the response_id so approval calls can use the correct response later
        process_function_calls(function_calls, @previous_response_id)
      else
        # GUARDRAIL: If no function calls were made on initial request, force correction
        if retry_count == 0
          puts "[WorldBuilderAI] GUARDRAIL: No function calls detected, forcing correction (retry #{retry_count + 1}/1)"

          # Send correction message forcing function use
          correction_message = [{
            type: 'message',
            role: 'user',
            content: "ERROR: You must use the available functions to handle requests. Do not write narrative descriptions or explanations - use function calls instead (create_location, create_npc, create_item, create_connection, update_*, find_location, etc.). Re-read my previous request and call the appropriate function(s)."
          }]

          # Wait briefly to avoid rate limits
          sleep 0.5

          # Retry once with correction (no context on retry)
          handle_user_message(user_id, correction_message, retry_count: retry_count + 1)
        else
          puts "[WorldBuilderAI] GUARDRAIL: Retry exhausted, allowing text-only response"
        end
      end

    rescue => e
      broadcast_status(false)
      error_msg = "AI Error: #{e.message}"
      broadcast_error(error_msg)
      puts "[WorldBuilderAI] EXCEPTION: #{e.class}: #{e.message}"
      puts "[WorldBuilderAI] Backtrace:\n#{e.backtrace.join("\n")}"
    end
  end

  def handle_approval_response(request_id, approved)
    return unless @pending_approvals[request_id]

    approval_data = @pending_approvals.delete(request_id)

    if approved
      # Execute the approved entities
      results = execute_entities(approval_data[:entities])

      # Broadcast results
      broadcast_execution_complete(results)

      # Build result message
      result_data = {
        approved: true,
        results: results
      }
      result_message = "Successfully created:\n"
      results.each do |r|
        if r[:success]
          result_message += "- #{r[:entity_type]}: #{r[:name] || r[:entity_id]}\n"
        else
          result_message += "- ERROR creating #{r[:entity_type]}: #{r[:error]}\n"
        end
      end

      # Save tool result
      save_message('tool', result_message,
                   tool_name: 'execute_approval',
                   tool_result: JSON.generate(results))

      # Let AI respond to the results (handle both single and multiple call_ids)
      add_to_history('tool', result_message)
      call_ids = approval_data[:call_ids] || [approval_data[:call_id]]
      # Use the stored response_id from when the function call was made
      continue_conversation_batch(call_ids, result_data, approval_data[:response_id])
    else
      # User rejected - let AI know
      rejection_data = { approved: false, rejected: true }
      rejection_message = "User rejected the proposed changes."
      save_message('tool', rejection_message,
                   tool_name: 'execute_approval',
                   tool_result: JSON.generate(rejection_data))

      add_to_history('tool', rejection_message)
      call_ids = approval_data[:call_ids] || [approval_data[:call_id]]
      # Use the stored response_id from when the function call was made
      continue_conversation_batch(call_ids, rejection_data, approval_data[:response_id])
    end
  end

  # Helper method to render ERB partials
  def render_partial(template, locals)
    template_path = File.join(File.dirname(__FILE__), '..', 'views', 'worlds', 'partials', "#{template}.erb")
    erb_content = File.read(template_path)
    erb = ERB.new(erb_content)

    # Create a binding with the locals
    binding_obj = binding
    locals.each do |key, value|
      binding_obj.local_variable_set(key, value)
    end

    erb.result(binding_obj)
  end

  # Helper method to broadcast DOM update messages
  def broadcast_dom_update(action, target, html, entity_type, entity_id, entity_data = nil)
    broadcast_to_builder_sockets({
      type: 'dom_update',
      action: action,
      target: target,
      html: html,
      entity_type: entity_type,
      entity_id: entity_id,
      entity_data: entity_data
    })
  end

  # Helper method to calculate location hierarchy level
  def calculate_location_level(location, all_locations)
    level = 0
    current = location

    while current && current.parent_location_id
      level += 1
      current = all_locations.find { |l| l.id == current.parent_location_id }
      break if level > 10  # Safety check for circular references
    end

    level
  end

  # Update stats counters via WebSocket
  def update_stats_counters
    stats = {
      locations: Location.where(world_id: @world_id).count,
      characters: Character.where(world_id: @world_id).count,
      items: Item.where(world_id: @world_id, character_id: nil, container_id: nil).count,
      containers: Container.where(world_id: @world_id).count,
      connections: Connection.where(world_id: @world_id).count,
      quests: Quest.where(world_id: @world_id).count
    }

    stats.each do |type, count|
      broadcast_dom_update('update_stats', "#stats-#{type}", count.to_s, type.to_s, nil)
    end
  end

  private

  # Deduplicate bidirectional connections within a batch
  def deduplicate_connections(entities)
    # Separate connections from other entities
    connections = entities.select { |e| e[:action] == 'create_connection' }
    other_entities = entities.reject { |e| e[:action] == 'create_connection' }

    return entities if connections.empty?

    # Track connections we've seen
    seen_pairs = {}
    deduplicated_connections = []

    connections.each do |conn|
      params = conn[:params]
      from_id = params[:from_location_id]
      to_id = params[:to_location_id]
      from_name = conn[:from_location_name]
      to_name = conn[:to_location_name]
      is_bidir = params[:is_bidirectional]

      # Create a normalized key (sorted pair) to identify the connection
      # Use IDs if available, otherwise use names
      if from_id && to_id
        pair_key = [from_id, to_id].sort.join('-')
      elsif from_name && to_name
        # Normalize names to lowercase for comparison
        pair_key = [from_name.downcase, to_name.downcase].sort.join('-')
      else
        # Can't determine pair, skip deduplication for this one
        deduplicated_connections << conn
        next
      end

      if seen_pairs[pair_key]
        # We've already seen a connection between these locations
        existing = seen_pairs[pair_key]

        # If either is bidirectional, upgrade to bidirectional and skip the duplicate
        if is_bidir || existing[:params][:is_bidirectional]
          puts "[WorldBuilderAI] Deduplicating: Upgrading connection between #{from_name || from_id}↔#{to_name || to_id} to bidirectional"
          existing[:params][:is_bidirectional] = true
          # Skip adding this duplicate
        else
          # Both are non-bidirectional in opposite directions
          # Keep the first one but mark it as bidirectional
          puts "[WorldBuilderAI] Deduplicating: Found opposite direction connections #{from_name || from_id}↔#{to_name || to_id}, converting to bidirectional"
          existing[:params][:is_bidirectional] = true
          # Skip adding this duplicate
        end
      else
        # First time seeing this connection pair
        seen_pairs[pair_key] = conn
        deduplicated_connections << conn
      end
    end

    # Return deduplicated connections + other entities
    other_entities + deduplicated_connections
  end

  # Conversational mode: User builds world piece-by-piece with AI assistance
  def system_prompt_conversational
    {
      role: 'system',
      content: <<~PROMPT
        You are a conversational RPG world builder assistant.
        You help users build fantasy/RPG worlds piece-by-piece by using tools provided by the system.

        CAPABILITIES:
        - Create locations (buildings, outdoor areas, dungeons, etc.)
        - Create NPCs with stats and personalities
        - Create items, containers, quests, and connections
        - Update any existing entity
        - Query the world state to understand what exists

        WORKFLOW:
        1. User requests something (e.g., "create a haunted mansion")
        2. Call query functions if needed to understand current world state
        3. Call creation/update functions to propose changes
        4. User reviews and approves/rejects in the UI
        5. Changes execute automatically if approved
        6. Confirm completion very briefly

        CRITICAL RULES:
        - Keep responses SHORT (1-3 sentences max)
        - ALWAYS use function calls - don't write descriptions in chat
        - Put vivid descriptions (2-3 sentences) in function parameters, not in your responses
        - When creating buildings/shops INSIDE a town, use parent_location_name
        - For "create a tavern", also create NPCs/items that logically belong there
        - Default hostile=false for NPCs unless context indicates danger

        IMPLICIT CONNECTIONS - VERY IMPORTANT:
        - Locations at the same level (siblings with same parent) are AUTOMATICALLY accessible to each other
        - Parent locations are AUTOMATICALLY accessible to their children (and vice versa)
        - Example: In town "Goodmead" with buildings "Blacksmith", "Tavern", "Bank":
          → These 3 buildings are automatically accessible from each other
          → The town square is automatically accessible from any building
          → NO explicit connections needed!
        - ONLY create explicit connections when:
          → The path is locked (requires key/item)
          → The path is hidden (secret door)
          → The path is one-way only (NOT bidirectional)
          → Special connection type (portal, teleporter, magical)
          → Different direction than default (e.g., special entrance)

        BIDIRECTIONAL CONNECTIONS - CRITICAL RULE:
        - When the user asks to "connect A and B", "link A to B", or similar, this means BIDIRECTIONAL
        - Use is_bidirectional=true parameter to create BOTH directions in ONE function call
        - NEVER call create_connection twice (once for each direction) - this creates duplicates!
        - ✅ CORRECT: create_connection(from_location: "A", to_location: "B", direction: "west", is_bidirectional: true)
        - ❌ WRONG: Two calls - create_connection(A→B) AND create_connection(B→A) - THIS IS DUPLICATE!
        - is_bidirectional=true automatically creates the reverse direction, so you only need ONE call

        UPDATE GUIDELINES:
        - For "change/update/modify/edit" requests, use update functions
        - Query first to confirm entity exists
        - Only specify fields being changed
        - Example: "Make John hostile" → update_npc(npc_name: "John", new_is_hostile: true)

        IMPORTANT: All creation/update functions require user approval. Query functions execute immediately.

        TONE: Helpful, creative, brief. Terminal-style formatting.
      PROMPT
    }
  end

  # Autonomous mode: AI generates complete world from single description (NOT IMPLEMENTED)
  def system_prompt_autonomous
    {
      role: 'system',
      content: <<~PROMPT
        You are an autonomous RPG world generator. Given a single description, you generate a complete, playable world.

        TASK:
        When user provides a theme/description, call generate_complete_world() to create:
        - 5-10 interconnected locations with logical connections
        - 3-5 NPCs distributed across locations
        - 5-10 items/treasure placed appropriately
        - At least one quest hook or interesting element
        - Coherent geography and internal logic

        STRUCTURE GUIDELINES:
        - Start with 1-2 central hub locations (town, village, camp)
        - Add 3-5 surrounding areas (forest, dungeon, cave, ruins)
        - Connect everything with bidirectional paths
        - Place NPCs where they make sense (shopkeeper in shop, guard at entrance)
        - Hide treasure in logical places
        - Create at least one "main quest" thread

        RULES:
        - Generate COMPLETE world in ONE function call
        - Use vivid descriptions (2-3 sentences per entity)
        - Ensure all locations are reachable
        - Default hostile=false unless dangerous area

        IMPORTANT: This mode generates everything at once without iterative approval.

        TONE: Creative, efficient, world-building focused.
      PROMPT
    }
  end

  # Use conversational mode by default (autonomous not implemented)
  def system_prompt
    system_prompt_conversational
  end

  def available_functions
    [
      # Query functions (execute immediately, no approval)
      {
        type: 'function',
        name: 'get_world_summary',
        description: 'Get an overview of the entire world including all locations, characters, items, and connections. Use this before creating new content to understand what already exists.',
        parameters: {
          type: 'object',
          properties: {},
          required: []
        }
      },
      {
        type: 'function',
        name: 'find_location',
        description: 'Find a location by name to get its ID and details',
        parameters: {
          type: 'object',
          properties: {
            name: {
              type: 'string',
              description: 'The name of the location to find'
            }
          },
          required: ['name']
        }
      },
      {
        type: 'function',
        name: 'list_locations',
        description: 'List all locations in the world',
        parameters: {
          type: 'object',
          properties: {},
          required: []
        }
      },
      {
        type: 'function',
        name: 'get_location_details',
        description: 'Get detailed information about a specific location including exits',
        parameters: {
          type: 'object',
          properties: {
            name: {
              type: 'string',
              description: 'The name of the location'
            }
          },
          required: ['name']
        }
      },
      # Creation functions (require approval)
      {
        type: 'function',
        name: 'create_location',
        description: 'Create a single location. This will show a preview to the user for approval.',
        parameters: {
          type: 'object',
          properties: {
            name: {
              type: 'string',
              description: 'The name of the location'
            },
            description: {
              type: 'string',
              description: 'A vivid 2-3 sentence description of the location'
            },
            location_type: {
              type: 'string',
              enum: ['indoor', 'outdoor', 'dungeon', 'cave', 'forest', 'town', 'building'],
              description: 'The type of location'
            },
            parent_location_name: {
              type: 'string',
              description: 'The name of the parent location (e.g., if creating a shop in a town, the town name). Leave empty for top-level locations.'
            }
          },
          required: ['name', 'description', 'location_type']
        }
      },
      {
        type: 'function',
        name: 'create_connection',
        description: 'Create an EXPLICIT connection between two locations. IMPORTANT: Only use this for SPECIAL cases (locked doors, hidden passages, one-way paths, portals). Sibling locations and parent-child locations are AUTOMATICALLY accessible - do NOT create connections for these! Use is_bidirectional=true to create both directions at once (never create two separate connections). This will show a preview to the user for approval.',
        parameters: {
          type: 'object',
          properties: {
            from_location: {
              type: 'string',
              description: 'The name of the starting location'
            },
            to_location: {
              type: 'string',
              description: 'The name of the destination location'
            },
            direction: {
              type: 'string',
              description: 'The direction (north, south, east, west, up, down, etc.)'
            },
            is_bidirectional: {
              type: 'boolean',
              description: 'Whether to create a reverse connection automatically (DO NOT create two separate connections - use this instead!)',
              default: false
            },
            description: {
              type: 'string',
              description: 'Optional description of the exit'
            },
            connection_type: {
              type: 'string',
              enum: ['passage', 'door', 'portal', 'teleporter', 'magical'],
              description: 'Type of connection (default: passage)',
              default: 'passage'
            },
            is_locked: {
              type: 'boolean',
              description: 'Whether this connection is locked',
              default: false
            },
            is_visible: {
              type: 'boolean',
              description: 'Whether this connection is visible (false for hidden/secret passages)',
              default: true
            }
          },
          required: ['from_location', 'to_location', 'direction']
        }
      },
      {
        type: 'function',
        name: 'create_npc',
        description: 'Create an NPC character. This will show a preview to the user for approval.',
        parameters: {
          type: 'object',
          properties: {
            name: {
              type: 'string',
              description: 'The name of the NPC'
            },
            description: {
              type: 'string',
              description: 'A vivid 2-3 sentence description of the NPC'
            },
            location_name: {
              type: 'string',
              description: 'The name of the location where this NPC starts'
            },
            max_hp: {
              type: 'integer',
              description: 'Maximum hit points (default 15 for friendly, 30 for hostile)',
              default: 15
            },
            strength: {
              type: 'integer',
              description: 'Strength stat (1-20, default 10)',
              default: 10
            },
            intelligence: {
              type: 'integer',
              description: 'Intelligence stat (1-20, default 10)',
              default: 10
            },
            charisma: {
              type: 'integer',
              description: 'Charisma stat (1-20, default 10)',
              default: 10
            },
            is_hostile: {
              type: 'boolean',
              description: 'Whether this NPC attacks players on sight',
              default: false
            },
            gold: {
              type: 'integer',
              description: 'Amount of gold coins this NPC carries',
              default: 0
            }
          },
          required: ['name', 'description', 'location_name']
        }
      },
      {
        type: 'function',
        name: 'create_item',
        description: 'Create an item. This will show a preview to the user for approval.',
        parameters: {
          type: 'object',
          properties: {
            name: {
              type: 'string',
              description: 'The name of the item'
            },
            description: {
              type: 'string',
              description: 'A description of the item'
            },
            location_name: {
              type: 'string',
              description: 'The name of the location where this item is placed'
            },
            item_type: {
              type: 'string',
              enum: ['misc', 'weapon', 'armor', 'potion', 'key', 'treasure', 'food'],
              description: 'The type of item',
              default: 'misc'
            },
            cost: {
              type: 'integer',
              description: 'The cost of the item in gold coins',
              default: 0
            }
          },
          required: ['name', 'description', 'location_name']
        }
      },
      {
        type: 'function',
        name: 'create_container',
        description: 'Create a container (chest, bag, etc.). This will show a preview to the user for approval.',
        parameters: {
          type: 'object',
          properties: {
            name: {
              type: 'string',
              description: 'The name of the container'
            },
            description: {
              type: 'string',
              description: 'A description of the container'
            },
            location_name: {
              type: 'string',
              description: 'The name of the location where this container is placed'
            },
            is_locked: {
              type: 'boolean',
              description: 'Whether the container is locked',
              default: false
            }
          },
          required: ['name', 'description', 'location_name']
        }
      },
      {
        type: 'function',
        name: 'generate_complete_world',
        description: 'Generate a complete world from a theme/description. Creates 5-10 locations, NPCs, items, and connections all at once. This will show a preview to the user for approval.',
        parameters: {
          type: 'object',
          properties: {
            theme: {
              type: 'string',
              description: 'The theme/genre (e.g., "medieval tavern", "haunted mansion", "space station")'
            },
            description: {
              type: 'string',
              description: 'Additional details about the world to create'
            }
          },
          required: ['theme']
        }
      },
      # Update functions (require approval)
      {
        type: 'function',
        name: 'update_location',
        description: 'Update an existing location. This will show a preview to the user for approval.',
        parameters: {
          type: 'object',
          properties: {
            location_name: {
              type: 'string',
              description: 'The current name of the location to update'
            },
            new_name: {
              type: 'string',
              description: 'The new name (optional, leave blank to keep current name)'
            },
            new_description: {
              type: 'string',
              description: 'The new description (optional, leave blank to keep current)'
            },
            new_location_type: {
              type: 'string',
              enum: ['indoor', 'outdoor', 'dungeon', 'cave', 'forest', 'town', 'building'],
              description: 'The new location type (optional, leave blank to keep current)'
            },
            new_parent_location_name: {
              type: 'string',
              description: 'The new parent location name (optional, use empty string to remove parent)'
            }
          },
          required: ['location_name']
        }
      },
      {
        type: 'function',
        name: 'update_connection',
        description: 'Update an existing connection between locations. This will show a preview to the user for approval.',
        parameters: {
          type: 'object',
          properties: {
            from_location: {
              type: 'string',
              description: 'The starting location of the connection to update'
            },
            direction: {
              type: 'string',
              description: 'The direction of the connection to update'
            },
            new_to_location: {
              type: 'string',
              description: 'The new destination location (optional)'
            },
            new_direction: {
              type: 'string',
              description: 'The new direction (optional)'
            },
            new_description: {
              type: 'string',
              description: 'The new description (optional)'
            },
            new_is_bidirectional: {
              type: 'boolean',
              description: 'Whether to make it bidirectional (optional)'
            }
          },
          required: ['from_location', 'direction']
        }
      },
      {
        type: 'function',
        name: 'update_npc',
        description: 'Update an existing NPC. This will show a preview to the user for approval.',
        parameters: {
          type: 'object',
          properties: {
            npc_name: {
              type: 'string',
              description: 'The current name of the NPC to update'
            },
            new_name: {
              type: 'string',
              description: 'The new name (optional)'
            },
            new_description: {
              type: 'string',
              description: 'The new description (optional)'
            },
            new_location_name: {
              type: 'string',
              description: 'The new location name (optional)'
            },
            new_max_hp: {
              type: 'integer',
              description: 'The new max HP (optional)'
            },
            new_strength: {
              type: 'integer',
              description: 'The new strength (optional)'
            },
            new_intelligence: {
              type: 'integer',
              description: 'The new intelligence (optional)'
            },
            new_charisma: {
              type: 'integer',
              description: 'The new charisma (optional)'
            },
            new_is_hostile: {
              type: 'boolean',
              description: 'Whether to make hostile/friendly (optional)'
            },
            new_gold: {
              type: 'integer',
              description: 'The new gold amount (optional)'
            }
          },
          required: ['npc_name']
        }
      },
      {
        type: 'function',
        name: 'update_item',
        description: 'Update an existing item. This will show a preview to the user for approval.',
        parameters: {
          type: 'object',
          properties: {
            item_name: {
              type: 'string',
              description: 'The current name of the item to update'
            },
            new_name: {
              type: 'string',
              description: 'The new name (optional)'
            },
            new_description: {
              type: 'string',
              description: 'The new description (optional)'
            },
            new_location_name: {
              type: 'string',
              description: 'The new location name (optional)'
            },
            new_item_type: {
              type: 'string',
              enum: ['misc', 'weapon', 'armor', 'potion', 'key', 'treasure', 'food'],
              description: 'The new item type (optional)'
            },
            new_cost: {
              type: 'integer',
              description: 'The new cost in gold coins (optional)'
            }
          },
          required: ['item_name']
        }
      },
      {
        type: 'function',
        name: 'update_container',
        description: 'Update an existing container. This will show a preview to the user for approval.',
        parameters: {
          type: 'object',
          properties: {
            container_name: {
              type: 'string',
              description: 'The current name of the container to update'
            },
            new_name: {
              type: 'string',
              description: 'The new name (optional)'
            },
            new_description: {
              type: 'string',
              description: 'The new description (optional)'
            },
            new_location_name: {
              type: 'string',
              description: 'The new location name (optional)'
            },
            new_is_locked: {
              type: 'boolean',
              description: 'Whether to lock/unlock (optional)'
            }
          },
          required: ['container_name']
        }
      },
      {
        type: 'function',
        name: 'create_quest',
        description: 'Create a quest with objectives. This will show a preview to the user for approval.',
        parameters: {
          type: 'object',
          properties: {
            name: {
              type: 'string',
              description: 'The name of the quest'
            },
            description: {
              type: 'string',
              description: 'A description of the quest objective and story'
            },
            quest_type: {
              type: 'string',
              enum: ['main', 'side', 'daily', 'achievement'],
              description: 'The type of quest',
              default: 'main'
            },
            status: {
              type: 'string',
              enum: ['active', 'completed', 'failed', 'hidden'],
              description: 'Initial status of the quest',
              default: 'active'
            },
            objectives: {
              type: 'array',
              description: 'List of quest objectives',
              items: {
                type: 'object',
                properties: {
                  description: {
                    type: 'string',
                    description: 'Description of what needs to be accomplished'
                  },
                  is_completed: {
                    type: 'boolean',
                    description: 'Whether this objective starts as completed',
                    default: false
                  }
                },
                required: ['description']
              }
            }
          },
          required: ['name', 'description']
        }
      },
      {
        type: 'function',
        name: 'update_quest',
        description: 'Update an existing quest. This will show a preview to the user for approval.',
        parameters: {
          type: 'object',
          properties: {
            quest_name: {
              type: 'string',
              description: 'The current name of the quest to update'
            },
            new_name: {
              type: 'string',
              description: 'The new name (optional)'
            },
            new_description: {
              type: 'string',
              description: 'The new description (optional)'
            },
            new_quest_type: {
              type: 'string',
              enum: ['main', 'side', 'daily', 'achievement'],
              description: 'The new quest type (optional)'
            },
            new_status: {
              type: 'string',
              enum: ['active', 'completed', 'failed', 'hidden'],
              description: 'The new status (optional)'
            },
            objectives: {
              type: 'array',
              description: 'Updated list of objectives (replaces existing)',
              items: {
                type: 'object',
                properties: {
                  description: {
                    type: 'string',
                    description: 'Description of the objective'
                  },
                  is_completed: {
                    type: 'boolean',
                    description: 'Whether this objective is completed',
                    default: false
                  }
                },
                required: ['description']
              }
            }
          },
          required: ['quest_name']
        }
      },
      {
        type: 'function',
        name: 'list_quests',
        description: 'List all quests in the world',
        parameters: {
          type: 'object',
          properties: {},
          required: []
        }
      }
    ]
  end

  def process_function_calls(function_calls, response_id)
    # First pass: execute all function calls and collect results
    results = []
    function_calls.each do |function_call|
      function_name = function_call.name
      function_args = function_call.arguments  # JSON string
      call_id = function_call.call_id

      puts "[WorldBuilderAI] Processing function: #{function_name}"
      puts "[WorldBuilderAI] Arguments: #{function_args[0..200]}"

      begin
        # Parse arguments from JSON string
        parsed_args = JSON.parse(function_args)

        # Execute the function
        result = send(function_name, **parsed_args.transform_keys(&:to_sym))

        results << {
          call_id: call_id,
          function_name: function_name,
          result: result
        }

      rescue JSON::ParserError => e
        error_result = { error: "Invalid JSON arguments: #{e.message}" }
        results << {
          call_id: call_id,
          function_name: function_name,
          result: error_result
        }
        puts "[WorldBuilderAI] JSON parse error: #{e.message}"
      rescue => e
        error_result = { error: e.message }
        results << {
          call_id: call_id,
          function_name: function_name,
          result: error_result
        }
        puts "[WorldBuilderAI] Function execution error: #{e.message}\n#{e.backtrace[0..5].join("\n")}"
      end
    end

    # Second pass: separate approval-requiring calls from query calls
    approval_calls = results.select { |r| r[:result].is_a?(Hash) && r[:result][:requires_approval] }
    query_calls = results.reject { |r| r[:result].is_a?(Hash) && r[:result][:requires_approval] }

    # Batch all approval-requiring entities into a single request
    if approval_calls.any?
      all_entities = []
      call_ids = []

      approval_calls.each do |call_data|
        all_entities.concat(call_data[:result][:entities])
        call_ids << call_data[:call_id]
      end

      # Deduplicate bidirectional connections within the same batch
      all_entities = deduplicate_connections(all_entities)

      request_id = SecureRandom.uuid
      @pending_approvals[request_id] = {
        call_ids: call_ids,  # Store array of call_ids
        entities: all_entities,
        response_id: response_id  # Store the response_id for later use
      }

      puts "[WorldBuilderAI] Sending batched approval request: #{request_id} (#{all_entities.length} entities from #{call_ids.length} function calls)"
      puts "[WorldBuilderAI] Stored response_id for approval: #{response_id}"
      broadcast_approval_request(request_id, all_entities)
    end

    # Process query calls immediately (batched together)
    if query_calls.any?
      query_calls.each do |call_data|
        result_str = JSON.generate(call_data[:result])
        save_message('tool', result_str, tool_name: call_data[:function_name], tool_result: result_str)
      end

      puts "[WorldBuilderAI] Continuing conversation with #{query_calls.length} query result(s)"
      continue_conversation_with_query_results(query_calls, response_id)
    end
  end

  def continue_conversation(call_id, function_result)
    # Call OpenAI again with the function result
    Thread.new do
      sleep 0.5  # Brief pause for UX

      begin
        response_content = ''
        function_calls = []
        final_response = nil

        # Build function_call_output item
        input_item = {
          type: 'function_call_output',
          call_id: call_id,
          output: JSON.generate(function_result)
        }

        # Call Responses API with previous response ID and function output
        stream = @client.responses.stream(
          model: 'gpt-5.2',
          previous_response_id: @previous_response_id,
          input: [input_item],
          tools: available_functions,
          store: true
        )

        stream.each do |event|
          case event.type
          when :'response.output_text.delta'
            # Streaming text chunk
            text = event.delta
            response_content += text if text
            broadcast_message_chunk(text) if text
          when :'response.function_call_arguments.delta'
            # Function call arguments streaming (collect but don't process yet)
          when :'response.output_item.done'
            # Output item completed
            item = event.item
            if item.type == :function_call || item.type == 'function_call'
              function_calls << item
            end
          when :'response.completed'
            # Response fully completed
            final_response = event.response
          when :error, :'response.failed'
            # Handle errors
            puts "[WorldBuilderAI] Stream error: #{event.inspect}"
            broadcast_error("AI Error: #{event.error&.message || 'Unknown error'}")
          end
        end

        # Store response ID for future chaining
        current_response_id = nil
        if final_response && final_response.id
          @previous_response_id = final_response.id
          current_response_id = final_response.id
        end

        # Add assistant response
        if response_content && !response_content.empty?
          add_to_history('assistant', response_content)
          save_message('assistant', response_content)
          broadcast_message_complete
        end

        # Handle any new function calls
        if function_calls && !function_calls.empty?
          process_function_calls(function_calls, current_response_id)
        end

      rescue => e
        broadcast_error("AI Error: #{e.message}")
        puts "[WorldBuilderAI] Error in continue_conversation: #{e.message}\n#{e.backtrace.join("\n")}"
      end
    end
  end

  def continue_conversation_with_query_results(query_calls, response_id)
    # Call OpenAI again with multiple query function results (each with their own result)
    Thread.new do
      sleep 0.5  # Brief pause for UX

      begin
        response_content = ''
        function_calls = []
        final_response = nil

        # Build function_call_output items for each query call (each has its own result)
        input_items = query_calls.map do |call_data|
          {
            type: 'function_call_output',
            call_id: call_data[:call_id],
            output: JSON.generate(call_data[:result])
          }
        end

        puts "[WorldBuilderAI] Batching #{query_calls.length} query results with response_id: #{response_id}"

        # Call Responses API with the response ID and all function outputs
        stream = @client.responses.stream(
          model: 'gpt-5-mini',
          previous_response_id: response_id,
          input: input_items,
          tools: available_functions,
          store: true
        )

        stream.each do |event|
          case event.type
          when :'response.output_text.delta'
            # Streaming text chunk
            text = event.delta
            response_content += text if text
            broadcast_message_chunk(text) if text
          when :'response.function_call_arguments.delta'
            # Function call arguments streaming (collect but don't process yet)
          when :'response.output_item.done'
            # Output item completed
            item = event.item
            if item.type == :function_call || item.type == 'function_call'
              function_calls << item
            end
          when :'response.completed'
            # Response fully completed
            final_response = event.response
          when :error, :'response.failed'
            # Handle errors
            puts "[WorldBuilderAI] Stream error: #{event.inspect}"
            broadcast_error("AI Error: #{event.error&.message || 'Unknown error'}")
          end
        end

        # Store response ID for future chaining
        current_response_id = nil
        if final_response && final_response.id
          @previous_response_id = final_response.id
          current_response_id = final_response.id
        end

        # Add assistant response
        if response_content && !response_content.empty?
          add_to_history('assistant', response_content)
          save_message('assistant', response_content)
          broadcast_message_complete
        end

        # Handle any new function calls
        if function_calls && !function_calls.empty?
          process_function_calls(function_calls, current_response_id)
        end

      rescue => e
        broadcast_error("AI Error: #{e.message}")
        puts "[WorldBuilderAI] Error in continue_conversation_with_query_results: #{e.message}\n#{e.backtrace.join("\n")}"
      end
    end
  end

  def continue_conversation_batch(call_ids, function_result, response_id)
    # Call OpenAI again with function results for multiple call_ids
    Thread.new do
      sleep 0.5  # Brief pause for UX

      begin
        response_content = ''
        function_calls = []
        final_response = nil

        # Build function_call_output items for each call_id
        input_items = call_ids.map do |call_id|
          {
            type: 'function_call_output',
            call_id: call_id,
            output: JSON.generate(function_result)
          }
        end

        puts "[WorldBuilderAI] Continuing conversation batch with response_id: #{response_id}"
        puts "[WorldBuilderAI] Call IDs: #{call_ids.inspect}"

        # Call Responses API with the stored response ID and all function outputs
        stream = @client.responses.stream(
          model: 'gpt-5-mini',
          previous_response_id: response_id,
          input: input_items,
          tools: available_functions,
          store: true
        )

        stream.each do |event|
          case event.type
          when :'response.output_text.delta'
            # Streaming text chunk
            text = event.delta
            response_content += text if text
            broadcast_message_chunk(text) if text
          when :'response.function_call_arguments.delta'
            # Function call arguments streaming (collect but don't process yet)
          when :'response.output_item.done'
            # Output item completed
            item = event.item
            if item.type == :function_call || item.type == 'function_call'
              function_calls << item
            end
          when :'response.completed'
            # Response fully completed
            final_response = event.response
          when :error, :'response.failed'
            # Handle errors
            puts "[WorldBuilderAI] Stream error: #{event.inspect}"
            broadcast_error("AI Error: #{event.error&.message || 'Unknown error'}")
          end
        end

        # Store response ID for future chaining
        current_response_id = nil
        if final_response && final_response.id
          @previous_response_id = final_response.id
          current_response_id = final_response.id
        end

        # Add assistant response
        if response_content && !response_content.empty?
          add_to_history('assistant', response_content)
          save_message('assistant', response_content)
          broadcast_message_complete
        end

        # Handle any new function calls
        if function_calls && !function_calls.empty?
          process_function_calls(function_calls, current_response_id)
        end

      rescue => e
        broadcast_error("AI Error: #{e.message}")
        puts "[WorldBuilderAI] Error in continue_conversation_batch: #{e.message}\n#{e.backtrace.join("\n")}"
      end
    end
  end

  # Query functions (execute immediately)

  # Helper method for fuzzy location lookup
  def fuzzy_find_location(name)
    # Try exact match first
    location = @db[:locations].where(world_id: @world_id, name: name).first
    return location if location

    # Try case-insensitive match
    location = @db[:locations].where(world_id: @world_id)
      .where(Sequel.function(:lower, :name) => name.downcase).first
    return location if location

    # Try partial match (contains)
    all_locations = @db[:locations].where(world_id: @world_id).all
    all_locations.find { |l| l[:name].downcase.include?(name.downcase) || name.downcase.include?(l[:name].downcase) }
  end

  def fuzzy_find_quest(name)
    # Try exact match first
    quest = @db[:quests].where(world_id: @world_id, name: name).first
    return quest if quest

    # Try case-insensitive match
    quest = @db[:quests].where(world_id: @world_id)
      .where(Sequel.function(:lower, :name) => name.downcase).first
    return quest if quest

    # Try partial match (contains)
    all_quests = @db[:quests].where(world_id: @world_id).all
    all_quests.find { |q| q[:name].downcase.include?(name.downcase) || name.downcase.include?(q[:name].downcase) }
  end

  def get_world_summary
    world = @db[:worlds].where(id: @world_id).first
    locations = @db[:locations].where(world_id: @world_id).all
    characters = @db[:characters].where(world_id: @world_id, character_type: 'npc').all
    items = @db[:items].where(world_id: @world_id).all
    containers = @db[:containers].where(world_id: @world_id).all
    connections = @db[:connections].where(world_id: @world_id).all

    {
      world_name: world[:name],
      world_description: world[:description],
      location_count: locations.size,
      locations: locations.map { |l| { id: l[:id], name: l[:name], type: l[:location_type] } },
      character_count: characters.size,
      characters: characters.map { |c| { id: c[:id], name: c[:name], location_id: c[:location_id], is_hostile: c[:is_hostile] } },
      item_count: items.size,
      items: items.map { |i| { id: i[:id], name: i[:name], location_id: i[:location_id], type: i[:item_type] } },
      container_count: containers.size,
      connection_count: connections.size
    }
  end

  def find_location(name:)
    location = fuzzy_find_location(name)

    if location
      { found: true, id: location[:id], name: location[:name], type: location[:location_type] }
    else
      # List similar names to help
      all_names = @db[:locations].where(world_id: @world_id).select(:name).map { |l| l[:name] }
      { found: false, message: "Location '#{name}' not found. Available locations: #{all_names.join(', ')}" }
    end
  end

  def list_locations
    locations = @db[:locations].where(world_id: @world_id).all
    {
      count: locations.size,
      locations: locations.map { |l| { id: l[:id], name: l[:name], type: l[:location_type], description: l[:description] } }
    }
  end

  def get_location_details(name:)
    location = fuzzy_find_location(name)
    return { error: "Location '#{name}' not found. Use list_locations to see all locations." } unless location

    result = @game_engine.describe_location(location[:id])
    result
  end

  # Creation functions (require approval)

  def create_location(name:, description:, location_type:, parent_location_name: nil)
    # Look up parent location if specified
    parent_location_id = nil
    parent_info = ""

    # Store parent_location_name for deferred resolution during execution
    # This allows hierarchical creation where parent doesn't exist yet
    if parent_location_name && !parent_location_name.empty?
      parent_loc = fuzzy_find_location(parent_location_name)
      if parent_loc
        # Parent exists now - use its ID
        parent_location_id = parent_loc[:id]
        parent_info = "\nParent: #{parent_loc[:name]}"
      else
        # Parent doesn't exist yet - defer resolution until execution
        parent_info = "\nParent: #{parent_location_name} (will be resolved)"
      end
    end

    {
      requires_approval: true,
      entities: [
        {
          action: 'create_location',
          entity_type: 'location',
          params: {
            world_id: @world_id,
            name: name,
            description: description,
            location_type: location_type,
            parent_location_id: parent_location_id
          },
          # Store parent name for deferred resolution
          parent_location_name: parent_location_name,
          preview: "📍 Location: #{name}\nType: #{location_type}#{parent_info}\nDescription: #{description[0..150]}#{description.length > 150 ? '...' : ''}"
        }
      ]
    }
  end

  def create_connection(from_location:, to_location:, direction:, is_bidirectional: false, description: nil, connection_type: 'passage', is_locked: false, is_visible: true)
    # Find location IDs using fuzzy matching (defer if not found)
    from_loc = fuzzy_find_location(from_location)
    to_loc = fuzzy_find_location(to_location)

    from_location_id = from_loc ? from_loc[:id] : nil
    to_location_id = to_loc ? to_loc[:id] : nil

    # Build preview text
    special_attrs = []
    special_attrs << "Type: #{connection_type}" if connection_type != 'passage'
    special_attrs << "🔒 LOCKED" if is_locked
    special_attrs << "👁 HIDDEN" if !is_visible
    special_text = special_attrs.any? ? " | " + special_attrs.join(', ') : ''

    {
      requires_approval: true,
      entities: [
        {
          action: 'create_connection',
          entity_type: 'connection',
          params: {
            world_id: @world_id,
            from_location_id: from_location_id,
            to_location_id: to_location_id,
            direction: direction,
            is_bidirectional: is_bidirectional,
            description: description,
            connection_type: connection_type,
            is_locked: is_locked,
            is_visible: is_visible
          },
          # Store location names for deferred resolution
          from_location_name: from_location,
          to_location_name: to_location,
          preview: "🔗 Connection: #{from_location} → [#{direction}] → #{to_location}#{is_bidirectional ? ' (bidirectional)' : ''}#{special_text}"
        }
      ]
    }
  end

  def create_npc(name:, description:, location_name:, max_hp: 15, strength: 10, intelligence: 10, charisma: 10, is_hostile: false, gold: 0)
    # Find location ID using fuzzy matching (defer if not found)
    location = fuzzy_find_location(location_name)
    location_id = location ? location[:id] : nil

    {
      requires_approval: true,
      entities: [
        {
          action: 'create_npc',
          entity_type: 'character',
          params: {
            world_id: @world_id,
            location_id: location_id,
            name: name,
            description: description,
            max_hp: max_hp,
            strength: strength,
            intelligence: intelligence,
            charisma: charisma,
            is_hostile: is_hostile,
            gold: gold
          },
          # Store location name for deferred resolution
          location_name: location_name,
          preview: "🧙 NPC: #{name}\nLocation: #{location_name}\nStats: HP #{max_hp}, STR #{strength}, INT #{intelligence}, CHA #{charisma}\nGold: #{gold}\n#{is_hostile ? '⚔️ HOSTILE' : '😊 Friendly'}\nDescription: #{description[0..100]}#{description.length > 100 ? '...' : ''}"
        }
      ]
    }
  end

  def create_item(name:, description:, location_name:, item_type: 'misc', cost: 0)
    # Find location ID using fuzzy matching (defer if not found)
    location = fuzzy_find_location(location_name)
    location_id = location ? location[:id] : nil

    {
      requires_approval: true,
      entities: [
        {
          action: 'create_item',
          entity_type: 'item',
          params: {
            world_id: @world_id,
            location_id: location_id,
            name: name,
            description: description,
            item_type: item_type,
            cost: cost
          },
          # Store location name for deferred resolution
          location_name: location_name,
          preview: "💎 Item: #{name}\nType: #{item_type}\nLocation: #{location_name}\nCost: #{cost} gold\nDescription: #{description[0..100]}#{description.length > 100 ? '...' : ''}"
        }
      ]
    }
  end

  def create_container(name:, description:, location_name:, is_locked: false)
    # Find location ID using fuzzy matching (defer if not found)
    location = fuzzy_find_location(location_name)
    location_id = location ? location[:id] : nil

    {
      requires_approval: true,
      entities: [
        {
          action: 'create_container',
          entity_type: 'container',
          params: {
            world_id: @world_id,
            location_id: location_id,
            name: name,
            description: description,
            is_locked: is_locked
          },
          # Store location name for deferred resolution
          location_name: location_name,
          preview: "📦 Container: #{name}\nLocation: #{location_name}\n#{is_locked ? '🔒 Locked' : '🔓 Unlocked'}\nDescription: #{description[0..100]}#{description.length > 100 ? '...' : ''}"
        }
      ]
    }
  end

  def generate_complete_world(theme:, description: '')
    # This is a meta-function that orchestrates multiple creation calls
    # The AI will call this, then we return all the entities to create at once

    # For now, return a simple structure that tells the AI to break it down
    # In a full implementation, this could use a second AI call to generate the full world
    {
      error: "Please create the world piece by piece using create_location, create_npc, create_item, and create_connection functions. Start with 5-10 locations, then add connections, NPCs, and items."
    }
  end

  # Quest functions

  def list_quests
    quests = @db[:quests].where(world_id: @world_id).order(:name).all
    quest_list = quests.map do |quest|
      objectives = @db[:quest_objectives].where(quest_id: quest[:id]).all
      {
        id: quest[:id],
        name: quest[:name],
        description: quest[:description],
        quest_type: quest[:quest_type],
        status: quest[:status],
        objectives_count: objectives.count
      }
    end

    {
      quests: quest_list,
      count: quest_list.length,
      summary: "Found #{quest_list.length} quest(s) in the world."
    }
  end

  def create_quest(name:, description:, quest_type: 'main', status: 'active', objectives: [])
    {
      requires_approval: true,
      entities: [
        {
          action: 'create_quest',
          entity_type: 'quest',
          params: {
            world_id: @world_id,
            room_id: nil,
            name: name,
            description: description,
            quest_type: quest_type,
            status: status,
            objectives: objectives
          },
          preview: "⚔️ Quest: #{name}\nType: #{quest_type} | Status: #{status}\nObjectives: #{objectives.length}\nDescription: #{description[0..100]}#{description.length > 100 ? '...' : ''}"
        }
      ]
    }
  end

  def update_quest(quest_name:, new_name: nil, new_description: nil, new_quest_type: nil, new_status: nil, objectives: nil)
    # Find the existing quest using fuzzy matching
    quest = fuzzy_find_quest(quest_name)
    unless quest
      all_names = @db[:quests].where(world_id: @world_id).select(:name).map { |q| q[:name] }
      return { error: "Quest '#{quest_name}' not found. Available quests: #{all_names.join(', ')}" }
    end

    # Build update params
    update_params = {}
    update_params[:name] = new_name if new_name && !new_name.empty?
    update_params[:description] = new_description if new_description && !new_description.empty?
    update_params[:quest_type] = new_quest_type if new_quest_type && !new_quest_type.empty?
    update_params[:status] = new_status if new_status && !new_status.empty?
    update_params[:objectives] = objectives if objectives

    return { error: "No changes specified" } if update_params.empty?

    # Build preview
    preview_parts = ["⚔️ Updating Quest: #{quest_name}"]
    preview_parts << "New name: #{new_name}" if new_name && !new_name.empty?
    preview_parts << "New type: #{new_quest_type}" if new_quest_type && !new_quest_type.empty?
    preview_parts << "New status: #{new_status}" if new_status && !new_status.empty?
    preview_parts << "New description: #{new_description[0..100]}..." if new_description && !new_description.empty?
    preview_parts << "Objectives: #{objectives.length}" if objectives

    {
      requires_approval: true,
      entities: [
        {
          action: 'update_quest',
          entity_type: 'quest',
          entity_id: quest[:id],
          params: update_params,
          preview: preview_parts.join("\n")
        }
      ]
    }
  end

  # Update functions (require approval)

  def update_location(location_name:, new_name: nil, new_description: nil, new_location_type: nil, new_parent_location_name: nil)
    # Find the existing location using fuzzy matching
    location = fuzzy_find_location(location_name)
    unless location
      all_names = @db[:locations].where(world_id: @world_id).select(:name).map { |l| l[:name] }
      return { error: "Location '#{location_name}' not found. Available locations: #{all_names.join(', ')}" }
    end

    # Build update params
    update_params = {}
    update_params[:name] = new_name if new_name && !new_name.empty?
    update_params[:description] = new_description if new_description && !new_description.empty?
    update_params[:location_type] = new_location_type if new_location_type && !new_location_type.empty?

    # Handle parent location with fuzzy matching
    if new_parent_location_name
      if new_parent_location_name.empty?
        update_params[:parent_location_id] = nil
      else
        parent_loc = fuzzy_find_location(new_parent_location_name)
        if parent_loc
          update_params[:parent_location_id] = parent_loc[:id]
        else
          all_names = @db[:locations].where(world_id: @world_id).select(:name).map { |l| l[:name] }
          return { error: "Parent location '#{new_parent_location_name}' not found. Available locations: #{all_names.join(', ')}" }
        end
      end
    end

    return { error: "No changes specified" } if update_params.empty?

    # Build preview
    preview_parts = ["📍 Updating Location: #{location_name}"]
    preview_parts << "New name: #{new_name}" if new_name && !new_name.empty?
    preview_parts << "New type: #{new_location_type}" if new_location_type && !new_location_type.empty?
    preview_parts << "New description: #{new_description[0..100]}..." if new_description && !new_description.empty?
    if new_parent_location_name
      preview_parts << (new_parent_location_name.empty? ? "Remove parent" : "New parent: #{new_parent_location_name}")
    end

    {
      requires_approval: true,
      entities: [
        {
          action: 'update_location',
          entity_type: 'location',
          entity_id: location[:id],
          params: update_params,
          preview: preview_parts.join("\n")
        }
      ]
    }
  end

  def update_connection(from_location:, direction:, new_to_location: nil, new_direction: nil, new_description: nil, new_is_bidirectional: nil)
    # Find from location using fuzzy matching
    from_loc = fuzzy_find_location(from_location)
    unless from_loc
      all_names = @db[:locations].where(world_id: @world_id).select(:name).map { |l| l[:name] }
      return { error: "Location '#{from_location}' not found. Available locations: #{all_names.join(', ')}" }
    end

    # Find the existing connection
    connection = @db[:connections].where(world_id: @world_id, from_location_id: from_loc[:id], direction: direction).first
    unless connection
      return { error: "Connection from '#{from_location}' going '#{direction}' not found." }
    end

    # Build update params
    update_params = {}

    if new_to_location && !new_to_location.empty?
      to_loc = fuzzy_find_location(new_to_location)
      unless to_loc
        all_names = @db[:locations].where(world_id: @world_id).select(:name).map { |l| l[:name] }
        return { error: "Destination location '#{new_to_location}' not found. Available locations: #{all_names.join(', ')}" }
      end
      update_params[:to_location_id] = to_loc[:id]
    end

    update_params[:direction] = new_direction if new_direction && !new_direction.empty?
    update_params[:description] = new_description if new_description && !new_description.empty?
    update_params[:is_bidirectional] = new_is_bidirectional unless new_is_bidirectional.nil?

    return { error: "No changes specified" } if update_params.empty?

    # Build preview
    preview_parts = ["🔗 Updating Connection: #{from_location} → [#{direction}]"]
    preview_parts << "New destination: #{new_to_location}" if new_to_location && !new_to_location.empty?
    preview_parts << "New direction: #{new_direction}" if new_direction && !new_direction.empty?
    preview_parts << "New description: #{new_description}" if new_description && !new_description.empty?
    preview_parts << "Bidirectional: #{new_is_bidirectional}" unless new_is_bidirectional.nil?

    {
      requires_approval: true,
      entities: [
        {
          action: 'update_connection',
          entity_type: 'connection',
          entity_id: connection[:id],
          params: update_params,
          preview: preview_parts.join("\n")
        }
      ]
    }
  end

  def update_npc(npc_name:, new_name: nil, new_description: nil, new_location_name: nil, new_max_hp: nil, new_strength: nil, new_intelligence: nil, new_charisma: nil, new_is_hostile: nil, new_gold: nil)
    # Find the existing NPC
    npc = @db[:characters].where(world_id: @world_id, name: npc_name, character_type: 'npc').first
    unless npc
      return { error: "NPC '#{npc_name}' not found." }
    end

    # Build update params
    update_params = {}
    update_params[:name] = new_name if new_name && !new_name.empty?
    update_params[:description] = new_description if new_description && !new_description.empty?
    update_params[:max_hp] = new_max_hp if new_max_hp
    update_params[:strength] = new_strength if new_strength
    update_params[:intelligence] = new_intelligence if new_intelligence
    update_params[:charisma] = new_charisma if new_charisma
    update_params[:is_hostile] = new_is_hostile unless new_is_hostile.nil?
    update_params[:gold] = new_gold if new_gold

    if new_location_name && !new_location_name.empty?
      location = fuzzy_find_location(new_location_name)
      unless location
        all_names = @db[:locations].where(world_id: @world_id).select(:name).map { |l| l[:name] }
        return { error: "Location '#{new_location_name}' not found. Available locations: #{all_names.join(', ')}" }
      end
      update_params[:location_id] = location[:id]
    end

    return { error: "No changes specified" } if update_params.empty?

    # Build preview
    preview_parts = ["🧙 Updating NPC: #{npc_name}"]
    preview_parts << "New name: #{new_name}" if new_name && !new_name.empty?
    preview_parts << "New location: #{new_location_name}" if new_location_name && !new_location_name.empty?
    preview_parts << "New description: #{new_description[0..80]}..." if new_description && !new_description.empty?
    stats_changes = []
    stats_changes << "HP: #{new_max_hp}" if new_max_hp
    stats_changes << "STR: #{new_strength}" if new_strength
    stats_changes << "INT: #{new_intelligence}" if new_intelligence
    stats_changes << "CHA: #{new_charisma}" if new_charisma
    preview_parts << "New stats: #{stats_changes.join(', ')}" if stats_changes.any?
    preview_parts << "New gold: #{new_gold}" if new_gold
    preview_parts << "#{new_is_hostile ? '⚔️ HOSTILE' : '😊 Friendly'}" unless new_is_hostile.nil?

    {
      requires_approval: true,
      entities: [
        {
          action: 'update_npc',
          entity_type: 'character',
          entity_id: npc[:id],
          params: update_params,
          preview: preview_parts.join("\n")
        }
      ]
    }
  end

  def update_item(item_name:, new_name: nil, new_description: nil, new_location_name: nil, new_item_type: nil, new_cost: nil)
    # Find the existing item
    item = @db[:items].where(world_id: @world_id, name: item_name).first
    unless item
      return { error: "Item '#{item_name}' not found." }
    end

    # Build update params
    update_params = {}
    update_params[:name] = new_name if new_name && !new_name.empty?
    update_params[:description] = new_description if new_description && !new_description.empty?
    update_params[:item_type] = new_item_type if new_item_type && !new_item_type.empty?
    update_params[:cost] = new_cost if new_cost

    if new_location_name && !new_location_name.empty?
      location = fuzzy_find_location(new_location_name)
      unless location
        all_names = @db[:locations].where(world_id: @world_id).select(:name).map { |l| l[:name] }
        return { error: "Location '#{new_location_name}' not found. Available locations: #{all_names.join(', ')}" }
      end
      update_params[:location_id] = location[:id]
    end

    return { error: "No changes specified" } if update_params.empty?

    # Build preview
    preview_parts = ["💎 Updating Item: #{item_name}"]
    preview_parts << "New name: #{new_name}" if new_name && !new_name.empty?
    preview_parts << "New type: #{new_item_type}" if new_item_type && !new_item_type.empty?
    preview_parts << "New location: #{new_location_name}" if new_location_name && !new_location_name.empty?
    preview_parts << "New cost: #{new_cost} gold" if new_cost
    preview_parts << "New description: #{new_description[0..80]}..." if new_description && !new_description.empty?

    {
      requires_approval: true,
      entities: [
        {
          action: 'update_item',
          entity_type: 'item',
          entity_id: item[:id],
          params: update_params,
          preview: preview_parts.join("\n")
        }
      ]
    }
  end

  def update_container(container_name:, new_name: nil, new_description: nil, new_location_name: nil, new_is_locked: nil)
    # Find the existing container
    container = @db[:containers].where(world_id: @world_id, name: container_name).first
    unless container
      return { error: "Container '#{container_name}' not found." }
    end

    # Build update params
    update_params = {}
    update_params[:name] = new_name if new_name && !new_name.empty?
    update_params[:description] = new_description if new_description && !new_description.empty?
    update_params[:is_locked] = new_is_locked unless new_is_locked.nil?

    if new_location_name && !new_location_name.empty?
      location = fuzzy_find_location(new_location_name)
      unless location
        all_names = @db[:locations].where(world_id: @world_id).select(:name).map { |l| l[:name] }
        return { error: "Location '#{new_location_name}' not found. Available locations: #{all_names.join(', ')}" }
      end
      update_params[:location_id] = location[:id]
    end

    return { error: "No changes specified" } if update_params.empty?

    # Build preview
    preview_parts = ["📦 Updating Container: #{container_name}"]
    preview_parts << "New name: #{new_name}" if new_name && !new_name.empty?
    preview_parts << "New location: #{new_location_name}" if new_location_name && !new_location_name.empty?
    preview_parts << "#{new_is_locked ? '🔒 Locked' : '🔓 Unlocked'}" unless new_is_locked.nil?
    preview_parts << "New description: #{new_description[0..80]}..." if new_description && !new_description.empty?

    {
      requires_approval: true,
      entities: [
        {
          action: 'update_container',
          entity_type: 'container',
          entity_id: container[:id],
          params: update_params,
          preview: preview_parts.join("\n")
        }
      ]
    }
  end

  # Execution logic

  def sort_entities_by_dependency(entities)
    # Sort entities to ensure parents are created before children
    # Order of execution:
    # 1. Top-level locations (no parent)
    # 2. Child locations (have parent)
    # 3. Connections (depend on locations)
    # 4. Quests (independent)
    # 5. NPCs, items, containers (depend on locations)
    # 6. Update actions (modify existing entities)

    sorted = []

    # Phase 1: Top-level locations (no parent_location_id)
    sorted += entities.select do |e|
      e[:action] == 'create_location' &&
      (!e[:params][:parent_location_id] || e[:params][:parent_location_id].nil?)
    end

    # Phase 2: Child locations (have parent_location_id)
    sorted += entities.select do |e|
      e[:action] == 'create_location' &&
      e[:params][:parent_location_id] &&
      !e[:params][:parent_location_id].nil?
    end

    # Phase 3: Connections (need locations to exist)
    sorted += entities.select { |e| e[:action] == 'create_connection' }

    # Phase 4: Quests (independent)
    sorted += entities.select { |e| e[:action] == 'create_quest' }

    # Phase 5: NPCs, items, containers (need locations to exist)
    sorted += entities.select do |e|
      ['create_npc', 'create_item', 'create_container'].include?(e[:action])
    end

    # Phase 6: Update actions (modify existing entities, should be last)
    sorted += entities.select do |e|
      e[:action].to_s.start_with?('update_')
    end

    # Return sorted entities (should be same count as input)
    puts "[WorldBuilderAI] Sorted #{sorted.length} entities by dependency (original: #{entities.length})"
    sorted
  end

  def execute_entities(entities)
    results = []

    # Sort entities by dependency before executing
    sorted_entities = sort_entities_by_dependency(entities)

    sorted_entities.each do |entity|
      begin
        case entity[:action]
        when 'create_location'
          # Resolve parent_location_name if it wasn't resolved during function call
          params = entity[:params].dup
          if entity[:parent_location_name] && !entity[:parent_location_name].empty? && !params[:parent_location_id]
            parent_loc = fuzzy_find_location(entity[:parent_location_name])
            if parent_loc
              params[:parent_location_id] = parent_loc[:id]
              puts "[WorldBuilderAI] Resolved parent '#{entity[:parent_location_name]}' to ID #{parent_loc[:id]}"
            else
              # Parent still not found - this is an error
              results << {
                success: false,
                entity_type: 'location',
                name: entity[:params][:name],
                error: "Parent location '#{entity[:parent_location_name]}' not found"
              }
              next
            end
          end

          result = @game_engine.create_location(**params)
          results << {
            success: result[:success],
            entity_type: 'location',
            entity_id: result[:location_id],
            name: entity[:params][:name],
            error: result[:error]
          }

        when 'create_connection'
          # Resolve location names if IDs weren't resolved during function call
          params = entity[:params].dup

          if entity[:from_location_name] && !params[:from_location_id]
            from_loc = fuzzy_find_location(entity[:from_location_name])
            if from_loc
              params[:from_location_id] = from_loc[:id]
            else
              results << {
                success: false,
                entity_type: 'connection',
                error: "From location '#{entity[:from_location_name]}' not found"
              }
              next
            end
          end

          if entity[:to_location_name] && !params[:to_location_id]
            to_loc = fuzzy_find_location(entity[:to_location_name])
            if to_loc
              params[:to_location_id] = to_loc[:id]
            else
              results << {
                success: false,
                entity_type: 'connection',
                error: "To location '#{entity[:to_location_name]}' not found"
              }
              next
            end
          end

          attributes = params.slice(:direction, :description, :is_bidirectional, :connection_type,
                                   :reverse_description, :is_visible, :is_locked, :is_open)
          result = @game_engine.create_connection(
            params[:world_id],
            params[:from_location_id],
            params[:to_location_id],
            attributes
          )
          results << {
            success: result[:success],
            entity_type: 'connection',
            entity_id: result[:connection_id],
            error: result[:error]
          }

        when 'create_npc'
          # Resolve location name if ID wasn't resolved during function call
          params = entity[:params].dup

          if entity[:location_name] && !params[:location_id]
            location = fuzzy_find_location(entity[:location_name])
            if location
              params[:location_id] = location[:id]
            else
              results << {
                success: false,
                entity_type: 'character',
                name: entity[:params][:name],
                error: "Location '#{entity[:location_name]}' not found"
              }
              next
            end
          end

          result = @game_engine.create_npc(**params)
          results << {
            success: result[:success],
            entity_type: 'character',
            entity_id: result[:character_id],
            name: entity[:params][:name],
            error: result[:error]
          }

        when 'create_item'
          # Resolve location name if ID wasn't resolved during function call
          params = entity[:params].dup

          if entity[:location_name] && !params[:location_id]
            location = fuzzy_find_location(entity[:location_name])
            if location
              params[:location_id] = location[:id]
            else
              results << {
                success: false,
                entity_type: 'item',
                name: entity[:params][:name],
                error: "Location '#{entity[:location_name]}' not found"
              }
              next
            end
          end

          result = @game_engine.create_item(@world_id, params.reject { |k| k == :world_id })
          results << {
            success: result[:success],
            entity_type: 'item',
            entity_id: result[:item_id],
            name: entity[:params][:name],
            error: result[:error]
          }

        when 'create_container'
          # Resolve location name if ID wasn't resolved during function call
          params = entity[:params].dup

          if entity[:location_name] && !params[:location_id]
            location = fuzzy_find_location(entity[:location_name])
            if location
              params[:location_id] = location[:id]
            else
              results << {
                success: false,
                entity_type: 'container',
                name: entity[:params][:name],
                error: "Location '#{entity[:location_name]}' not found"
              }
              next
            end
          end

          result = @game_engine.create_container(**params)
          results << {
            success: result[:success],
            entity_type: 'container',
            entity_id: result[:container_id],
            name: entity[:params][:name],
            error: result[:error]
          }

        # Update actions
        when 'update_location'
          location = Location[entity[:entity_id]]
          if location
            location.update(entity[:params])
            results << {
              success: true,
              entity_type: 'location',
              entity_id: entity[:entity_id],
              name: entity[:params][:name] || location[:name]
            }
          else
            results << {
              success: false,
              entity_type: 'location',
              error: 'Location not found'
            }
          end

        when 'update_connection'
          connection = Connection[entity[:entity_id]]
          if connection
            connection.update(entity[:params])
            results << {
              success: true,
              entity_type: 'connection',
              entity_id: entity[:entity_id]
            }
          else
            results << {
              success: false,
              entity_type: 'connection',
              error: 'Connection not found'
            }
          end

        when 'update_npc'
          npc = Character[entity[:entity_id]]
          if npc
            npc.update(entity[:params])
            results << {
              success: true,
              entity_type: 'character',
              entity_id: entity[:entity_id],
              name: entity[:params][:name] || npc[:name]
            }
          else
            results << {
              success: false,
              entity_type: 'character',
              error: 'NPC not found'
            }
          end

        when 'update_item'
          item = Item[entity[:entity_id]]
          if item
            item.update(entity[:params])
            results << {
              success: true,
              entity_type: 'item',
              entity_id: entity[:entity_id],
              name: entity[:params][:name] || item[:name]
            }
          else
            results << {
              success: false,
              entity_type: 'item',
              error: 'Item not found'
            }
          end

        when 'update_container'
          container = Container[entity[:entity_id]]
          if container
            container.update(entity[:params])
            results << {
              success: true,
              entity_type: 'container',
              entity_id: entity[:entity_id],
              name: entity[:params][:name] || container[:name]
            }
          else
            results << {
              success: false,
              entity_type: 'container',
              error: 'Container not found'
            }
          end

        when 'update_quest'
          quest = Quest[entity[:entity_id]]
          if quest
            # Handle objectives separately if provided
            objectives_data = entity[:params].delete(:objectives)

            # Update quest basic fields
            quest.update(entity[:params]) unless entity[:params].empty?

            # Handle objectives update if provided
            if objectives_data
              # This follows the same pattern as app.rb update route
              existing_objective_ids = []
              objectives_data.each do |obj_data|
                if obj_data['id'] && !obj_data['id'].to_s.empty?
                  # Update existing objective
                  objective = QuestObjective[obj_data['id'].to_i]
                  if objective && objective.quest_id == quest.id
                    objective.update(
                      description: obj_data['description'],
                      is_completed: obj_data['is_completed'] || false
                    )
                    existing_objective_ids << objective.id
                  end
                else
                  # Create new objective
                  new_obj = QuestObjective.create(
                    quest_id: quest.id,
                    description: obj_data['description'],
                    is_completed: obj_data['is_completed'] || false,
                    display_order: 0
                  )
                  existing_objective_ids << new_obj.id
                end
              end

              # Delete objectives that were removed
              quest.quest_objectives.each do |objective|
                unless existing_objective_ids.include?(objective.id)
                  objective.destroy
                end
              end
            end

            results << {
              success: true,
              entity_type: 'quest',
              entity_id: entity[:entity_id],
              name: entity[:params][:name] || quest[:name]
            }
          else
            results << {
              success: false,
              entity_type: 'quest',
              error: 'Quest not found'
            }
          end
        end
      rescue => e
        results << {
          success: false,
          entity_type: entity[:entity_type],
          error: e.message
        }
      end
    end

    results
  end

  # Conversation management

  def load_conversation
    messages = @db[:world_builder_conversations]
      .where(world_id: @world_id)
      .order(:created_at)
      .all

    if messages.empty?
      @conversation_history = [system_prompt]
      save_message('system', system_prompt[:content])
    else
      @conversation_history = messages.map do |msg|
        hash = { role: msg[:role] }

        if msg[:content] && !msg[:content].empty?
          hash[:content] = msg[:content]
        end

        if msg[:tool_name]
          hash[:tool_call_id] = msg[:tool_name]  # Simplified for storage
        end

        hash
      end
    end
  end

  def add_to_history(role, content, tool_call_id: nil)
    msg = { role: role, content: content }
    msg[:tool_call_id] = tool_call_id if tool_call_id
    @conversation_history << msg
  end

  def save_message(role, content, tool_name: nil, tool_result: nil)
    @db[:world_builder_conversations].insert(
      world_id: @world_id,
      role: role,
      content: content,
      tool_name: tool_name,
      tool_result: tool_result
    )
  end

  # WebSocket broadcasting

  def send_greeting
    broadcast_message_chunk("Hello! I'm your AI world building assistant. ")
    sleep 0.1
    broadcast_message_chunk("I can help you create and edit locations, NPCs, items, and connections for your RPG world.\n\n")
    sleep 0.1
    broadcast_message_chunk("Try saying: 'Create a mysterious tavern' or 'Change the blacksmith's description' or 'Make the goblin hostile'")
    broadcast_message_complete
  end

  def broadcast_status(thinking)
    broadcast_to_builder_sockets({
      type: 'ai_thinking',
      status: thinking
    })
  end

  def broadcast_message_chunk(content)
    broadcast_to_builder_sockets({
      type: 'ai_message_chunk',
      content: content
    })
  end

  def broadcast_message_complete
    broadcast_to_builder_sockets({
      type: 'ai_message_complete'
    })
  end

  def broadcast_approval_request(request_id, entities)
    broadcast_to_builder_sockets({
      type: 'approval_request',
      request_id: request_id,
      entities: entities.map do |e|
        {
          type: e[:entity_type],
          action: e[:action],
          params: e[:params],
          preview: e[:preview]
        }
      end
    })
  end

  def broadcast_execution_complete(results)
    broadcast_to_builder_sockets({
      type: 'execution_complete',
      results: results
    })

    # Load all locations for rendering partials (needed for lookups)
    locations = Location.where(world_id: @world_id).order(:name).all

    # Send DOM updates for each successfully created entity
    results.each do |result|
      next unless result[:success]

      begin
        case result[:entity_type]
        when 'location'
          entity = Location[result[:entity_id]]
          next unless entity
          level = calculate_location_level(entity, locations)
          html = render_partial('_location_card', { location: entity, locations: locations, level: level })
          entity_data = { id: entity.id, name: entity.name, location_type: entity.location_type, parent_location_id: entity.parent_location_id }
          broadcast_dom_update('append', '#locations-list', html, 'location', entity.id, entity_data)

        when 'connection'
          entity = Connection[result[:entity_id]]
          next unless entity
          html = render_partial('_connection_card', { connection: entity, locations: locations })
          entity_data = { id: entity.id, from_location_id: entity.from_location_id, to_location_id: entity.to_location_id, is_bidirectional: entity.is_bidirectional }
          broadcast_dom_update('append', '#connections-list', html, 'connection', entity.id, entity_data)

        when 'character'
          entity = Character[result[:entity_id]]
          next unless entity
          html = render_partial('_character_card', { character: entity, locations: locations })
          entity_data = { id: entity.id, name: entity.name, location_id: entity.location_id }
          broadcast_dom_update('append', '#characters-list', html, 'character', entity.id, entity_data)

        when 'item'
          entity = Item[result[:entity_id]]
          next unless entity
          html = render_partial('_item_card', { item: entity, locations: locations })
          entity_data = { id: entity.id, name: entity.name, location_id: entity.location_id }
          broadcast_dom_update('append', '#items-list', html, 'item', entity.id, entity_data)

        when 'container'
          entity = Container[result[:entity_id]]
          next unless entity
          html = render_partial('_container_card', { container: entity, locations: locations })
          entity_data = { id: entity.id, name: entity.name, location_id: entity.location_id }
          broadcast_dom_update('append', '#containers-list', html, 'container', entity.id, entity_data)

        when 'quest'
          entity = Quest[result[:entity_id]]
          next unless entity
          html = render_partial('_quest_card', { quest: entity })
          # Quests don't appear on map, so no entity_data needed
          broadcast_dom_update('append', '#quests-list', html, 'quest', entity.id, nil)
        end
      rescue => e
        puts "[WorldBuilderAI] Error rendering #{result[:entity_type]} ##{result[:entity_id]}: #{e.message}"
      end
    end

    # Update stats counters
    update_stats_counters
  end

  def format_context(context)
    return "" unless context

    parts = []
    parts << "[FOCUSED ENTITY CONTEXT]"
    parts << "Type: #{context['type'].upcase}"
    parts << "ID: #{context['id']}"

    case context['type']
    when 'location'
      parts << "Name: #{context['name']}" if context['name']
      parts << "Location Type: #{context['locationType']}" if context['locationType']
      parts << "Parent Location ID: #{context['parentId']}" if context['parentId'] && !context['parentId'].empty?
    when 'character'
      parts << "Name: #{context['name']}" if context['name']
      parts << "Location: #{context['location']}" if context['location']
      parts << "Hostile: #{context['hostile']}" if context['hostile']
    when 'item'
      parts << "Name: #{context['name']}" if context['name']
      parts << "Item Type: #{context['itemType']}" if context['itemType']
      parts << "Location: #{context['location']}" if context['location']
    when 'container'
      parts << "Name: #{context['name']}" if context['name']
      parts << "Locked: #{context['locked']}" if context['locked']
      parts << "Location: #{context['location']}" if context['location']
    when 'connection'
      parts << "From: #{context['fromLocation']}" if context['fromLocation']
      parts << "Direction: #{context['direction']}" if context['direction']
      parts << "To: #{context['toLocation']}" if context['toLocation']
    end

    parts << "[END CONTEXT]"
    parts.join("\n")
  end

  def broadcast_error(message)
    broadcast_to_builder_sockets({
      type: 'error',
      message: message
    })
  end

  def broadcast_to_builder_sockets(data)
    @sockets_mutex.synchronize do
      sockets = @sockets["builder_#{@world_id}"]
      if sockets
        sockets.each do |socket|
          begin
            socket.send(JSON.generate(data))
          rescue => e
            puts "[WorldBuilderAI] Broadcast error: #{e.message}"
          end
        end
      end
    end
  end
end
