# frozen_string_literal: true

require 'securerandom'

module Thimble
  class QueueItem
    attr_reader :id, :item

    def initialize(item, name = 'Item')
      @id = SecureRandom.uuid
      @item = item
      @name = name
    end

    def to_s
      "#{@name}: #{@item} ID: #{@id}"
    end
  end
end
