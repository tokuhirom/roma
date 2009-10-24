#!/usr/bin/env ruby
# -*- coding: utf-8 -*-
#
require 'optparse'
require 'roma/config'
require 'roma/version'
require 'roma/stats'
require 'roma/cron'
require 'roma/command_plugin'
require 'roma/async_process'
require 'roma/write_behind'
require 'roma/logging/rlogger'
require 'roma/command/receiver'
require 'roma/messaging/con_pool'
require 'roma/event/con_pool'
require 'roma/routing/routing_data'
require 'timeout'

module Roma
  
  class Romad
    include Cron
    include AsyncProcess
    include WriteBehindProcess

    attr :storages
    attr :rttable
    attr :stats

    attr_accessor :eventloop

    def initialize(argv = nil)
      @stats = Roma::Stats.instance
      initialize_stats
      options(argv)
      initialize_logger
      initialize_rttable
      initialize_storages
      initialize_cron
      initialize_handler
      initialize_plugin
      initialize_wb_witer
    end

    def start
      if node_check(@stats.ap_str)
        @log.error("#{@stats.ap_str} is already running.")
        return
      end

      @storages.each{|hashname,st|
        st.opendb
      }
      
      start_async_process
      start_wb_process
      timer

      @eventloop = true
      while(@eventloop)
        @eventloop = false
        begin
          EventMachine::run do
            EventMachine.start_server('0.0.0.0', @stats.port, 
                                      Roma::Command::Receiver,
                                      @storages, @rttable)

            @log.info("Now accepting connections on address #{@stats.address}, port #{@stats.port}")
            EventMachine.add_periodic_timer(60) { cron }
          end
        rescue =>e
          @log.error("#{e}\n#{$@}")
          retry
        end
      end
      stop_async_process
      stop_wb_process
      stop
    end

    def daemon?; @stats.daemon; end

    private

    def initialize_stats
      if Roma::Config.const_defined? :REDUNDANT_ZREDUNDANT_SIZE
        @stats.size_of_zredundant = Roma::Config::REDUNDANT_ZREDUNDANT_SIZE
      end
    end

    def initialize_wb_witer
      @wb_writer = Roma::WriteBehind::FileWriter.new(
                                                     Roma::Config::WRITEBEHIND_PATH, 
                                                     Roma::Config::WRITEBEHIND_SHIFT_SIZE,
                                                     @log)
    end

    def initialize_plugin
      return unless Roma::Config.const_defined? :PLUGIN_FILES

      Roma::Config::PLUGIN_FILES.each do|f|
        require "roma/plugin/#{f}"
        @log.info("roma/plugin/#{f} loaded")
      end
      Roma::CommandPlugin.plugins.each do|plugin|
          Roma::Command::Receiver.class_eval do
            include plugin
          end
          @log.info("#{plugin.to_s} included")
      end
    end

    def initialize_handler
      return if @stats.verbose==false

      Roma::Event::Handler.class_eval{
        alias gets2 gets
        undef gets
        
        def gets
          ret = gets2
          @log.info("command log:#{ret.chomp}") if ret
          ret
        end
      }
    end

    def initialize_logger
      Roma::Logging::RLogger.create_singleton_instance("#{Roma::Config::LOG_PATH}/#{@stats.ap_str}.log",
                                                       Roma::Config::LOG_SHIFT_AGE,
                                                       Roma::Config::LOG_SHIFT_SIZE)
      @log = Roma::Logging::RLogger.instance
    end

    def options(argv)
      opts = OptionParser.new
      opts.banner="usage:#{File.basename($0)} [options] address"

      @stats.daemon = false
      opts.on("-d","--daemon") { |v| @stats.daemon = true }

      opts.on_tail("-h", "--help", "Show this message") {
        puts opts; exit
      }

      opts.on("-j","--join [address:port]") { |v| @stats.join_ap = v }

      @stats.port = Roma::Config::DEFAULT_PORT.to_s
      opts.on("-p", "--port [PORT]") { |v| @stats.port = v }

      @stats.start_with_failover = false
      opts.on(nil,"--start_with_failover"){ |v| @stats.start_with_failover = true }

      @stats.verbose = false
      opts.on(nil,"--verbose"){ |v| @stats.verbose = true }

      opts.on_tail("-v", "--version", "Show version") {
        puts "romad.rb #{Roma::VERSION}"; exit
      }
      
      @stats.name = Roma::Config::DEFAULT_NAME
      opts.on("-n", "--name [name]") { |v| @stats.name = v }

      @stats.enabled_repetition_host_in_routing = false
      opts.on(nil,"--enabled_repeathost"){ |v|
        @stats.enabled_repetition_host_in_routing = true
      }

      opts.parse!(argv)
      raise OptionParser::ParseError.new if argv.length < 1
      @stats.address = argv[0]

      unless @stats.port =~ /^\d+$/
        raise OptionParser::ParseError.new('Port number is not numeric.')
      end
      
      @stats.join_ap.sub!(':','_') if @stats.join_ap
      if @stats.join_ap && !(@stats.join_ap =~ /^.+_\d+$/)
        raise OptionParser::ParseError.new('[address:port] can not parse.')
      end
    rescue OptionParser::ParseError => e
      $stderr.puts e.message
      $stderr.puts opts.help
      exit 1
    end

    def initialize_storages
      @storages = {}
      if Config.const_defined? :STORAGE_PATH
        path = "#{Roma::Config::STORAGE_PATH}/#{@stats.ap_str}"
      end
      
      if Config.const_defined? :STORAGE_CLASS
        st_class = Config::STORAGE_CLASS
      end

      if Config.const_defined? :STORAGE_DIVNUM
        st_divnum = Config::STORAGE_DIVNUM
      end
      if Config.const_defined? :STORAGE_OPTION
        st_option = Config::STORAGE_OPTION
      end

      path ||= './'
      st_class ||= Storage::RubyHashStorage
      st_divnum ||= 10
      st_option ||= nil
      Dir.glob("#{path}/*").each{|f|
        if File.directory?(f)
          hname = File.basename(f)
          st = st_class.new
          st.storage_path = "#{path}/#{hname}"
          st.vn_list = @rttable.vnodes
          st.divnum = st_divnum
          st.option = st_option
          @storages[hname] = st
        end
      }
      if @storages.length == 0
        hname = 'roma'
        st = st_class.new
        st.storage_path = "#{path}/#{hname}"
        st.vn_list = @rttable.vnodes
        st.divnum = st_divnum
        st.option = st_option
        @storages[hname] = st
      end
    end

    def initialize_rttable
      if @stats.join_ap
        initialize_rttable_join
      else
        fname = "#{Roma::Config::RTTABLE_PATH}/#{@stats.ap_str}.route"
        raise "#{fname} not found." unless File::exist?(fname)
        rd = Roma::Routing::RoutingData::load(fname)
        raise "It failed in loading the routing table data." unless rd
        @rttable = Roma::Routing::ChurnbasedRoutingTable.new(rd,fname)
      end
      
      @rttable.lost_action = Roma::Config::DEFAULT_LOST_ACTION
      @rttable.enabled_failover = @stats.start_with_failover
      @rttable.set_leave_proc{|nid|
        Roma::Messaging::ConPool.instance.close_same_host(nid)
        Roma::Event::EMConPool.instance.close_same_host(nid)
        Roma::AsyncProcess::queue.push(Roma::AsyncMessage.new('broadcast_cmd',["leave #{nid}",[@stats.ap_str,nid,5]]))
      }
      @rttable.set_lost_proc{
        if @rttable.lost_action == :shutdown
          async_broadcast_cmd("rbalse lose_data\r\n")
          EventMachine::stop_event_loop
          @log.error("Romad has stopped, so that lose data.")
        end
      }
    end

    def initialize_rttable_join
      name = async_send_cmd(@stats.join_ap,"whoami\r\n")
      unless name
        raise "No respons from #{@stats.join_ap}."
      end

      if name != @stats.name
        raise "#{@stats.join_ap} has diffarent name.\n" +
          "me = \"#{@stats.name}\"  #{@stats.join_ap} = \"#{name}\""
      end

      fname = "#{Roma::Config::RTTABLE_PATH}/#{@stats.ap_str}.route"
      if rd = get_routedump(@stats.join_ap)
        rd.save(fname)
      else
        raise "It failed in getting the routing table data from #{@stats.join_ap}."
      end

      if rd.nodes.include?(@stats.ap_str)
        raise "ROMA has already contained #{@stats.ap_str}."
      end

      @rttable = Roma::Routing::ChurnbasedRoutingTable.new(rd,fname)
      nodes = @rttable.nodes

      nodes.each{|nid|
        begin
          con = Roma::Messaging::ConPool.instance.get_connection(nid)
          con.write("join #{@stats.ap_str}\r\n")
          con.gets
          Roma::Messaging::ConPool.instance.return_connection(nid, con)
        rescue =>e
          raise "Hotscale initialize failed.\n#{nid} unreachabled."
        end
      }
      @rttable.add_node(@stats.ap_str)
    end

    def get_routedump(nid)
      con = Roma::Messaging::ConPool.instance.get_connection(nid)
      con.write("routingdump\r\n")
      len = con.gets
      if len.to_i <= 0
        con.close
        return nil
      end

      rcv=''
      while(rcv.length != len.to_i)
        rcv = rcv + con.read(len.to_i - rcv.length)
      end
      con.read(2)
      con.gets
      rd = Marshal.load(rcv)
      Roma::Messaging::ConPool.instance.return_connection(nid,con)
      rd
    rescue
      nil
    end

    def acquire_vnodes
      return if @stats.run_acquire_vnodes || @rttable.nodes.length < 2

      if @rttable.vnode_balance(@stats.ap_str)==:less
        Roma::AsyncProcess::queue.push(Roma::AsyncMessage.new('start_acquire_vnodes_process'))
      end
    end

    def timer
      Thread.new do
        loop do
          sleep 1
          timer_event_1sec
        end
      end
      Thread.new do
        loop do
          sleep 10
          timer_event_10sec
        end
      end
    end

    def timer_event_1sec
      if @rttable.enabled_failover
        nodes=@rttable.nodes
        nodes.delete(@stats.ap_str)
        nodes_check(nodes)
      end

      if (@stats.run_acquire_vnodes || @stats.run_recover) &&
          @stats.run_storage_clean_up
        @storages.each_value{|st| st.stop_clean_up}
        @log.info("stop a storage clean up process")
      end
    end

    def timer_event_10sec
      if @rttable.enabled_failover == false
        @log.debug("nodes_check start")
        nodes=@rttable.nodes
        nodes.delete(@stats.ap_str)
        if nodes_check(nodes)
          @log.info("all nodes started")
          @rttable.enabled_failover = true
        end
      else
        version_check
        @rttable.delete_old_trans
        start_sync_routing_process
      end

      if @stats.join_ap || @stats.enabled_vnodes_balance
        acquire_vnodes
      end

      if (@rttable.enabled_failover &&
          @stats.run_storage_clean_up == false &&
          @stats.run_acquire_vnodes == false &&
          @stats.run_recover == false &&
          @stats.run_iterate_storage == false)
        Roma::AsyncProcess::queue.push(Roma::AsyncMessage.new('start_storage_clean_up_process'))
      end

      @stats.clear_counters
    rescue =>e
      @log.error("#{e}\n#{$@}")
    end

    def nodes_check(nodes)
      nodes.each{|nid|
        return false unless node_check(nid)
      }
      return true
    end

    def node_check(nid)
      name = async_send_cmd(nid,"whoami\r\n",1)
      return false unless name
      if name != @stats.name
        @log.error("#{nid} has diffarent name.")
        @log.error("me = \"#{@stats.name}\"  #{nid} = \"#{name}\"")
        return false
      end
      return true
    end

    def version_check
      nodes=@rttable.nodes
      nodes.each{|nid|
        vs = async_send_cmd(nid,"version\r\n",1)
        next unless vs
        if /VERSION\s(\d+)\.(\d+)\.(\d+)/ =~ vs
          ver = ($1.to_i << 16) + ($2.to_i << 8) + $3.to_i
          @rttable.set_version(nid, ver)
        end
      }
    end

    def start_sync_routing_process
      return if @stats.run_acquire_vnodes || @stats.run_recover || @stats.run_sync_routing

      nodes = @rttable.nodes
      return if nodes.length <= 1

      @stats.run_sync_routing = true

      idx=nodes.index(@stats.ap_str)
      unless idx
        @log.error("My node-id(=#{@stats.ap_str}) dose not found in the routingtable.")
        EventMachine::stop_event_loop
        return
      end
      Thread.new{
        begin
          ret = routing_hash_comparison(nodes[idx-1])
          if ret == :inconsistent
            @log.info("create nodes from v_idx");

            @rttable.create_nodes_from_v_idx
            begin
              con = Roma::Messaging::ConPool.instance.get_connection(nodes[idx-1])
              con.write("create_nodes_from_v_idx\r\n")
              con.gets
              Roma::Messaging::ConPool.instance.return_connection(nodes[idx-1], con)
            rescue =>e
              @log.error("create_nodes_from_v_idx command unreachabled to the #{nodes[idx-1]}.")
            end
          end
        rescue =>e
          @log.error("#{e}\n#{$@}")
        end
        @stats.run_sync_routing = false
      }
    end    

    def routing_hash_comparison(nid,id='0')
      return :skip if @stats.run_acquire_vnodes || @stats.run_recover
      
      h = async_send_cmd(nid,"mklhash #{id}\r\n")
      if h && @rttable.mtree.get(id) != h
        if (id.length - 1) == @rttable.div_bits
          sync_routing(nid,id)
        else
          routing_hash_comparison(nid,"#{id}0")
          routing_hash_comparison(nid,"#{id}1")
        end
        return :inconsistent
      end
      :consistent
    end

    def sync_routing(nid,id)
      vn = @rttable.mtree.to_vn(id)
      @log.warn("vn=#{vn} inconsistent")
      
      res = async_send_cmd(nid,"getroute #{vn}\r\n")
      return unless res
      clk,*nids = res.split(/ /)
      clk = @rttable.set_route(vn, clk.to_i, nids)
      
      if clk.is_a?(Integer) == false
        clk,nids = @rttable.search_nodes_with_clk(vn)
        cmd = "setroute #{vn} #{clk-1}"
        nids.each{|nid2| cmd << " #{nid2}" }
        async_send_cmd(nid,"#{cmd}\r\n")
      end
    end

    def async_send_cmd(nid, cmd, tout=nil)
      res = nil
      if tout
        timeout(tout){
          con = Roma::Messaging::ConPool.instance.get_connection(nid)
          con.write(cmd)
          res = con.gets
          Roma::Messaging::ConPool.instance.return_connection(nid, con)
        }
      else
        con = Roma::Messaging::ConPool.instance.get_connection(nid)
        con.write(cmd)
        res = con.gets
        Roma::Messaging::ConPool.instance.return_connection(nid, con)
      end
      if res
        res.chomp!
        @rttable.proc_succeed(nid) if @rttable
      else
        @rttable.proc_failed(nid) if @rttable
      end
      res
    rescue => e
      @rttable.proc_failed(nid) if @rttable
      @log.error("#{__FILE__}:#{__LINE__}:Send command failed that node-id is #{nid},command is #{cmd}.")
      nil
    end

    def async_broadcast_cmd(cmd,without_nids=nil,tout=nil)
      without_nids=[@stats.ap_str] unless without_nids
      res = {}
      @rttable.nodes.each{ |nid|
        res[nid] = async_send_cmd(nid,cmd,tout) unless without_nids.include?(nid)
      }
      res
    rescue => e
      @log.error("#{e}\n#{$@}")
      nil
    end
    
    def stop
      @storages.each_value{|st|
        st.closedb
      }
      if @rttable.instance_of?(Roma::Routing::ChurnbasedRoutingTable)
        @rttable.close_log
      end
      @log.info("Romad has stopped: #{@stats.ap_str}")
    end

  end

  def self.daemon
    p = Process.fork {
      pid=Process.setsid
      Signal.trap(:INT){
        exit! 0
      }
      Signal.trap(:TERM){
        exit! 0       
      }
      Signal.trap(:HUP){
        exit! 0
      }
      File.open("/dev/null","r+"){|f|
        STDIN.reopen f
        STDOUT.reopen f
        STDERR.reopen f
      }
      yield
    }
    $stderr.puts p
    exit! 0
  end
end

$roma = Roma::Romad.new(ARGV)
if $roma.daemon?
  Roma::daemon{ $roma.start }
else
  $roma.start
end
