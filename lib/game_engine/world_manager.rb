# frozen_string_literal: true

# Manages world-level operations (time, state)
module WorldManager

  def get_world_time(world_id)
    world = World[world_id]
    return { error: 'World not found' } unless world

    {
      time_of_day: world.time_of_day,
      days_elapsed: world.days_elapsed
    }
  end

  def advance_time(world_id, to_time_of_day)
    world = World[world_id]
    return { error: 'World not found' } unless world

    valid_times = ['morning', 'afternoon', 'evening', 'night']
    return { error: 'Invalid time of day' } unless valid_times.include?(to_time_of_day)

    old_time = world.time_of_day
    world.update(time_of_day: to_time_of_day)

    log(world_id, 'time_advanced', {
      actor_type: 'System',
      target_type: 'World',
      target_id: world_id,
      event_data: { from: old_time, to: to_time_of_day }.to_json
    })

    { success: true, time_of_day: to_time_of_day }
  end

  def advance_day(world_id)
    world = World[world_id]
    return { error: 'World not found' } unless world

    world.update(
      days_elapsed: world.days_elapsed + 1,
      time_of_day: 'morning'
    )

    log(world_id, 'day_advanced', {
      actor_type: 'System',
      target_type: 'World',
      target_id: world_id,
      event_data: { days_elapsed: world.days_elapsed }.to_json
    })

    { success: true, days_elapsed: world.days_elapsed }
  end

  def set_world_state(world_id, key, value)
    world = World[world_id]
    return { error: 'World not found' } unless world

    state = parse_json(world.world_state)
    old_value = state[key]
    state[key] = value
    world.update(world_state: state.to_json)

    log(world_id, 'world_state_changed', {
      target_type: 'World',
      target_id: world_id,
      event_data: { key: key, old_value: old_value, new_value: value }.to_json
    })

    { success: true, key: key, value: value }
  end

  def get_world_state(world_id, key)
    world = World[world_id]
    return { error: 'World not found' } unless world

    state = parse_json(world.world_state)
    { value: state[key] }
  end

  private

  def parse_json(json_string)
    return {} if json_string.nil? || json_string.empty?
    JSON.parse(json_string)
  rescue JSON::ParserError
    {}
  end
end
