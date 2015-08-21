class Context
  attr_reader :pids, :batchSize, :queueSize
  def initialize(pids: 6,batchSize: 1000, queueSize: 1000)
    @pids = pids
    @batchSize = batchSize
    @queueSize = queueSize
  end

  def self.deterministic
    self.new(pids: 1, batchSize: 1, queueSize: 1)
  end

  def self.small
    self.new(pids: 1, batchSize: 3, queueSize: 3)
  end
end