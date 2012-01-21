require File.join(File.dirname(__FILE__), 'setup')

class TestGet < MiniTest::Unit::TestCase

  def setup
    @mock = start_mock
  end

  def teardown
    stop_mock(@mock)
  end

  def test_trivial_get
    connection = Couchbase.new(:port => @mock.port)
    connection.set(test_id, "bar")
    val = connection.get(test_id)
    assert_equal "bar", val
  end

  def test_extended_get
    connection = Couchbase.new(:port => @mock.port)

    orig_cas = connection.set(test_id, "bar")
    val, flags, cas = connection.get(test_id, :extended => true)
    assert_equal "bar", val
    assert_equal 0x0, flags
    assert_equal orig_cas, cas

    orig_cas = connection.set(test_id, "bar", :flags => 0x1000)
    val, flags, cas = connection.get(test_id, :extended => true)
    assert_equal "bar", val
    assert_equal 0x1000, flags
    assert_equal orig_cas, cas
  end

  def test_multi_get
    connection = Couchbase.new(:port => @mock.port)

    connection.set(test_id(1), "foo1")
    connection.set(test_id(2), "foo2")

    val1, val2 = connection.get(test_id(1), test_id(2))
    assert_equal "foo1", val1
    assert_equal "foo2", val2
  end

  def test_multi_get_extended
    connection = Couchbase.new(:port => @mock.port)

    cas1 = connection.set(test_id(1), "foo1")
    cas2 = connection.set(test_id(2), "foo2")

    results = connection.get(test_id(1), test_id(2), :extended => true)
    assert_equal ["foo1", 0x0, cas1], results[test_id(1)]
    assert_equal ["foo2", 0x0, cas2], results[test_id(2)]
  end

  def test_missing_in_quiet_mode
    connection = Couchbase.new(:port => @mock.port)
    cas1 = connection.set(test_id(1), "foo1")
    cas2 = connection.set(test_id(2), "foo2")

    val = connection.get(test_id(:missing))
    refute(val)
    val = connection.get(test_id(:missing), :extended => true)
    refute(val)

    val1, missing, val2  = connection.get(test_id(1), test_id(:missing), test_id(2))
    assert_equal "foo1", val1
    refute missing
    assert_equal "foo2", val2

    results  = connection.get(test_id(1), test_id(:missing), test_id(2), :extended => true)
    assert_equal ["foo1", 0x0, cas1], results[test_id(1)]
    refute results[test_id(:missing)]
    assert_equal ["foo2", 0x0, cas2], results[test_id(2)]
  end

  def test_it_allows_temporary_quiet_flag
    connection = Couchbase.new(:port => @mock.port, :quiet => false)
    assert_raises(Couchbase::Error::NotFound) do
      connection.get(test_id(:missing))
    end
    refute connection.get(test_id(:missing), :quiet => true)
  end

  def test_missing_in_verbose_mode
    connection = Couchbase.new(:port => @mock.port, :quiet => false)
    connection.set(test_id(1), "foo1")
    connection.set(test_id(2), "foo2")

    assert_raises(Couchbase::Error::NotFound) do
      connection.get(test_id(:missing))
    end

    assert_raises(Couchbase::Error::NotFound) do
      connection.get(test_id(:missing), :extended => true)
    end

    assert_raises(Couchbase::Error::NotFound) do
      connection.get(test_id(1), test_id(:missing), test_id(2))
    end

    assert_raises(Couchbase::Error::NotFound) do
      connection.get(test_id(1), test_id(:missing), test_id(2), :extended => true)
    end
  end

  def test_asynchronous_get
    connection = Couchbase.new(:port => @mock.port)
    cas = connection.set(test_id, "foo", :flags => 0x6660)
    res = []

    suite = lambda do |conn|
      res.clear
      conn.get(test_id) # ignore result
      conn.get(test_id) {|v| res[1] = v}
      conn.get(test_id) {|v, k| res[2] = {:key => k, :value => v}}
      handler = lambda {|v, k| res[3] = {:key => k, :value => v}}
      conn.get(test_id, &handler)
      conn.get(test_id, :extended => true){|v, k, f, c| res[4] = {:value => v, :cas => c, :key => k, :flags => f}}
      assert_equal 5, conn.seqno
    end

    checks = lambda do
      assert_equal "foo", res[1]
      assert_equal "foo", res[2][:value]
      assert_equal test_id, res[2][:key]
      assert_equal "foo", res[3][:value]
      assert_equal test_id, res[3][:key]
      assert_equal "foo", res[4][:value]
      assert_equal test_id, res[4][:key]
      assert_equal 0x6660, res[4][:flags]
      assert_equal cas, res[4][:cas]
    end

    connection.run(&suite)
    checks.call

    connection.run{ suite.call(connection) }
    checks.call
  end

  def test_asynchronous_multi_get
    connection = Couchbase.new(:port => @mock.port)
    connection.set(test_id(1), "foo")
    connection.set(test_id(2), "bar")

    res = {}
    connection.run do |conn|
      conn.get(test_id(1), test_id(2)) {|v, k| res[k] = v}
      assert_equal 2, conn.seqno
    end

    assert res[test_id(1)]
    assert_equal "foo", res[test_id(1)]
    assert res[test_id(2)]
    assert_equal "bar", res[test_id(2)]
  end

  def test_asynchronous_get_missing
    connection = Couchbase.new(:port => @mock.port)
    connection.set(test_id, "foo")
    res = {}
    missing = []

    hit_handler = lambda {|v, k| res[k] = v}
    miss_handler = lambda do |opcode, key, err|
      assert_equal :get, opcode
      if err.is_a?(Couchbase::Error::NotFound)
        missing << key
      else
        raise err
      end
    end

    suite = lambda do |conn|
      res.clear
      missing.clear
      conn.get(test_id(:missing1), &hit_handler)
      conn.get(test_id, test_id(:missing2), &hit_handler)
      assert 3, conn.seqno
    end

    connection.run(&suite)
    assert_equal "foo", res[test_id]
    assert res.has_key?(test_id(:missing1)) # handler was called with nil
    refute res[test_id(:missing1)]
    assert res.has_key?(test_id(:missing2))
    refute res[test_id(:missing2)]
    assert_empty missing

    connection.quiet = false

    connection.on_error = miss_handler
    connection.run(&suite)
    refute res.has_key?(test_id(:missing1))
    refute res.has_key?(test_id(:missing2))
    assert_equal [test_id(:missing1), test_id(:missing2)], missing.sort
    assert_equal "foo", res[test_id]

    connection.on_error = nil
    assert_raises(Couchbase::Error::NotFound) do
      connection.run(&suite)
    end
  end

  def test_get_using_brackets
    connection = Couchbase.new(:port => @mock.port)

    orig_cas = connection.set(test_id, "foo", :flags => 0x1100)

    val = connection[test_id]
    assert_equal "foo", val

    if RUBY_VERSION =~ /^1\.9/
      eval <<-EOC
      val, flags, cas = connection[test_id, :extended => true]
      assert_equal "foo", val
      assert_equal 0x1100, flags
      assert_equal orig_cas, cas
      EOC
    end
  end
end
