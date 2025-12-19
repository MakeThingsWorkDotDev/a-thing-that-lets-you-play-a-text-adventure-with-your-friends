# frozen_string_literal: true

# Manages quests and objectives
module QuestManager

  def create_quest(world_id, room_id, attributes)
    quest = Quest.create(
      world_id: world_id,
      room_id: room_id,
      name: attributes[:name],
      description: attributes[:description],
      quest_type: attributes[:quest_type] || 'main',
      status: 'active'
    )

    log(world_id, 'quest_created', {
      room_id: room_id,
      target_type: 'Quest',
      target_id: quest.id,
      event_data: { quest_type: quest.quest_type }.to_json
    })

    { success: true, quest_id: quest.id }
  end

  def add_quest_objective(quest_id, attributes)
    quest = Quest[quest_id]
    return { error: 'Quest not found' } unless quest

    objective = QuestObjective.create(
      quest_id: quest_id,
      objective_type: attributes[:objective_type],
      target_type: attributes[:target_type],
      target_id: attributes[:target_id],
      quantity: attributes[:quantity] || 1,
      description: attributes[:description],
      is_optional: attributes[:is_optional] || false
    )

    { success: true, objective_id: objective.id }
  end

  def complete_objective(objective_id)
    objective = QuestObjective[objective_id]
    return { error: 'Objective not found' } unless objective

    objective.update(
      is_completed: true,
      current_progress: objective.quantity
    )

    # Check if all quest objectives are complete
    quest = objective.quest
    if quest.all_objectives_complete?
      quest.update(status: 'completed', completed_at: Time.now)

      log(quest.world_id, 'quest_completed', {
        room_id: quest.room_id,
        target_type: 'Quest',
        target_id: quest.id,
        event_data: { quest_name: quest.name }.to_json
      })
    end

    log(quest.world_id, 'objective_completed', {
      room_id: quest.room_id,
      target_type: 'QuestObjective',
      target_id: objective_id,
      event_data: { quest_id: quest.id, objective_type: objective.objective_type }.to_json
    })

    { success: true, quest_completed: quest.status == 'completed' }
  end

  def update_objective_progress(objective_id, progress)
    objective = QuestObjective[objective_id]
    return { error: 'Objective not found' } unless objective

    old_progress = objective.current_progress
    new_progress = [progress, objective.quantity].min

    objective.update(current_progress: new_progress)

    # Auto-complete if progress reached quantity
    if new_progress >= objective.quantity && !objective.is_completed
      complete_objective(objective_id)
    end

    { success: true, current_progress: new_progress, quantity: objective.quantity }
  end

  def get_active_quests(room_id)
    quests = Quest.where(room_id: room_id, status: 'active').all.map do |quest|
      quest_summary(quest)
    end

    { quests: quests, count: quests.length }
  end

  def get_quest_details(quest_id)
    quest = Quest[quest_id]
    return { error: 'Quest not found' } unless quest

    { quest: quest_summary(quest) }
  end

  def check_quest_progress(quest_id)
    quest = Quest[quest_id]
    return { error: 'Quest not found' } unless quest

    objectives = quest.quest_objectives.map do |obj|
      {
        id: obj.id,
        description: obj.description,
        progress: "#{obj.current_progress}/#{obj.quantity}",
        is_completed: obj.is_completed,
        is_optional: obj.is_optional
      }
    end

    all_complete = quest.all_objectives_complete?

    {
      quest_id: quest.id,
      quest_name: quest.name,
      status: quest.status,
      all_objectives_complete: all_complete,
      objectives: objectives
    }
  end

  private

  def quest_summary(quest)
    objectives = quest.quest_objectives.map do |obj|
      {
        id: obj.id,
        description: obj.description,
        progress: "#{obj.current_progress}/#{obj.quantity}",
        is_completed: obj.is_completed,
        is_optional: obj.is_optional
      }
    end

    {
      id: quest.id,
      name: quest.name,
      description: quest.description,
      quest_type: quest.quest_type,
      status: quest.status,
      objectives: objectives
    }
  end
end
