# Thimble
Thimble is a ruby gem for pararrelism and conconcurrency.  It allows you to decide if you want to use separate processes, or if you want to use threads in ruby.  
____
### Example
```
  require 'thimble'
    
  manager = Thimble::Manager.new(max_workers: 5, batch_size: 5, queue_size: 10, worker_type: :fork)
  thimble = Thimble::Thimble.new((1..100).to_a, manager)
  results = thimble.par_map do |x|
    x * 1000
  end 
```

You must pass an explicit manager to your thimble.  They can be used in multiple thimbles at the same time.  

batch_size is how many chunks of work you will send with the worker.
