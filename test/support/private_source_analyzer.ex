defmodule AshStorage.Test.PrivateSourceAnalyzer do
  @moduledoc false
  @behaviour AshStorage.Analyzer

  @impl true
  def accept?(_), do: true

  @impl true
  def analyze(path, _opts) do
    Process.put(__MODULE__, path)

    {:ok,
     %{
       "source_mode" => Bitwise.band(File.stat!(path).mode, 0o777),
       "directory_mode" => Bitwise.band(File.stat!(Path.dirname(path)).mode, 0o777),
       "source_sha256" => Base.encode16(:crypto.hash(:sha256, File.read!(path)))
     }}
  end
end
