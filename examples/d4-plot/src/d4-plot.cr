require "option_parser"
require "./d4_plot/app"

OptionParser.parse do |parser|
  parser.banner = "Usage: d4-plot [file.d4 [chromosome:start-end]]"
  parser.on("-h", "--help", "Show usage") { puts parser; exit }
end
abort "Usage: d4-plot [file.d4 [chromosome:start-end]]" if ARGV.size > 2
UIng.init
menu_items = D4Plot::App.create_menu_bar
D4Plot::App.new(menu_items).run(ARGV[0]?, ARGV[1]?)
