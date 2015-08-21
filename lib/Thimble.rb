
require_relative 'Context.rb'
require_relative 'ThimbleQueue'

module Thimble
  attr_reader :work, :context
  # Work is the array of values to be worked on (anything)
  def Thimble.prep(context: Context.new)
    @context = context
  end

  def Thimble.map(work)
    @work = ThimbleQueue.new(work.length, work)
    @context = Context.new if @context.nil?
    raise "work is not iterable!" unless work.respond_to? :each
    work.map { |e| yield e }
  end
end

