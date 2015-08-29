require_relative 'ThimbleQueue'
require_relative 'Context'
require_relative 'Thimble'
# Here we will managed the Processes doing the actual work.

class ThimbleManager < Thimble
  attr_reader :context, :resultQueue,
  def initialize(context, array)
    @context = context
    super(array)
  end

  def process
    
  end

  def parMap

  end


end

m = ThimbleManager.new(Context.small, (1..20000).to_a)
m.close(false)
m.process

