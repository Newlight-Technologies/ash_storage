defmodule AshStorage.AnalyzerScratchTest do
  use ExUnit.Case, async: true

  alias AshStorage.AnalyzerScratch

  test "source and directory are private and removed after success" do
    assert {:ok, path} =
             AnalyzerScratch.with_file("private evidence", fn path ->
               assert File.read!(path) == "private evidence"
               assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
               assert Bitwise.band(File.stat!(Path.dirname(path)).mode, 0o777) == 0o700
               {:ok, path}
             end)

    refute File.exists?(path)
    refute File.exists?(Path.dirname(path))
  end

  test "analyzer errors preserve the reason and remove scratch" do
    assert {:error, {:unavailable, path}} =
             AnalyzerScratch.with_file("private evidence", fn path ->
               {:error, {:unavailable, path}}
             end)

    refute File.exists?(path)
    refute File.exists?(Path.dirname(path))
  end

  test "raised analyzer failures still remove owned scratch" do
    test_pid = self()

    assert_raise RuntimeError, "analyzer failed", fn ->
      AnalyzerScratch.with_file("private evidence", fn path ->
        send(test_pid, {:scratch, path})
        raise "analyzer failed"
      end)
    end

    assert_received {:scratch, path}
    refute File.exists?(path)
    refute File.exists?(Path.dirname(path))
  end
end
