defmodule Bobbin.NodeWaitTest do
  use ExUnit.Case, async: true

  test "waits for a call with a key, through success or timeout" do
    assert {:wait, wait} = Bobbin.Node.wait_for_call("ask/1")

    assert wait == %{
             "call" => true,
             "key" => "ask/1",
             "outputs" => %{"call" => "success", "timeout" => "timeout"}
           }
  end

  test "a time limit says when it ends, and outputs can be named" do
    assert {:wait, %{"resume_at" => at, "outputs" => outputs}} =
             Bobbin.Node.wait_for_call("ask/1",
               timeout: 60,
               output: :replied,
               timeout_output: "late"
             )

    assert {:ok, at, 0} = DateTime.from_iso8601(at)
    assert DateTime.diff(at, DateTime.utc_now()) in 58..60
    assert outputs == %{"call" => "replied", "timeout" => "late"}
  end

  test "again calls the handler back, with the data kept in the wait" do
    assert {:wait, wait} = Bobbin.Node.wait_for_call("ask/1", again: true, data: %{"n" => 1})
    assert wait["again"] == true
    assert wait["data"] == %{"n" => 1}

    assert {:wait, plain} = Bobbin.Node.wait_for_call("ask/1", again: false)
    refute Map.has_key?(plain, "again")
    refute Map.has_key?(plain, "data")
  end

  test "waits for a person's approval, with what to approve" do
    assert {:wait, wait} =
             Bobbin.Node.wait_for_approval("Refund R$ 50?", details: "Order 12", again: true)

    assert wait["call"] == true
    assert wait["approval"] == %{"title" => "Refund R$ 50?", "details" => "Order 12"}
    assert wait["again"] == true
    refute Map.has_key?(wait, "key")
  end
end
