def debug(*args, **kwargs)
  ENV['DEBUG'] == 'true' && STDERR.puts(*args, **kwargs)
end
