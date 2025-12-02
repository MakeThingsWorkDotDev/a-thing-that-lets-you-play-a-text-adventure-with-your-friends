# frozen_string_literal: true

class DiceRoll
  VALID_DICE = %w[4 6 8 10 12 20 100].freeze
  attr_accessor :result_dice, :modifiers

  def initialize(argument_string)
    arguments = argument_string.scan(/(\d{1,2}d\d{1,2})|([-+]\d{1,2})/)
    dice_strings = arguments.filter_map(&:first)
    modifiers = arguments.filter_map(&:last)

    @modifiers = modifiers.nil? ? [] : modifiers
    @result_dice = parse_dice_strings(dice_strings)
  end

  def parse_dice_strings(dice_strings)
    rolls = []

    dice_strings.each do |dice_string|
      next unless dice_string.include?("d")

      count, die = dice_string.split("d")
      next unless VALID_DICE.include?(die) || count.to_i&.zero?

      rolls << [count, die]
    end

    results = []
    rolls.each do |roll|
      roll.first.to_i.times do
        results << [rand(1..roll.last.to_i), roll.last]
      end
    end

    results
  end

  def modifiers_total
    return 0 if @modifiers.nil?

    @modifiers.sum(&:to_i)
  end

  def total
    dice_total = @result_dice.sum(&:first)
    dice_total + modifiers_total
  end
end
