defmodule AshStorage.AnalyzerScratchTest do
  use ExUnit.Case, async: true

  alias AshStorage.AnalyzerScratch
  import ExUnit.CaptureLog

  @tag :tmp_dir
  test "cleanup failure is visible and does not delete analyzer-created files", %{tmp_dir: root} do
    test_pid = self()

    log =
      capture_log(fn ->
        assert {:error,
                %AshStorage.Analyzer.Failure{
                  code: :analyzer_scratch_cleanup_failed,
                  retryable?: false
                }} =
                 AnalyzerScratch.with_file(
                   "private evidence",
                   fn path ->
                     extra = Path.join(Path.dirname(path), "analyzer-owned")
                     File.write!(extra, "diagnostic")
                     send(test_pid, {:extra, extra, path})
                     {:ok, %{verdict: :clean}}
                   end,
                   root
                 )
      end)

    assert log =~ "scratch cleanup failed"
    refute log =~ "private evidence"
    assert_received {:extra, extra, source}
    assert File.read!(extra) == "diagnostic"
    refute File.exists?(source)
    File.rm!(extra)
    File.rmdir!(Path.dirname(extra))
  end

  @tag :tmp_dir
  test "unavailable scratch root fails safely without invoking analyzer", %{tmp_dir: root} do
    missing = Path.join(root, "missing/parent")

    assert {:error,
            %AshStorage.Analyzer.Failure{
              code: :analyzer_scratch_unavailable,
              retryable?: true
            }} =
             AnalyzerScratch.with_file(
               "private evidence",
               fn _ -> flunk("must not analyze") end,
               missing
             )

    assert File.ls!(root) == []
  end

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
