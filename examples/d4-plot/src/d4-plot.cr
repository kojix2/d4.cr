require "./d4_plot/app"

if ARGV.size > 0
  puts "Usage: #{PROGRAM_NAME}"
  puts "This is a GUI application. Run without arguments."
  exit 1
end

UIng.init
menu_items = D4Plot::App.create_menu_bar
D4Plot::App.new(menu_items).run
