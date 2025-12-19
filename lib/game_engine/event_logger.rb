# frozen_string_literal: true

# Handles event logging and querying
module EventLogger
  def log(world_id, event_type, attributes)
    GameEvent.create(
      world_id: world_id,
      room_id: attributes[:room_id],
      event_type: event_type,
      actor_type: attributes[:actor_type],
      actor_id: attributes[:actor_id],
      target_type: attributes[:target_type],
      target_id: attributes[:target_id],
      event_data: attributes[:event_data],
      created_by: attributes[:created_by]
    )
  end

  def get_recent_events(world_id, limit: 50, room_id: nil)
    query = GameEvent.where(world_id: world_id)
    query = query.where(room_id: room_id) if room_id

    query.order(Sequel.desc(:created_at))
         .limit(limit)
         .all
         .map { |event| event_summary(event) }
  end

  def get_events(world_id, filters: {})
    query = GameEvent.where(world_id: world_id)

    filters.each do |key, value|
      query = query.where(key => value)
    end

    query.order(Sequel.desc(:created_at))
         .all
         .map { |event| event_summary(event) }
  end

  private

  def event_summary(event)
    {
      id: event.id,
      event_type: event.event_type,
      actor: event.actor_type ? "#{event.actor_type}##{event.actor_id}" : nil,
      target: event.target_type ? "#{event.target_type}##{event.target_id}" : nil,
      data: parse_json(event.event_data),
      created_at: event.created_at
    }
  end

  def parse_json(json_string)
    return {} if json_string.nil? || json_string.empty?
    JSON.parse(json_string)
  rescue JSON::ParserError
    {}
  end
end
