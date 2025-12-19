# frozen_string_literal: true

# Manages connections/exits between locations
module ConnectionManager

  def create_connection(world_id, from_location_id, to_location_id, attributes)
    is_bidirectional = attributes.fetch(:is_bidirectional, false)

    # Check for existing connections between these two locations (in both directions)
    existing_forward = Connection.where(
      world_id: world_id,
      from_location_id: from_location_id,
      to_location_id: to_location_id
    ).first

    existing_reverse = Connection.where(
      world_id: world_id,
      from_location_id: to_location_id,
      to_location_id: from_location_id
    ).first

    # CASE 1: Bidirectional connection already exists (in either direction)
    if (existing_forward && existing_forward.is_bidirectional) ||
       (existing_reverse && existing_reverse.is_bidirectional)
      # Already fully bidirectional - skip creation
      return {
        success: true,
        connection_id: (existing_forward || existing_reverse).id,
        message: 'Connection already exists (bidirectional)'
      }
    end

    # CASE 2: Creating bidirectional, but non-bidirectional connection(s) exist
    if is_bidirectional && (existing_forward || existing_reverse)
      # Upgrade existing connection(s) to bidirectional
      if existing_forward
        existing_forward.update(is_bidirectional: true)

        # Create or update reverse connection
        if existing_reverse
          # Both directions exist separately - keep forward as bidirectional, delete reverse
          existing_reverse.delete
        else
          # Only forward exists - create reverse
          Connection.create(
            world_id: world_id,
            from_location_id: to_location_id,
            to_location_id: from_location_id,
            connection_type: attributes[:connection_type] || 'passage',
            direction: reverse_direction(existing_forward.direction),
            description: attributes[:reverse_description] || existing_forward.description,
            is_visible: existing_forward.is_visible,
            is_locked: existing_forward.is_locked,
            is_open: existing_forward.is_open,
            required_item_id: existing_forward.required_item_id,
            is_bidirectional: false
          )
        end

        return {
          success: true,
          connection_id: existing_forward.id,
          message: 'Upgraded existing connection to bidirectional'
        }
      else
        # Only reverse exists - upgrade it
        existing_reverse.update(is_bidirectional: true)

        # Create forward connection
        Connection.create(
          world_id: world_id,
          from_location_id: from_location_id,
          to_location_id: to_location_id,
          connection_type: attributes[:connection_type] || 'passage',
          direction: reverse_direction(existing_reverse.direction),
          description: attributes[:description] || existing_reverse.description,
          is_visible: existing_reverse.is_visible,
          is_locked: existing_reverse.is_locked,
          is_open: existing_reverse.is_open,
          required_item_id: existing_reverse.required_item_id,
          is_bidirectional: false
        )

        return {
          success: true,
          connection_id: existing_reverse.id,
          message: 'Upgraded existing connection to bidirectional'
        }
      end
    end

    # CASE 3: Creating non-bidirectional, but bidirectional already exists
    if !is_bidirectional && (existing_forward || existing_reverse)
      # Skip - already covered by existing connection
      return {
        success: true,
        connection_id: (existing_forward || existing_reverse).id,
        message: 'Connection already exists'
      }
    end

    # CASE 4: No conflicts - create new connection normally
    connection = Connection.create(
      world_id: world_id,
      from_location_id: from_location_id,
      to_location_id: to_location_id,
      connection_type: attributes[:connection_type] || 'passage',
      direction: attributes[:direction],
      description: attributes[:description],
      is_visible: attributes.fetch(:is_visible, true),
      is_locked: attributes.fetch(:is_locked, false),
      is_open: attributes.fetch(:is_open, true),
      required_item_id: attributes[:required_item_id],
      is_bidirectional: is_bidirectional,
      reverse_description: attributes[:reverse_description]
    )

    # Create reverse connection if bidirectional
    if is_bidirectional
      Connection.create(
        world_id: world_id,
        from_location_id: to_location_id,
        to_location_id: from_location_id,
        connection_type: attributes[:connection_type] || 'passage',
        direction: reverse_direction(attributes[:direction]),
        description: attributes[:reverse_description] || attributes[:description],
        is_visible: attributes.fetch(:is_visible, true),
        is_locked: attributes.fetch(:is_locked, false),
        is_open: attributes.fetch(:is_open, true),
        required_item_id: attributes[:required_item_id],
        is_bidirectional: false
      )
    end

    { success: true, connection_id: connection.id }
  end

  def list_exits(location_id)
    location = Location[location_id]
    return { error: 'Location not found' } unless location

    # Get explicit connections
    explicit_exits = location.exits.map do |conn|
      {
        id: conn.id,
        direction: conn.direction,
        description: conn.description,
        connection_type: conn.connection_type,
        is_locked: conn.is_locked,
        is_open: conn.is_open,
        to_location: conn.to_location.name,
        to_location_id: conn.to_location_id,
        is_implicit: false
      }
    end

    # Get implicit connections (siblings and children)
    implicit_exits = get_implicit_connections(location_id)

    # Merge: explicit overrides implicit
    # Remove implicit connections where an explicit one already exists to the same location
    explicit_target_ids = explicit_exits.map { |e| e[:to_location_id] }.compact
    filtered_implicit = implicit_exits.reject { |e| explicit_target_ids.include?(e[:to_location_id]) }

    all_exits = explicit_exits + filtered_implicit

    { exits: all_exits }
  end

  def get_implicit_connections(location_id)
    location = Location[location_id]
    return [] unless location

    implicit_connections = []

    # 1. Sibling locations (same parent)
    if location.parent_location_id
      siblings = Location.where(
        world_id: location.world_id,
        parent_location_id: location.parent_location_id
      ).exclude(id: location_id).all

      siblings.each do |sibling|
        implicit_connections << {
          id: nil,
          direction: "to #{sibling.name.downcase}",
          description: nil,
          connection_type: 'passage',
          is_locked: false,
          is_open: true,
          is_visible: true,
          to_location: sibling.name,
          to_location_id: sibling.id,
          is_implicit: true
        }
      end
    end

    # 2. Child locations (from parent to children)
    children = Location.where(
      world_id: location.world_id,
      parent_location_id: location_id
    ).all

    children.each do |child|
      implicit_connections << {
        id: nil,
        direction: "to #{child.name.downcase}",
        description: nil,
        connection_type: 'passage',
        is_locked: false,
        is_open: true,
        is_visible: true,
        to_location: child.name,
        to_location_id: child.id,
        is_implicit: true
      }
    end

    implicit_connections
  end

  def get_connection(from_location_id, direction)
    # First check for explicit connection
    connection = Connection.where(
      from_location_id: from_location_id,
      direction: direction,
      is_visible: true
    ).first

    if connection
      return {
        id: connection.id,
        direction: connection.direction,
        description: connection.description,
        connection_type: connection.connection_type,
        is_locked: connection.is_locked,
        is_open: connection.is_open,
        to_location_id: connection.to_location_id,
        is_implicit: false
      }
    end

    # Check for implicit connection
    implicit_connections = get_implicit_connections(from_location_id)
    implicit = implicit_connections.find { |c| c[:direction] == direction }

    return { error: 'Connection not found' } unless implicit

    {
      id: nil,
      direction: implicit[:direction],
      description: implicit[:description],
      connection_type: implicit[:connection_type],
      is_locked: implicit[:is_locked],
      is_open: implicit[:is_open],
      to_location_id: implicit[:to_location_id],
      is_implicit: true
    }
  end

  def open_door(connection_id)
    connection = Connection[connection_id]
    return { error: 'Connection not found' } unless connection

    connection.update(is_open: true)

    log(connection.world_id, 'connection_state_changed', {
      target_type: 'Connection',
      target_id: connection_id,
      event_data: { action: 'opened' }.to_json
    })

    { success: true, message: 'Door opened' }
  end

  def close_door(connection_id)
    connection = Connection[connection_id]
    return { error: 'Connection not found' } unless connection

    connection.update(is_open: false)

    log(connection.world_id, 'connection_state_changed', {
      target_type: 'Connection',
      target_id: connection_id,
      event_data: { action: 'closed' }.to_json
    })

    { success: true, message: 'Door closed' }
  end

  def lock_door(connection_id, with_item_id: nil)
    connection = Connection[connection_id]
    return { error: 'Connection not found' } unless connection

    connection.update(
      is_locked: true,
      is_open: false,
      required_item_id: with_item_id
    )

    log(connection.world_id, 'connection_state_changed', {
      target_type: 'Connection',
      target_id: connection_id,
      event_data: { action: 'locked', required_item_id: with_item_id }.to_json
    })

    { success: true, message: 'Door locked' }
  end

  def unlock_door(connection_id, using_item_id: nil)
    connection = Connection[connection_id]
    return { error: 'Connection not found' } unless connection

    if connection.required_item_id && using_item_id != connection.required_item_id
      return { error: 'Wrong key' }
    end

    connection.update(is_locked: false)

    log(connection.world_id, 'connection_state_changed', {
      target_type: 'Connection',
      target_id: connection_id,
      event_data: { action: 'unlocked', used_item_id: using_item_id }.to_json
    })

    { success: true, message: 'Door unlocked' }
  end

  def reveal_exit(connection_id)
    connection = Connection[connection_id]
    return { error: 'Connection not found' } unless connection

    connection.update(is_visible: true)

    log(connection.world_id, 'connection_state_changed', {
      target_type: 'Connection',
      target_id: connection_id,
      event_data: { action: 'revealed' }.to_json
    })

    { success: true, message: 'Exit revealed' }
  end

  def hide_exit(connection_id)
    connection = Connection[connection_id]
    return { error: 'Connection not found' } unless connection

    connection.update(is_visible: false)

    log(connection.world_id, 'connection_state_changed', {
      target_type: 'Connection',
      target_id: connection_id,
      event_data: { action: 'hidden' }.to_json
    })

    { success: true, message: 'Exit hidden' }
  end

  def traverse_connection(character_id, connection_id)
    character = Character[character_id]
    return { error: 'Character not found' } unless character

    connection = Connection[connection_id]
    return { error: 'Connection not found' } unless connection
    return { error: 'Connection is locked' } if connection.is_locked
    return { error: 'Door is closed' } if !connection.is_open && connection.connection_type == 'door'

    character.update(location_id: connection.to_location_id)

    log(connection.world_id, 'character_moved', {
      actor_type: 'Character',
      actor_id: character_id,
      target_type: 'Location',
      target_id: connection.to_location_id,
      event_data: {
        via_connection_id: connection_id,
        direction: connection.direction
      }.to_json
    })

    { success: true, new_location_id: connection.to_location_id }
  end

  def traverse_by_direction(character_id, direction)
    character = Character[character_id]
    return { error: 'Character not found' } unless character

    connection_data = get_connection(character.location_id, direction)
    return connection_data if connection_data[:error]

    # Check if locked or closed
    return { error: 'Connection is locked' } if connection_data[:is_locked]
    return { error: 'Door is closed' } if !connection_data[:is_open] && connection_data[:connection_type] == 'door'

    # Update character location
    old_location = character.location_id
    character.update(location_id: connection_data[:to_location_id])

    # Log the movement
    location = Location[old_location]
    if location
      log(location.world_id, 'character_moved', {
        actor_type: 'Character',
        actor_id: character_id,
        target_type: 'Location',
        target_id: connection_data[:to_location_id],
        event_data: {
          via_connection_id: connection_data[:id],
          direction: direction,
          is_implicit: connection_data[:is_implicit]
        }.to_json
      })
    end

    { success: true, new_location_id: connection_data[:to_location_id] }
  end

  private

  def reverse_direction(direction)
    opposites = {
      'north' => 'south',
      'south' => 'north',
      'east' => 'west',
      'west' => 'east',
      'up' => 'down',
      'down' => 'up',
      'northeast' => 'southwest',
      'northwest' => 'southeast',
      'southeast' => 'northwest',
      'southwest' => 'northeast'
    }
    opposites[direction] || direction
  end
end
