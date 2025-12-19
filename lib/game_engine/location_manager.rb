# frozen_string_literal: true

# Manages location-level operations (state, descriptions, queries)
module LocationManager

  def describe_location(location_id)
    location = Location[location_id]
    return { error: 'Location not found' } unless location

    state = parse_json(location.state)
    description = location.description.dup

    # Add state-based description modifiers
    description += apply_state_descriptions(state)

    # Get visible exits
    exits = location.exits.map do |conn|
      {
        direction: conn.direction,
        description: conn.description,
        connection_type: conn.connection_type,
        is_locked: conn.is_locked,
        is_open: conn.is_open
      }
    end

    {
      id: location.id,
      name: location.name,
      description: description,
      location_type: location.location_type,
      state: state,
      exits: exits
    }
  end

  def list_characters_at(location_id)
    Character.where(location_id: location_id, is_dead: false).all.map do |char|
      character_summary(char)
    end
  end

  def list_items_at(location_id)
    Item.where(location_id: location_id, character_id: nil, container_id: nil).all.map do |item|
      item_summary(item)
    end
  end

  def list_containers_at(location_id)
    Container.where(location_id: location_id, character_id: nil).all.map do |container|
      container_summary(container)
    end
  end

  def get_location_state(location_id, key)
    location = Location[location_id]
    return { error: 'Location not found' } unless location

    state = parse_json(location.state)
    { value: state[key] }
  end

  def set_location_state(location_id, key, value)
    location = Location[location_id]
    return { error: 'Location not found' } unless location

    state = parse_json(location.state)
    old_value = state[key]
    state[key] = value
    location.update(state: state.to_json)

    log(location.world_id, 'location_state_changed', {
      target_type: 'Location',
      target_id: location_id,
      event_data: { key: key, old_value: old_value, new_value: value }.to_json
    })

    { success: true, key: key, value: value }
  end

  def get_all_location_state(location_id)
    location = Location[location_id]
    return { error: 'Location not found' } unless location

    { state: parse_json(location.state) }
  end

  def clear_location_state(location_id, key)
    location = Location[location_id]
    return { error: 'Location not found' } unless location

    state = parse_json(location.state)
    old_value = state.delete(key)
    location.update(state: state.to_json)

    log(location.world_id, 'location_state_changed', {
      target_type: 'Location',
      target_id: location_id,
      event_data: { key: key, old_value: old_value, new_value: nil, action: 'cleared' }.to_json
    })

    { success: true, cleared: true }
  end

  private

  def parse_json(json_string)
    return {} if json_string.nil? || json_string.empty?
    JSON.parse(json_string)
  rescue JSON::ParserError
    {}
  end

  def apply_state_descriptions(state)
    additions = []

    if state['is_on_fire']
      additions << " Flames lick at the walls, filling the air with smoke."
    end

    if state['water_level']
      case state['water_level']
      when 1
        additions << " Water covers the floor, reaching your ankles."
      when 2
        additions << " You wade through waist-deep water."
      when 3
        additions << " The room is completely flooded. You must swim."
      end
    end

    if state['is_dark']
      return " It's pitch black. You can't see anything."
    end

    additions.join
  end

  def character_summary(character)
    {
      id: character.id,
      name: character.name,
      description: character.description,
      hp: "#{character.current_hp}/#{character.max_hp}",
      is_dead: character.is_dead,
      character_type: character.character_type,
      stats: {
        strength: character.strength,
        intelligence: character.intelligence,
        charisma: character.charisma,
        athletics: character.athletics,
        armor_class: character.armor_class
      }
    }
  end

  def item_summary(item)
    {
      id: item.id,
      name: item.name,
      description: item.description,
      quantity: item.quantity,
      item_type: item.item_type
    }
  end

  def container_summary(container)
    {
      id: container.id,
      name: container.name,
      description: container.description,
      is_locked: container.is_locked,
      is_open: container.is_open
    }
  end
end
