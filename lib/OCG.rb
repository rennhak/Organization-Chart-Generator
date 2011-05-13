#!/usr/bin/ruby
#

# = Standard Libraries

# == OptionParser related
require 'optparse'
require 'optparse/time'
require 'ostruct'
require 'pp'

# == Config related
require 'yaml'

# == Custom includes
require 'Extensions.rb'

# == Gem's
require 'rubygems'        # foreign gem's
require 'mechanize'

# = OCG is the main class which handles commandline interface and other central tasks in order to
# extract the person data from the livingdreams.jp website.
class OCG # {{{

  def initialize options = nil # {{{
    @options  = options

    unless( options.nil? )
      message :debug, "Starting #{__FILE__} run"
      message :debug, "Colorizing output as requested" if( @options.colorize )

      ####
      # Main Control Flow
      ##########

      # Mandatory config file aquire (keep sensitive information away from being hardcoded here)
      raise ArgumentError, "Please specify the YAML config file for your project" if( @options.config_filename == "" )
      @config       = load_config( @options.config_filename )

      # Login and extract data from the webpages
      # Pass function ptr to use_cache function and use cache if possible or create new one for next call
      organization = use_cache( lambda { get_organization_information } )

      # Fix the missing information with knowledge from the YAML file
      organization  = insert_missing_information( organization )

      # Sort people into global groups and groups
      hierarchy     = sort_groups( organization )

      # TODO: Weighting of roles so that they receive a different height in their corresponding subgroup
      # Each name receives an importance weight which is defined in the YAML
      # weighted      = add_weight_to_names( hierarchy )

      # Generate dot content from extracted information and YAML
      # dot_content = generate_dot_from_organization_array( organization, @organization )

      # Generate dot content from extracted information and YAML
      dot_content = generate_dot( hierarchy, @organization )

      # Write to file
      write_file( dot_content )

      message( :debug, "End of #{__FILE__} run" )
    end # of unless( options.nil? )
  end # of initialize }}}


  # = Generic Caching Functions {{{

  # = The function use_cache tries to use the existing cache if possible, if not it will create one for later uses
  # @param function Function name of the function which returns us the data we want to use
  # @param file String, containing name and path of target cache file
  # @returns Ruby object from file which was deserialized or which was extracted by calling the function ptr.
  def use_cache function, file = @options.cache_file # {{{
    result = nil

    if( cached? )
      message( :debug, "Using already existing cache" )
      result = read_cache
    else
      message( :debug, "Old cache or not existing, recaching" )
      result = function.call
      write_cache result
    end

    result
  end # }}}

  # = The function re_cache forces a recache of the current cache not matter what state it is in.
  # @param file String, containing name and path of target cache file
  def re_cache object = get_organization_information, file = @options.cache_file  # {{{
    write_cache object
  end # }}}

  # = The function cached? checks wheather the cache file exists and is not too old (one day).
  # @param file String, containing name and path of target cache file
  # @returns Boolean, true if exists and is not too old, false if it doesn't exist or too old
  def cached? file = @options.cache_file, re_cache = @options.re_cache # {{{
    # Standard is false, so that only when cache is not too old and it exists it will be considered.
    result = false

    if( File.exists?( file ) )
      # check time and maybe cache it because to old
      if( Date.parse( File.stat( file ).mtime.to_s ).to_s == Date.jd(DateTime.now.jd).to_s )    # we cached it today
        message( :debug, "Cache is there and it is not too old." )
        result = true
      end
    end

    message( :debug, "Cache isn't there or it is too old" ) unless( result )

    if( re_cache )
      message( :debug, "Forcing re-cache of data" )
      result = false
    end

    result
  end # }}}

  # = The function write_cache takes an Ruby object and commits it to a /tmp/file for caching
  #   This is particularly good  during development.
  # @param object, Ruby object which we will serialize
  # @param file String, containing name and path of target cache file
  def write_cache object, file = @options.cache_file # {{{
    File.open( file, File::WRONLY|File::TRUNC|File::CREAT, 0666 ) { |f| Marshal.dump( object, f ) }
  end # }}}

  # = The function read_cache takes a filename and deserializes from this file the object into Ruby ObjectSpace.
  # @param file String, containing name and path of target cache file
  # @returns Ruby object from file which was deserialized
  def read_cache file = @options.cache_file # {{{
    result = nil
    File.open( file ) { |f| result = Marshal.load( f ) }                                   # load object from cache
    result
  end # }}}

  # end of Caching Functions }}}

  # = The sort_groups method takes the organization array and reshapes it according to the given YAML structure of "global groups" and "volunteer groups"
  # @param organization Array, containing the [ [name, role], ..] structure obtained from the get_organization_information function.
  # @param volunteers_groups OStruct Array, with subarrays, obtained from the YAML config file
  # @param global_groups OStruct Array with subarrays, obtained from the YAML config file
  # FIXME: This method is too complex
  def sort_groups organization = get_organization_information, volunteers_groups = @volunteers_groups, global_groups = @global_groups # {{{
    org       = organization.dup
    hierarchy = Hash.new

    global_groups.each do |gg|
      # Prepare Hierarchy Hash with global group keys
      global_group      = ( gg.methods - YAML::DefaultResolver.methods - OpenStruct.new.methods ).delete_if { |i| i =~ %r{=} }

      # Split along "_" and capitalize words
      global_group_pp               = global_group.to_s.gsub( "_", " " ).split( " " ).collect { |w| w.capitalize }.join( " " )
      hierarchy[ global_group_pp ]  = [] # push empty array to hash key

      roles_in_gg = eval( "gg.#{global_group}" )

      # Go over the gg ostruct content and search in organization array after the corresponding people and stuff them into the global groups hash
      org.collect! do |name, role|
        roles_in_gg.each do |r| 
          if(  role =~ %r{#{r.to_s}}i )
            hierarchy[ global_group_pp ] << [ name, role ] unless( name.nil? or role.nil? ) 
            name, role = nil, nil
          end # of if(
        end # of roles_in_gg.each

        [ name, role ]
      end # of organization.each
    end # of global_groups.each

    # failsafe in case the website changes and we get roles we didn't consider in the YAML
    raise ArgumentError, "The org array should be empty, seems there is a problem in the sorting algorithm." unless( org.flatten.compact.empty? )

    # FIXME: Change hardcoding into generic sort
    # Go through volunteers and sort them into subgroups
    # now we have an hash filled with the corresponding people but we still need to sort them into sub-groups
    # global group -> [ sub group -> pers1, pers2] ,... 
    volunteers      = hierarchy[ "Volunteers" ]
    volunteers_new  = Hash.new

    volunteers_groups.each do |vg|
      # Extract vg names 
      volunteer_group               = ( vg.methods - YAML::DefaultResolver.methods - OpenStruct.new.methods ).delete_if { |i| i =~ %r{=} }

      # Split along "_" and capitalize words
      volunteer_group_pp            = volunteer_group.to_s.gsub( "_", " " ).split( " " ).collect { |w| w.capitalize }.join( " " )
      roles_in_vg                   = eval( "vg.#{volunteer_group}" )

      volunteers_new[ volunteer_group_pp ] = []
      
      volunteers.each do |name, role|
        roles_in_vg.each do |r|
          if(  role =~ %r{#{r.to_s}}i )
            volunteers_new[ volunteer_group_pp ] << [ name, role ]
          end
        end # of roles_in_vg.each
      end # of volunteers.each
    end # of volunteers_groups

    # overwrite current volunteer entry with regrouped volunteer entry
    hierarchy[ "Volunteers" ] = volunteers_new

    hierarchy
  end # of sort_groups }}}

  # = The function "insert_missing_information" will go over the YAML file and insert missing
  # information not extracted directly from the HTML pages
  # @param organization Array of subarrays of the shape [[name1,role1],[name2,role2],..] from the
  #        function get_organization_information
  # @returns Array, containing subarrays of the structure [ [name1, role1], [name2,role2], ..]
  def insert_missing_information organization = get_organization_information, add_persons = @add_persons  # {{{
    result = organization.dup

    add_persons.each do |entry| 
      role    = ( entry.methods - YAML::DefaultResolver.methods - OpenStruct.new.methods ).delete_if { |i| i =~ %r{=} } 
      name    = eval( "entry.#{role.to_s}" )

      name.each do |n|
        # Split _, and capitalize words
        role_pp = role.to_s.gsub( "_", " " ).split( " " ).collect { |w| w.capitalize }.join( " " )

        result << [ n.to_s, role_pp.to_s ]
      end
    end

    result
  end # }}}

  # = The function "get_organization_information" logs into the website using the provided
  # credentials, then tries to extract all useful information from the tables in certain team lists.
  # @returns Array, containing subarrays of the structure [ [name1, role1], [name2,role2], ..]
  def get_organization_information # {{{

    message( :debug, "Logging into the Frontpage of PBWorks" )

    # login & get frontpage
    start_page = login

    message( :debug, "Crawling other pages" )

    # get team pages
    team_pages = []
    start_page.links.each do |link|
      # extract html with $name.body
      team_pages << get_page_content( link ) if( link.text.to_s =~ %r{Team List|Consultant}i )
    end # of @start_page.links.each do

    # get data from pages
    data = []
    team_pages.each do |page|
      data << get_data( page.body )
    end

    people = []

    data.each do |one_team_array|
      one_team_array.each_with_index do |one_person, op_index|
        # FIXME: We are currently only curious about name & role
        name, role = one_person[0], one_person[one_person.length - 2]

        # this person has a dual role
        if( role =~ %r{&} )
          r1, r2 = role.split( "&" )
          people << [ name, r1.chomp ]
          people << [ name, r2.chomp ]
        else
          people << [ name, role ]
        end
      end # of one_team_array.each..
    end # of one_team_array.each ...

    people
  end # }}}

  # = Generic write to file function, mostly used for dot files
  # @param data String, containing text data which should be written to file (separated by "\n"'s)
  # @param filename String, representing the filename and path were the file should be written
  def write_file data, filename = "/tmp/organization.dot"  # {{{
    File.open( filename, File::WRONLY|File::TRUNC|File::CREAT, 0666 ) do |f|
      f.write( data )
    end
  end # }}}

  # = The function generates a dot file from an simple array input containing names and role inside the team
  # @param hash, Cosisting of keys which are top groups, which either contain subgroups (volunteers key) or just names and roles as arrays
  # @returns String, dot file output
  def generate_dot hierarchy_hash, graph_name, global_groups_order = @global_groups_order # {{{
    # start processing
    result = []
    result << "digraph #{graph_name.gsub( " ", "_" )} {"
    result << "\tnodesep=1.0 // increases the separation between nodes"
    result << "\tedge [style=\"setlinewidth(1)\"];"
    result << "\trankdir = \"TB\""
    result << "\tsplines = true"
    result << "\tfontname = Helvetica"
    result << "\tconcentrate = true"
    result << "\tcenter = true"
    result << "\tcompound = true"
    result << "\tclusterrank = local"

    cnt = 0
    weight = 1

    # Create org node (top most node)
    result << ""
    result << "\t#{cnt.to_s} [label=\"#{graph_name.to_s}\" style=\"filled\" shape=\"triangle\" fillcolor=\"steelblue\" weight=\"#{weight.to_s}\"]"
    result << ""
    cnt += 1
    weight += 1

    # Use the invisible edge trick to orientate the graph
    # Create an arrow from org to founder (will be first anyway according to YAML spec)
    result << ""
    result << "\t#{(cnt-1).to_s} -> #{cnt.to_s} [style=\"invis\"]"
    result << "\t#{(cnt-1).to_s} -> #{(cnt+1).to_s} [style=\"invis\"]"
    result << ""

    # store the dot labels here (we use simple ints for that)
    roles = Hash.new
    names = Hash.new

    # Create clusters according to global_groups_order
    global_groups_order.each do |gg|

      # Subgraph Header
      result << "subgraph cluster_#{gg.to_s.downcase} {"
      result << "\tstyle = filled"
      result << "\tbgcolor = lemonchiffon"
      result << "\tlabel = \"#{gg.to_s}\""
      result << "\trankdir = \"TB\""
      result << "\tsplines = true"
      result << "\tfontname = Helvetica"
      result << "\tconcentrate = true"
      result << "\tcenter = true"
      result << "\tcompound = true"
      result << ""

      # Subgraph Data
      if( gg.to_s == "Volunteers" )
        # Volunteers are still more divided into subgroups

        # roles that are in the volunteer group
        v_group_hash  = hierarchy_hash[ gg.to_s ]
        v_groups      = v_group_hash.keys

        # Create labels for volunteer groups
        hierarchy_hash[ gg ].keys.each do |role|
          unless( roles.keys.include?( role ) )
            result << "\t#{cnt.to_s} [label=\"#{role.to_s}\" style=\"filled\" shape=\"trapezium\" fillcolor=\"greenyellow\" weight=\"#{weight.to_s}\"]"
            roles[ role.to_s ] = cnt
            cnt += 1
          end
        end

        # Create labels for titles of people
        hierarchy_hash[ gg ].keys.each do |group|
          hierarchy_hash[ gg ][ group ].each do |name, role|
            unless( roles.keys.include?( role ) )
              result << "\t#{cnt.to_s} [label=\"#{role.to_s}\" style=\"filled\" shape=\"box\" fillcolor=\"lightblue\" weight=\"#{weight.to_s}\"]"
              roles[ role.to_s ] = cnt
              cnt += 1
            end
          end # end of hierarchy_hash[ gg ][ group ].eachf 
        end

        # Create labels for names of people
        hierarchy_hash[ gg ].keys.each do |group|
          hierarchy_hash[ gg ][ group ].each do |name, role|
            unless( names.keys.include?( name ) )
              result << "\t#{cnt.to_s} [label=\"#{name.to_s}\" style=\"filled\" shape=\"egg\" fillcolor=\"steelblue\" weight=\"#{weight.to_s}\"]"
              names[ name.to_s ] = cnt
              cnt += 1
            end
          end # end of hierarchy_hash[ gg ][ group ].eachf 
        end

        # Edges from subgroup to title
        done = Hash.new
        hierarchy_hash[ gg ].keys.each do |group|
          hierarchy_hash[ gg ][ group ].each do |name, role|
            unless( done[ role ] )
              result << "\t#{roles[ group ].to_s} -> #{roles[ role ].to_s}"
              done[ role ] = true
            end
          end
        end

        # Edges from title to person
        done = Hash.new
        hierarchy_hash[ gg ].keys.each do |group|
          hierarchy_hash[ gg ][ group ].each do |name, role|
              result << "\t#{roles[ role ].to_s} -> #{names[ name ].to_s}"
          end
        end

      else

        # Create labels for roles
        hierarchy_hash[ gg ].each do |name, role|
          unless( roles.keys.include?( role ) )
            result << "\t#{cnt.to_s} [label=\"#{role.to_s}\" style=\"filled\" shape=\"box\" fillcolor=\"lightblue\" weight=\"#{weight.to_s}\"]"
            roles[ role.to_s ] = cnt
            cnt += 1
          end
        end

        # Create labels for names
        hierarchy_hash[ gg ].each do |name, role|
          unless( names.keys.include?( name ) )
            result << "\t#{cnt.to_s} [label=\"#{name.to_s}\" style=\"filled\" shape=\"egg\" fillcolor=\"steelblue\" weight=\"#{weight.to_s}\"]"
            names[ name.to_s ] = cnt
            cnt += 1
          end
        end

        # Create arrows
        hierarchy_hash[ gg ].each do |name, role|
          # Create arrows
          result << "\t#{roles[ role ].to_s} -> #{names[ name ].to_s}"
        end # of hierarchy_hash[ gg ]
      end

      # Closing
      result << "}"
      weight += 1
    end # of global_groups_order


    result << ""
    result << ""

    # Invisible edges
    # FIXME: This is messy find a better approach
    global_groups_order.each_with_index do |outer_gg, outer_index|
      global_groups_order.each_with_index do |inner_gg, inner_index|
        if( outer_index != inner_index ) # make sure we are not at the same node
          if( (outer_index + 1)  == inner_index ) # make sure we always have outer (e.g. 0) and inner (e.g. 1) (always the direct next)
          
            if( inner_gg == "Volunteers" )
              source = hierarchy_hash[ outer_gg ].collect { |name, title| name }
              target = hierarchy_hash[ inner_gg ].keys

              source.each do |name|
                target.each do |title|
                  result << "\t#{names[name].to_s} -> #{roles[title].to_s} [style=\"invis\"]"
                end # of target.each do |title|
              end # of source.each do |name|
            else
              source = hierarchy_hash[ outer_gg ].collect { |name, title| name }
              target = hierarchy_hash[ inner_gg ].collect { |name, title| title }

              source.each do |name|
                target.each do |title|
                  result << "\t#{names[name].to_s} -> #{roles[title].to_s} [style=\"invis\"]"
                end # of target.each do |title|
              end # of source.each do |name|

            end # of if( inner_gg == "Volunteers" )
          end # of if( (outer_index + 1) == inner_index )
        end # of if( outer_index != inner_index
      end # of global_groups_order.each do |inner
    end # of global_groups_order.each do |outer


    # end processing
    result << "}"
    result.join( "\n" )
  end # of def generate_dot }}}


  # = The function generates a dot file from an simple array input containing names and role inside the team
  # @param array Cosisting of [ [name1, role1], [name2, role2],...]
  # @returns String, dot file output
  # FIXME: We currently expect a hardcoded structure in the array, change this to a more flexible approach
  def generate_dot_from_organization_array array, graph_name # {{{
    # start processing
    result = []
    result << "digraph #{graph_name.gsub( " ", "_" )} {"
    result << "\tnodesep=1.0 // increases the separation between nodes"
    result << "\tedge [style=\"setlinewidth(1)\"];"

    # FIXME: Change this from quickhack to real code
    # create labels
    roles = []; array.each { |name, role| roles << role; }
    roles = roles.uniq
    roles.each_with_index { |role, index| result << "\t#{index.to_s} [label=\"#{role}\" style=\"filled\" shape=\"box\" fillcolor=\"lightblue\"]" }

    # people
    cnt = roles.length 
    array.each { |name, role| result << "\t#{cnt.to_s} [label=\"#{name}\" style=\"filled\" shape=\"egg\" fillcolor=\"lightgrey\"]"; cnt += 1; }

    # data
    cnt = roles.length 
    array.each { |name, role| result << "#{roles.index(role)} -> #{cnt.to_s};"; cnt += 1  }

    # end processing
    result << "}"
    result.join( "\n" )
  end # of def generate_dot }}}

  # = The function get_data will extract the useful team member data from the current schema used in the wiki
  # @param html_page String, containing the html page with the team information for each subsection
  # @warning This method will break if the table formatting in the wiki changes significantly.
  # @fixme This method currently only extracts the first line which contains the name
  def get_data html_page # {{{
    doc = Nokogiri::HTML( html_page )

    page_data = []

    doc.xpath( '//div[@id="wikipage-inner"]/table/tbody/tr' ).each do |node|
      # FIXME: Probably we can realize this smarter..
      inner_doc = Nokogiri::HTML( node.to_html )

      # name, contact, email, title, children
      row_data = []

      inner_doc.xpath( '//td' ).each_with_index do |inner_node, index|
        # puts "#{index.to_s} | #{inner_node.to_s}"
        row_data[ index ] = inner_node.content
      end # of inner_doc.xpath

      page_data << row_data
    end # of doc.xpath

    # get rid of this line: "["NAME", "CONTACT INFO", "EMAIL ADDRESS", "TITLE", "CHILDREN'S HOME"]"
    page_data.shift

    # the data is currently unfiltered and multi column
    # FIXME: we are currently only interested in name and title
    # FIXME: This method is ugly rewrite
    selected_data = []
    page_data.each do |array|
      name = array.first.dup

      next if( name =~ %r{TBD}i ) 

      # filter out newlines and unicode junk
      name = name.gsub( /\n/, "" )
      n = name.remove_non_ascii

      next if( n == "" )
      next if( n =~ %r{project|Family|International|Design|Wish}i )

      # Split camelcase in case we concatednated to far due to unicode stuff
      n = n.split(/(?=[A-Z])/).join( " " ).gsub( "  ", " " )

      array[0] = n
      array.collect! { |i| i.remove_non_ascii }

      selected_data << array
    end

    selected_data
  end # }}}

  # = Logs into PBWorks workspace and takes care of getting a cookie etc.
  # @param url String, containing the base url of the PBWorks workspace we are interested in
  # @returns Curb Curl Object and cookie array for future use
  # @warning This method will break if the login way or the HTML code is significantly changed
  def login url = @base_url, login = @login_url, username = @username, password = @password # {{{
    fqdn              = url + login
    m                 = Mechanize.new
    result            = nil

    m.get( fqdn ) do |page|

      # Submit login form
      start_page      = page.form_with( :action => 'https://my.pbworks.com/m/accept-credentials/pbworks' ) do |f|
        f.u_email     = username
        f.u_password  = password
      end.click_button

      result = start_page
    end

    result
  end # }}}

  # = Follows a given mechanize link and returns the content of that page for further processing
  # @param link Mechanize link object (already logged in - after the "login" function)
  # @returns Mechanize object with the content of the link clicked
  def get_page_content link # {{{
    page = link.click
  end # }}}

  # = Loads a YAML config for this project
  # @param filename String, containing the fully qualified filename and path to the config
  # @returns OpenStruct, containing the loaded YAML data (Hash->Ostruct)
  def load_config filename = @options.config_file # {{{
    raise ArgumentError, "No configuration filename provided." if( filename.nil? or filename == "" )

    config = File.open( filename, "r" ) { |file| YAML.load( file ) }                 # return proc which is in this case a hash

    # Simplify the mapping from @config to internal, get all ostruct methods and create instance vars from them locally
    # Checks for shadow variable problem and empty username/password {{{
    methods = ( config.methods - YAML::DefaultResolver.methods - OpenStruct.new.methods ).delete_if { |i| i =~ %r{=} }
    methods.each do |m| 
      raise ArgumentError, "Can't create dynamical variable from YAML file, since it already exists internally (YAML: #{m.to_s}, Internal: @#{m.to_s})" if( self.instance_variables.include?( "@#{m.to_s}" ) )
      self.instance_variable_set( "@#{m.to_s}", eval( "config.#{m}" ) )

      # Fix important variables such as username & password in case they are empty
      raise ArgumentError, "Please provide username & password either in the config file or via command line options" if( ( @options.username == "" and @username == "" ) or ( @options.password == "" and @password == "" ) )
      @username = @options.username if( @username == "" )
      @password = @options.password if( @password == "" )

      config
    end # }}}
  end # }}}

  # = The function 'parse_cmd_arguments' takes a number of arbitrary commandline arguments and parses them into a proper data structure via optparse
  # @param args Ruby's STDIN.ARGS from commandline
  # @returns Ruby optparse package options hash object
  def parse_cmd_arguments( args ) # {{{
    options                           = OpenStruct.new

    # Define default options
    options.verbose                   = false
    options.clean                     = false
    options.colorize                  = false
    options.re_cache                  = false
    options.config_filename           = ""
    options.username                  = ""
    options.password                  = ""
    options.cache_file                = "/tmp/#{__FILE__.gsub("\./","").gsub("\.", "_")}.cache"

    pristine_options                  = options.dup

    opts                              = OptionParser.new do |opts|
      opts.banner                     = "Usage: #{__FILE__.to_s} [options]"

      opts.separator ""
      opts.separator "General options:"


      opts.separator ""
      opts.separator "Specific options:"


      # Boolean switch.
      opts.on("-v", "--verbose", "Run verbosely") do |v|
        options.verbose = v
      end

      # Boolean switch.
      opts.on("-d", "--debug", "Run in debug mode") do |d|
        options.debug = d
      end

      # Boolean switch.
      opts.on("-r", "--re-cache", "Force a re-cache of the data") do |r|
        options.re_cache = r
      end


      # Boolean switch.
      opts.on("-q", "--quiet", "Run quietly, don't output much") do |q|
        options.quiet = q
      end

      opts.separator ""
      opts.separator "Common options:"

      opts.on("--config FILENAME", "Load the given YAML config file") do |filename|
        options.config_filename = filename
      end

      opts.on("-u", "--username USERNAME", "Use the given username to login") do |u|
        options.username = u
      end

      opts.on("-p", "--password PASSWORD", "Use the given password to login") do |p|
        options.password = p
      end

      # Boolean switch.
      opts.on("-c", "--colorize", "Colorizes the output of the script for easier reading") do |c|
        options.colorize = c
      end

      # Boolean switch.
      opts.on("-u", "--use-cache", "Use cached/archived files instead of downloading/processing again") do |u|
        options.cache = u
      end

      # Boolean switch.
      opts.on( "--clean", "Cleanup after the script and remove things not needed") do |c|
        options.clean = c
      end

      opts.on_tail("-h", "--help", "Show this message") do
        puts opts
        exit
      end

      # Another typical switch to print the version.
      opts.on_tail("--version", "Show version") do
        puts OptionParser::Version.join('.')
        exi.sortt
      end
    end

    opts.parse!(args)

    # Show opts if we have no cmd arguments
    if( options == pristine_options )
      puts opts
      puts ""
    end

    options
  end # of parse_cmd_arguments }}}

  # = The function colorize takes a message and wraps it into standard color commands such as for bash.
  # @param color String, of the colorname in plain english. e.g. "LightGray", "Gray", "Red", "BrightRed"
  # @param message String, of the message which should be wrapped
  # @returns String, colorized message string
  # WARNING: Might not work for your terminal
  # FIXME: Implement bold behavior
  # FIXME: This method is currently b0rked
  def colorize color, message # {{{

    # Black       0;30     Dark Gray     1;30
    # Blue        0;34     Light Blue    1;34
    # Green       0;32     Light Green   1;32
    # Cyan        0;36     Light Cyan    1;36
    # Red         0;31     Light Red     1;31
    # Purple      0;35     Light Purple  1;35
    # Brown       0;33     Yellow        1;33
    # Light Gray  0;37     White         1;37

    colors  = { 
      "Gray"        => "\e[1;30m",
      "LightGray"   => "\e[0;37m",
      "Cyan"        => "\e[0;36m",
      "LightCyan"   => "\e[1;36m",
      "Blue"        => "\e[0;34m",
      "LightBlue"   => "\e[1;34m",
      "Green"       => "\e[0;32m",
      "LightGreen"  => "\e[1;32m",
      "Red"         => "\e[0;31m",
      "LightRed"    => "\e[1;31m",
      "Purple"      => "\e[0;35m",
      "LightPurple" => "\e[1;35m",
      "Brown"       => "\e[0;33m",
      "Yellow"      => "\e[1;33m",
      "White"       => "\e[1;37m"
    }
    nocolor    = "\e[0m"

    colors[ color ] + message + nocolor
  end # of def colorize }}}

  # = The function message will take a message as argument as well as a level (e.g. "info", "ok", "error", "question", "debug", "warning") which then would print 
  #   ( "(--) msg..", "(II) msg..", "(EE) msg..", "(??) msg.. (WW) msg.."people)
  # @param level Ruby symbol, can either be :info, :success, :error or :question, :warning
  # @param msg String, which represents the message you want to send to stdout (info, ok, question) stderr (error)
  # Helpers: colorize
  def message level, msg # {{{

    symbols = {
      :info      => "(--)",
      :success   => "(II)",
      :error     => "(EE)",
      :question  => "(??)",
      :debug     => "(++)",
      :warning   => "(WW)"
    }

    raise ArugmentError, "Can't find the corresponding symbol for this message level (#{level.to_s}) - is the spelling wrong?" unless( symbols.key?( level )  )

    if( @options.colorize )
      if( level == :error )
        STDERR.puts colorize( "LightRed", "#{symbols[ level ].to_s} #{msg.to_s}" )
      else
        STDOUT.puts colorize( "LightGreen", "#{symbols[ level ].to_s} #{msg.to_s}" ) if( level == :success )
        STDOUT.puts colorize( "LightCyan", "#{symbols[ level ].to_s} #{msg.to_s}" ) if( level == :question )
        STDOUT.puts colorize( "Brown", "#{symbols[ level ].to_s} #{msg.to_s}" ) if( level == :info )
        STDOUT.puts colorize( "LightBlue", "#{symbols[ level ].to_s} #{msg.to_s}" ) if( level == :debug and @options.debug )
        STDOUT.puts colorize( "Yellow", "#{symbols[ level ].to_s} #{msg.to_s}" ) if( level == :warning )
      end
    else
      if( level == :error )
        STDERR.puts "#{symbols[ level ].to_s} #{msg.to_s}" 
      else
        STDOUT.puts "#{symbols[ level ].to_s} #{msg.to_s}" if( level == :success )
        STDOUT.puts "#{symbols[ level ].to_s} #{msg.to_s}" if( level == :question )
        STDOUT.puts "#{symbols[ level ].to_s} #{msg.to_s}" if( level == :info )
        STDOUT.puts "#{symbols[ level ].to_s} #{msg.to_s}" if( level == :debug and @options.debug )
        STDOUT.puts "#{symbols[ level ].to_s} #{msg.to_s}" if( level == :warning )
      end
    end # of if( @config.colorize )

  end # of def message }}}

end # of class OCG }}}


# = Direct invocation {{{
if __FILE__ == $0

  options = OCG.new.parse_cmd_arguments( ARGV )
  ocg     = OCG.new( options )

end # of if __FILE__ == $0 }}}

