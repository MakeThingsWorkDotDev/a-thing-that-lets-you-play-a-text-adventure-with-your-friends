# frozen_string_literal: true

# Manages world building operations (creating worlds, locations, copying templates)
module WorldBuilder

  def create_world(name:, description: nil, created_by: nil, is_template: false)
    world = World.create(
      name: name,
      description: description,
      created_by: created_by,
      is_template: is_template,
      time_of_day: 'morning',
      days_elapsed: 0,
      world_state: '{}'
    )

    log(world.id, 'world_created', {
      actor_type: created_by ? 'User' : 'System',
      actor_id: created_by,
      target_type: 'World',
      target_id: world.id,
      event_data: { is_template: is_template }.to_json
    })

    { success: true, world_id: world.id, world: world_summary(world) }
  end

  def create_location(world_id:, name:, description: nil, location_type: nil, parent_location_id: nil)
    location = Location.create(
      world_id: world_id,
      parent_location_id: parent_location_id,
      name: name,
      description: description,
      location_type: location_type,
      state: '{}'
    )

    log(world_id, 'location_created', {
      target_type: 'Location',
      target_id: location.id,
      event_data: { location_type: location_type }.to_json
    })

    { success: true, location_id: location.id, location: location_summary(location) }
  end

  def copy_world(template_world_id, new_name: nil, created_by: nil, is_template: false)
    template = World[template_world_id]
    return { error: 'Template world not found' } unless template

    # Create new world
    new_world = World.create(
      name: new_name || "#{template.name} (Copy)",
      description: template.description,
      created_by: created_by,
      is_template: is_template,
      time_of_day: template.time_of_day,
      days_elapsed: 0,
      world_state: template.world_state
    )

    # Map old IDs to new IDs for relationships
    location_map = {}
    character_map = {}
    item_map = {}
    container_map = {}

    # Copy locations
    template.locations.each do |old_location|
      new_location = Location.create(
        world_id: new_world.id,
        parent_location_id: nil, # Will fix this after all locations are created
        name: old_location.name,
        description: old_location.description,
        location_type: old_location.location_type,
        state: old_location.state
      )
      location_map[old_location.id] = new_location.id
    end

    # Fix parent_location_id references
    template.locations.each do |old_location|
      if old_location.parent_location_id
        new_location = Location[location_map[old_location.id]]
        new_location.update(parent_location_id: location_map[old_location.parent_location_id])
      end
    end

    # Copy connections
    template.connections.each do |old_conn|
      Connection.create(
        world_id: new_world.id,
        from_location_id: location_map[old_conn.from_location_id],
        to_location_id: location_map[old_conn.to_location_id],
        connection_type: old_conn.connection_type,
        direction: old_conn.direction,
        description: old_conn.description,
        is_visible: old_conn.is_visible,
        is_locked: old_conn.is_locked,
        is_open: old_conn.is_open,
        is_bidirectional: old_conn.is_bidirectional,
        reverse_description: old_conn.reverse_description
      )
    end

    # Copy characters
    template.characters.each do |old_char|
      new_char = Character.create(
        world_id: new_world.id,
        location_id: old_char.location_id ? location_map[old_char.location_id] : nil,
        character_type: old_char.character_type,
        name: old_char.name,
        description: old_char.description,
        max_hp: old_char.max_hp,
        current_hp: old_char.max_hp, # Reset to full HP
        strength: old_char.strength,
        intelligence: old_char.intelligence,
        charisma: old_char.charisma,
        athletics: old_char.athletics,
        armor_class: old_char.armor_class,
        is_hostile: old_char.is_hostile,
        is_dead: false, # Reset death state
        faction: old_char.faction,
        additional_stats: old_char.additional_stats
      )
      character_map[old_char.id] = new_char.id
    end

    # Copy containers
    template.containers.each do |old_container|
      new_container = Container.create(
        world_id: new_world.id,
        location_id: old_container.location_id ? location_map[old_container.location_id] : nil,
        character_id: old_container.character_id ? character_map[old_container.character_id] : nil,
        name: old_container.name,
        description: old_container.description,
        is_locked: old_container.is_locked,
        is_open: old_container.is_open,
        capacity: old_container.capacity
      )
      container_map[old_container.id] = new_container.id
    end

    # Copy items
    template.items.each do |old_item|
      Item.create(
        world_id: new_world.id,
        location_id: old_item.location_id ? location_map[old_item.location_id] : nil,
        character_id: old_item.character_id ? character_map[old_item.character_id] : nil,
        container_id: old_item.container_id ? container_map[old_item.container_id] : nil,
        name: old_item.name,
        description: old_item.description,
        quantity: old_item.quantity,
        item_type: old_item.item_type,
        is_stackable: old_item.is_stackable,
        cost: old_item.cost,
        properties: old_item.properties
      )
    end

    log(new_world.id, 'world_copied', {
      actor_type: created_by ? 'User' : 'System',
      actor_id: created_by,
      target_type: 'World',
      target_id: new_world.id,
      event_data: {
        source_world_id: template_world_id,
        locations_copied: location_map.size,
        characters_copied: character_map.size,
        items_copied: template.items.count,
        containers_copied: container_map.size,
        connections_copied: template.connections.count
      }.to_json
    })

    {
      success: true,
      world_id: new_world.id,
      world: world_summary(new_world),
      stats: {
        locations: location_map.size,
        connections: template.connections.count,
        characters: character_map.size,
        items: template.items.count,
        containers: container_map.size
      }
    }
  end

  private

  def world_summary(world)
    {
      id: world.id,
      name: world.name,
      description: world.description,
      is_template: world.is_template,
      time_of_day: world.time_of_day,
      days_elapsed: world.days_elapsed
    }
  end

  def location_summary(location)
    {
      id: location.id,
      name: location.name,
      description: location.description,
      location_type: location.location_type
    }
  end
end
