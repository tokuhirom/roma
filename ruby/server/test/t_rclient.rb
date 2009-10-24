#!/usr/bin/env ruby
# -*- coding: utf-8 -*-
require 'test/unit'
require 'shell'

path =  File.dirname(File.expand_path($PROGRAM_NAME))
$LOAD_PATH << path + "/../lib"
$LOAD_PATH << path  + "/../../commons/lib"
$LOAD_PATH << path  + "/../../client/lib"

require 'roma/client/rclient'

MiniTest::Unit.class_eval{
  alias run2 run

  def run args = []
    start_roma
    run2 args
    stop_roma
  end

  def start_roma
    path =  File.dirname(File.expand_path($PROGRAM_NAME))
    sh = Shell.new
    sh.transact do
      Dir.glob("localhost_1121?.*").each{|f| rm f }
    end
    rm_rf("localhost_11211")
    rm_rf("localhost_11212")
    sleep 1

    sh.system("ruby","#{path}/../bin/mkroute",
              "localhost_11211","localhost_11212",
              "-d","3",
              "--enabled_repeathost")
    sleep 1
    sh.system("ruby","#{path}/../bin/romad","localhost","-p","11211","-d","--verbose")
    sh.system("ruby","#{path}/../bin/romad","localhost","-p","11212","-d","--verbose")
    sleep 2
  end

  # looked like a "rm -rf" command
  def rm_rf(fname)
    return unless File::exist?(fname)
    if File::directory?(fname)
      Dir["#{fname}/*"].each{|f| rm_rf(f) }
      Dir.rmdir(fname)
    else

      File.delete(fname)
    end
  end

  def stop_roma
    conn = Roma::Messaging::ConPool.instance.get_connection("localhost_11211")
    if conn
      conn.write "balse\r\n"
      conn.gets
      conn.write "yes\r\n"
      conn.gets
      conn.close
    end
  rescue =>e
    puts "#{e} #{$@}"
  end
}

Roma::Client::RomaClient.class_eval{
  def init_sync_routing_proc
  end
}

class RClientTest < Test::Unit::TestCase

  def setup
    @rc=Roma::Client::RomaClient.new(["localhost_11211","localhost_11212"])
  end

  def teardown
  end

  def test_set_get_delete
    puts "#{self.class} #{__method__}"
    @rc.delete("abc")
    assert_nil( @rc.get("abc") )
    assert_equal("STORED", @rc.set("abc","value abc"))
    assert_equal("value abc", @rc.get("abc"))
    assert_equal("STORED", @rc.set("abc","value abc")) # 上書きは成功する
    assert_equal("DELETED", @rc.delete("abc"))
    assert_nil( @rc.get("abc"))
    assert_equal("NOT_FOUND", @rc.delete("abc"))
  end

  def test_set_get
    puts "#{self.class} #{__method__}"
    10.times{|i|
      s = i.to_s * 1024000
      assert_equal("STORED", @rc.set("abc", s))
      assert(s == @rc.get("abc"))
   }
  end

  def test_out
    puts "#{self.class} #{__method__}"
    # 本当に消す
    @rc.out("key-out")
    # 本当にない場合は NOT_DELETED
    assert_equal("NOT_DELETED", @rc.out("key-out"))
    assert_equal("STORED", @rc.set("key-out","value out"))
    assert_equal("DELETED", @rc.out("key-out"))
    assert_equal("STORED", @rc.set("key-out","value out"))
    # 削除マークをつける
    assert_equal("DELETED", @rc.delete("key-out"))
    # delete してもマークを消すので DELETED
    assert_equal("DELETED", @rc.out("key-out"))
  end

  def test_add
    puts "#{self.class} #{__method__}"
    assert_nil( @rc.get("add") )
    assert_equal("STORED", @rc.add("add","value add"))
    assert_equal("NOT_STORED", @rc.add("add","value add")) # 上書きは失敗する
    assert_equal("DELETED", @rc.delete("add"))
    assert_equal("STORED", @rc.add("add","value add")) # delete 後の add の成功を確認
    assert_equal("DELETED", @rc.delete("add"))
  end

  def test_replace
    puts "#{self.class} #{__method__}"
    assert_nil( @rc.get("replace") )
    assert_equal("NOT_STORED", @rc.replace("replace","value replace"))
    assert_nil( @rc.get("replace") )
    assert_equal("STORED", @rc.add("replace","value add"))
    assert_equal("STORED", @rc.replace("replace","value replace"))
    assert_equal("DELETED", @rc.delete("replace"))
  end

  def test_append
    puts "#{self.class} #{__method__}"
    assert_nil( @rc.get("append") )
    assert_equal("NOT_STORED", @rc.append("append","append"))
    assert_equal("STORED", @rc.set("append","set"))
    assert_equal("set", @rc.get("append"))
    assert_equal("STORED", @rc.append("append","append"))
    assert_equal("setappend", @rc.get("append"))
    assert_equal("DELETED", @rc.delete("append"))
  end

  def test_prepend
    puts "#{self.class} #{__method__}"
    assert_nil( @rc.get("prepend"))
    assert_equal("NOT_STORED", @rc.prepend("prepend","prepend"))
    assert_equal("STORED", @rc.set("prepend","set"))
    assert_equal("set", @rc.get("prepend"))
    assert_equal("STORED", @rc.prepend("prepend","prepend"))
    assert_equal("prependset", @rc.get("prepend"))
    assert_equal("DELETED", @rc.delete("prepend"))
  end

  def test_incr
    puts "#{self.class} #{__method__}"
    assert_nil( @rc.get("incr"))
    assert_equal("NOT_FOUND", @rc.incr("incr"))
    assert_equal("STORED", @rc.set("incr","100"))
    assert_equal(101, @rc.incr("incr"))
    assert_equal(102, @rc.incr("incr"))
    assert_equal("DELETED", @rc.delete("incr"))
  end

  def test_decr
    puts "#{self.class} #{__method__}"
    assert_nil( @rc.get("decr") )
    assert_equal("NOT_FOUND", @rc.decr("decr"))
    assert_equal("STORED", @rc.set("decr","100"))
    assert_equal(99, @rc.decr("decr"))
    assert_equal(98, @rc.decr("decr"))
    assert_equal("DELETED", @rc.delete("decr"))
  end

  def test_createhash
    puts "#{self.class} #{__method__}"
    con = Roma::Messaging::ConPool.instance.get_connection("localhost_11211")
    con.write("hashlist\r\n")
    ret = con.gets
    assert_equal("roma", ret.chomp )

    con.write("createhash test\r\n")
    ret = con.gets
    assert_equal("{\"localhost_11212\"=>\"CREATED\", \"localhost_11211\"=>\"CREATED\"}", ret.chomp )

    con.write("hashlist\r\n")
    ret = con.gets
    assert_equal("roma test", ret.chomp )

    assert_equal("STORED", @rc.set("roma","hname=roma"))
    assert_equal("hname=roma", @rc.get("roma"))
    @rc.default_hash_name='test'
    assert_nil( @rc.get("roma") )
    assert_equal("STORED", @rc.set("roma","hname=test"))
    assert_equal("hname=test", @rc.get("roma"))
    @rc.default_hash_name='roma'
    assert_equal("hname=roma", @rc.get("roma"))
    assert_equal("DELETED", @rc.delete("roma"))

    @rc.default_hash_name='not_exist_hash' # 存在しないハッシュへのアクセス
    begin
      @rc.get("roma")
      assert(false)
    rescue =>e
      assert_equal('SERVER_ERROR not_exist_hash dose not exists.',e.message)
    end

    begin
      @rc.set("roma","hname=roma")
      assert(false)
    rescue =>e
      assert_equal('SERVER_ERROR not_exist_hash dose not exists.',e.message)
    end

    begin
      @rc.delete("roma")
      assert(false)
    rescue =>e
      assert_equal('SERVER_ERROR not_exist_hash dose not exists.',e.message)
    end

    begin
      @rc.add("add","value add")
      assert(false)
    rescue =>e
      assert_equal('SERVER_ERROR not_exist_hash dose not exists.',e.message)
    end

    begin
      @rc.replace("replace","value replace")
      assert(false)
    rescue =>e
      assert_equal('SERVER_ERROR not_exist_hash dose not exists.',e.message)
    end

    begin
      @rc.append("append","append")
      assert(false)
    rescue =>e
      assert_equal('SERVER_ERROR not_exist_hash dose not exists.', e.message)
    end

    begin
      @rc.prepend("prepend","prepend")
      assert(false)
    rescue =>e
      assert_equal('SERVER_ERROR not_exist_hash dose not exists.',e.message)
    end

    begin
      @rc.incr("incr")
      assert(false)
    rescue =>e
      assert_equal('SERVER_ERROR not_exist_hash dose not exists.',e.message)
    end

    begin
      @rc.decr("decr")
      assert(false)
    rescue =>e
      assert_equal('SERVER_ERROR not_exist_hash dose not exists.',e.message)
    end

    con.write("deletehash test\r\n")
    ret = con.gets
    assert_equal( "{\"localhost_11212\"=>\"DELETED\", \"localhost_11211\"=>\"DELETED\"}", ret.chomp  )

    con.close
  end

  def test_createhash2
    puts "#{self.class} #{__method__}"
    # test ハッシュを追加し終了する
    con = Roma::Messaging::ConPool.instance.get_connection("localhost_11211")
    con.write("hashlist\r\n")
    ret = con.gets
    assert_equal("roma", ret.chomp)

    con.write("createhash test\r\n")
    ret = con.gets
#p ret
    assert_equal("{\"localhost_11212\"=>\"CREATED\", \"localhost_11211\"=>\"CREATED\"}", ret.chomp  )

    assert_equal("STORED", @rc.set("roma","hname=roma"))
    assert_equal("hname=roma", @rc.get("roma"))
    @rc.default_hash_name='test'
    assert_equal("STORED", @rc.set("roma","hname=test"))
    assert_equal("hname=test", @rc.get("roma"))
    con.write("balse\r\n")
    con.gets
    con.write "yes\r\n"
    ret = con.gets
    con.close


    # 再起動
    path =  File.dirname(File.expand_path($PROGRAM_NAME))
    sh = Shell.new
    sh.system("ruby","#{path}/../bin/romad","localhost","-p","11211","-d","--verbose")
    sh.system("ruby","#{path}/../bin/romad","localhost","-p","11212","-d","--verbose")
    sleep 2
    Roma::Messaging::ConPool.instance.close_all

    @rc=Roma::Client::RomaClient.new(["localhost_11211","localhost_11212"])
    @rc.default_hash_name='test'
    con = Roma::Messaging::ConPool.instance.get_connection("localhost_11211")
    con.write("hashlist\r\n")
    ret = con.gets
#p ret

    # 停止前のデータが残っていることを確認
#p @rc.get("roma")
    assert_equal("hname=test", @rc.get("roma"))

    # test ハッシュを削除
    con.write("deletehash test\r\n")
    ret = con.gets
#p ret
    assert_equal("{\"localhost_11212\"=>\"DELETED\", \"localhost_11211\"=>\"DELETED\"}", ret.chomp )
    
    # デフォルトハッシュに残ったテストデータを削除
    @rc.default_hash_name='roma'
    assert_equal('DELETED', @rc.delete("roma"))

  #rescue =>e
    #p e
  end
  
  def test_createhash3
    puts "#{self.class} #{__method__}"
    con = Roma::Messaging::ConPool.instance.get_connection("localhost_11211")

    # 存在しないハッシュを削除
    con.write("deletehash test\r\n")
    ret = con.gets
    assert_equal("{\"localhost_11212\"=>\"SERVER_ERROR test dose not exists.\", \"localhost_11211\"=>\"SERVER_ERROR test dose not exists.\"}", ret.chomp )
    
    # デフォルトハッシュを削除
    con.write("deletehash roma\r\n")
    ret = con.gets
    assert_equal("{\"localhost_11212\"=>\"SERVER_ERROR the hash name of 'roma' can't delete.\", \"localhost_11211\"=>\"SERVER_ERROR the hash name of 'roma' can't delete.\"}", ret.chomp )
  end
end

class RClientTestForceForward < RClientTest
  def setup
    @rc=Roma::Client::RomaClient.new(["localhost_11211","localhost_11212"])
    @rc.rttable.instance_eval{
      undef search_node

      def search_node(key); search_node2(key); end

      def search_node2(key)
        d = Digest::SHA1.hexdigest(key).hex % @hbits
        @rd.v_idx[d & @search_mask][1]
      end
    }
  end  

end
