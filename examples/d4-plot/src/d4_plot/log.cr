module D4Plot
  module Log
    PREFIX = "[d4-plot]"

    def self.info(message : String)
      STDOUT.puts "#{PREFIX} #{message}"
    end

    def self.error(message : String)
      STDERR.puts "#{PREFIX} #{message}"
    end
  end
end
