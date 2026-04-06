defmodule Pincer.Core.Session.CommandQueueTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.Session.CommandQueue

  describe "new/1" do
    test "creates empty queue with default collect mode" do
      q = CommandQueue.new()
      assert q.mode == :collect
      assert CommandQueue.pending?(q) == false
    end

    test "creates queue with specified mode" do
      q = CommandQueue.new(:steer)
      assert q.mode == :steer
    end
  end

  describe "push/2 in collect mode" do
    test "buffers messages without flushing" do
      q = CommandQueue.new(:collect)

      {:ok, q} = CommandQueue.push(q, "hello")
      assert CommandQueue.pending?(q)

      {:ok, q} = CommandQueue.push(q, "world")
      assert CommandQueue.pending?(q)
    end

    test "drain returns all buffered messages" do
      q = CommandQueue.new(:collect)
      {:ok, q} = CommandQueue.push(q, "hello")
      {:ok, q} = CommandQueue.push(q, "world")

      {messages, q} = CommandQueue.drain(q)
      assert messages == ["hello", "world"]
      assert CommandQueue.pending?(q) == false
    end
  end

  describe "push/2 in steer mode" do
    test "flushes immediately even with single message" do
      q = CommandQueue.new(:steer)

      {:flush, messages, q} = CommandQueue.push(q, "steer this")
      assert messages == ["steer this"]
      assert CommandQueue.pending?(q) == false
    end

    test "flushes on every push" do
      q = CommandQueue.new(:steer)

      {:flush, m1, q} = CommandQueue.push(q, "first")
      assert m1 == ["first"]

      {:flush, m2, _q} = CommandQueue.push(q, "second")
      assert m2 == ["second"]
    end
  end

  describe "push/2 in followup mode" do
    test "holds messages until explicit drain" do
      q = CommandQueue.new(:followup)
      {:ok, q} = CommandQueue.push(q, "next task")

      assert CommandQueue.pending?(q)

      {messages, q} = CommandQueue.drain(q)
      assert messages == ["next task"]
      assert CommandQueue.pending?(q) == false
    end
  end

  describe "set_mode/2" do
    test "switches mode at runtime" do
      q = CommandQueue.new(:collect)
      {:ok, q} = CommandQueue.push(q, "buffered")

      q = CommandQueue.set_mode(q, :steer)
      assert q.mode == :steer

      {:flush, messages, _q} = CommandQueue.push(q, "steer msg")
      assert "buffered" in messages
      assert "steer msg" in messages
    end
  end

  describe "drain/1" do
    test "returns empty list when queue empty" do
      q = CommandQueue.new()
      {messages, _q} = CommandQueue.drain(q)
      assert messages == []
    end

    test "clears the queue" do
      q = CommandQueue.new(:collect)
      {:ok, q} = CommandQueue.push(q, "msg")
      {_, q} = CommandQueue.drain(q)

      assert CommandQueue.pending?(q) == false
    end
  end

  describe "join/1" do
    test "returns combined text of pending messages" do
      q = CommandQueue.new(:collect)
      {:ok, q} = CommandQueue.push(q, "hello")
      {:ok, q} = CommandQueue.push(q, "world")

      assert CommandQueue.join(q) == "hello\nworld"
    end

    test "returns empty string when empty" do
      q = CommandQueue.new()
      assert CommandQueue.join(q) == ""
    end
  end
end
