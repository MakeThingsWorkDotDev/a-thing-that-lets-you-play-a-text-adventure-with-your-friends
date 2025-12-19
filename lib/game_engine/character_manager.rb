# frozen_string_literal: true

# Manages character-level operations (movement, combat, inventory)
module CharacterManager

  def move_character(character_id, to_location_id)
    character = Character[character_id]
    return { error: 'Character not found' } unless character

    location = Location[to_location_id]
    return { error: 'Location not found' } unless location

    old_location_id = character.location_id
    character.update(location_id: to_location_id)

    log(character.world_id, 'character_moved', {
      actor_type: 'Character',
      actor_id: character_id,
      target_type: 'Location',
      target_id: to_location_id,
      event_data: {
        from_location_id: old_location_id,
        to_location_id: to_location_id
      }.to_json
    })

    { success: true, new_location: location.name }
  end

  def move_party(character_ids, to_location_id)
    # Validate location exists first
    location = Location[to_location_id]
    return { error: 'Location not found' } unless location

    results = []
    moved_count = 0
    failed_count = 0

    character_ids.each do |character_id|
      result = move_character(character_id, to_location_id)

      if result[:success]
        moved_count += 1
        results << { character_id: character_id, status: 'moved' }
      else
        failed_count += 1
        results << { character_id: character_id, status: 'failed', error: result[:error] }
      end
    end

    {
      success: true,
      location: location.name,
      moved: moved_count,
      failed: failed_count,
      details: results
    }
  end

  def damage_character(character_id, amount, source: nil)
    character = Character[character_id]
    return { error: 'Character not found' } unless character

    old_hp = character.current_hp
    new_hp = [old_hp - amount, 0].max
    is_dead = new_hp <= 0

    character.update(
      current_hp: new_hp,
      is_dead: is_dead
    )

    log(character.world_id, 'character_damaged', {
      actor_type: source&.class&.name,
      actor_id: source&.id,
      target_type: 'Character',
      target_id: character_id,
      event_data: {
        damage: amount,
        old_hp: old_hp,
        new_hp: new_hp,
        is_dead: is_dead
      }.to_json
    })

    {
      success: true,
      new_hp: new_hp,
      max_hp: character.max_hp,
      is_dead: is_dead,
      message: is_dead ? "#{character.name} has been killed!" : "#{character.name} took #{amount} damage (#{new_hp}/#{character.max_hp} HP)"
    }
  end

  def heal_character(character_id, amount, source: nil)
    character = Character[character_id]
    return { error: 'Character not found' } unless character
    return { error: 'Cannot heal a dead character' } if character.is_dead

    old_hp = character.current_hp
    new_hp = [old_hp + amount, character.max_hp].min

    character.update(current_hp: new_hp)

    log(character.world_id, 'character_healed', {
      actor_type: source&.class&.name,
      actor_id: source&.id,
      target_type: 'Character',
      target_id: character_id,
      event_data: {
        healing: amount,
        old_hp: old_hp,
        new_hp: new_hp
      }.to_json
    })

    {
      success: true,
      new_hp: new_hp,
      max_hp: character.max_hp,
      message: "#{character.name} restored #{amount} HP (#{new_hp}/#{character.max_hp} HP)"
    }
  end

  def character_take_item(character_id, item_id)
    character = Character[character_id]
    return { error: 'Character not found' } unless character

    item = Item[item_id]
    return { error: 'Item not found' } unless item

    old_location_id = item.location_id
    old_container_id = item.container_id

    item.update(
      character_id: character_id,
      location_id: nil,
      container_id: nil
    )

    log(character.world_id, 'item_taken', {
      actor_type: 'Character',
      actor_id: character_id,
      target_type: 'Item',
      target_id: item_id,
      event_data: {
        from_location_id: old_location_id,
        from_container_id: old_container_id
      }.to_json
    })

    { success: true, message: "#{character.name} took #{item.name}" }
  end

  def character_drop_item(character_id, item_id)
    character = Character[character_id]
    return { error: 'Character not found' } unless character

    item = Item[item_id]
    return { error: 'Item not found' } unless item
    return { error: 'Character does not have this item' } unless item.character_id == character_id

    item.update(
      character_id: nil,
      location_id: character.location_id
    )

    log(character.world_id, 'item_dropped', {
      actor_type: 'Character',
      actor_id: character_id,
      target_type: 'Item',
      target_id: item_id,
      event_data: {
        at_location_id: character.location_id
      }.to_json
    })

    { success: true, message: "#{character.name} dropped #{item.name}" }
  end

  def get_character_inventory(character_id)
    character = Character[character_id]
    return { error: 'Character not found' } unless character

    items = character.items.map { |item| item_summary(item) }
    containers = character.containers.map { |container| container_summary(container) }

    { character: character.name, items: items, containers: containers }
  end

  def create_player_character(user_id, world_id, attributes)
    # Check if user already has a character in this world
    existing = Character.where(user_id: user_id, world_id: world_id, character_type: 'player').first
    return { error: 'User already has a character in this world', character_id: existing.id } if existing

    character = Character.create(
      user_id: user_id,
      world_id: world_id,
      character_type: 'player',
      name: attributes[:name],
      description: attributes[:description],
      location_id: attributes[:location_id],
      max_hp: attributes[:max_hp] || 20,
      current_hp: attributes[:max_hp] || 20,
      strength: attributes[:strength] || 10,
      intelligence: attributes[:intelligence] || 10,
      charisma: attributes[:charisma] || 10,
      athletics: attributes[:athletics] || 10,
      armor_class: attributes[:armor_class] || (10 + ((attributes[:athletics] || 10) / 2)),
      created_by: user_id
    )

    log(world_id, 'character_created', {
      actor_type: 'User',
      actor_id: user_id,
      target_type: 'Character',
      target_id: character.id,
      event_data: { character_type: 'player' }.to_json
    })

    { success: true, character_id: character.id, character: character_summary(character) }
  end

  def get_player_character(user_id, world_id)
    character = Character.where(user_id: user_id, world_id: world_id, character_type: 'player').first
    return { error: 'No character found for this user in this world' } unless character

    { success: true, character: character_summary(character) }
  end

  def create_npc(world_id:, name:, description: nil, location_id: nil, max_hp: 10, strength: 10, intelligence: 10, charisma: 10, is_hostile: false, gold: 0, created_by: nil)
    character = Character.create(
      world_id: world_id,
      character_type: 'npc',
      name: name,
      description: description,
      location_id: location_id,
      max_hp: max_hp,
      current_hp: max_hp,
      strength: strength,
      intelligence: intelligence,
      charisma: charisma,
      athletics: 10,
      armor_class: 10,
      is_hostile: is_hostile,
      gold: gold,
      created_by: created_by
    )

    log(world_id, 'character_created', {
      actor_type: created_by ? 'User' : 'System',
      actor_id: created_by,
      target_type: 'Character',
      target_id: character.id,
      event_data: { character_type: 'npc', is_hostile: is_hostile }.to_json
    })

    { success: true, character_id: character.id, character: character_summary(character) }
  end

  def kill_character(character_id)
    result = damage_character(character_id, 9999)
    return result unless result[:is_dead]

    # TODO: Create corpse container with character's inventory
    { success: true, message: "Character killed" }
  end

  private

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
