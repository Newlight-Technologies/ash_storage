defmodule AshStorage.AnalyzerScratch do
  @moduledoc false

  # Infrastructure only: callers own analyzer execution and result persistence.
  # Never expose uploaded bytes in a shared temporary directory.
  def with_file(bytes, callback, root \\ System.tmp_dir!())
      when is_binary(bytes) and is_function(callback, 1) do
    with {:ok, directory} <- create_directory(root, 4) do
      try do
        with :ok <- File.chmod(directory, 0o700) do
          write_and_run(Path.join(directory, "source"), bytes, callback)
        else
          {:error, _} -> scratch_failure()
        end
      after
        File.rmdir(directory)
      end
    end
  end

  defp write_and_run(path, bytes, callback) do
    case File.open(path, [:write, :binary, :exclusive]) do
      {:ok, file} ->
        try do
          with :ok <- File.chmod(path, 0o600),
               :ok <- IO.binwrite(file, bytes),
               :ok <- File.close(file) do
            callback.(path)
          else
            {:error, _} -> scratch_failure()
          end
        after
          File.close(file)
          File.rm(path)
        end

      {:error, _} ->
        scratch_failure()
    end
  end

  defp create_directory(_root, 0), do: scratch_failure()

  defp create_directory(root, attempts) do
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    directory = Path.join(root, "ash-storage-analyzer-" <> suffix)

    case File.mkdir(directory) do
      :ok -> {:ok, directory}
      {:error, :eexist} -> create_directory(root, attempts - 1)
      {:error, _} -> scratch_failure()
    end
  end

  defp scratch_failure do
    {:error, %AshStorage.Analyzer.Failure{code: :analyzer_scratch_unavailable, retryable?: true}}
  end
end
