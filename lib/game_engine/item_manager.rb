# frozen_string_literal: true

# Manages item-level operations (creation, modification, transfers)
module ItemManager

  def create_item(world_id, attributes)
    item = Item.create(
      world_id: world_id,
      name: attributes[:name],
      description: attributes[:description],
      location_id: attributes[:location_id],
      item_type: attributes[:item_type] || 'misc',
      quantity: attributes[:quantity] || 1,
      is_stackable: attributes[:is_stackable] || false,
      cost: attributes[:cost] || 0,
      properties: (attributes[:properties] || {}).to_json
    )

    log(world_id, 'item_created', {
      actor_type: 'System',
      target_type: 'Item',
      target_id: item.id,
      event_data: { item_type: item.item_type }.to_json
    })

    { success: true, item_id: item.id }
  end

  def modify_item_quantity(item_id, change)
    item = Item[item_id]
    return { error: 'Item not found' } unless item

    old_quantity = item.quantity
    new_quantity = old_quantity + change

    if new_quantity <= 0
      item.destroy
      log(item.world_id, 'item_consumed', {
        target_type: 'Item',
        target_id: item_id,
        event_data: { reason: 'quantity_depleted' }.to_json
      })
      return { success: true, removed: true, message: "#{item.name} depleted and removed" }
    end

    item.update(quantity: new_quantity)

    log(item.world_id, 'item_quantity_changed', {
      target_type: 'Item',
      target_id: item_id,
      event_data: { old_quantity: old_quantity, new_quantity: new_quantity, change: change }.to_json
    })

    { success: true, new_quantity: new_quantity }
  end

  def move_item(item_id, to:)
    item = Item[item_id]
    return { error: 'Item not found' } unless item

    # Determine what 'to' is
    old_location_id = item.location_id
    old_character_id = item.character_id
    old_container_id = item.container_id

    case to
    when Location
      item.update(location_id: to.id, character_id: nil, container_id: nil)
    when Character
      item.update(character_id: to.id, location_id: nil, container_id: nil)
    when Container
      item.update(container_id: to.id, location_id: nil, character_id: nil)
    else
      return { error: 'Invalid target for item movement' }
    end

    log(item.world_id, 'item_moved', {
      target_type: 'Item',
      target_id: item_id,
      event_data: {
        from_location_id: old_location_id,
        from_character_id: old_character_id,
        from_container_id: old_container_id,
        to_type: to.class.name,
        to_id: to.id
      }.to_json
    })

    { success: true, message: "Item moved to #{to.class.name}##{to.id}" }
  end
end
