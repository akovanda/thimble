class Workload
  def initialize(start, stop, workLoadSize)
    @start = start
    @stop = stop
    @workLoadSize = workLoadSize
    @className = "ProcessingWork"
  end

  def workLoadSize
    @workLoadSize
  end

  def className
    @className
  end

  def start
    @start
  end

  def stop
    @stop
  end
end