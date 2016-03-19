Gem::Specification.new do |s|
  s.name        = 'thimble'
  s.version     = '0.0.3'
  s.date        = '2016-03-15'
  s.summary     = "Concurrency and Parallelism gem that uses blocks to move data"
  s.description = "Pass a block and get some results"
  s.authors     = ["Andrew Kovanda"]
  s.email       = 'andrew.kovanda@gmail.com'
  s.files       = `git ls-files lib MIT-LICENSE.txt`.split("\n")
  s.homepage    = 'https://github.com/akovanda/thimble'
  s.license     = 'MIT'
end
