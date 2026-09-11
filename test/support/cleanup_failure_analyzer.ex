defmodule AshStorage.Test.CleanupFailureAnalyzer do
  @moduledoc false
  @behaviour AshStorage.Analyzer

  def accept?(_), do: true

  def analyze(path, opts) do
    extra = Path.join(Path.dirname(path), "analyzer-owned")
    File.write!(extra, "test artifact")
    Process.put({__MODULE__, Keyword.fetch!(opts, :test_key)}, extra)
    {:ok, %{"should_not_persist" => true}}
  end
end
