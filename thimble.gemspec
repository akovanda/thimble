Gem::Specification.new do |s|
  s.name        = 'thimble'
  s.version     = '0.1.0'
  s.date        = '2017-04-11'
  s.summary     = "Concurrency and Parallelism gem that uses blocks to move data"
  s.description = "Thimble is a ruby gem for parallelism and concurrency. It allows you to decide if you want to use separate processes, or if you want to use threads in ruby. It allows you to create stages with a thread safe queue, and break apart large chunks of work."
  s.authors     = ["Andrew Kovanda"]
  s.email       = 'andrew.kovanda@gmail.com'
  s.files       = `git ls-files lib MIT-LICENSE.txt`.split("\n")
  s.homepage    = 'https://github.com/akovanda/thimble'
  s.license     = 'MIT'
end
