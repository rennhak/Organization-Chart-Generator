#!/usr/bin/ruby
#

# = Standard Libraries
require 'optparse'

# = OCG is the main class which handles commandline interface and other central tasks
class OCG # {{{

  def initialize options
    @options = options

    # bla if( @options[ :foo ] )

  end # of initialize }}}


  # = The formatting helper function takes care of returning properly formatted strings 
  # @param text String, text to display in the formatting
  # @returns String, with the formatted content which various show_* functions display.
  # @helpers percentage_of, generate_bar
  def formatting text, color = false # {{{

    if( @options[:raw] )
      stack << [ "%s", text                                                             ]  if( @options[ :text     ] )
      stack << [ "%s", value                                                            ]  if( @options[ :value    ] )
      stack << [ "%s", generate_bar( percentage )                                       ]  if( @options[ :bar      ] )
      stack << [ "%s", percentage                                                       ]  if( @options[ :percent  ] )
    else
      stack << [ "[ %-25s ]", text                                                      ]  if( @options[ :text     ] )
      stack << [ "[ %10s ]", value                                                      ]  if( @options[ :value    ] )

      if( @options[:color] )
        color_end                   = "\e[0m"
        green, yellow, red, blink   = "\e[1;32m", "\e[1;33m", "\e[1;31m", "\e[5;31m"
        high, medium, low           = 70, 35, 12

        color = green   if( percentage >= high )
        color = yellow  if( (percentage < high) and (percentage >= medium) )
        color = red     if( (percentage < medium) && ( percentage >= low ) )
        color = blink   if( percentage < low )

        stack << [ "[ %-100s ]", color + generate_bar( percentage ) + color_end         ]  if( @options[ :bar      ] )
        stack << [ "[ %3s ]", color + percentage.to_s + " Percent" + color_end          ]  if( @options[ :percent  ] )
      else
        stack << [ "[ %-100s ]", generate_bar( percentage )                             ]  if( @options[ :bar      ] )
        stack << [ "[ %3s Percent ]", percentage                                        ]  if( @options[ :percent  ] )
      end # of if( @option[:color] )
    end # of if( @options[:raw] )

    format  = stack.transpose.first.join(" ")
    values  = stack.transpose.last
    sprintf( format, *values )
  end # of def formatting }}}


end # of class OCG }}}


# = Direct invocation {{{
if __FILE__ == $0

  options = {}
  OptionParser.new do |opts|
    opts.banner = "Usage: OCG.rb [options]"

    opts.on("-v", "--[no-]verbose", "Run verbosely") do |v|
      options[:verbose]   = v
    end

    opts.on("-c", "--color", "Colorize all output") do |c|
      options[:color]   = c
    end
  end.parse!


  if( options.empty? )
    raise ArgumentError, "Please try '-h' or '--help' to view all possible options"
  end

  ocg = OCG.new( options )

end # of if __FILE__ == $0 }}}

